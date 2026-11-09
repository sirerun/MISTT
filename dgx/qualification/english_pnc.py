"""Cheap fixed-pin English punctuation probe; no adapter/server/provider activation."""
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import queue
import re
import sys
import threading
import time
import wave

MODEL='nvidia/nemotron-speech-streaming-en-0.6b'
REVISION='ebe59e5a817142986528bbbee5dba8db7b38ed50'


def normalize(text):
    return ' '.join(re.findall(r'[^\W_]+',text.lower(),flags=re.UNICODE))


def canonical_date(text):
    text=normalize(text);text=re.sub(r'\bmarch (fifth|5th|five|5)\b','march 5',text)
    return re.sub(r'\b(twenty twenty four|two thousand twenty four|2024)\b','2024',text)


def marked_clauses(text,clauses,*,date=False):
    norm=canonical_date if date else normalize;closed=[norm(part) for part in text.split('?')[:-1]]
    return {index for index,clause in enumerate(clauses) if norm(clause) in closed}


class TokenSnapshotStreamer:
    def __init__(self,tokenizer,timeout=60):
        self.tokenizer=tokenizer;self.timeout=timeout;self.tokens=[];self.queue=queue.Queue(maxsize=4096);self.closed=False
    def put(self,value):
        tokens=value.tolist()
        if tokens and isinstance(tokens[0],list):
            if len(tokens)!=1:raise ValueError('one English probe stream required')
            tokens=tokens[0]
        if len(self.tokens)+len(tokens)>4096:raise ValueError('English probe token bound')
        self.tokens.extend(tokens);text=self.tokenizer.decode(self.tokens,skip_special_tokens=True)
        self.queue.put((time.monotonic(),text),timeout=self.timeout)
    def end(self):
        if not self.closed:self.closed=True;self.queue.put(None,timeout=self.timeout)
    def __iter__(self):return self
    def __next__(self):
        item=self.queue.get(timeout=self.timeout)
        if item is None:raise StopIteration
        return item


def main(root):
    import numpy as np
    import torch
    from transformers import AutoModelForRNNT,AutoProcessor
    if importlib.metadata.version('transformers')!='5.13.0':raise RuntimeError('English probe dependency pin mismatch')
    root=Path(root);reuse=json.loads((root/'cache-reuse.json').read_text());cache=Path(reuse['directory'])
    if reuse.get('local_files_only') is not True:raise RuntimeError('English probe offline cache required')
    fixtures=json.loads((root/'fixture-manifest.json').read_text());clauses=json.loads((root/'reference-clauses.json').read_text());ends=json.loads((root/'clause-speech-ends.json').read_text())
    if len(fixtures)!=12 or {f['id'] for f in fixtures}!={'q%02d'%i for i in range(1,13)}:raise RuntimeError('English probe fixed fixtures required')
    torch.set_num_threads(2);torch.cuda.set_per_process_memory_fraction(0.05,0)
    fd=os.open(root/'candidate-metrics.jsonl',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output:
        def emit(event,**fields):output.write(json.dumps({'event':event,**fields})+'\n');output.flush();os.fsync(output.fileno())
        model=None;phase='load'
        try:
            processor=AutoProcessor.from_pretrained(MODEL,revision=REVISION,cache_dir=str(cache),local_files_only=True,trust_remote_code=False)
            model=AutoModelForRNNT.from_pretrained(MODEL,revision=REVISION,cache_dir=str(cache),local_files_only=True,trust_remote_code=False,torch_dtype=torch.float32).to('cuda:0').eval()
            processor.set_num_lookahead_tokens(6)
            if processor.feature_extractor.sampling_rate!=16000:raise RuntimeError('English probe sample rate changed')
            emit('model_loaded',model=MODEL,revision=REVISION,chunk_latency_ms=processor.streaming_latency_ms,no_step_adapter=True)
            phase='paced_punctuation'
            for fixture in fixtures:
                path=root/fixture['file']
                if hashlib.sha256(path.read_bytes()).hexdigest()!=fixture['sha256']:raise RuntimeError('English probe fixture mismatch')
                with wave.open(str(path),'rb') as audio:
                    if (audio.getframerate(),audio.getsampwidth(),audio.getnchannels())!=(16000,2,1):raise RuntimeError('English probe format mismatch')
                    pcm=np.frombuffer(audio.readframes(audio.getnframes()),dtype='<i2').astype(np.float32)/32768
                pcm=np.pad(pcm,(0,48000));started=time.monotonic();text='';word=None;canonical_word=None;raw_mark=None;times={};errors=[]
                def process(part,first):return processor(part,sampling_rate=16000,is_streaming=True,is_first_audio_chunk=first,return_tensors='pt').to(model.device,dtype=model.dtype)
                time.sleep(max(0,started+processor.num_samples_first_audio_chunk/16000-time.monotonic()));first=process(pcm[:processor.num_samples_first_audio_chunk],True)
                def features():
                    yield first.input_features[:,:processor.num_mel_frames_first_audio_chunk,:]
                    mel=processor.num_mel_frames_first_audio_chunk;hop=processor.feature_extractor.hop_length;fft=processor.feature_extractor.n_fft;offset=mel*hop-fft//2
                    while (end:=offset+processor.num_samples_per_audio_chunk)<len(pcm):
                        time.sleep(max(0,started+end/16000-time.monotonic()));yield process(pcm[offset:end],False).input_features
                        mel+=processor.num_mel_frames_per_audio_chunk;offset=mel*hop-fft//2
                streamer=TokenSnapshotStreamer(processor.tokenizer)
                def generate():
                    try:
                        with torch.inference_mode():model.generate(**{**first,'input_features':features(),'streamer':streamer})
                    except BaseException as error:errors.append(type(error).__name__);streamer.end()
                thread=threading.Thread(target=generate,daemon=True);thread.start()
                for observed,snapshot in streamer:
                    text=snapshot;elapsed=round((observed-started)*1000)
                    if normalize(fixture['reference']) in normalize(text) and word is None:word=elapsed
                    if fixture['id']=='q03' and canonical_date(fixture['reference']) in canonical_date(text) and canonical_word is None:canonical_word=elapsed
                    if '?' in text and raw_mark is None:raw_mark=elapsed
                    for index in marked_clauses(text,clauses[fixture['id']],date=fixture['id']=='q03'):times.setdefault(index,elapsed)
                thread.join(timeout=10)
                if thread.is_alive() or errors:raise RuntimeError('English probe generation failed')
                normalized=normalize(text);expected=normalize(fixture['reference']);difference='exact' if normalized==expected else ('date_format_only' if fixture['id']=='q03' and canonical_date(text)==canonical_date(fixture['reference']) else 'semantic_or_other_difference')
                emit('english_punctuation_result',fixture_id=fixture['id'],difference_class=difference,word_complete_ms=word,word_tail_ms=None if word is None else word-fixture['speech_end_ms'],date_canonical_word_ms=canonical_word,first_literal_mark_ms=raw_mark,native_question_marks=text.count('?'),native_periods=text.count('.'),native_fullwidth_question_marks=text.count('？'),reference_question_marks=sum(c.count('?') for c in clauses[fixture['id']]),clauses=[{'index':i,'reference_has_question_mark':'?' in clause,'speech_end_ms':ends[fixture['id']][i],'recognized_with_literal_mark_ms':times.get(i),'literal_question_tail_ms':None if i not in times else times[i]-ends[fixture['id']][i]} for i,clause in enumerate(clauses[fixture['id']])])
            emit('completed',fixtures=12,model_promoted=False,no_step_adapter=True,peak_cuda_allocated_bytes=torch.cuda.max_memory_allocated())
        except BaseException as error:emit('failed',phase=phase,error_class=type(error).__name__);raise SystemExit(1)
        finally:
            model=None;torch.cuda.empty_cache()

if __name__=='__main__':main(sys.argv[1])
