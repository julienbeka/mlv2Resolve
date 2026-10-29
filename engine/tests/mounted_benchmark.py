#!/usr/bin/env python3
"""Measure sequential and interleaved DNG reads on an isolated temporary FUSE-T mount.
Usage: MLV_BENCH_BAD=0 python3 engine/tests/mounted_benchmark.py /path/to/shoot
Source clips are read only; indexes and logs stay in a temporary diagnostics folder.
The test unmounts its own volume before exiting. Uses the built engine.
"""
import subprocess,time,tempfile,pathlib,json,os,signal,sys
root=pathlib.Path(tempfile.mkdtemp(prefix='mlv-perf-'))
mount=root/'mount';mount.mkdir();index=root/'index';index.mkdir()
if len(sys.argv)!=2:raise SystemExit(__doc__)
repo=pathlib.Path(__file__).resolve().parents[2];source=pathlib.Path(sys.argv[1]).resolve()
if not source.is_dir():raise SystemExit('Source folder does not exist')
bad=os.environ.get('MLV_BENCH_BAD','1')=='1'
log=(root/'engine.log').open('wb')
args=[str(repo/'build/engine/mlvfs'),str(mount),'--mlv-dir='+str(source),'--resolve-naming','--dual-iso-preview','--fpm-dir='+str(repo/'engine/mlvfs/fpm'),'--index-dir='+str(index),'-f']
if bad:args.append('--bad-pix')
p=subprocess.Popen(args,stdout=log,stderr=log)
try:
 deadline=time.monotonic()+12
 while not os.path.ismount(mount):
  if p.poll() is not None:raise RuntimeError('engine exited '+str(p.returncode))
  if time.monotonic()>deadline:raise RuntimeError('mount timeout')
  time.sleep(.1)
 def timeout(*_):raise TimeoutError('benchmark exceeded 40s')
 signal.signal(signal.SIGALRM,timeout);signal.alarm(40)
 start=time.perf_counter();dirs=sorted(d for d in mount.iterdir() if d.is_dir());listing=time.perf_counter()-start
 sequences=[]
 start=time.perf_counter()
 for d in dirs:
  files=sorted(d.glob('*.dng'))
  if files:sequences.append(files)
 sequence_listing=time.perf_counter()-start
 def bench(mixed):
  times=[];size=0;start=time.perf_counter()
  for i in range(84):
   seq=sequences[i%len(sequences)] if mixed else sequences[0]
   frame=(i//len(sequences)) if mixed else i
   t=time.perf_counter()
   with seq[frame%len(seq)].open('rb') as f:size+=len(f.read())
   times.append(time.perf_counter()-t)
  elapsed=time.perf_counter()-start;times.sort()
  return dict(fps=round(84/elapsed,2),median_ms=round(times[42]*1000,2),p95_ms=round(times[78]*1000,2),MBps=round(size/elapsed/1e6,2))
 print(json.dumps(dict(bad_pixels=bad,clips=len(sequences),root_listing_seconds=listing,sequence_listing_seconds=sequence_listing,single=bench(False),mixed=bench(True),diagnostics=str(root))),flush=True)
 signal.alarm(0)
finally:
 signal.alarm(0)
 try:subprocess.run(['umount',str(mount)],timeout=8,check=True,capture_output=True)
 except Exception:subprocess.run(['diskutil','unmount','force',str(mount)],timeout=8,capture_output=True)
 p.terminate()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.kill();p.wait()
 log.close()
 if os.path.ismount(mount):raise RuntimeError('Test mount could not be removed: '+str(mount))
