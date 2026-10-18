#!/usr/bin/env python3
"""Compare the sliced image projection with the original real BF16 input graph."""
import argparse
import asyncio
import gc
import json
import os
from pathlib import Path
os.environ['USE_OS_COREAI']='1'
import ml_dtypes
import numpy as np
from coreai.runtime import AIModel,NDArray,SpecializationOptions,ComputeUnitKind

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
p.add_argument('--split-root',type=Path,required=True)
p.add_argument('--fixture',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()

async def run(path,inputs):
    model=await AIModel.load(path,specialization_options=SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()))
    function=model.load_function('main');values=await function(inputs=inputs)
    result=values['image_h'].numpy().copy()
    del values,function,model;gc.collect()
    return result

async def main():
    noise=np.fromfile(a.fixture/'noise.f32',dtype='<f4').reshape(1024,128).astype(ml_dtypes.bfloat16)
    image=NDArray(noise)
    expected=await run(a.source_root/'input.aimodel',{'image':image,'text':NDArray(np.zeros((160,20480),dtype=ml_dtypes.bfloat16)),
        'current_t':NDArray(np.array([.75],dtype=ml_dtypes.bfloat16)),'target_t':NDArray(np.array([.5],dtype=ml_dtypes.bfloat16))})
    actual=await run(a.split_root/'input_image.aimodel',{'image':image})
    x,y=actual.astype(np.float32),expected.astype(np.float32)
    r={'scope':'Real BF16 CoreAI input graph vs exact image-output dependency slice on Mac GPU preferred; not phone timing',
       'exact_equal':bool(np.array_equal(x,y)),'relative_rmse':float(np.linalg.norm(x-y)/np.linalg.norm(y)),
       'maximum_absolute_error':float(np.max(np.abs(x-y))),'finite':bool(np.isfinite(x).all())}
    r['passed']=r['exact_equal'] and r['finite'];a.output.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2));assert r['passed']
asyncio.run(main())
