"""Bounded synthetic-only paired TLS qualification. Never captures devices."""
import argparse,json,ssl,time,uuid,wave,struct,threading,urllib.request,subprocess,sys
from pathlib import Path
from websockets.sync.client import connect
p=argparse.ArgumentParser();p.add_argument('--private',type=Path,required=True);p.add_argument('--decision-script',type=Path);a=p.parse_args();r=a.private
ctx=ssl.create_default_context(cafile=str(r/'tls.crt'));token=(r/'asr.token').read_text().strip()
base='https://192.168.86.250:18772';report={'synthetic_only':True,'endpoint':base,'tls_verified':True}
for auth in [False,True]:
 try:
  req=urllib.request.Request(base+'/mistt/v1/capabilities',headers={'Authorization':'Bearer '+token} if auth else {})
  with urllib.request.urlopen(req,context=ctx,timeout=10) as response:status=response.status;body=json.load(response)
 except urllib.error.HTTPError as e:status=e.code;body={}
 report['auth' if auth else 'no_auth']={'status':status,'body':body}
formats=[{'source':s,'sample_rate_hz':16000,'channels':1,'encoding':'s16le'} for s in ['microphone','call_audio']]
session=str(uuid.uuid4());start=time.monotonic();events=[];errors=[]
with connect(base.replace('https:','wss:')+'/mistt/v1/stream',ssl=ctx,additional_headers={'Authorization':'Bearer '+token},open_timeout=15,close_timeout=5,max_size=65536) as ws:
 ws.send(json.dumps({'type':'start','protocol':'mistt.paired.v1','session_id':session,'language':'en','sources':formats}))
 ready=json.loads(ws.recv(timeout=240));report['ready']=ready;report['ready_seconds']=time.monotonic()-start
 if ready.get('type')!='ready':raise RuntimeError('not ready')
 decision_result=[]
 def decision_check():
  result=subprocess.run([sys.executable,str(a.decision_script)],text=True,capture_output=True,timeout=60)
  decision_result.append({'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
 decision_worker=threading.Thread(target=decision_check) if a.decision_script else None
 if decision_worker:decision_worker.start()
 ws.send(json.dumps({'type':'capture_started','request_id':str(uuid.uuid4()),'session_id':session,'capture_epoch_host_ns':time.monotonic_ns(),'capture_epoch_unix_ms':int(time.time()*1000),'sources':formats,'microphone_ready':True,'call_audio_ready':True}))
 def receive():
  try:
   for _ in range(200):
    e=json.loads(ws.recv(timeout=90));e['received_elapsed']=time.monotonic()-start;events.append(e)
    if e.get('type')=='done':return
  except Exception as e:errors.append(type(e).__name__+':'+str(e))
 worker=threading.Thread(target=receive);worker.start()
 pcm=[]
 for name in ['mic.wav','call.wav']:
  with wave.open(str(r/name),'rb') as w:
   assert w.getframerate()==16000 and w.getnchannels()==1 and w.getsampwidth()==2
   pcm.append(w.readframes(w.getnframes()))
 size=max(map(len,pcm));size=(size+3199)//3200*3200;pcm=[v+b'\0'*(size-len(v)) for v in pcm]
 sent=time.monotonic();sequence=0
 for offset in range(0,size,3200):
  sequence+=1
  for source in [1,2]:
   payload=pcm[source-1][offset:offset+3200];samples=len(payload)//2
   header=struct.pack('>4s16sB3sQQQI',b'MST1',uuid.UUID(session).bytes,source,b'\0'*3,sequence,offset//2,(offset//2)*62500,samples)
   ws.send(header+payload)
  delay=sent+(offset//3200+1)*0.1-time.monotonic()
  if delay>0:time.sleep(delay)
 for source in ['microphone','call_audio']:
  ws.send(json.dumps({'type':'source_end','session_id':session,'source':source,'last_sequence':sequence,'total_samples':size//2,'cutoff_offset_ns':(size//2)*62500}))
 eof=time.monotonic();worker.join(timeout=100)
 report.update({'events':events,'errors':errors,'duration_seconds':size/32000,'eof_to_done_seconds':time.monotonic()-eof,'completed':any(e.get('type')=='done' for e in events)})
if decision_worker:decision_worker.join(timeout=65)
report['decision_concurrent']=decision_result
(r/('paired-qualification-'+session+'.json')).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
