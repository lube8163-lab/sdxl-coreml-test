#!/usr/bin/env python3
"""Controlled original/effective-INT4 weight comparison on a CUDA GPU.

All inference math is FP32 in every variant. This isolates weight degradation;
it is not native INT4 throughput or an exact iPhone BF16 pipeline replica.
Images are emitted only in memory to the Mac's fail-closed safety gate. Windows
retains latents and numerical metadata, never unchecked PNG/JPEG files.
"""
import argparse
import base64
import gc
import io
import json
import os
import platform
import subprocess
import time
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--cases',type=Path,required=True)
p.add_argument('--gpu-uuid')
p.add_argument('--resume',action='store_true')
p.add_argument('--expected-cases-sha256')
a=p.parse_args()
if a.gpu_uuid is None:
    inventory=subprocess.check_output(['nvidia-smi','--query-gpu=uuid,name','--format=csv,noheader'],text=True)
    candidates=[line.split(',',1)[0].strip() for line in inventory.splitlines() if 'Tesla V100' in line]
    assert len(candidates)==1, 'Pass the intended V100 UUID explicitly'
    a.gpu_uuid=candidates[0]
os.environ['CUDA_VISIBLE_DEVICES']=a.gpu_uuid
os.environ['CUBLAS_WORKSPACE_CONFIG']=':4096:8'
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from safetensors import safe_open
from tokenizers import Tokenizer
from models import reference,positions,InputStage,DiffusionBlock,OutputStage,Decoder,TextLayer,TextEmbedding,text_position_inputs
from quantized_reference import QuantizedComponent,sha256,round_bf16_inplace


def emit(kind,**kwargs):
    print(json.dumps({'kind':kind,**kwargs},ensure_ascii=True),flush=True)


def sync(): torch.cuda.synchronize()
def release(): gc.collect();torch.cuda.empty_cache()


def ssim_7x7(first,second):
    # Uniform 7x7 window, valid interior, per-channel mean, unbiased covariance.
    x=torch.from_numpy(first).permute(2,0,1)[None]
    y=torch.from_numpy(second).permute(2,0,1)[None]
    mean=lambda v:F.avg_pool2d(v,7,stride=1)
    ux,uy=mean(x),mean(y)
    vx=(mean(x*x)-ux*ux)*(49/48)
    vy=(mean(y*y)-uy*uy)*(49/48)
    cov=(mean(x*y)-ux*uy)*(49/48)
    return float((((2*ux*uy+.01**2)*(2*cov+.03**2))/((ux*ux+uy*uy+.01**2)*(vx+vy+.03**2))).mean())


def math_attention(q,k,v,bounds):
    _,heads,length,dim=q.shape
    out=torch.zeros(length,heads*dim,device=q.device,dtype=q.dtype)
    for start,end in bounds:
        if start==end:continue
        with torch.nn.attention.sdpa_kernel(torch.nn.attention.SDPBackend.MATH):
            chunk=F.scaled_dot_product_attention(q[:,:,start:end],k[:,:,start:end],v[:,:,start:end])
        out[start:end]=chunk[0].transpose(0,1).reshape(end-start,heads*dim)
    return out


def assign(module,reader,mapper,component=None):
    quant=QuantizedComponent(a.work/'quantized-weights',component) if component else None
    if quant:assert quant.receipt['source_checkpoint_sha256']==spec['weights']['text' if component.startswith('te_') else 'dit']['sha256']
    state={}
    for name,parameter in module.named_parameters():
        if quant and name.removeprefix('block.') in quant.matrices:
            value=torch.from_numpy(quant.weight(name.removeprefix('block.'))).to(device='cuda',dtype=torch.float32)
        else:value=reader.get_tensor(mapper(name)).float().cuda()
        assert value.shape==parameter.shape and torch.isfinite(value).all(),name
        state[name]=value
    module.load_state_dict(state,strict=True,assign=True)
    return module.eval()


@torch.inference_mode()
def encode_text(cases,manifest):
    length=manifest['text_length']
    tokenizer=Tokenizer.from_file(str(a.work/'tokenizer/tokenizer.json'))
    prepared={}
    for case in cases:
        chat='<|im_start|>user\n'+case['caption']+'<|im_end|>\n<|im_start|>assistant\n'
        ids=tokenizer.encode(chat,add_special_tokens=False).ids
        assert len(ids)<=length and tokenizer.decode(ids,skip_special_tokens=False)==chat
        cos,sin,mask=text_position_inputs(len(ids),length)
        prepared[case['id']]=(torch.tensor([ids+[151643]*(length-len(ids))],device='cuda'),*[x.float().cuda() for x in (cos,sin,mask)])
    results={}
    for mode in ['original','int4']:
        started=time.perf_counter()
        with safe_open(a.work/'weights/text.safetensors',framework='pt',device='cpu') as reader:
            with torch.device('meta'):embed=TextEmbedding()
            embed=assign(embed,reader,lambda k:'model.language_model.'+k)
            hidden={name:embed(values[0]) for name,values in prepared.items()}
            del embed;release()
            layers={name:[] for name in hidden}
            for index in range(32):
                with torch.device('meta'):layer=TextLayer()
                layer=assign(layer,reader,lambda k:f'model.language_model.layers.{index}.'+k,f'te_{index:02}' if mode=='int4' else None)
                for name,values in prepared.items():
                    hidden[name]=layer(hidden[name],*values[1:])
                    assert torch.isfinite(hidden[name]).all()
                    if (index+1)%4==0:layers[name].append(hidden[name].detach().cpu())
                del layer;release()
                emit('progress',phase='text',mode=mode,layer=index+1)
        results[mode]={name:torch.cat(features,dim=-1)[0].contiguous() for name,features in layers.items()}
        torch.save(results[mode],output/('conditioning-'+mode+'.pt'))
        del hidden,layers;release();sync()
        emit('progress',phase='text_complete',mode=mode,seconds=time.perf_counter()-started)
    return results


class DiT:
    def __init__(self,ref,quantized,length):
        image_ids,text_ids=positions(32,length)
        with safe_open(a.work/'weights/dit.safetensors',framework='pt',device='cpu') as reader:
            with torch.device('meta'):module=InputStage(ref)
            self.input=assign(module,reader,lambda k:k)
            self.blocks={}
            for mode,count,ids in [('image',5,image_ids),('text',5,text_ids),('shared',28,torch.cat((image_ids,text_ids)))]:
                self.blocks[mode]=[]
                freqs=ref.rope_embed(ids[None]).cuda()
                for index in range(count):
                    with torch.device('meta'):block=ref.Block(3072,24,3.0)
                    wrapper=DiffusionBlock(block,freqs,1024 if mode=='shared' else 0)
                    prefix=f'single_blocks.{index}.' if mode=='shared' else (f'txt_mode_blocks.{index}.' if mode=='text' else f'content_mode_blocks.image.{index}.')
                    wrapper=assign(wrapper,reader,lambda k,prefix=prefix:prefix+k.removeprefix('block.'),f'{mode}_{index:02}' if quantized else None)
                    self.blocks[mode].append(wrapper)
                    emit('progress',phase='load_dit',mode='int4' if quantized else 'original',component=f'{mode}_{index:02}')
            with torch.device('meta'):module=OutputStage(ref,1024)
            self.output=assign(module,reader,lambda k:'final_layer.image.'+k.removeprefix('final.'))

    def velocity(self,latents,conditioning,current,target,cached=None):
        if cached is None:
            image,text,early_image,early_text,mods,vec=self.input(latents,conditioning,current,target)
            for block in self.blocks['text']:text=block(text,early_text)
        else:
            text,early_image,mods,vec=cached
            image=self.input.emb_in['image'](latents)
        for block in self.blocks['image']:image=block(image,early_image)
        hidden=torch.cat((image,text))
        for block in self.blocks['shared']:hidden=block(hidden,mods)
        return self.output(hidden,vec)

    @torch.inference_mode()
    def precompute(self,conditioning,schedule):
        result=[];zero=torch.zeros(1024,128,device='cuda')
        for current,target in zip(schedule[:-1],schedule[1:]):
            _,text,early_image,early_text,mods,vec=self.input(zero,conditioning,current,target)
            for block in self.blocks['text']:text=block(text,early_text)
            result.append((text,early_image,mods,vec))
        return result


@torch.inference_mode()
def sample(model,conditioning,seed,schedule,cached=None):
    if seed==42:noise=np.fromfile(a.work/'fixture/noise.f32',dtype='<f4').reshape(1024,128)
    else:noise=round_bf16_inplace(torch.randn((1024,128),generator=torch.Generator().manual_seed(seed)).numpy())
    latents=torch.from_numpy(noise.copy()).cuda()
    started=time.perf_counter()
    for step in range(16):
        velocity=model.velocity(latents,conditioning,schedule[step],schedule[step+1],None if cached is None else cached[step])
        dt=np.float32(schedule_values[step+1])-np.float32(schedule_values[step])
        latents=latents+float(dt)*velocity
        assert torch.isfinite(latents).all()
    sync()
    return latents.cpu(),time.perf_counter()-started


assert torch.cuda.is_available()
assert torch.cuda.get_device_capability(0)==(7,0), 'This controlled run was planned for the V100; review precision/VRAM for another device'
torch.set_num_threads(4)
torch.backends.cuda.matmul.allow_tf32=False
torch.backends.cudnn.allow_tf32=False
manifest=json.loads(a.cases.read_text());assert manifest['steps']==16 and manifest['width']==manifest['height']==512
if a.expected_cases_sha256:assert sha256(a.cases)==a.expected_cases_sha256, 'Remote prompts differ from screened local manifest'
output=a.work/'quality-reference-results'
if output.exists(): assert a.resume, 'Existing results preserved; use --resume with the same checked contract'
output.mkdir(exist_ok=True)
spec=json.loads((Path(__file__).parent/'model-spec.json').read_text())
for name,entry in spec['weights'].items():
    receipt=json.loads((a.work/'weights'/(name+'-source.json')).read_text())
    assert receipt['verified'] and receipt['sha256']==entry['sha256'] and (a.work/'weights'/(name+'.safetensors')).stat().st_size==entry['size']
ref,ae=reference(a.work/'reference');ref.packed_attention=math_attention
plan=json.loads((a.work/'model-plan.json').read_text());schedule_values=plan['caption']['schedule']
schedule=[torch.tensor([v],device='cuda') for v in schedule_values]
cases=manifest['cases'];report={'scope':__doc__,'gpu':torch.cuda.get_device_name(0),'torch':torch.__version__,'cuda':torch.version.cuda,'python':platform.python_version(),'cases_sha256':sha256(a.cases),'checkpoint_sha256':{k:v['sha256'] for k,v in spec['weights'].items()},'samples':[]}
contract={'version':'fp32-effective-int4-v1','cases_sha256':report['cases_sha256'],'checkpoint_sha256':report['checkpoint_sha256'],'torch':torch.__version__,'quant_reconstruction_sha256':sha256(Path(__file__).with_name('quantized_reference.py'))}
contract_path=output/'contract.json'
if contract_path.exists():assert json.loads(contract_path.read_text())==contract
else:contract_path.write_text(json.dumps(contract,indent=2)+'\n')
prior={}
progress_path=output/'samples-progress.jsonl'
if progress_path.exists():
    for line in progress_path.read_text().splitlines():
        entry=json.loads(line);assert sha256(output/(entry['label']+'.pt'))==entry['latent_file_sha256'];prior[entry['label']]=entry
emit('environment',**{k:report[k] for k in ['gpu','torch','cuda','python']})
features=encode_text(cases,manifest)
for mode in ['original','dit-int4','all-int4']:
    model=DiT(ref,mode!='original',manifest['text_length']);sync()
    for case in cases:
        conditioning=features['int4' if mode=='all-int4' else 'original'][case['id']].cuda()
        for seed in manifest['seeds']:
            label=f'{case["id"]}-seed{seed}-{mode}'
            if label in prior:
                latent=torch.load(output/(label+'.pt'),weights_only=True);entry=prior[label]
            else:
                latent,seconds=sample(model,conditioning,seed,schedule)
                torch.save(latent,output/(label+'.pt'))
                entry={'label':label,'case_id':case['id'],'seed':seed,'mode':mode,'denoising_seconds':seconds,'latent_file_sha256':sha256(output/(label+'.pt'))}
                with progress_path.open('a') as stream:stream.write(json.dumps(entry)+'\n')
            report['samples'].append(entry)
            emit('sample_complete',**report['samples'][-1])
            if mode=='original' and case['id']==cases[0]['id'] and seed==manifest['seeds'][0]:
                cache=model.precompute(conditioning,schedule)
                optimized,_=sample(model,conditioning,seed,schedule,cache)
                difference=float(torch.max(torch.abs(latent-optimized)))
                report['precompute_algorithm_check']={'max_abs_latent_error':difference,'exact_equal':bool(torch.equal(latent,optimized))}
                assert torch.equal(latent,optimized),report['precompute_algorithm_check']
                emit('precompute_check',**report['precompute_algorithm_check']);del cache
        del conditioning
    del model;release()

with torch.device('meta'):decoder=Decoder(ae)
with safe_open(a.work/'weights/vae.safetensors',framework='pt',device='cpu') as reader:decoder=assign(decoder,reader,lambda k:k)
mean=torch.tensor(plan['bn_mean'],device='cuda');var=torch.tensor(plan['bn_var'],device='cuda')
pixels={};latents={}
with torch.inference_mode():
    for sample_info in report['samples']:
        label=sample_info['label'];latent=torch.load(output/(label+'.pt'),weights_only=True);latents[label]=latent.numpy()
        h=latent.cuda()*torch.sqrt(var+plan['bn_eps'])+mean
        spatial=h.reshape(32,32,32,2,2).permute(2,0,3,1,4).reshape(1,32,64,64)
        rgb=decoder(spatial)[0].permute(1,2,0).cpu().numpy();assert np.isfinite(rgb).all()
        rgb=np.clip((rgb*.5+.5)*255,0,255).astype(np.uint8);pixels[label]=rgb
        stream=io.BytesIO();Image.fromarray(rgb).save(stream,format='PNG')
        emit('image',label=label,case_id=sample_info['case_id'],mode=sample_info['mode'],seed=sample_info['seed'],png_base64=base64.b64encode(stream.getvalue()).decode())
del decoder;release()
report['distances']=[]
for case in cases:
    for seed in manifest['seeds']:
        baseline=f'{case["id"]}-seed{seed}-original';base=pixels[baseline].astype(np.float32)/255
        for mode in ['dit-int4','all-int4']:
            label=f'{case["id"]}-seed{seed}-{mode}';image=pixels[label].astype(np.float32)/255
            mse=float(np.mean((base-image)**2))
            metric={'case_id':case['id'],'seed':seed,'mode':mode,'pixel_mae_0_to_1':float(np.mean(np.abs(base-image))),
                    'psnr_db':float(-10*np.log10(max(mse,1e-20))),'ssim':ssim_7x7(base,image),
                    'latent_relative_rmse':float(np.linalg.norm(latents[label]-latents[baseline])/np.linalg.norm(latents[baseline]))}
            report['distances'].append(metric)
report['max_cuda_allocated_bytes']=torch.cuda.max_memory_allocated()
report['max_cuda_reserved_bytes']=torch.cuda.max_memory_reserved()
(output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
emit('complete',report=report)
