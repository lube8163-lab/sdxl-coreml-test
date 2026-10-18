#!/usr/bin/env python3
"""Slice the original BF16 input graph to its image projection dependency closure."""
import argparse
import json
from pathlib import Path
from coreai.authoring import AIModelAsset,AIProgram,Context,Module
from coreai.authoring.graph_builder import GraphOp
from coreai._compiler import ir
from coreai._compiler.dialects import coreai
from quantized_reference import sha256

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
p.add_argument('--output-root',type=Path,required=True)
a=p.parse_args();a.output_root.mkdir(parents=True,exist_ok=True)
receipt=json.loads((a.source_root/'input.json').read_text());assert receipt['compute_dtype']=='bfloat16'
source=a.source_root/'input.aimodel'
for name,value in receipt['asset_files_sha256'].items():assert sha256(source/name)==value
destination=a.output_root/'input_image.aimodel';assert not destination.exists()
with Context():
    source_program=AIModelAsset.load(source).program
    main=next(g for g in source_program._module._mlir_module.body.operations if g.attributes['sym_name'].value=='main')
    old=main.regions[0].blocks[0];result=list(old.operations)[-1].operands[0]
    needed=set();arguments=set()
    def visit(value):
        if value in old.arguments:arguments.add(value);return
        owner=value.owner
        if owner in needed:return
        for operand in owner.operands:visit(operand)
        needed.add(owner)
    visit(result);assert arguments=={old.arguments[0]}
    module=Module.create()
    with module:
        graph=GraphOp('main',[old.arguments[0].type],[result.type],input_names=['image'],result_names=['image_h'])
        with graph.block:
            mapping={old.arguments[0]:graph.arguments[0]}
            for op in old.operations:
                if op.operation not in needed:continue
                cloned=op.operation.clone(ip=ir.InsertionPoint.current)
                for index,operand in enumerate(op.operands):cloned.operands[index]=mapping[operand]
                mapping.update(zip(op.results,cloned.results,strict=True))
            coreai.OutputOp([mapping[result]])
    module.verify();program=AIProgram(module);program.save_asset(destination)
    (a.output_root/'input_image-elided.mlir').write_text(module._mlir_module.operation.get_asm(large_elements_limit=4,large_resource_limit=4))
result={'component':'input_image','completed':True,'compute_dtype':'bfloat16','source_asset_files_sha256':receipt['asset_files_sha256'],
        'derivation':'Exact dependency closure of input.main image_h; original constants/ops retained',
        'input_names':['image'],'output_names':['image_h'],
        'asset_files_sha256':{str(f.relative_to(destination)):sha256(f) for f in sorted(destination.rglob('*')) if f.is_file()},
        'asset_bytes':sum(f.stat().st_size for f in destination.rglob('*') if f.is_file()),'script_sha256':sha256(Path(__file__))}
(a.output_root/'input_image.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
