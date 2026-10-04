import importlib.util, json, time, pathlib, torch, psutil, uvicorn
out=pathlib.Path('/task/evidence')
spec=importlib.util.spec_from_file_location('upstream_demo','/task/source/demo/vibevoice_asr_streaming_fastapi_demo.py')
demo=importlib.util.module_from_spec(spec); spec.loader.exec_module(demo)
path=json.loads((out/'checkpoint.json').read_text())['model_path']
start=time.monotonic(); demo.load_model(path,'cuda','sdpa'); torch.cuda.synchronize()
def metrics():
 return {'process_rss_bytes':psutil.Process().memory_info().rss,'torch_allocated_bytes':torch.cuda.memory_allocated(),'torch_reserved_bytes':torch.cuda.memory_reserved(),'torch_peak_allocated_bytes':torch.cuda.max_memory_allocated(),'torch_peak_reserved_bytes':torch.cuda.max_memory_reserved()}
load={'load_seconds':time.monotonic()-start, 'device':torch.cuda.get_device_name(0),'attention':'sdpa', **metrics()}
(out/'load.json').write_text(json.dumps(load,indent=2))
original=demo.transcribe_window
count=0
def measured(window, session):
 global count
 start=time.monotonic(); result=original(window,session);torch.cuda.synchronize();count+=1
 with (out/'inference.jsonl').open('a') as f:
  f.write(json.dumps({'index':count,'seconds':time.monotonic()-start,'window_samples':len(window),'result':result,**metrics()})+'\n')
 return result
demo.transcribe_window=measured
uvicorn.run(demo.app,host='127.0.0.1',port=7870)
