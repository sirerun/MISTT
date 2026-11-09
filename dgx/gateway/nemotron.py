"""Opt-in fixed-pin RNNT steps: independent source state, no generate threads."""
from __future__ import annotations

from dataclasses import dataclass, field
import importlib.metadata
import threading
from pathlib import Path
from typing import Any, Callable

import numpy as np

MODEL_ID = 'nvidia/nemotron-3.5-asr-streaming-0.6b'
MODEL_REVISION = 'ea30d66debe3740a08b573244286791d423d6b3e'
SOURCE_COMMIT = '6af945f436d85f2b0c5dff9b14feccd27b1d470b'
MAX_LABELS = 4096
MAX_TEXT_BYTES = 32768
MAX_STEPS = 16384


@dataclass(frozen=True)
class NemotronGeometry:
    sample_rate: int = 16000
    chunk_samples: int = 8960
    lookahead_samples: int = 7680  # six encoder frames, not STFT overlap
    speech_token_samples: int = 1280
    max_context_tokens: int = 57  # actual bounded encoder cache slots
    prompt_tokens: int = 0  # language conditioning is not decoder KV text
    first_samples: int = 7880
    first_next_start: int = 7584
    window_samples: int = 9360
    reserved_tokens_per_window: int = 0  # recurrent/sliding cache does not grow per window


@dataclass
class StepState:
    encoder_cache: Any = None
    padding_cache: Any = None
    decoder_cache: Any = None
    prompt_ids: Any = None
    last_token: int = 13087
    token_ids: list[int] = field(default_factory=list)
    first: bool = True
    steps: int = 0
    closed: bool = False
    failed: bool = False
    lock: Any = field(default_factory=threading.RLock, repr=False)
    trace: list[int] | None = None  # qualification only; never persisted


class StepEngine:
    """One finite encoded chunk; the gateway owns global serial scheduling."""
    def __init__(self, backend: Any):
        self.backend = backend

    def new_state(self, *, trace: bool = False) -> StepState:
        return StepState(decoder_cache=self.backend.new_decoder_cache(), last_token=self.backend.blank_id,
                         trace=[self.backend.blank_id] if trace else None)

    def step(self, state: StepState, audio: np.ndarray,
             observer: Callable[[list[int], str], None] | None = None) -> str:
        with state.lock:
            if state.closed or state.failed:
                raise RuntimeError('rnnt_state_unavailable')
            try:
                encoded = self.backend.encode(audio, state)
                state.first = False
                frames = self.backend.frame_count(encoded)
                if not 0 < frames <= 8:
                    raise RuntimeError('rnnt_encoder_frame_bound')
                for frame in range(frames):
                    symbols = 0
                    while True:
                        if state.steps >= MAX_STEPS:
                            raise RuntimeError('rnnt_step_bound')
                        token = self.backend.predict(encoded, frame, state.last_token, state.decoder_cache)
                        state.steps += 1
                        # Persist blank too: the pinned decoder reuses its cache on blank INPUT.
                        # Keeping the previous nonblank would consume that label twice next frame.
                        state.last_token = token
                        if state.trace is not None:
                            state.trace.append(token)
                        if token == self.backend.blank_id:
                            break
                        if len(state.token_ids) >= MAX_LABELS:
                            raise RuntimeError('rnnt_label_bound')
                        state.token_ids.append(token)
                        text = self.backend.decode(state.token_ids)
                        if len(text.encode('utf-8')) > MAX_TEXT_BYTES:
                            raise RuntimeError('rnnt_text_bound')
                        if observer is not None:
                            observer(state.token_ids, text)
                        symbols += 1
                        if symbols >= self.backend.max_symbols:
                            break
                if self.backend.cache_slots(state) > 57:
                    raise RuntimeError('rnnt_cache_bound')
                return self.backend.decode(state.token_ids)
            except BaseException:
                state.failed = True
                raise

    def release(self, state: StepState) -> None:
        with state.lock:  # joins a late blocking step before any tensor is cleared
            state.closed = True
            state.encoder_cache = state.padding_cache = state.decoder_cache = state.prompt_ids = None
            state.token_ids.clear()
            if state.trace is not None:
                state.trace.clear()


class TransformersBackend:
    """Pinned public forward/encoder APIs; no GenerationMixin mutable globals."""
    blank_id = 13087
    max_symbols = 10

    def __init__(self, cache: Path):
        if importlib.metadata.version('transformers') != '5.13.0':
            raise RuntimeError('rnnt_transformers_pin_mismatch')
        import torch
        from transformers import AutoModelForRNNT, AutoProcessor
        from transformers.models.nemotron3_5_asr.generation_nemotron3_5_asr import Nemotron3_5AsrRNNTDecoderCache
        from transformers.models.nemotron_asr_streaming.modeling_nemotron_asr_streaming import NemotronAsrStreamingEncoderModelOutput
        torch.set_num_threads(2)
        torch.cuda.set_per_process_memory_fraction(0.05, 0)
        self.torch = torch
        self.cache_class = Nemotron3_5AsrRNNTDecoderCache
        self.output_class = NemotronAsrStreamingEncoderModelOutput
        self.processor = AutoProcessor.from_pretrained(MODEL_ID, revision=MODEL_REVISION, cache_dir=str(cache),
                                                       local_files_only=True, trust_remote_code=False)
        self.processor.set_num_lookahead_tokens(6)
        p = self.processor
        if (p.feature_extractor.sampling_rate, p.num_samples_first_audio_chunk, p.num_samples_per_audio_chunk,
                p.num_mel_frames_first_audio_chunk, p.num_mel_frames_per_audio_chunk,
                p.feature_extractor.hop_length, p.feature_extractor.n_fft) != (16000, 7880, 9360, 49, 56, 160, 512):
            raise RuntimeError('rnnt_processor_geometry_mismatch')
        self.model = None
        try:
            self.model = AutoModelForRNNT.from_pretrained(MODEL_ID, revision=MODEL_REVISION, cache_dir=str(cache),
                                                         local_files_only=True, trust_remote_code=False,
                                                         torch_dtype=torch.float32).to('cuda:0').eval()
            c = self.model.config
            if (c.blank_token_id, c.max_symbols_per_step, c.encoder_config.sliding_window,
                    c.encoder_config.num_hidden_layers, c.num_decoder_layers, c.decoder_hidden_size) != (13087, 10, 57, 24, 2, 640):
                raise RuntimeError('rnnt_model_geometry_mismatch')
        except BaseException:
            self.model = None
            torch.cuda.empty_cache()
            raise

    def new_decoder_cache(self):
        return self.cache_class(self.model.config)

    def encode(self, audio: np.ndarray, state: StepState):
        expected = 7880 if state.first else 9360
        if audio.shape != (expected,) or not np.isfinite(audio).all():
            raise ValueError('rnnt_audio_geometry_invalid')
        inputs = self.processor(audio, sampling_rate=16000, is_streaming=True,
                                is_first_audio_chunk=state.first, language='en-US', return_tensors='pt')
        inputs = inputs.to(self.model.device, dtype=self.model.dtype)
        features = inputs.input_features[:, :49, :] if state.first else inputs.input_features
        if features.shape[1] != (49 if state.first else 56):
            raise RuntimeError('rnnt_feature_geometry_invalid')
        if state.prompt_ids is None:
            state.prompt_ids = inputs.prompt_ids
        with self.torch.inference_mode():
            output = self.model.get_audio_features(input_features=features, past_key_values=state.encoder_cache,
                                                   padding_cache=state.padding_cache, use_cache=True,
                                                   num_lookahead_tokens=6, prompt_ids=state.prompt_ids,
                                                   output_attention_mask=False)
        state.encoder_cache, state.padding_cache = output.past_key_values, output.padding_cache
        return output.pooler_output

    def frame_count(self, encoded):
        return encoded.shape[1]

    def predict(self, encoded, frame, last_token, cache):
        torch = self.torch
        token = torch.tensor([[last_token]], dtype=torch.long, device=self.model.device)
        one_frame = self.output_class(pooler_output=encoded[:, frame:frame + 1, :])
        with torch.inference_mode():
            output = self.model(encoder_outputs=one_frame, decoder_input_ids=token, decoder_cache=cache)
        if output.logits.shape != (1, 1, 13088) or not bool(torch.isfinite(output.logits).all().item()):
            raise RuntimeError('rnnt_logits_invalid')
        if output.decoder_cache is not cache:
            raise RuntimeError('rnnt_decoder_cache_identity_changed')
        return int(output.logits[0, 0].argmax().item())

    def decode(self, tokens):
        return self.processor.tokenizer.decode(tokens, skip_special_tokens=True)

    def cache_slots(self, state):
        cache = state.encoder_cache
        if cache is None:
            return 0
        layers = getattr(cache, 'layers', None)
        if not layers:
            raise RuntimeError('rnnt_encoder_cache_shape_invalid')
        sizes = [layer.keys.shape[-2] for layer in layers if getattr(layer, 'keys', None) is not None]
        if len(sizes) != 24:
            raise RuntimeError('rnnt_encoder_cache_layers_invalid')
        return max(sizes)


class NemotronRuntime:
    geometry = NemotronGeometry()
    transcript_mode = 'snapshot'

    def __init__(self, settings):
        if (settings.model_id, settings.model_revision, settings.source_commit) != (MODEL_ID, MODEL_REVISION, SOURCE_COMMIT):
            raise ValueError('rnnt_identity_mismatch')
        cache = Path(settings.nemotron_cache_directory)
        if not cache.is_absolute() or cache.resolve() != cache or not cache.is_dir():
            raise ValueError('rnnt_public_cache_unavailable')
        self.backend = TransformersBackend(cache)
        self.engine = StepEngine(self.backend)

    def new_state(self):
        return self.engine.new_state()

    def transcribe_window(self, state, audio):
        return self.engine.step(state, audio)

    def release_state(self, state):
        self.engine.release(state)

    def context_tokens(self, state):
        return self.backend.cache_slots(state)

    def source_context(self, source, ledger, state):
        return NemotronSourceContext(source=source, ledger=ledger, state=state)

    def close(self):
        self.backend.model = None
        self.backend.torch.cuda.empty_cache()


@dataclass
class NemotronSourceContext:
    source: str
    ledger: Any
    state: StepState
    geometry: NemotronGeometry = field(default_factory=NemotronGeometry)
    prompt_tokens: int = 0
    base_context_tokens: int = 57  # reserve fixed encoder capacity, not a growing KV cache
    max_context_tokens: int = 57
    model_audio: np.ndarray = field(default_factory=lambda: np.empty(0, dtype=np.float32))
    resampler_output_samples: int = 0
    distinct_window_samples: int = 0
    final_tail_geometry: Any = None
    windows_enqueued: int = 0
    transcript: str = ''
    event_sequence: int = 0
    ended: bool = False
    completed: bool = False
    _reserved_windows: int = 0
    _buffer_start: int = 0
    _next_start: int = 0
    _next_end: int = 7880
    _highwater: int = 0

    @property
    def source_samples(self):
        return self.ledger.total_samples

    def reserve_for_input(self, source_samples, aggregate_context_tokens, aggregate_limit):
        from .protocol import ProtocolError
        if self.base_context_tokens > self.max_context_tokens or aggregate_context_tokens > aggregate_limit:
            raise ProtocolError('context_limit')
        full = 0 if source_samples < 7880 else 1 + max(0, (source_samples - 16944) // 8960 + 1)
        self._reserved_windows = full + (1 if source_samples else 0)
        return self._reserved_windows

    def _job(self, padded=False):
        from .pair import WindowJob
        size = 7880 if self.windows_enqueued == 0 else 9360
        start = self._next_start - self._buffer_start
        valid = min(size, len(self.model_audio) - start)
        audio = np.zeros(size, dtype=np.float32)
        audio[:valid] = self.model_audio[start:start + valid]
        end = min(self._next_start + valid, self.source_samples)
        overlap = max(0, min(valid, self._highwater - self._next_start))
        distinct = max(0, end - self._highwater)
        self._highwater = max(self._highwater, end)
        self.distinct_window_samples += distinct
        self.windows_enqueued += 1
        job = WindowJob(audio, end, valid, overlap, distinct, size - valid)
        if padded:
            self.final_tail_geometry = {'emitted':True,'valid_input_samples':valid,'overlap_samples':overlap,
                                        'distinct_samples':distinct,'padded_samples':size-valid}
        self._next_start = 7584 if self.windows_enqueued == 1 else self._next_start + 8960
        self._next_end = self._next_start + 9360
        trim = min(max(0, self._next_start - self._buffer_start), len(self.model_audio))
        self.model_audio = self.model_audio[trim:]
        self._buffer_start += trim
        return job

    def push_frame(self, frame):
        self.ledger.accept(frame)
        pcm = np.frombuffer(frame.pcm, dtype='<i2').astype(np.float32) / 32768
        self.model_audio = np.concatenate((self.model_audio, pcm))
        self.resampler_output_samples += len(pcm)  # identity16k transport; no synthetic resampling
        jobs = []
        while self.source_samples >= self._next_end:
            jobs.append(self._job())
        return jobs

    def finish_input(self):
        from .protocol import ProtocolError
        if self.ended:
            raise ProtocolError('invalid_config')
        self.ended = True
        if not self.source_samples:
            self.final_tail_geometry = {'emitted':False,'valid_input_samples':0,'overlap_samples':0,'distinct_samples':0,'padded_samples':0}
            return []
        return [self._job(padded=True)]
