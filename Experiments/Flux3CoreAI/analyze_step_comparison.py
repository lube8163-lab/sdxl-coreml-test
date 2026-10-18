#!/usr/bin/env python3
"""Verify native step-count runs, summarize timings, and render comparison sheets."""

import argparse
import collections
import csv
import hashlib
import json
import math
import statistics
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def stats(values):
    assert values and all(math.isfinite(x) for x in values)
    return {'n': len(values), 'mean': statistics.mean(values), 'median': statistics.median(values),
            'min': min(values), 'max': max(values)}


def box_mean(x):
    # Uniform 7x7 valid window, matching the prior CUDA comparison metric.
    integral = np.pad(x, ((1, 0), (1, 0), (0, 0))).cumsum(0).cumsum(1)
    return (integral[7:, 7:] - integral[:-7, 7:] - integral[7:, :-7] + integral[:-7, :-7]) / 49


def distances(x, y):
    x, y = x.astype(np.float64) / 255, y.astype(np.float64) / 255
    ux, uy = box_mean(x), box_mean(y)
    vx, vy = (box_mean(x * x) - ux * ux) * (49 / 48), (box_mean(y * y) - uy * uy) * (49 / 48)
    cov = (box_mean(x * y) - ux * uy) * (49 / 48)
    ssim = ((2 * ux * uy + .01 ** 2) * (2 * cov + .03 ** 2)) / ((ux * ux + uy * uy + .01 ** 2) * (vx + vy + .03 ** 2))
    mse = float(np.mean((x - y) ** 2))
    return {'pixel_mae_0_to_1': float(np.mean(np.abs(x - y))),
            'psnr_db': -10 * math.log10(max(mse, 1e-20)), 'ssim_7x7': float(ssim.mean())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    protocol = json.loads((args.run / 'protocol.json').read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    reports, summaries, images = {}, {}, {}
    integrity = []
    for spec in protocol['runs']:
        name = spec['name']
        folder = args.run / name
        report = json.loads((folder / 'report.json').read_text())
        analysis = json.loads((folder / 'analysis.json').read_text())
        assert report['image_saved'] and report['image_approved'] and report['asset_hashes_verified']
        assert analysis['six_view_safety_verified'] and len(report['step_records']) == spec['steps']
        path = folder / report['image_filename']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == report['image_sha256']
        samples = list(csv.DictReader((folder / 'memory.csv').open()))
        sampled_peak = max(int(x['physical_footprint_bytes']) for x in samples)
        assert sampled_peak == report['sampled_peak_physical_footprint_bytes']
        with Image.open(path) as image:
            assert image.size == (512, 512)
            images[name] = image.convert('RGB').copy()
        reports[name], summaries[name] = report, analysis
        integrity.append({'run': name, 'png_sha256_verified': True, 'six_view_safety_verified': True,
                          'csv_peak_matches_report': True, 'samples': len(samples),
                          'maximum_sample_gap_ms': report['maximum_observed_sample_gap_ms']})
    aggregates = {}
    fields = ['model_pipeline_seconds', 'text_encoding_seconds', 'text_precompute_seconds', 'denoising_seconds',
              'vae_seconds', 'run_to_saved_seconds', 'output_safety_seconds',
              'safety_preparation_seconds', 'input_safety_seconds', 'sampled_peak_footprint_bytes']
    for steps in (16, 8, 4):
        names = [x['name'] for x in protocol['runs'] if x['profile'] and x['steps'] == steps]
        eligible = [n for n in names if all(s['thermal_state'] <= 1 for s in reports[n]['step_records'])]
        aggregates[str(steps)] = {}
        for scope, selected in [('all_completed', names), ('without_serious_or_critical_steps', eligible)]:
            aggregates[str(steps)][scope] = {'runs': selected, 'n': len(selected), 'metrics': {
                field: stats([summaries[n][field] for n in selected]) for field in fields
            } if selected else {}}
    comparisons = []
    profiles = list(dict.fromkeys(x['profile'] for x in protocol['runs'] if x['profile']))
    matched_profiles = [p for p in profiles if all(
        s['thermal_state'] <= 1 for steps in (16, 8, 4)
        for s in reports[p + '-s' + str(steps)]['step_records'])]
    matched_timings = {str(steps): {'profiles': matched_profiles, 'n': len(matched_profiles), 'metrics': {
        field: stats([summaries[p + '-s' + str(steps)][field] for p in matched_profiles])
        for field in fields
    } if matched_profiles else {}} for steps in (16, 8, 4)}
    paired_speedups = {str(steps): stats([
        summaries[p + '-s16']['model_pipeline_seconds'] / summaries[p + '-s' + str(steps)]['model_pipeline_seconds']
        for p in matched_profiles]) for steps in (8, 4)} if matched_profiles else {}
    cohort_path = args.run / 'cooling-cohorts.json'
    cohort_map = json.loads(cohort_path.read_text())['profiles'] if cohort_path.exists() else {p: 'unspecified' for p in profiles}
    assert set(cohort_map) == set(profiles)
    cohorts = {}
    for cohort in sorted(set(cohort_map.values())):
        selected = [p for p in matched_profiles if cohort_map[p] == cohort]
        cohorts[cohort] = {'matched_profiles': selected, 'n': len(selected), 'metrics_by_steps': {
            str(steps): {field: stats([summaries[p + '-s' + str(steps)][field] for p in selected])
                         for field in fields} if selected else {} for steps in (16, 8, 4)}}
    for profile in profiles:
        baseline = np.asarray(images[profile + '-s16'])
        for steps in (8, 4):
            comparisons.append({'profile': profile, 'steps': steps,
                                **distances(baseline, np.asarray(images[profile + '-s' + str(steps)]))})
    distance_summary = {str(steps): {key: stats([x[key] for x in comparisons if x['steps'] == steps])
                       for key in ['pixel_mae_0_to_1', 'psnr_db', 'ssim_7x7']} for steps in (8, 4)}
    summary = {'hardware_model': reports['warmup']['hardware_model'], 'os': reports['warmup']['os_version'],
               'complete_runs_including_warmup': len(reports), 'comparison_images': len(reports) - 1,
               'conditions': 'Release,512x512,CoreAI INT4/BF16,Groups8,precompute-text,cache0/shared4; fixed160 text tokens',
               'aggregates': aggregates, 'matched_profile_timings': matched_timings,
               'matched_profile_speedups': paired_speedups, 'cooling_cohorts': cohorts,
               'distance_summary': distance_summary,
               'safety_all_runs': True, 'low_power_mode_any': any(r['low_power_mode'] for r in reports.values()),
               'thermal_state_counts_by_steps': {str(steps): dict(collections.Counter(
                   str(s['thermal_state']) for spec in protocol['runs'] if spec['profile'] and spec['steps'] == steps
                   for s in reports[spec['name']]['step_records'])) for steps in (16, 8, 4)},
               'interpretation': 'Distances from matching 16-step output, not quality percentages. Timings are model wall time, not isolated GPU kernels. Memory is sampled process physical footprint.'}
    for filename, value in [('summary.json', summary), ('memory-integrity.json', integrity), ('distances.json', comparisons)]:
        (args.output / filename).write_text(json.dumps(value, indent=2) + '\n')
    font, small = ImageFont.load_default(size=22), ImageFont.load_default(size=18)
    for seed in sorted({x['seed'] for x in protocol['runs'] if x['profile']}):
        names = [p for p in profiles if p.endswith('-seed' + str(seed))]
        tile, margin, header, row_label = 384, 20, 78, 44
        sheet = Image.new('RGB', (margin * 2 + 3 * tile, header + len(names) * (tile + row_label) + margin), 'white')
        draw = ImageDraw.Draw(sheet)
        draw.text((margin, 8), f'FLUX.3 / iPhone 17 / CoreAI INT4 / 512px / seed {seed}', fill='black', font=font)
        for column, steps in enumerate((16, 8, 4)):
            draw.text((margin + column * tile, 44), f'{steps} steps', fill='black', font=small)
        for row, profile in enumerate(names):
            y = header + row * (tile + row_label)
            for column, steps in enumerate((16, 8, 4)):
                name = profile + '-s' + str(steps)
                x = margin + column * tile
                draw.text((x, y + 8), f'{profile.split("-seed")[0]} / {summaries[name]["model_pipeline_seconds"]:.1f}s', fill='black', font=small)
                sheet.paste(images[name].resize((tile, tile), Image.Resampling.LANCZOS), (x, y + row_label))
        sheet.save(args.output / f'comparison-seed{seed}.png')
    table = ['| Run | Steps | Model s | To saved s | Output safety s | Peak GB | Thermal states |',
             '| --- | ---: | ---: | ---: | ---: | ---: | --- |']
    for spec in protocol['runs']:
        name = spec['name']
        r, s = reports[name], summaries[name]
        states = sorted({x['thermal_state'] for x in r['step_records']})
        table.append(f'| {name} | {spec["steps"]} | {s["model_pipeline_seconds"]:.3f} | {r["run_to_saved_seconds"]:.3f} | {r["output_safety_seconds"]:.4f} | {s["sampled_peak_footprint_bytes"]/1e9:.3f} | {states} |')
    (args.output / 'all-runs.md').write_text('\n'.join(table) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
