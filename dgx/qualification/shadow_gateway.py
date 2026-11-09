"""Bounded synthetic-only loopback gateway/production-Go transport qualification.

Invoked only by an independently reviewed Spark exec preview. This is not a
production listener or physical/native-capture or Copilot assessment proof.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.request

GATEWAY_PORT=17874
RELAY_PORT=17875
MODEL='nvidia/nemotron-3.5-asr-streaming-0.6b'


def new_file(path, body, mode=0o600):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
    with os.fdopen(fd,'wb') as out:
        out.write(body);out.flush();os.fsync(out.fileno())


def free_loopback(port):
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',port))


def run(root):
    root=Path(root).resolve(strict=True)
    os.umask(0o077)
    process=None
    result={'status':'failed','production_service_modified':False,
            'physical_capture_qualified':False,'assessment_qualified':False}
    started=time.monotonic()
    try:
        for port in (GATEWAY_PORT,RELAY_PORT):free_loopback(port)
        cache=Path(json.loads((root/'cache-reuse.json').read_text())['directory'])
        # Flat source archive is independently SHA-pinned by the owning operator.
        package=root/'gateway';package.mkdir(mode=0o700)
        for source in root.glob('gateway__*.py'):
            new_file(package/source.name.removeprefix('gateway__'),source.read_bytes())
        if not (package/'__main__.py').is_file():raise RuntimeError('gateway_source_missing')
        relay=root/'mistt';os.chmod(relay,0o700)
        credentials=root/'test-only-credentials';credentials.mkdir(mode=0o700)
        cert=credentials/'tls.crt';key=credentials/'tls.key';token=credentials/'asr.token'
        # New scoped test material only. Never read retained production secrets.
        new_file(token,secrets.token_urlsafe(32).encode())
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
            '-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=synthetic-loopback-only',
            '-addext','subjectAltName=IP:127.0.0.1',
            '-addext','basicConstraints=critical,CA:TRUE',
            '-addext','keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign',
            '-addext','extendedKeyUsage=serverAuth'],check=True,timeout=15,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        os.chmod(cert,0o600);os.chmod(key,0o600)
        env={k:v for k,v in os.environ.items() if not k.startswith('MISTT_')}
        env.update(PYTHONPATH=str(root),HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',
            MISTT_RUNTIME='nemotron3_5',MISTT_NEMOTRON_CACHE_DIR=str(cache),
            MISTT_LISTEN_HOST='127.0.0.1',MISTT_LISTEN_PORT=str(GATEWAY_PORT),
            MISTT_TOKEN_FILE=str(token),MISTT_TLS_CERT_FILE=str(cert),MISTT_TLS_KEY_FILE=str(key),
            MISTT_STARTUP_TIMEOUT_SECONDS='600',MISTT_IDLE_UNLOAD_SECONDS='600')
        # Child stderr is discarded: only content-free qualification receipts persist.
        process=subprocess.Popen([sys.executable,'-m','gateway'],env=env,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        import paired_transport as transport
        until=time.monotonic()+20
        while not transport.owns_linux_listener(process.pid,GATEWAY_PORT):
            if process.poll() is not None or time.monotonic()>until:
                raise RuntimeError('owned_shadow_listener_unavailable')
            time.sleep(.05)
        context=ssl.create_default_context(cafile=str(cert))
        request=urllib.request.Request(f'https://127.0.0.1:{GATEWAY_PORT}/healthz')
        request.add_header('Authorization','Bearer '+token.read_text())
        with urllib.request.urlopen(request,context=context,timeout=5) as response:
            if response.status!=200:raise RuntimeError('shadow_health_failed')
        plan=json.loads((root/'shadow-plan.json').read_text())
        if plan != {'mode':'baseline','duration_seconds':119}:
            raise RuntimeError('reviewed_short_stage_required')
        stages=[]
        for mode in ('baseline',):
            config={'relay':str(relay),'relay_sha256':hashlib.sha256(relay.read_bytes()).hexdigest(),
                'endpoint':f'wss://127.0.0.1:{GATEWAY_PORT}/mistt/v1/stream',
                'token_file':str(token),'ca_file':str(cert),'listen':f'127.0.0.1:{RELAY_PORT}',
                'expected_model':MODEL,'fixture_manifest':str(root/'fixture-manifest.json'),
                'mode':mode,'output_dir':str(root/('transport-'+mode))}
            validated,items,_=transport.validate(config)
            driver=transport.Driver(validated,items,None)
            passed=driver.run()
            stages.append({'mode':mode,'passed':passed,'duration_seconds':driver.duration})
            if not passed:raise RuntimeError('production_go_transport_failed')
        result.update(status='completed',stages=stages)
    except BaseException as error:
        result['error_class']=type(error).__name__
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:process.wait(15)
            except subprocess.TimeoutExpired:
                process.kill();process.wait();result['status']='failed';result['cleanup_error']='owned_shadow_killed'
        result['elapsed_seconds']=round(time.monotonic()-started,3)
        result['owned_gateway_reaped']=process is None or process.poll() is not None
        new_file(root/'shadow-result.json',(json.dumps(result,sort_keys=True)+'\n').encode())
    return result['status']=='completed'

if __name__=='__main__':raise SystemExit(0 if run(sys.argv[1]) else 1)
