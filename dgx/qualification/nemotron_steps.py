"""Explicit synthetic-only step/reference/paired qualification; numeric receipts only."""
from __future__ import annotations

import asyncio
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import sys
import time
import types
from uuid import uuid4
import wave

import numpy as np


def normalize(text):
    return ' '.join(re.findall(r'[^\W_]+',text.lower(),flags=re.UNICODE))


def canonical_date(text):
    text=normalize(text)
    text=re.sub(r'\bmarch (fifth|5th|five|5)\b','march 5',text)
    return re.sub(r'\b(twenty twenty four|two thousand twenty four|2024)\b','2024',text)


def marked_clauses(text,clauses,*,date=False):
    norm=canonical_date if date else normalize
    closed=[norm(part) for part in text.split('?')[:-1]]
    return {index for index,clause in enumerate(clauses) if norm(clause) in closed}


def modules(root):
    # A reviewed flat public archive is a private import namespace, not a live
    # /opt/mistt edit. Every package file is separately hash-pinned by the operator.
    package=types.ModuleType('mistt_step_qualification');package.__path__=[str(root)]
    sys.modules[package.__name__]=package
    return tuple(importlib.import_module(package.__name__+'.'+name) for name in ('nemotron','pair','ledger','protocol'))


def build_jobs(pcm,source,adapter,ledger_module,protocol):
    session=uuid4();context=adapter.NemotronSourceContext(source,ledger_module.SourceLedger(session,source,1_920_000),None)
    jobs=[]
    for offset in range(0,len(pcm),1600):
        part=pcm[offset:offset+1600]
        paired_cache_limit=context.geometry.max_context_tokens*2
        context.reserve_for_input(offset+len(part),paired_cache_limit,paired_cache_limit)
        for job in context.push_frame(protocol.AudioFrame(session,source,offset//1600+1,offset,offset*62500,len(part),part.tobytes())):
            jobs.append(((offset+len(part))/16000,job,False))
    for job in context.finish_input():jobs.append((len(pcm)/16000,job,True))
    if jobs and (jobs[-1][1].end_sample!=len(pcm) or context.distinct_window_samples!=len(pcm)):
        raise RuntimeError('qualification_real_tail_coverage_failed')
    return jobs


def reference_ids(backend,jobs):
    processor=backend.processor;model=backend.model
    def process(audio,first):
        return processor(audio,sampling_rate=16000,is_streaming=True,is_first_audio_chunk=first,
                         language='en-US',return_tensors='pt').to(model.device,dtype=model.dtype)
    first=process(jobs[0][1].audio,True)
    def features():
        yield first.input_features[:,:49,:]
        for _,job,_ in jobs[1:]:yield process(job.audio,False).input_features
    with backend.torch.inference_mode():
        result=model.generate(**{**first,'input_features':features()})
    return result.sequences[0].tolist()


def main(root):
    root=Path(root);adapter,pair,ledger,protocol=modules(root)
    fixtures=json.loads((root/'fixture-manifest.json').read_text());clauses=json.loads((root/'reference-clauses.json').read_text());clause_ends=json.loads((root/'clause-speech-ends.json').read_text())
    if {f['id'] for f in fixtures}!={'q%02d'%i for i in range(1,13)} or len(fixtures)!=12:
        raise ValueError('exact twelve fictional fixtures required')
    reuse=json.loads((root/'cache-reuse.json').read_text())
    if reuse.get('local_files_only') is not True:raise ValueError('offline settled cache required')
    fd=os.open(root/'candidate-metrics.jsonl',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output:
        def emit(event,**fields):output.write(json.dumps({'event':event,**fields})+'\n');output.flush();os.fsync(output.fileno())
        backend=None;phase='load'
        try:
            backend=adapter.TransformersBackend(Path(reuse['directory']));engine=adapter.StepEngine(backend);load_peak=backend.torch.cuda.max_memory_allocated();backend.torch.cuda.reset_peak_memory_stats()
            emit('model_loaded',model=adapter.MODEL_ID,revision=adapter.MODEL_REVISION,adapter_source=json.loads((root/'adapter-source.json').read_text())['revision'],model_load_peak_cuda_allocated_bytes=load_peak)
            audio={};references={};peak_slots=0
            phase='single_parity'
            for fixture in fixtures:
                path=root/fixture['file'];data=path.read_bytes()
                if hashlib.sha256(data).hexdigest()!=fixture['sha256']:raise RuntimeError('fixture_digest_changed')
                with wave.open(str(path),'rb') as wav:
                    if (wav.getframerate(),wav.getsampwidth(),wav.getnchannels())!=(16000,2,1):raise RuntimeError('fixture_format_changed')
                    pcm=np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').copy()
                audio[fixture['id']]=np.concatenate((pcm,np.zeros(48000,dtype='<i2')))
                jobs=build_jobs(audio[fixture['id']],'call_audio',adapter,ledger,protocol)
                expected=reference_ids(backend,jobs);state=engine.new_state(trace=True)
                try:
                    for _,job,_ in jobs:
                        text=engine.step(state,job.audio);peak_slots=max(peak_slots,backend.cache_slots(state))
                    actual=list(state.trace);equal=actual==expected
                    difference='exact' if normalize(text)==normalize(fixture['reference']) else ('date_format_only' if fixture['id']=='q03' and canonical_date(text)==canonical_date(fixture['reference']) else 'semantic_or_other_difference')
                    emit('full_token_parity',fixture_id=fixture['id'],equal=equal,reference_tokens=len(expected),step_tokens=len(actual),first_difference=None if equal else next((i for i,(a,b) in enumerate(zip(expected,actual)) if a!=b),min(len(expected),len(actual))),difference_class=difference,native_question_marks=text.count('?'),reference_question_marks=sum(c.count('?') for c in clauses[fixture['id']]),real_samples=len(audio[fixture['id']]),last_end_sample=jobs[-1][1].end_sample)
                    if not equal:raise RuntimeError('full_token_parity_failed')
                    references[fixture['id']]=expected
                finally:
                    engine.release(state)
                    for _,job,_ in jobs:job.audio.fill(0)

            async def run_pair(left,right,*,paced=False,fixture=None):
                nonlocal peak_slots
                scheduler=pair.FairInferenceScheduler();states={source:engine.new_state(trace=True) for source in ('microphone','call_audio')}
                jobs={source:build_jobs(pcm,source,adapter,ledger,protocol) for source,pcm in [('microphone',left),('call_audio',right)]}
                started=time.monotonic();active=0;max_active=0;dispatch=[];clause_times={};word_time=None;canonical_word_time=None;raw_mark_time=None;observed_before_end={}
                async def worker(source,work):
                    nonlocal active,max_active
                    active+=1;max_active=max(max_active,active);dispatch.append(source)
                    try:await work()
                    finally:active-=1
                scheduler.start(worker)
                async def produce(source):
                    nonlocal peak_slots,word_time,canonical_word_time,raw_mark_time
                    for available,job,is_tail in jobs[source]:
                        if paced:await asyncio.sleep(max(0,started+available-time.monotonic()))
                        completed=asyncio.Event()
                        def observer(ids,text):
                            nonlocal word_time,canonical_word_time,raw_mark_time
                            if not paced or source!='call_audio':return
                            elapsed=round((time.monotonic()-started)*1000)
                            if normalize(fixture['reference']) in normalize(text) and word_time is None:word_time=elapsed
                            if fixture['id']=='q03' and canonical_date(fixture['reference']) in canonical_date(text) and canonical_word_time is None:canonical_word_time=elapsed
                            if '?' in text and raw_mark_time is None:raw_mark_time=elapsed
                            for index in marked_clauses(text,clauses[fixture['id']],date=fixture['id']=='q03'):
                                if index not in clause_times:clause_times[index]=elapsed;observed_before_end[index]=not is_tail
                        async def work(job=job,completed=completed,observer=observer):
                            try:
                                task=asyncio.create_task(asyncio.to_thread(engine.step,states[source],job.audio,observer))
                                try:await asyncio.shield(task)
                                except asyncio.CancelledError:
                                    await task
                                    raise
                            finally:completed.set()
                        await scheduler.submit(source,work,valid_input_samples=job.valid_input_samples,overlap_samples=job.overlap_samples,distinct_model_samples=job.distinct_model_samples,padding_samples=job.padding_samples,on_discard=lambda job=job:job.audio.fill(0))
                        completion_task=asyncio.create_task(completed.wait());failure_task=asyncio.create_task(scheduler.wait_failure())
                        try:
                            done,_=await asyncio.wait((completion_task,failure_task),timeout=60,return_when=asyncio.FIRST_COMPLETED)
                            if not done or failure_task in done or scheduler.failure_reason:raise RuntimeError('paired_scheduler_failed')
                        finally:
                            for task in (completion_task,failure_task):
                                if not task.done():task.cancel()
                            await asyncio.gather(completion_task,failure_task,return_exceptions=True)
                        peak_slots=max(peak_slots,backend.cache_slots(states[source]))
                try:
                    await asyncio.gather(produce('microphone'),produce('call_audio'))
                    return {'microphone_trace':list(states['microphone'].trace),'call_audio_trace':list(states['call_audio'].trace),'max_inference_active':max_active,'dispatch_count':len(dispatch),'max_same_source_run_including_after_other_eof':max((len(list(group)) for _,group in __import__('itertools').groupby(dispatch)),default=0),'microphone_emitted_labels':len(states['microphone'].token_ids),'microphone_question_marks':backend.decode(states['microphone'].token_ids).count('?'),'call_audio_question_marks':backend.decode(states['call_audio'].token_ids).count('?'),'word_complete_ms':word_time,'date_canonical_word_complete_ms':canonical_word_time,'first_literal_mark_ms':raw_mark_time,'clauses':[{'index':i,'reference_has_question_mark':'?' in clause,'speech_end_ms':clause_ends[fixture['id']][i],'recognized_with_literal_mark_ms':clause_times.get(i),'literal_question_tail_ms':None if i not in clause_times else clause_times[i]-clause_ends[fixture['id']][i],'current_question_mark_trigger_gap':i not in clause_times,'observed_before_end_source':observed_before_end.get(i,False)} for i,clause in enumerate(clauses[fixture['id']])] if paced else []}
                finally:
                    await scheduler.cancel_and_wait()
                    for state in states.values():engine.release(state)

            # Every fixture is interleaved with another, then source roles are swapped.
            phase='paired_parity'
            for swap in (False,True):
                for index in range(0,12,2):
                    a,b=fixtures[index]['id'],fixtures[index+1]['id']
                    if swap:a,b=b,a
                    result=asyncio.run(run_pair(audio[a],audio[b]))
                    equal_a=result.pop('microphone_trace')==references[a];equal_b=result.pop('call_audio_trace')==references[b]
                    emit('paired_token_parity',microphone_fixture=a,call_audio_fixture=b,microphone_equal=equal_a,call_audio_equal=equal_b,**result)
                    if not equal_a or not equal_b or result['max_inference_active']!=1:raise RuntimeError('paired_token_parity_failed')
            phase='paced_question'
            for fixture in fixtures:
                pcm=audio[fixture['id']];result=asyncio.run(run_pair(np.zeros(len(pcm),dtype='<i2'),pcm,paced=True,fixture=fixture))
                result.pop('microphone_trace');result.pop('call_audio_trace')
                emit('paced_question_result',fixture_id=fixture['id'],speech_end_ms=fixture['speech_end_ms'],end_source_ms=len(pcm)/16,word_complete_tail_ms=None if result['word_complete_ms'] is None else result['word_complete_ms']-fixture['speech_end_ms'],**result)
            phase='nonspeech'
            for kind,pcm in [('silence',np.zeros(32000,dtype='<i2')),('noise',np.random.default_rng(1).integers(-100,101,32000,dtype=np.int16))]:
                jobs=build_jobs(pcm,'microphone',adapter,ledger,protocol);state=engine.new_state()
                try:
                    for _,job,_ in jobs:text=engine.step(state,job.audio)
                    emit('nonspeech_probe',kind=kind,emitted_labels=len(state.token_ids),question_marks=text.count('?'),nonempty=bool(normalize(text)),decoder_steps=state.steps)
                finally:
                    engine.release(state)
                    for _,job,_ in jobs:job.audio.fill(0)
            emit('completed',fixtures=12,peak_encoder_slots=peak_slots,paired_directions=2,model_promoted=False,peak_cuda_allocated_bytes=backend.torch.cuda.max_memory_allocated(),peak_cuda_reserved_bytes=backend.torch.cuda.max_memory_reserved())
        except BaseException as error:
            emit('failed',phase=phase,error_class=type(error).__name__,error_code=str(error) if re.fullmatch(r'(rnnt|qualification|full_token|paired|fixture)_[a-z_]{1,100}',str(error)) else None);raise SystemExit(1)
        finally:
            if backend is not None:backend.model=None;backend.torch.cuda.empty_cache()

if __name__=='__main__':main(sys.argv[1])
