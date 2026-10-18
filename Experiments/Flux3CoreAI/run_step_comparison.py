#!/usr/bin/env python3
"""Run a balanced 16/8/4-step native-device comparison, preserving every run."""

import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path


def emit(**value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--label-prefix', required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--rest-seconds', type=float, default=20)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    assert args.label_prefix and len(args.label_prefix) <= 32
    assert all(c.isascii() and (c.isalnum() or c in '-_') for c in args.label_prefix)
    args.output.mkdir(parents=True, exist_ok=args.resume)
    manifest = json.loads((args.fixtures / 'manifest.json').read_text())
    baseline = json.loads(args.baseline.read_text())
    bundle = 'com.tasuku.sdxlcoremltest.flux3generationprobe'
    orders = [(16, 8, 4), (8, 4, 16), (4, 16, 8)]
    runs = [{'name': 'warmup', 'steps': 16, 'profile': None}]
    for index, profile in enumerate(manifest['profiles']):
        for steps in orders[index % len(orders)]:
            runs.append(dict(profile, name=profile['profile'] + '-s' + str(steps), steps=steps))
    protocol = {'device': args.device, 'bundle': bundle, 'rest_seconds': args.rest_seconds,
                'thermal_policy': 'Retain all completed runs; separately summarize runs with no serious/critical step.',
                'warmup': 'Excluded from aggregate comparisons; must reproduce prior 16-step PNG.',
                'runs': runs}
    protocol_path = args.output / 'protocol.json'
    if protocol_path.exists():
        assert json.loads(protocol_path.read_text()) == protocol
    else:
        protocol_path.write_text(json.dumps(protocol, indent=2) + '\n')
    for index, run in enumerate(runs):
        name = run['name']
        final = args.output / name
        if final.exists():
            assert args.resume and json.loads((final / 'report.json').read_text())['image_saved']
            emit(run=name, reused_completed=True)
            continue
        if index:
            time.sleep(args.rest_seconds)
        label = args.label_prefix + '-' + name
        launch_json = args.output / ('launch-' + name + '.json')
        command = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                   '--terminate-existing', '--json-output', str(launch_json), bundle, '--',
                   '--result-label=' + label, '--precompute-text', '--steps=' + str(run['steps'])]
        if run['profile']:
            command.append('--fixture-profile=' + run['profile'])
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        (args.output / ('launch-' + name + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        emit(run=name, launched=True, steps=run['steps'])
        for check in range(91):
            time.sleep(10)
            progress = args.output / ('progress-' + name + '-' + str(check).zfill(2) + '.json')
            source = 'Documents/Flux3Results-' + label
            copy = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                                   '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                   '--source', source + '/report.json', '--destination', str(progress)],
                                  capture_output=True, text=True, timeout=35)
            if copy.returncode:
                emit(run=name, retry=check, detail=(copy.stdout + copy.stderr)[-400:])
                continue
            report = json.loads(progress.read_text())
            emit(run=name, stage=report['stage'], completed_steps=len(report.get('step_records', [])))
            assert not report.get('error'), report
            if not report.get('image_saved'):
                continue
            copy = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                                   '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                   '--source', source, '--destination', str(final)],
                                  capture_output=True, text=True, timeout=45)
            assert copy.returncode == 0, copy.stdout + copy.stderr
            report = json.loads((final / 'report.json').read_text())
            assert report['image_approved'] and report['asset_hashes_verified'] and report['image_input_slice_verified']
            assert len(report['step_records']) == run['steps'] == report['steps'] == report['cached_text_step_count']
            assert report['sampling_schedule'] == manifest['schedules'][str(run['steps'])]
            if run['profile']:
                assert report['fixture_profile_sha256'] == run['profile_sha256']
                assert report['seed'] == run['seed']
            else:
                assert report['image_sha256'] == baseline['image_sha256'], '16-step baseline changed'
            assert hashlib.sha256((final / report['image_filename']).read_bytes()).hexdigest() == report['image_sha256']
            analyze = subprocess.run(['python3', str(Path(__file__).with_name('analyze_performance.py')),
                                      str(final), '--output', str(final / 'analysis.json')],
                                     capture_output=True, text=True, timeout=60)
            assert analyze.returncode == 0, analyze.stdout + analyze.stderr
            analysis = json.loads((final / 'analysis.json').read_text())
            emit(run=name, complete=True, model_seconds=analysis['model_pipeline_seconds'],
                 total_seconds=report['run_to_saved_seconds'], safety_seconds=report['output_safety_seconds'],
                 thermal_states=sorted({x['thermal_state'] for x in report['step_records']}))
            break
        else:
            raise TimeoutError(name)
    emit(complete=True, completed_runs=len(runs))


if __name__ == '__main__':
    main()
