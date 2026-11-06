"""Render one owned shared-GPU practice pod; no credentials in this manifest."""
import base64,io,tarfile,json,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[2]
b=io.BytesIO()
with tarfile.open(fileobj=b,mode='w:gz') as t:
 for rel in sorted(subprocess.check_output(['git','ls-files','dgx/gateway'],cwd=root,text=True).splitlines()):
  t.add(root/rel,arcname=rel)
 for p in sorted((root/'dgx/practice').iterdir()):
  if p.is_file() and p.suffix in ('.py','.sh','.txt'): t.add(p,arcname=str(p.relative_to(root)))
payload=base64.b64encode(b.getvalue()).decode()
script="set -eu; umask 077; mkdir -p /opt/mistt; printf '%s' '"+payload+"' | base64 -d | tar xz -C /opt/mistt; exec timeout 43200 bash /opt/mistt/dgx/practice/bootstrap.sh"
manifest={'apiVersion':'v1','kind':'Pod','metadata':{'name':'zendesk-paired-practice-20261104','labels':{'purpose':'owned-bounded-paired-practice'}},'spec':{'restartPolicy':'Never','containers':[{'name':'practice','image':'nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7','command':['bash','-lc',script],'env':[{'name':'MISTT_TLS_PROBE_SERVER_NAME','value':'192.168.86.250'}],'ports':[{'containerPort':7870,'hostPort':18772},{'containerPort':28193,'hostPort':28193}],'resources':{'requests':{'cpu':'8','memory':'64Gi','nvidia.com/gpu':'1'},'limits':{'cpu':'8','memory':'64Gi','nvidia.com/gpu':'1'}},'volumeMounts':[{'name':'work','mountPath':'/work'}]}],'volumes':[{'name':'work','emptyDir':{}}]}}
(root/'dgx/practice/spark-pod.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'pod':manifest['metadata']['name'],'resources':manifest['spec']['containers'][0]['resources'],'ports':manifest['spec']['containers'][0]['ports'],'archive_bytes':len(b.getvalue())}))
