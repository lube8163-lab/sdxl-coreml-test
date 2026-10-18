#!/usr/bin/env python3
"""Check all seven extracted text linear mappings against the real CoreAI layer."""
import argparse
import asyncio
import json
import math
import os
from pathlib import Path
os.environ['USE_OS_COREAI']='1'
import numpy as np
import torch
from coreai.authoring import AIModelAsset
from coreai._compiler import ir
from coreai._compiler._mlir_libs._coreaiIR._bindings import compiler
from coreai.runtime import AIModel,NDArray,ComputeUnitKind,SpecializationOptions
from models import TextLayer,text_position_inputs
from quantized_reference import QuantizedComponent

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
p.add_argument('--quant-root',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();torch.set_num_threads(2);torch.manual_seed(42)
q=QuantizedComponent(a.quant_root,'te_00')
program=AIModelAsset.load(a.source_root/'te_00.aimodel').program
main=next(g for g in program._module._mlir_module.body.operations if g.attributes['sym_name'].value=='main')
ops=list(main.regions[0].blocks[0].operations);norms=[]
for op in ops:
    if op.operation.name!='coreai.constant':continue
    t=ir.RankedTensorType(op.results[0].type)
    if list(t.shape)!=[2560] or str(t.element_type) not in ('f16','f32'):continue
    raw=np.empty(2560*(2 if str(t.element_type)=='f16' else 4),dtype=np.uint8)
    compiler.copy_constant_value_to_array(constant_op=op.operation,destination=raw)
    first=min(i for i,user in enumerate(ops) if any(v==op.results[0] for v in user.operands))
    norms.append((first,raw.view(np.float16 if str(t.element_type)=='f16' else np.float32).copy()))
assert len(norms)==2
with torch.device('meta'):module=TextLayer()
state={name:torch.from_numpy(q.weight(name)).half() for name in q.matrices}
for i,name in enumerate(['self_attn.q_norm.weight','self_attn.k_norm.weight']):state[name]=torch.from_numpy(q.arrays[f'validation_norm_{i}']).half()
for (_,values),name in zip(sorted(norms,key=lambda item:item[0]),['input_layernorm.weight','post_attention_layernorm.weight']):state[name]=torch.from_numpy(values).half()
module.load_state_dict(state,strict=True,assign=True);module.eval()
hidden=torch.randn(1,160,2560).half()*.3
cos,sin,mask=text_position_inputs(117,160)
with torch.inference_mode():expected=module(hidden,cos,sin,mask).float().numpy()
async def main():
    model=await AIModel.load(a.source_root/'te_00.aimodel',specialization_options=SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()))
    function=model.load_function('main')
    result=await function(inputs={name:NDArray(v.numpy()) for name,v in [('hidden',hidden),('cos',cos),('sin',sin),('mask',mask)]})
    actual=result['hidden'].numpy().astype(np.float32)
    relative=float(np.linalg.norm(actual-expected)/np.linalg.norm(expected))
    report={'scope':'One real FP16 Qwen layer, actual extracted INT4 vs CoreAI, random input; not image quality','relative_rmse':relative,'max_absolute_error':float(np.max(np.abs(actual-expected))),'finite':bool(np.isfinite(actual).all()),'passed':bool(np.isfinite(actual).all() and relative<.01)}
    a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));assert report['passed']
asyncio.run(main())
