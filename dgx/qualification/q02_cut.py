"""Reviewed public-fictional model-only q02 cut experiment; no WS/production change."""
from __future__ import annotations
import hashlib,json,math,os
from pathlib import Path
import sys,time,wave
import numpy as np
try:
    from .nemotron_steps import modules,build_jobs,reference_ids,normalize
except ImportError:
    from nemotron_steps import modules,build_jobs,reference_ids,normalize

CUT_SAMPLE=24000  # Exact executed first-cut minus q02 origin:1,760,000−1,736,000.


def padding_jobs(pair,real_end,count):
    if real_end<0 or not 0<=count<=6:raise ValueError('bounded_model_padding_required')
    return [(0,pair.WindowJob(np.zeros(9360,dtype=np.float32),real_end,0,0,0,9360),True)
            for _ in range(count)]


def main(root):
    root=Path(root);os.umask(0o077);adapter,pair,ledger,protocol=modules(root)
    fixture=next(item for item in json.loads((root/'fixture-manifest.json').read_text()) if item['id']=='q02')
    data=(root/fixture['file']).read_bytes()
    if hashlib.sha256(data).hexdigest()!=fixture['sha256']:raise RuntimeError('fixture_digest_changed')
    with wave.open(str(root/fixture['file']),'rb') as audio:
        if (audio.getframerate(),audio.getsampwidth(),audio.getnchannels())!=(16000,2,1):raise RuntimeError('fixture_geometry_changed')
        pcm=np.frombuffer(audio.readframes(audio.getnframes()),dtype='<i2').copy()
    if len(pcm)!=33674 or not 0<CUT_SAMPLE<len(pcm):raise RuntimeError('exact_q02_cut_required')
    reuse=json.loads((root/'cache-reuse.json').read_text())
    if reuse.get('local_files_only') is not True:raise RuntimeError('offline_cache_required')
    metrics=os.open(root/'candidate-metrics.jsonl',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    private=os.open(root/'fictional-q02-hypotheses.jsonl',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    backend=None;phase='load';all_jobs=[];hypothesis_bytes=0
    with os.fdopen(metrics,'w') as numeric,os.fdopen(private,'w') as hypotheses:
        def emit(event,**fields):numeric.write(json.dumps({'event':event,**fields})+'\n');numeric.flush();os.fsync(numeric.fileno())
        def retain(name,text,ids,trace,real_end,origin=0):
            nonlocal hypothesis_bytes
            body=json.dumps({'synthetic_only':True,'variant':name,'raw_hypothesis':text,
                'actual_label_token_ids':ids,'actual_decoder_trace_including_blanks':trace,
                'claimed_real_source_samples':real_end,'original_source_origin_sample':origin})+'\n'
            size=len(body.encode())
            if hypothesis_bytes+size>16*1024*1024:raise RuntimeError('private_fictional_hypothesis_bound')
            hypotheses.write(body);hypotheses.flush();os.fsync(hypotheses.fileno());hypothesis_bytes+=size
        def jobs_for(samples,zeros=0):
            jobs=build_jobs(samples,'call_audio',adapter,ledger,protocol)+padding_jobs(pair,len(samples),zeros)
            if any(job.end_sample>len(samples) for _,job,_ in jobs):raise RuntimeError('claimed_coverage_advanced')
            all_jobs.extend(jobs);return jobs
        try:
            backend=adapter.TransformersBackend(Path(reuse['directory']));engine=adapter.StepEngine(backend)
            emit('model_loaded',model=adapter.MODEL_ID,revision=adapter.MODEL_REVISION,
                 synthetic_only=True,real_capture=False,websocket_sessions=0,model_promoted=False)
            phase='reference'
            reference_jobs=jobs_for(pcm,6)
            reference=reference_ids(backend,reference_jobs)
            if 'get_audio_features' in backend.model.__dict__ or getattr(backend.model,'_streaming',False):
                raise RuntimeError('reference_encoder_method_not_restored')
            reference_labels=[x for x in reference if x!=backend.blank_id]
            retain('HF_uncut_reference_with_six_model_zero_steps',backend.decode(reference_labels),reference_labels,reference,len(pcm))
            outputs={}
            phase='steps'
            for name,samples,zeros in [('uncut_current_EOF',pcm,0),('uncut_reference_padding',pcm,6),
                    ('prefix_cut_current_EOF',pcm[:CUT_SAMPLE],0),('prefix_cut_plus_one_model_zero_step',pcm[:CUT_SAMPLE],1),
                    ('reset_successor_current_EOF',pcm[CUT_SAMPLE:],0),('reset_successor_plus_one_model_zero_step',pcm[CUT_SAMPLE:],1)]:
                jobs=jobs_for(samples,zeros);state=engine.new_state(trace=True);started=time.monotonic();times=[]
                try:
                    for _,job,_ in jobs:
                        tick=time.monotonic();text=engine.step(state,job.audio);backend.torch.cuda.synchronize()
                        times.append(round((time.monotonic()-tick)*1000,3))
                    ids=list(state.token_ids);trace=list(state.trace);outputs[name]=text
                    origin=CUT_SAMPLE if name.startswith('reset_successor_') else 0
                    retain(name,text,ids,trace,len(samples),origin)
                    parity=trace==reference if name=='uncut_reference_padding' else None
                    emit('variant_result',variant=name,actual_label_count=len(ids),decoder_trace_count=len(trace),
                         token_trace_sha256=hashlib.sha256(json.dumps(trace).encode()).hexdigest(),
                         exact_full_reference=normalize(text)==normalize(fixture['reference']),
                         reference_token_parity=parity,model_zero_steps=zeros,model_inference_calls=len(jobs),
                         claimed_real_source_samples=len(samples),last_processed_end_sample=jobs[-1][1].end_sample,
                         original_source_origin_sample=origin,original_source_end_sample=origin+jobs[-1][1].end_sample,
                         unobserved_future_fixture_samples=(len(pcm)-CUT_SAMPLE if name.startswith('prefix_cut_') else 0),
                         padding_prediction_does_not_establish_future_audio_truth=True,
                         reliable_acoustic_continuity_qualified=False,
                         model_padding_did_not_advance_source_coverage=True,
                         decode_ms=times,elapsed_ms=round((time.monotonic()-started)*1000,3))
                    if parity is False:raise RuntimeError('full_token_parity_failed')
                finally:engine.release(state)
            for mode in ('current_EOF','plus_one_model_zero_step'):
                old=outputs['prefix_cut_'+mode];new=outputs['reset_successor_'+mode]
                literal=old+' '+new
                emit('literal_old_successor_comparison',mode=mode,
                     raw_literal_concatenation_exact=normalize(literal)==normalize(fixture['reference']),
                     old_word_count=len(normalize(old).split()),successor_word_count=len(normalize(new).split()),
                     reference_word_count=len(normalize(fixture['reference']).split()),
                     duplicate_reconciliation_applied=False,consumer_reassembly_qualified=False)
            emit('completed',fixture_id='q02',cut_sample=CUT_SAMPLE,uncut_real_samples=len(pcm),
                 private_fictional_hypotheses_retained=True,audio_PCM_retained=False,model_promoted=False,
                 isolated_q02_not_preceding_108_second_context=True,
                 peak_cuda_allocated_bytes=backend.torch.cuda.max_memory_allocated())
        except BaseException as error:
            emit('failed',phase=phase,error_class=type(error).__name__);raise SystemExit(1)
        finally:
            for _,job,_ in all_jobs:job.audio.fill(0)
            pcm.fill(0)
            if backend is not None:backend.model=None;backend.torch.cuda.empty_cache()

if __name__=='__main__':main(sys.argv[1])
