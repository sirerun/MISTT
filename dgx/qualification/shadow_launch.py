"""Bounded isolated shadow dependencies and joined worker process-group cleanup."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import venv


def bounded_group(argv,environment,log,seconds,grace=3):
    process=subprocess.Popen(argv,env=environment,stdout=log,stderr=log,start_new_session=True)
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGTERM)
        try:process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=2)
        raise
    finally:
        # Even a failed worker must not leave listener/model descendants behind.
        try:os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        else:
            time.sleep(.2)
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        if process.poll() is None:
            process.wait(timeout=2)


def run(root):
    root=Path(root);os.umask(0o077);started=time.monotonic();os.nice(10)
    def terminate(_signal,_frame):raise SystemExit(128+_signal)
    signal.signal(signal.SIGTERM,terminate)
    result={'status':'failed','phase':'dependencies'}
    try:
        pins=json.loads((root/'pins.json').read_text());(root/'tmp').mkdir(mode=0o700)
        transport_pins=json.loads((root/'transport-dependencies.json').read_text())
        if transport_pins!=['fastapi==0.116.1','uvicorn==0.35.0','websockets==15.0.1']:
            raise ValueError('exact_shadow_transport_dependencies_required')
        environment={k:v for k,v in os.environ.items() if k in {'PATH','HOME','LANG','LD_LIBRARY_PATH','CUDA_VISIBLE_DEVICES'}}
        environment.update(HF_HOME=str(root/'hf'),PIP_CACHE_DIR=str(root/'pip'),TMPDIR=str(root/'tmp'),PIP_CONFIG_FILE='/dev/null',PIP_NO_INPUT='1',PIP_DISABLE_PIP_VERSION_CHECK='1',OMP_NUM_THREADS='2',MKL_NUM_THREADS='2',TOKENIZERS_PARALLELISM='false',HF_HUB_DISABLE_TELEMETRY='1',HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1')
        venv.create(root/'venv',with_pip=True,system_site_packages=True)
        python=str(root/'venv/bin/python')
        with (root/'dependency.log').open('xb') as log:
            if bounded_group([python,'-m','pip','install',*pins['dependencies'],*transport_pins],environment,log,max(1,min(480,1750-(time.monotonic()-started)))):
                raise RuntimeError('isolated_dependency_failed')
        with (root/'import-check.log').open('xb') as log:
            if bounded_group([python,'-c','import fastapi,uvicorn,websockets,transformers,torch,numpy'],environment,log,20):
                raise RuntimeError('isolated_import_failed')
        result['phase']='transport'
        with (root/'worker.log').open('xb') as log:
            if bounded_group([python,str(root/'worker.py'),str(root)],environment,log,max(1,1750-(time.monotonic()-started))):
                raise RuntimeError('shadow_worker_failed')
        result['status']='completed'
    except BaseException as error:result['error_class']=type(error).__name__
    finally:
        result['elapsed_seconds']=round(time.monotonic()-started,3)
        fd=os.open(root/'completion.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as output:json.dump(result,output);output.flush();os.fsync(output.fileno())
    return result['status']=='completed'

if __name__=='__main__':raise SystemExit(0 if run(sys.argv[1]) else 1)
