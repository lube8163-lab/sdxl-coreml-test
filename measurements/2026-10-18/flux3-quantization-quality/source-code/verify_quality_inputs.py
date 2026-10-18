#!/usr/bin/env python3
"""Return 2 while task-owned downloads/transfers are pending; verify before CUDA."""
import argparse
import json
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
a=p.parse_args();spec=json.loads((Path(__file__).parent/'model-spec.json').read_text());missing=[]
for name,entry in spec['weights'].items():
    file=a.work/'weights'/(name+'.safetensors');receipt=a.work/'weights'/(name+'-source.json')
    if not file.exists() or not receipt.exists():missing.append(name);continue
    r=json.loads(receipt.read_text());assert r['verified'] and r['sha256']==entry['sha256'] and file.stat().st_size==entry['size']
names=[f'{m}_{i:02}' for m,n in [('image',5),('text',5),('shared',28),('te',32)] for i in range(n)]
for name in names:
    file=a.work/'quantized-weights'/(name+'.safetensors');receipt=a.work/'quantized-weights'/(name+'.json')
    if not file.exists() or not receipt.exists():missing.append(name);continue
    r=json.loads(receipt.read_text())
    if file.stat().st_size!=r['bytes']:missing.append(name)
print(json.dumps({'ready':not missing,'pending':missing}),flush=True)
raise SystemExit(2 if missing else 0)
