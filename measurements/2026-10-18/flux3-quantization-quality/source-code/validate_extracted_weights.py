#!/usr/bin/env python3
"""Check nibble order, scale math and linear mapping against the retained probe."""
import argparse
import json
from pathlib import Path
import numpy as np
import torch
from models import reference, positions, DiffusionBlock
from quantized_reference import QuantizedComponent

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--quant-root',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
torch.set_num_threads(2)
ref,_=reference(a.work/'reference')
q=QuantizedComponent(a.quant_root,'shared_00')
image,text=positions(32,160)
with torch.device('meta'): block=ref.Block(3072,24,3.0)
wrapper=DiffusionBlock(block,ref.rope_embed(torch.cat((image,text))[None]),1024).eval()
state={'block.'+name:torch.from_numpy(q.weight(name,math_dtype='float16')).half() for name in q.matrices}
assert q.receipt['validation_norm_count']==2
for i,name in enumerate(['norm.query_norm.scale','norm.key_norm.scale']):state['block.'+name]=torch.from_numpy(q.arrays['validation_norm_'+str(i)]).half()
wrapper.load_state_dict(state,strict=True,assign=True)
folder=a.work/'block-smoke'
hidden=torch.from_numpy(np.fromfile(folder/'hidden.f32',dtype='<f4').reshape(1184,3072)).half()
mods=torch.from_numpy(np.fromfile(folder/'mods.f32',dtype='<f4').reshape(2,3,3072)).half()
expected=np.fromfile(folder/'expected.f32',dtype='<f4').reshape(1184,3072)
with torch.inference_mode():actual=wrapper(hidden,mods).float().numpy()
relative=float(np.linalg.norm(actual-expected)/np.linalg.norm(expected))
result={'scope':'One real full-width shared block; reconstructed actual packed weights vs retained CoreAI-opt PyTorch FP16 output; not image quality',
        'relative_rmse':relative,'maximum_absolute_error':float(np.max(np.abs(actual-expected))),
        'finite':bool(np.isfinite(actual).all()),'passed':bool(np.isfinite(actual).all() and relative<.001)}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));assert result['passed']
