"""Prospective owner custody and bounded reconciliation; never repairs old receipts."""
import argparse,datetime,hashlib,json,os,subprocess,urllib.request,urllib.error
from pathlib import Path
API='http://192.168.86.250:8080'
POD='zendesk-paired-practice-20261104'
CLAIM='R-mistt-dgx-deployment'
ROOT=Path(__file__).resolve().parents[2]
def remote(path):
 try:
  with urllib.request.urlopen(API+path,timeout=15) as r:return r.status,json.loads(r.read(4*1024*1024))
 except urllib.error.HTTPError as e:
  if e.code==404:return 404,None
  raise

def guard(args):
 actual=subprocess.check_output(['git','ls-remote','origin','refs/claims/'+CLAIM],cwd=ROOT,text=True).strip().split()
 if len(actual)!=2 or actual[0]!=args.claim_sha:raise RuntimeError('prospective claim not held')
 head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
 if head!=args.approved_source:raise RuntimeError('approved source differs from checkout')
 if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip():raise RuntimeError('source checkout is dirty')
 return head

def main():
 p=argparse.ArgumentParser();p.add_argument('mode',choices=['reconcile','qualify']);p.add_argument('--claim-sha',required=True);p.add_argument('--approved-source',required=True);p.add_argument('--private',type=Path,required=True);p.add_argument('--python',default='python3');a=p.parse_args()
 os.umask(0o077)
 if not a.private.is_dir() or a.private.is_symlink() or a.private.stat().st_mode&0o077:raise RuntimeError('private receipt directory required')
 head=guard(a)
 status,pod=remote('/api/v1/pods/'+POD);_,resources=remote('/api/v1/resources');_,inventory=remote('/api/v1/pods')
 receipt={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source':head,'claim_sha':a.claim_sha,'claim_scope':'prospective only; preapply claim was omitted','pod_http_status':status,'pod':pod,'resources':resources,'inventory':inventory,'real_audio_admitted':False}
 if status!=200 or not isinstance(pod,dict) or pod.get('name')!=POD:raise RuntimeError('exact owned pod absent or schema mismatch')
 if a.mode=='qualify':
  if pod.get('status')!='running':raise RuntimeError('exact pod not running')
  guard(a) # Recheck immediately before the next consumed synthetic operation.
  result=subprocess.run([a.python,str(ROOT/'dgx/practice/qualify.py'),'--private',str(a.private)],cwd=ROOT,text=True,capture_output=True,timeout=360)
  receipt.update({'synthetic_probe_exit':result.returncode,'synthetic_stdout':result.stdout,'synthetic_stderr':result.stderr})
 name='owner-'+a.mode+'-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'.json'
 with (a.private/name).open('x') as f:json.dump(receipt,f,indent=2)
 print(json.dumps({'receipt':str(a.private/name),'mode':a.mode,'pod_status':pod.get('status'),'synthetic_probe_exit':receipt.get('synthetic_probe_exit')}))
 if receipt.get('synthetic_probe_exit',0):raise SystemExit(1)
if __name__=='__main__':main()
