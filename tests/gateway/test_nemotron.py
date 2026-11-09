from __future__ import annotations

import threading
import asyncio
import unittest
from unittest.mock import patch
from uuid import uuid4

import numpy as np

from dgx.gateway.ledger import SourceLedger
from dgx.gateway.nemotron import NemotronGeometry, NemotronSourceContext, StepEngine
from dgx.gateway.protocol import AudioFrame, ProtocolError


class FakeBackend:
    blank_id = 0
    max_symbols = 10

    def new_decoder_cache(self):
        return {'initialized':False,'consumed':[],'inputs':[]}

    def encode(self, audio, state):
        if state.encoder_cache is None:
            state.encoder_cache = {'calls':0,'slots':0}
        state.encoder_cache['calls'] += 1
        state.encoder_cache['slots'] = min(57,state.encoder_cache['calls']*7)
        state.padding_cache = {'tag':int(round(float(audio[0])))}
        return {'plans':[[11 if int(round(float(audio[0])))==1 else 22,0],[0]],'cursors':[0,0]}

    def frame_count(self, encoded):
        return len(encoded['plans'])

    def predict(self, encoded, frame, last_token, cache):
        cache['inputs'].append(last_token)
        if last_token != self.blank_id:
            cache['consumed'].append(last_token)
        cache['initialized'] = True
        cursor=encoded['cursors'][frame];encoded['cursors'][frame]+=1
        return encoded['plans'][frame][min(cursor,len(encoded['plans'][frame])-1)]

    def cache_slots(self,state):
        return 0 if state.encoder_cache is None else state.encoder_cache['slots']

    def decode(self,tokens):
        return ' '.join('alpha?' if token==11 else 'beta?' for token in tokens)


class StepTests(unittest.TestCase):
    def test_blank_advancement_never_consumes_last_nonblank_twice(self):
        engine=StepEngine(FakeBackend());state=engine.new_state(trace=True)
        text=engine.step(state,np.ones(7880,dtype=np.float32))
        self.assertEqual(text,'alpha?');self.assertEqual(state.trace,[0,11,0,0])
        self.assertEqual(state.decoder_cache['inputs'],[0,11,0])
        self.assertEqual(state.decoder_cache['consumed'],[11])
        engine.step(state,np.ones(9360,dtype=np.float32))
        self.assertEqual(state.decoder_cache['inputs'],[0,11,0,0,11,0])
        self.assertEqual(state.decoder_cache['consumed'],[11,11])

    def test_two_interleaved_sources_keep_all_caches_and_tokens_isolated(self):
        engine=StepEngine(FakeBackend());a=engine.new_state();b=engine.new_state()
        for _ in range(3):
            engine.step(a,np.ones(9360,dtype=np.float32));engine.step(b,np.full(9360,2,dtype=np.float32))
        self.assertEqual(a.token_ids,[11]*3);self.assertEqual(b.token_ids,[22]*3)
        self.assertIsNot(a.encoder_cache,b.encoder_cache);self.assertIsNot(a.padding_cache,b.padding_cache);self.assertIsNot(a.decoder_cache,b.decoder_cache)
        engine.release(a);self.assertEqual(b.token_ids,[22]*3)
        with self.assertRaisesRegex(RuntimeError,'unavailable'):engine.step(a,np.ones(9360))

    def test_max_symbols_forces_finite_frame_advance(self):
        class Repeating(FakeBackend):
            def predict(self,*args):return 11
        engine=StepEngine(Repeating());state=engine.new_state(trace=True)
        engine.step(state,np.ones(7880))
        self.assertEqual(state.steps,20);self.assertEqual(len(state.token_ids),20)
        self.assertEqual(state.trace,[0]+[11]*20)

    def test_bounds_fail_closed_and_cannot_resume(self):
        engine=StepEngine(FakeBackend());state=engine.new_state()
        with patch('dgx.gateway.nemotron.MAX_TEXT_BYTES',2),self.assertRaisesRegex(RuntimeError,'text_bound'):
            engine.step(state,np.ones(7880))
        self.assertTrue(state.failed)
        with self.assertRaisesRegex(RuntimeError,'unavailable'):engine.step(state,np.ones(7880))

    def test_release_joins_late_step_before_clearing_state(self):
        entered=threading.Event();finish=threading.Event();release_started=threading.Event();released=threading.Event()
        class Blocking(FakeBackend):
            def encode(self,audio,state):entered.set();finish.wait(2);return super().encode(audio,state)
        engine=StepEngine(Blocking());state=engine.new_state()
        worker=threading.Thread(target=lambda:engine.step(state,np.ones(7880)));worker.start();self.assertTrue(entered.wait(1))
        def release():release_started.set();engine.release(state);released.set()
        cleaner=threading.Thread(target=release);cleaner.start();self.assertTrue(release_started.wait(1));self.assertFalse(released.is_set())
        finish.set();worker.join(2);cleaner.join(2)
        self.assertFalse(worker.is_alive());self.assertFalse(cleaner.is_alive());self.assertTrue(state.closed);self.assertIsNone(state.decoder_cache)

    def test_silence_can_remain_blank_and_noise_is_bounded(self):
        class Silent(FakeBackend):
            def predict(self,*args):return 0
        engine=StepEngine(Silent());state=engine.new_state()
        self.assertEqual(engine.step(state,np.zeros(7880)),'');self.assertEqual(state.token_ids,[])
        with patch('dgx.gateway.nemotron.MAX_STEPS',1),self.assertRaisesRegex(RuntimeError,'step_bound'):
            engine.step(state,np.random.default_rng(0).normal(size=9360).astype(np.float32))


class FramingTests(unittest.TestCase):
    def context(self):
        session=uuid4();ledger=SourceLedger(session,'call_audio',1_920_000)
        return session,NemotronSourceContext('call_audio',ledger,StepEngine(FakeBackend()).new_state())

    def test_boundaries_keep_every_real_sample_and_never_count_padding(self):
        for length in (0,1,7879,7880,7881,16943,16944,16945,32000,1_920_000):
            with self.subTest(length=length):
                session,context=self.context();pcm=(np.arange(length,dtype=np.int64)%30000).astype('<i2');jobs=[]
                for offset in range(0,length,1600):
                    samples=pcm[offset:offset+1600]
                    context.reserve_for_input(offset+len(samples),114,114)
                    jobs.extend(context.push_frame(AudioFrame(session,'call_audio',offset//1600+1,offset,offset*62500,len(samples),samples.tobytes())))
                jobs.extend(context.finish_input());coverage=np.zeros(length,dtype=np.bool_);start=0
                for index,job in enumerate(jobs):
                    self.assertEqual(len(job.audio),7880 if index==0 else 9360)
                    self.assertEqual(job.end_sample,min(start+min(job.valid_input_samples,7880 if index==0 else 9256),length))
                    np.testing.assert_array_equal(job.audio[:job.valid_input_samples],pcm[start:start+job.valid_input_samples].astype(np.float32)/32768)
                    coverage[start:start+job.valid_input_samples]=True
                    self.assertTrue(np.all(job.audio[job.valid_input_samples:]==0))
                    start=7584 if index==0 else start+8960
                self.assertTrue(coverage.all());self.assertEqual(context.distinct_window_samples,length);self.assertEqual(context.resampler_output_samples,length)
                if jobs:self.assertEqual(jobs[-1].end_sample,length)
                with self.assertRaises(ProtocolError):context.finish_input()

    def test_both_sources_full_production_audio_budget_reserves_real_windows(self):
        # Mirror app.py's paired context reservation policy; cache slots are not
        # a cumulative inference-window allowance (57 slots per source).
        from dgx.gateway.config import MAX_AUDIO_SAMPLES
        session=uuid4();geometry=NemotronGeometry()
        contexts={source:NemotronSourceContext(source,SourceLedger(session,source,MAX_AUDIO_SAMPLES),None)
                  for source in ('call_audio','mic')}
        aggregate_limit=geometry.max_context_tokens*len(contexts)
        aggregate_reserved=sum(c.base_context_tokens for c in contexts.values())
        counts={source:0 for source in contexts}
        pcm=np.zeros(1600,dtype='<i2').tobytes()
        for offset in range(0,MAX_AUDIO_SAMPLES,1600):
            for source,context in contexts.items():
                own=context.reserve_for_input(offset+1600,aggregate_reserved,aggregate_limit)
                aggregate_reserved=sum(c.base_context_tokens+c._reserved_windows*geometry.reserved_tokens_per_window
                                       for c in contexts.values())
                jobs=context.push_frame(AudioFrame(session,source,offset//1600+1,offset,offset*62500,1600,pcm))
                counts[source]+=len(jobs)
                self.assertLessEqual(context.windows_enqueued,own)
                self.assertEqual(aggregate_reserved,aggregate_limit)
                for job in jobs:job.audio.fill(0)
        for source,context in contexts.items():
            full=counts[source];tails=context.finish_input()
            self.assertEqual(full,214)
            self.assertEqual(len(tails),1)
            self.assertEqual(context.windows_enqueued,215)
            self.assertEqual(context._reserved_windows,215)
            self.assertEqual(tails[-1].end_sample,MAX_AUDIO_SAMPLES)
            self.assertEqual(context.distinct_window_samples,MAX_AUDIO_SAMPLES)
            for job in tails:job.audio.fill(0)

    def test_first_and_later_window_cursors_match_pinned_processor(self):
        session,context=self.context();samples=np.zeros(17600,dtype='<i2');jobs=[]
        for offset in range(0,len(samples),1600):jobs.extend(context.push_frame(AudioFrame(session,'call_audio',offset//1600+1,offset,offset*62500,1600,samples[offset:offset+1600].tobytes())))
        self.assertEqual([job.end_sample for job in jobs],[7880,16840]);self.assertEqual([job.overlap_samples for job in jobs],[0,296]);self.assertEqual(context._next_start,16544)
        self.assertEqual(context.geometry,NemotronGeometry())

class ShadowContinuationTests(unittest.TestCase):
    def test_opt_in_fictional_hypotheses_private_bounded_and_unchanged(self):
        from dgx.qualification.paired_transport import Driver
        import tempfile,time,json
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);manifest=root/'manifest.json';manifest.write_text('[]')
            items=[{'id':f'q{i:02d}','reference':'Did it work?'} for i in range(1,13)]
            driver=Driver({'mode':'baseline','output_dir':str(root/'output'),'relay_sha256':'a'*64,
                           'fixture_manifest':str(manifest),'retain_fictional_hypotheses':True},items,None)
            try:
                driver.start_time=time.monotonic()
                event={'session_id':'synthetic-session','Payload':{'Transcription':{'source':'call_audio','end_sample':8960,'end_offset_ns':560000000}}}
                driver.retain_hypothesis(event,'Fictional unchanged words')
                driver.retain_hypothesis(event,'Fictional unchanged words')
                path=root/'output/fictional-hypotheses.jsonl'
                rows=[json.loads(line) for line in path.read_text().splitlines()]
                self.assertEqual(len(rows),1)
                self.assertEqual(rows[0]['raw_hypothesis'],'Fictional unchanged words')
                self.assertTrue(rows[0]['synthetic_only'])
                self.assertEqual(path.stat().st_mode & 0o777,0o600)
                driver.hypothesis_bytes=16*1024*1024
                driver.retain_hypothesis(event,'Different fictional words')
                self.assertIn('fictional_hypothesis_budget_exceeded',driver.errors)
                self.assertEqual(len(path.read_text().splitlines()),1)
            finally:driver.hypothesis_log.close();driver.log.close()

    def test_soak_schedules_all_twelve_and_initializes_proof_custody(self):
        from dgx.qualification.paired_transport import Driver
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);manifest=root/'manifest.json';manifest.write_text('[]')
            items=[{'id':f'q{i:02d}','reference':'Did it work?'} for i in range(1,13)]
            driver=Driver({'mode':'soak','output_dir':str(root/'output'),'relay_sha256':'a'*64,
                           'fixture_manifest':str(manifest)},items,None)
            try:
                self.assertEqual(driver.duration,900)
                self.assertEqual(len(driver.metrics),12)
                self.assertEqual(len(driver.schedule),12)
                self.assertEqual(driver.continuation_proofs,0)
                self.assertIsNone(driver.current_asr_id)
            finally:driver.log.close()

    def test_exact_ordered_native_global_boundary_attestation(self):
        from dgx.qualification.paired_transport import valid_continuation
        import copy
        proof={'version':1,'previous_session_id':'old','native_session_id':'native',
               'cutover_offset_ns':110_000_000_000,'sources':[
                   {'source':source,'start_sample':1_760_000,'capture_offset_ns':110_000_000_000}
                   for source in ('microphone','call_audio')]}
        self.assertTrue(valid_continuation(proof,'old','native',0))
        self.assertFalse(valid_continuation(proof,'foreign','native',0))
        self.assertFalse(valid_continuation(proof,'old','foreign',0))
        self.assertFalse(valid_continuation(proof,'old','native',110_000_000_000))
        altered=copy.deepcopy(proof);altered['sources'].reverse()
        self.assertFalse(valid_continuation(altered,'old','native',0))
        altered=copy.deepcopy(proof);altered['sources'][1]['start_sample']+=1
        self.assertFalse(valid_continuation(altered,'old','native',0))


class ShadowDependencyTests(unittest.TestCase):
    def test_exact_gateway_dependencies_and_imports_precede_worker(self):
        from dgx.qualification import shadow_launch
        import json,tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'pins.json').write_text(json.dumps({'dependencies':['transformers==5.13.0']}))
            (root/'transport-dependencies.json').write_text(json.dumps(['fastapi==0.116.1','uvicorn==0.35.0','websockets==15.0.1']))
            with patch.object(shadow_launch.os,'nice'),patch.object(shadow_launch.signal,'signal'),patch.object(shadow_launch.venv,'create'),patch.object(shadow_launch,'bounded_group',return_value=0) as bounded:
                self.assertTrue(shadow_launch.run(root))
            calls=bounded.call_args_list
            self.assertEqual(len(calls),3)
            self.assertEqual(calls[0].args[0][-3:],['fastapi==0.116.1','uvicorn==0.35.0','websockets==15.0.1'])
            self.assertIn('import fastapi,uvicorn,websockets',calls[1].args[0][-1])
            self.assertEqual(calls[2].args[0][-2:], [str(root/'worker.py'),str(root)])


class ShadowGroupCleanupTests(unittest.TestCase):
    def test_timeout_terminates_then_kills_owned_worker_group(self):
        from dgx.qualification.shadow_launch import bounded_group
        import signal,subprocess
        from unittest.mock import Mock
        child=Mock(pid=12345)
        child.wait.side_effect=[subprocess.TimeoutExpired('worker',1),subprocess.TimeoutExpired('worker',3),-9]
        with patch('dgx.qualification.shadow_launch.subprocess.Popen',return_value=child),patch('dgx.qualification.shadow_launch.os.killpg') as kill,patch('dgx.qualification.shadow_launch.time.sleep'):
            with self.assertRaises(subprocess.TimeoutExpired):bounded_group(['worker'],{},None,1)
        self.assertEqual(kill.call_args_list[0].args,(12345,signal.SIGTERM))
        self.assertEqual(kill.call_args_list[1].args,(12345,signal.SIGKILL))

    def test_finished_worker_still_cleans_any_descendant_group(self):
        from dgx.qualification.shadow_launch import bounded_group
        import signal
        from unittest.mock import Mock
        child=Mock(pid=12345);child.wait.return_value=0
        with patch('dgx.qualification.shadow_launch.subprocess.Popen',return_value=child),patch('dgx.qualification.shadow_launch.os.killpg') as kill,patch('dgx.qualification.shadow_launch.time.sleep'):
            self.assertEqual(bounded_group(['worker'],{},None,1),0)
        self.assertEqual(kill.call_args_list[0].args,(12345,signal.SIGTERM))
        self.assertEqual(kill.call_args_list[1].args,(12345,signal.SIGKILL))


class ShadowTransportOwnershipTests(unittest.TestCase):
    def test_listener_requires_exact_pid_inode_loopback_port_and_listen_state(self):
        from dgx.qualification.paired_transport import matching_listener_inode
        row='0: 0100007F:45CF 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 12345'
        self.assertTrue(matching_listener_inode([row],{'12345'},17871))
        self.assertFalse(matching_listener_inode([row],{'foreign'},17871))
        self.assertFalse(matching_listener_inode([row],{'12345'},17872))
        self.assertFalse(matching_listener_inode([row.replace('0100007F','00000000')],{'12345'},17871))
        self.assertFalse(matching_listener_inode([row.replace(' 0A ',' 01 ')],{'12345'},17871))


class SchedulerDisposalTests(unittest.TestCase):
    def test_active_pending_and_unqueued_cancelled_pcm_are_disposed_once(self):
        from dgx.gateway.pair import FairInferenceScheduler
        async def scenario():
            scheduler=FairInferenceScheduler(max_items_per_source=1)
            entered=asyncio.Event();gate=asyncio.Event();joined=asyncio.Event()
            arrays={name:np.ones(10,dtype=np.float32) for name in ('active','queued','unqueued')};counts={name:0 for name in arrays}
            async def worker(source,work):
                entered.set()
                try:await gate.wait();await work()
                finally:joined.set()
            async def nothing():pass
            def dispose(name):
                if name=='active':self.assertTrue(joined.is_set())
                counts[name]+=1;arrays[name].fill(0)
            scheduler.start(worker)
            await scheduler.submit('microphone',nothing,on_discard=lambda:dispose('active'))
            await entered.wait()
            await scheduler.submit('microphone',nothing,on_discard=lambda:dispose('queued'))
            pending=asyncio.create_task(scheduler.submit('microphone',nothing,on_discard=lambda:dispose('unqueued')))
            await asyncio.sleep(0);pending.cancel();await asyncio.gather(pending,return_exceptions=True)
            self.assertEqual(counts['unqueued'],1);self.assertTrue(arrays['active'].all())
            await scheduler.cancel_and_wait()
            self.assertEqual(counts,{'active':1,'queued':1,'unqueued':1})
            self.assertTrue(all(not array.any() for array in arrays.values()))
        asyncio.run(scenario())


class WireIntegrationTests(unittest.TestCase):
    def test_unchanged_nonempty_words_advance_processed_bounds_but_empty_mic_emits_no_text(self):
        from fastapi.testclient import TestClient
        from dgx.gateway.app import create_app
        from dgx.gateway.config import GatewaySettings
        from dgx.gateway.nemotron import NemotronRuntime, MODEL_ID, MODEL_REVISION, SOURCE_COMMIT
        from dgx.gateway.protocol import encode_frame
        class OnceBackend(FakeBackend):
            def encode(self,audio,state):
                encoded=super().encode(audio,state)
                if state.encoder_cache['calls']!=1 or not np.any(audio):encoded['plans']=[[0],[0]]
                return encoded
        class FakeNemo(NemotronRuntime):
            def __init__(self):self.backend=OnceBackend();self.engine=StepEngine(self.backend)
            def close(self):pass
        settings=GatewaySettings(token='fictional-token',runtime_profile='nemotron3_5',model_id=MODEL_ID,model_revision=MODEL_REVISION,source_commit=SOURCE_COMMIT,nemotron_cache_directory='/not-read-by-fake')
        formats=[{'source':source,'sample_rate_hz':16000,'channels':1,'encoding':'s16le'} for source in ('microphone','call_audio')]
        with TestClient(create_app(settings,FakeNemo)) as client:
            session=uuid4()
            with client.websocket_connect('/mistt/v1/stream',headers={'Authorization':'Bearer fictional-token'}) as socket:
                socket.send_json({'type':'start','protocol':'mistt.paired.v2','session_id':str(session),'language':'en','sources':formats});self.assertEqual(socket.receive_json()['type'],'ready')
                socket.send_json({'type':'capture_started','request_id':str(uuid4()),'session_id':str(session),'capture_epoch_host_ns':1,'capture_epoch_unix_ms':1791000000000,'sources':formats,'microphone_ready':True,'call_audio_ready':True})
                for offset in range(0,48000,1600):
                    for source in ('microphone','call_audio'):socket.send_bytes(encode_frame(session,source,offset//1600+1,offset,offset*62500,[32767 if source=='call_audio' else 0]*1600))
                for source in ('microphone','call_audio'):socket.send_json({'type':'source_end','session_id':str(session),'source':source,'last_sequence':30,'total_samples':48000,'cutoff_offset_ns':3000000000})
                events=[]
                while True:
                    event=socket.receive_json();events.append(event)
                    if event['type'] in ('done','error'):break
                self.assertEqual(events[-1]['type'],'done')
                partials=[event for event in events if event['type']=='transcript' and not event['is_final']]
                self.assertGreaterEqual(len(partials),2);self.assertTrue(all(event['source']=='call_audio' and event['text']=='alpha?' for event in partials))
                self.assertTrue(all(a['end_sample']<b['end_sample'] and a['source_event_sequence']<b['source_event_sequence'] for a,b in zip(partials,partials[1:])))
                self.assertGreaterEqual(partials[1]['end_sample']-partials[0]['end_sample'],8000)
                for event in partials:self.assertEqual(event['end_offset_ns'],event['end_sample']*62500)

    def test_opt_in_profile_preserves_v1_v2_ready_and_real_final_bounds(self):
        from fastapi.testclient import TestClient
        from dgx.gateway.app import create_app
        from dgx.gateway.config import GatewaySettings
        from dgx.gateway.nemotron import NemotronRuntime, MODEL_ID, MODEL_REVISION, SOURCE_COMMIT
        from dgx.gateway.protocol import encode_frame
        formats=[{'source':source,'sample_rate_hz':16000,'channels':1,'encoding':'s16le'} for source in ('microphone','call_audio')]
        class FakeNemo(NemotronRuntime):
            def __init__(self):self.backend=FakeBackend();self.engine=StepEngine(self.backend)
            def close(self):pass
        settings=GatewaySettings(token='fictional-token',runtime_profile='nemotron3_5',model_id=MODEL_ID,model_revision=MODEL_REVISION,source_commit=SOURCE_COMMIT,nemotron_cache_directory='/not-read-by-fake')
        runtime=FakeNemo();app=create_app(settings,lambda:runtime)
        with TestClient(app) as client:
            for protocol in ('mistt.paired.v1','mistt.paired.v2'):
                session=uuid4()
                with client.websocket_connect('/mistt/v1/stream',headers={'Authorization':'Bearer fictional-token'}) as socket:
                    socket.send_json({'type':'start','protocol':protocol,'session_id':str(session),'language':'en','sources':formats})
                    ready=socket.receive_json();self.assertEqual(ready['type'],'ready');self.assertEqual(ready['language'],'en');self.assertEqual(ready['model']['id'],MODEL_ID);self.assertEqual(ready['model']['sample_rate'],16000)
                    self.assertEqual(ready['aggregate_max_context_tokens'],114);self.assertEqual(ready['aggregate_drain_reserve_tokens'],0)
                    socket.send_json({'type':'capture_started','request_id':str(uuid4()),'session_id':str(session),'capture_epoch_host_ns':1,'capture_epoch_unix_ms':1791000000000,'sources':formats,'microphone_ready':True,'call_audio_ready':True})
                    for offset in range(0,16000,1600):
                        for source in ('microphone','call_audio'):
                            socket.send_bytes(encode_frame(session,source,offset//1600+1,offset,offset*62500,[32767 if source=='call_audio' else -32767]*1600))
                    for source in ('microphone','call_audio'):
                        socket.send_json({'type':'source_end','session_id':str(session),'source':source,'last_sequence':10,'total_samples':16000,'cutoff_offset_ns':1000000000})
                    events=[]
                    while True:
                        event=socket.receive_json();events.append(event)
                        if event['type'] in ('done','error'):break
                    self.assertEqual(events[-1]['type'],'done')
                    finals={event['source']:event for event in events if event['type']=='transcript' and event['is_final']}
                    self.assertEqual(set(finals),{'microphone','call_audio'})
                    self.assertEqual(finals['call_audio']['text'],'alpha? alpha?');self.assertEqual(finals['microphone']['text'],'beta? beta?')
                    for final in finals.values():self.assertEqual(final['end_sample'],16000)


class PunctuationMetricTests(unittest.TestCase):
    def test_word_complete_without_native_mark_is_not_assessable(self):
        from dgx.qualification.nemotron_steps import marked_clauses
        self.assertEqual(marked_clauses('Did you approve it',['Did you approve it?']),set())
        self.assertEqual(marked_clauses('Did you approve it?',['Did you approve it?']),{0})
        self.assertEqual(marked_clauses('Did you approve it? Or did you reject it',['Did you approve it?','Or did you reject it?']),{0})
        self.assertEqual(marked_clauses('Did you approve it? Or did you reject it?',['Did you approve it?','Or did you reject it?']),{0,1})
    def test_english_probe_uses_identical_literal_mark_gate(self):
        from dgx.qualification.english_pnc import marked_clauses as english
        from dgx.qualification.nemotron_steps import marked_clauses as steps
        for text in ('Did you approve it','Did you approve it?','Did you approve it? Or did you reject it?'):
            clauses=['Did you approve it?','Or did you reject it?']
            self.assertEqual(english(text,clauses),steps(text,clauses))
    def test_date_format_classification_keeps_date_and_negation_semantics(self):
        from dgx.qualification.nemotron_steps import marked_clauses
        reference=['Was it signed before March fifth twenty twenty four?']
        self.assertEqual(marked_clauses('Was it signed before March 5th 2024?',reference,date=True),{0})
        self.assertEqual(marked_clauses('Was it signed before March 6th 2024?',reference,date=True),set())
        self.assertEqual(marked_clauses('Was it not signed before March 5th 2024?',reference,date=True),set())

if __name__=='__main__':unittest.main()
