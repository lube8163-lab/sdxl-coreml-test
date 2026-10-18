#!/usr/bin/env python3
"""Upload a prepared model to a new immutable R2 prefix and verify public bytes."""
import argparse
import hashlib
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path


def remote_hash(url):
    with subprocess.Popen(['curl', '--fail', '--silent', '--show-error', '--location', '--retry', '3',
                           '--retry-delay', '3', '--max-time', '900', url], stdout=subprocess.PIPE) as response:
        digest = hashlib.sha256()
        count = 0
        for chunk in iter(lambda: response.stdout.read(2 << 20), b''):
            digest.update(chunk)
            count += len(chunk)
        assert response.wait() == 0, 'Public download failed'
        return count, digest.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package', type=Path, required=True)
    p.add_argument('--account', required=True)
    p.add_argument('--bucket', required=True)
    p.add_argument('--prefix', required=True)
    p.add_argument('--journal', type=Path, required=True)
    args = p.parse_args()
    assert args.prefix.startswith('CoreAI/generation/flux3-') and args.prefix.endswith('/')
    assert '..' not in args.prefix and len(args.account) == 32
    download_path = args.package / 'flux3-download-manifest.json'
    for _ in range(180):
        if download_path.exists(): break
        time.sleep(10)
    else: raise TimeoutError('Package was not completed')
    package = json.loads(download_path.read_text())
    objects = list(package['fragments'])
    base = 'https://pub-41a85dcbeaae42d58c317781ea160d68.r2.dev/'
    for name in ['flux3-catalog-manifest.json', 'flux3-download-manifest.json']:
        data = (args.package / name).read_bytes()
        objects.append({'url': base + args.prefix + name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    progress = {'revision': package['revision'], 'bucket': args.bucket, 'prefix': args.prefix,
                'completed': [], 'total': len(objects), 'status': 'uploading'}
    if args.journal.exists():
        previous = json.loads(args.journal.read_text())
        assert previous['revision'] == progress['revision'] and previous['prefix'] == args.prefix
    args.journal.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CLOUDFLARE_ACCOUNT_ID=args.account)
    for obj in objects:
        assert obj['url'].startswith(base + args.prefix)
        name = obj['url'].rsplit('/', 1)[1]
        source = args.package / name
        progress['current'] = name
        args.journal.write_text(json.dumps(progress, indent=2) + '\n')
        head = subprocess.run(['curl', '--silent', '--show-error', '--head', '--max-time', '30',
            '--output', '/dev/null', '--write-out', '%{http_code}', obj['url']], capture_output=True, text=True)
        assert head.returncode == 0 and head.stdout in ['200', '404'], head.stdout + head.stderr
        exists = head.stdout == '200'
        if not exists:
            assert source.stat().st_size == obj['bytes']
            log = args.journal.parent / ('upload-' + name + '.log')
            with log.open('a') as handle:
                for attempt in range(3):
                    result = subprocess.run(['wrangler', 'r2', 'object', 'put', args.bucket + '/' + args.prefix + name,
                        '--file', str(source), '--content-type', 'application/json' if name.endswith('.json') else 'application/octet-stream',
                        '--cache-control', 'public, max-age=31536000, immutable', '--remote'],
                        env=env, stdout=handle, stderr=subprocess.STDOUT, timeout=3600)
                    if result.returncode == 0: break
                    time.sleep(5)
                assert result.returncode == 0, 'Upload failed: ' + name
        # Never replace a different object under an immutable URL.
        count, actual = remote_hash(obj['url'])
        assert count == obj['bytes'] and actual == obj['sha256'], ('Public integrity mismatch', name)
        progress['completed'].append(dict(obj, public_sha256_verified=True, reused_existing=exists))
        args.journal.write_text(json.dumps(progress, indent=2) + '\n')
        print(json.dumps({'verified': len(progress['completed']), 'total': len(objects), 'name': name}), flush=True)
    progress['status'] = 'completed'
    progress.pop('current', None)
    args.journal.write_text(json.dumps(progress, indent=2) + '\n')
    print(json.dumps({'complete': True, 'verified_objects': len(objects)}), flush=True)


if __name__ == '__main__': main()
