from __future__ import annotations

import math
import json
from pathlib import Path
from dataclasses import dataclass
from typing import Any, Protocol

import numpy as np

from .config import GatewaySettings, MAX_NEW_TOKENS_PER_WINDOW


PROMPT = (
    "You are a helpful assistant that transcribes audio input into text output. "
    "Please transcribe the following audios streamingly with these keys: speaker, content\n"
)


@dataclass(frozen=True)
class ModelGeometry:
    sample_rate: int
    chunk_samples: int
    lookahead_samples: int
    speech_token_samples: int
    max_context_tokens: int
    prompt_tokens: int

    @property
    def window_samples(self) -> int:
        return self.chunk_samples + self.lookahead_samples

    @property
    def reserved_tokens_per_window(self) -> int:
        # Audio positions, speech boundary markers, the upstream per-window
        # generation cap, and its mandatory <|text_chunk_end|> cache entry.
        return math.ceil(self.window_samples / self.speech_token_samples) + 2 + MAX_NEW_TOKENS_PER_WINDOW + 1


def geometry_from_metadata(preprocessor: dict[str, Any], model_config: dict[str, Any], prompt_tokens: int) -> ModelGeometry:
    decoder = model_config.get("decoder_config", {})
    max_context = decoder.get("max_position_embeddings", model_config.get("max_position_embeddings"))
    sample_rate = preprocessor.get("target_sample_rate")
    compress_ratio = preprocessor.get("speech_tok_compress_ratio")
    chunk_frames = preprocessor.get("chunk_frames")
    lookahead_frames = preprocessor.get("lookahead_frames")
    if not all(isinstance(value, int) and value > 0 for value in
               (max_context, sample_rate, compress_ratio, chunk_frames)):
        raise RuntimeError("pinned checkpoint is missing valid streaming geometry or context metadata")
    if not isinstance(lookahead_frames, int) or lookahead_frames < 0:
        raise RuntimeError("pinned checkpoint is missing valid lookahead metadata")
    if sample_rate != 24_000 or prompt_tokens < 1:
        raise RuntimeError("pinned checkpoint is not the supported streaming ASR model")
    return ModelGeometry(
        sample_rate=sample_rate,
        chunk_samples=chunk_frames * compress_ratio,
        lookahead_samples=lookahead_frames * compress_ratio,
        speech_token_samples=compress_ratio,
        max_context_tokens=max_context,
        prompt_tokens=prompt_tokens,
    )


def cached_context_tokens(state: Any) -> int:
    """Read the actual KV cache length returned by the pinned upstream model."""
    if not isinstance(state, dict) or "past_key_values" not in state:
        raise RuntimeError("streaming state has no KV cache")
    cache = state["past_key_values"]
    get_seq_length = getattr(cache, "get_seq_length", None)
    if callable(get_seq_length):
        length = get_seq_length()
        if isinstance(length, int) and length >= 0:
            return length
    if isinstance(cache, (tuple, list)) and cache:
        layer = cache[0]
        if isinstance(layer, (tuple, list)) and layer:
            key = layer[0]
            shape = getattr(key, "shape", ())
            if len(shape) >= 3:
                return int(shape[-2])
    raise RuntimeError("streaming state has an unsupported KV cache shape")


class StreamingRuntime(Protocol):
    geometry: ModelGeometry

    def new_state(self) -> Any: ...

    def transcribe_window(self, state: Any, audio: np.ndarray) -> str: ...

    def release_state(self, state: Any) -> None: ...

    def close(self) -> None: ...


class VibeVoiceRuntime:
    """Loads only the source/checkpoint pair pinned for the production gateway."""

    def __init__(self, settings: GatewaySettings) -> None:
        if settings.model_id != GatewaySettings.__dataclass_fields__["model_id"].default:
            raise ValueError("model identity is fixed by the gateway")
        if settings.model_revision != GatewaySettings.__dataclass_fields__["model_revision"].default:
            raise ValueError("model revision is fixed by the gateway")
        if settings.source_commit != GatewaySettings.__dataclass_fields__["source_commit"].default:
            raise ValueError("source revision is fixed by the gateway")

        import torch
        from huggingface_hub import snapshot_download
        from vibevoice.modular.modeling_vibevoice_asr import VibeVoiceASRForConditionalGeneration
        from vibevoice.processor.vibevoice_asr_processor import VibeVoiceASRProcessor

        revision = settings.model_revision
        model_path = Path(snapshot_download(repo_id=settings.model_id, revision=revision))
        processor = VibeVoiceASRProcessor.from_pretrained(str(model_path), local_files_only=True)
        tokenizer = processor.tokenizer
        with (model_path / "preprocessor_config.json").open(encoding="utf-8") as config_file:
            preprocessor = json.load(config_file)
        with (model_path / "config.json").open(encoding="utf-8") as config_file:
            model_config = json.load(config_file)
        self.geometry = geometry_from_metadata(
            preprocessor,
            model_config,
            prompt_tokens=len(tokenizer.encode(PROMPT, add_special_tokens=False)),
        )
        if getattr(tokenizer, "text_chunk_end_id", None) is None:
            raise RuntimeError("pinned checkpoint is not the supported streaming ASR model")
        self._torch = torch
        self._tokenizer = tokenizer
        self._model = VibeVoiceASRForConditionalGeneration.from_pretrained(
            str(model_path),
            local_files_only=True,
            dtype=torch.bfloat16,
            device_map="cuda:0",
            attn_implementation="sdpa",
        ).eval()

    def new_state(self) -> Any:
        return self._model.init_streaming_state(self._tokenizer)

    def release_state(self, state: Any) -> None:
        # Streaming states own per-source KV caches. Drop the entire mutable
        # state only after its scheduler queue and any inference have drained.
        if isinstance(state, dict):
            state.clear()

    def transcribe_window(self, state: Any, audio: np.ndarray) -> str:
        torch = self._torch
        device = next(self._model.parameters()).device
        tensor = torch.from_numpy(audio).to(device)
        with torch.inference_mode():
            features = self._model.encode_speech(tensor.unsqueeze(0))
            text, _ = self._model.streaming_generate_step(
                audio_features=features,
                streaming_state=state,
                tokenizer=self._tokenizer,
                max_new_tokens=MAX_NEW_TOKENS_PER_WINDOW,
                temperature=0.0,
            )
        return text

    def close(self) -> None:
        self._model = None
        self._tokenizer = None
        self._torch.cuda.empty_cache()
