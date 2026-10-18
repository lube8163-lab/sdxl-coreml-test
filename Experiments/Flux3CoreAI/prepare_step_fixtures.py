#!/usr/bin/env python3
"""Prepare hash-checked native fixtures for 16/8/4-step comparison."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
from tokenizers import Tokenizer

from models import text_position_inputs


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--tokenizer', type=Path, required=True)
    parser.add_argument('--cases', type=Path, default=Path(__file__).with_name('quality-cases.json'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    cases = json.loads(args.cases.read_text())
    length = plan['caption']['text_length']
    assert cases['text_length'] == length and cases['width'] == cases['height'] == 512
    tokenizer = Tokenizer.from_file(str(args.tokenizer))
    assert sha(args.tokenizer) == plan['caption']['tokenizer_sha256']['tokenizer.json']
    schedules = {}
    base = torch.tensor(plan['caption']['schedule'], dtype=torch.float32)
    for steps in (16, 8, 4):
        t = torch.linspace(1., 0., steps + 1)
        expected = 6.93 * t / (1. + (6.93 - 1.) * t)
        actual = base[::16 // steps]
        assert torch.equal(actual, expected), (steps, actual, expected)
        schedules[str(steps)] = actual.tolist()
    args.output.mkdir(parents=True, exist_ok=False)
    profiles = []
    for case in cases['cases']:
        assert case['id'] and all(c.isascii() and (c.isalnum() or c in '-_') for c in case['id'])
        chat = '<|im_start|>user\n' + case['caption'] + '<|im_end|>\n<|im_start|>assistant\n'
        ids = tokenizer.encode(chat, add_special_tokens=False).ids
        assert len(ids) <= length and tokenizer.decode(ids, skip_special_tokens=False) == chat
        cos, sin, mask = text_position_inputs(len(ids), length)
        for seed in cases['seeds']:
            name = case['id'] + '-seed' + str(seed)
            folder = args.output / name
            folder.mkdir()
            np.asarray(ids + [151643] * (length - len(ids)), dtype='<i4').tofile(folder / 'token_ids.i32')
            for key, value in [('cos', cos), ('sin', sin), ('mask', mask)]:
                value.float().numpy().astype('<f4').tofile(folder / (key + '.f32'))
            noise = torch.randn((1024, 128), generator=torch.Generator().manual_seed(seed)).bfloat16().float()
            noise.numpy().astype('<f4').tofile(folder / 'noise.f32')
            caption = dict(plan['caption'], original_prompt=case['original_prompt'], expanded_caption=case['caption'],
                           seed=seed, real_tokens=len(ids), exact_tokenizer_input=chat,
                           token_ids=ids + [151643] * (length - len(ids)))
            hashes = {p.name: sha(p) for p in sorted(folder.iterdir())}
            (folder / 'profile.json').write_text(json.dumps({'caption': caption, 'fixture_files_sha256': hashes}, indent=2) + '\n')
            profiles.append({'profile': name, 'case': case['id'], 'seed': seed, 'real_tokens': len(ids),
                             'profile_sha256': sha(folder / 'profile.json'), 'fixture_files_sha256': hashes})
    receipt = {'cases_sha256': sha(args.cases), 'source_plan_sha256': sha(args.plan),
               'tokenizer_sha256': sha(args.tokenizer), 'schedules': schedules,
               'reference_schedule_exact_match': True, 'profiles': profiles}
    (args.output / 'manifest.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'profiles': len(profiles), 'reference_schedule_exact_match': True}))


if __name__ == '__main__':
    main()
