#!/usr/bin/env python3
"""Run the SSH CUDA reference and save only Mac safety-approved images."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--host',default='windows-v100')
p.add_argument('--remote-root',default='D:/Codex/flux3-quality-20261018')
p.add_argument('--gate',type=Path,required=True)
p.add_argument('--classifier',type=Path,required=True)
p.add_argument('--cases',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
manifest=json.loads(a.cases.read_text())
expected={f'{c["id"]}-seed{seed}-{mode}' for c in manifest['cases'] for seed in manifest['seeds'] for mode in ['original','dit-int4','all-int4']}
receipts=[];gpu_report=None;worker=None
with (a.output/'safety.stderr.log').open('w') as safety_log, (a.output/'cuda.stderr.log').open('w') as cuda_log, (a.output/'progress.jsonl').open('w') as progress:
    gate=subprocess.Popen([str(a.gate),str(a.classifier),str(a.output/'images'),str(a.cases)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=safety_log,text=True)
    try:
        ready=json.loads(gate.stdout.readline());assert ready['ready'] and ready['input_safety_passed']
        print('Mac prompt/six-view gate ready',flush=True)
        expected_hash=hashlib.sha256(a.cases.read_bytes()).hexdigest()
        command=f'{a.remote_root}/.venv-v100/Scripts/python.exe {a.remote_root}/scripts/cuda_quality_reference.py --work {a.remote_root} --cases {a.remote_root}/scripts/quality-cases.json --resume --expected-cases-sha256={expected_hash}'
        worker=subprocess.Popen(['ssh','-o','ServerAliveInterval=20',a.host,command],stdout=subprocess.PIPE,stderr=cuda_log,text=True,encoding='utf-8')
        for line in worker.stdout:
            item=json.loads(line)
            if item['kind']=='image':
                assert item['label'] in expected
                gate.stdin.write(json.dumps(item)+'\n');gate.stdin.flush()
                receipt=json.loads(gate.stdout.readline());assert receipt['label']==item['label']
                receipts.append(receipt)
                print('Image',receipt['label'],'approved' if receipt['approved'] else 'WITHHELD',flush=True)
                progress.write(json.dumps({'kind':'safety',**receipt})+'\n')
            else:
                progress.write(json.dumps(item)+'\n')
                if item['kind']=='complete':gpu_report=item['report']
                else:print(json.dumps(item),flush=True)
            progress.flush()
        code=worker.wait()
        assert code==0,f'CUDA worker exit {code}; see cuda.stderr.log and retained remote latents'
        assert gpu_report and gpu_report['cases_sha256']==expected_hash and {r['label'] for r in receipts}==expected
        report={'gpu_comparison':gpu_report,'safety_receipts':receipts,'expected_images':len(expected),
                'approved_images':sum(r['approved'] for r in receipts),
                'scope':'Common FP32 math on V100; real extracted CoreAI effective INT4 vs original weights. iPhone native BF16 quality/speed is separate.'}
        (a.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('COMPLETE',report['approved_images'],'/',len(expected),'images approved',flush=True)
    finally:
        (a.output/'safety-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
        if worker and worker.poll() is None:worker.terminate();worker.wait()
        gate.stdin.close();gate.wait()
