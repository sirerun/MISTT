"""Bounded local JSON generation service; deliberately no prompt/output logging."""
import hmac
import json
import os
from pathlib import Path
import secrets
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
os.environ.setdefault('HF_HUB_DISABLE_TELEMETRY','1')
os.environ.setdefault('DO_NOT_TRACK','1')
MODEL='Qwen/Qwen3-4B-Instruct-2507'
REVISION='cdbee75f17c01a7cc42f958dc650907174af0554'
MAX_CONTEXT=4096

def validate(body):
    if not isinstance(body,dict) or body.get('model',MODEL)!=MODEL:
        raise ValueError('unsupported model')
    messages=body.get('messages')
    if not isinstance(messages,list) or not 1<=len(messages)<=20:
        raise ValueError('messages required')
    if any(not isinstance(x,dict) or x.get('role') not in {'system','user','assistant'} or not isinstance(x.get('content'),str) for x in messages):
        raise ValueError('invalid message')
    if sum(len(x['content']) for x in messages)>32000:
        raise ValueError('too much text')
    maximum=body.get('max_tokens',192)
    if type(maximum) is not int or not 1<=maximum<=384 or body.get('stream',False) is not False:
        raise ValueError('unsupported generation bounds')
    if body.get('response_format',{'type':'json_object'})!={'type':'json_object'}:
        raise ValueError('only json_object supported')
    return messages,maximum

def parse_model_json(text):
    text=text.strip()
    if text.startswith('```json\n') and text.endswith('\n```'):
        text=text[8:-4].strip()
    parsed=json.loads(text)
    if not isinstance(parsed,dict):raise ValueError('not JSON object')
    return parsed

def main():
    import torch
    from transformers import AutoTokenizer,AutoModelForCausalLM
    torch.set_num_threads(2)
    work=Path('/work');work.mkdir(exist_ok=True)
    path=work/'auth.token'
    if not path.exists():
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as f:f.write(secrets.token_urlsafe(36))
    token=path.read_text().strip()
    if not token or path.stat().st_mode &0o077:raise RuntimeError('unsafe authentication')
    device=os.environ.get('DECISION_DEVICE','cpu')
    if device=='cuda' and not torch.cuda.is_available():raise RuntimeError('requested CUDA unavailable')
    dtype=torch.bfloat16 if device=='cuda' and torch.cuda.is_bf16_supported() else torch.float32
    tokenizer=AutoTokenizer.from_pretrained(MODEL,revision=REVISION,trust_remote_code=False)
    model=AutoModelForCausalLM.from_pretrained(MODEL,revision=REVISION,torch_dtype=dtype,trust_remote_code=False).to(device).eval()
    admission=threading.BoundedSemaphore(1)
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup();self.connection.settimeout(15)
        def log_message(self,*_):pass
        def reply(self,code,data):
            wire=json.dumps(data,allow_nan=False).encode();self.send_response(code)
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(wire)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(wire)
        def do_GET(self):
            if self.path=='/healthz':self.reply(200,{'status':'ready','model':MODEL,'revision':REVISION,'device':device,'max_context':MAX_CONTEXT,'content_logging':False})
            else:self.reply(404,{'error':'not found'})
        def do_POST(self):
            if self.path!='/v1/chat/completions':self.reply(404,{'error':'not found'});return
            if not hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+token):self.reply(401,{'error':'unauthorized'});return
            if not admission.acquire(blocking=False):self.reply(429,{'error':'local model busy'});return
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=131072:self.reply(413,{'error':'request too large or empty'});return
                body=json.loads(self.rfile.read(length))
                messages,maximum=validate(body)
                inputs=tokenizer.apply_chat_template(messages,tokenize=True,add_generation_prompt=True,enable_thinking=False,return_tensors='pt',return_dict=True)
                inputs={k:v.to(device) for k,v in inputs.items()}
                size=inputs['input_ids'].shape[-1]
                if size+maximum>MAX_CONTEXT:self.reply(400,{'error':'request exceeds context limit'});return
                with torch.inference_mode():
                    output=model.generate(**inputs,max_new_tokens=maximum,do_sample=False,pad_token_id=tokenizer.eos_token_id)
                generated=output[0,size:];text=tokenizer.decode(generated,skip_special_tokens=True).strip()
                try:
                    parsed=parse_model_json(text)
                except json.JSONDecodeError:
                    if body.get('synthetic_debug') is True:
                        self.reply(502,{'error':'model output is not JSON','raw_output':text[:2000],'generated_tokens':len(generated),'finish_reason':'length' if len(generated)>=maximum else 'stop'})
                    else:
                        self.reply(502,{'error':'model output is not JSON'})
                    return
                if not isinstance(parsed,dict):raise ValueError('not JSON object')
                self.reply(200,{'object':'chat.completion','model':MODEL,'revision':REVISION,
                    'choices':[{'index':0,'message':{'role':'assistant','content':json.dumps(parsed)},'finish_reason':'length' if len(generated)>=maximum else 'stop'}],
                    'usage':{'prompt_tokens':size,'completion_tokens':len(generated),'total_tokens':size+len(generated)}})
            except (json.JSONDecodeError,ValueError,TypeError):self.reply(400,{'error':'invalid request or model JSON output'})
            except Exception:self.reply(503,{'error':'local model unavailable'})
            finally:admission.release()
    server=ThreadingHTTPServer(('0.0.0.0',28193),Handler);server.daemon_threads=True;server.timeout=1
    import ssl
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.load_cert_chain('/run/mistt-input/tls.crt','/run/mistt-input/tls.key')
    server.socket=context.wrap_socket(server.socket,server_side=True)
    stop=threading.Event()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    deadline=time.monotonic()+43200
    print(json.dumps({'status':'ready','model':MODEL,'revision':REVISION,'device':device}),flush=True)
    while not stop.is_set() and time.monotonic()<deadline:server.handle_request()
    server.server_close()
if __name__=='__main__':main()
