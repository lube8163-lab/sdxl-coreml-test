#!/usr/bin/env python3
"""Package the measured native FLUX.3 route without duplicate block weights.

Writes a ZIP64 stream directly into 200MB fragments: no second multi-GB archive
is needed. Model receipts are verified before packaging. Nothing uploads here.
"""
import argparse
import hashlib
import io
import json
import os
import shutil
import sys
import zipfile
from pathlib import Path

REVISION = 'coreai-flux3-512-int4-dd2ae0a-v1'
PREFIX = 'CoreAI/generation/flux3-klein-512-int4-dd2ae0a-v1/'
PUBLIC = 'https://pub-41a85dcbeaae42d58c317781ea160d68.r2.dev/'
ROOT = 'flux3-klein-512-v1/'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(4 << 20), b''):
            value.update(block)
    return value.hexdigest()


class Fragments(io.RawIOBase):
    def __init__(self, folder, size=200_000_000):
        self.folder, self.size = folder, size
        self.position, self.current_size = 0, 0
        self.archive_hash = hashlib.sha256()
        self.current_hash = hashlib.sha256()
        self.handle = None
        self.parts = []

    def writable(self): return True
    def seekable(self): return False
    def tell(self): return self.position

    def finish_part(self):
        if self.handle is None: return
        self.handle.close()
        self.parts.append({'url': PUBLIC + PREFIX + self.name, 'bytes': self.current_size,
                           'sha256': self.current_hash.hexdigest()})
        print(json.dumps({'fragment': len(self.parts), 'bytes': self.current_size}), flush=True)
        self.handle = None

    def write(self, data):
        total = len(data)
        self.archive_hash.update(data)
        while data:
            if self.handle is None:
                self.name = 'flux3_klein_512_int4_v1.zip.part' + str(len(self.parts) + 1).zfill(3)
                self.handle = (self.folder / self.name).open('xb')
                self.current_hash = hashlib.sha256()
                self.current_size = 0
            count = min(len(data), self.size - self.current_size)
            block, data = data[:count], data[count:]
            self.handle.write(block)
            self.current_hash.update(block)
            self.current_size += count
            self.position += count
            if self.current_size == self.size: self.finish_part()
        return total


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--models', type=Path, required=True)
    p.add_argument('--split-input', type=Path, required=True)
    p.add_argument('--tokenizer', type=Path, required=True)
    p.add_argument('--licenses', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    contents = args.output / 'contents'
    contents.mkdir()
    plan = json.loads((args.models / 'model-plan.json').read_text())
    groups = json.loads((args.models / 'Groups8/groups.json').read_text())['groups']
    active = [x for x in plan['components'] if not x['component'].startswith(('image_', 'text_', 'shared_'))]
    assert len(active) == 37 and len(groups) == 6
    assert plan['caption']['text_length'] == 160
    paths = {}

    def import_asset(source, relative, receipt):
        paths[receipt['component']] = relative
        for name, expected in receipt['asset_files_sha256'].items():
            src = source / name
            assert digest(src) == expected, src
            target = contents / relative / name
            target.parent.mkdir(parents=True, exist_ok=True)
            os.link(src, target)

    for item in active:
        import_asset(args.models / (item['component'] + '.aimodel'), item['component'] + '.aimodel', item)
    for group in groups:
        relative = 'Groups8/' + group['component'] + '.aimodel'
        import_asset(args.models / relative, relative, group)
    split = json.loads((args.split_input / 'input_image.json').read_text())
    import_asset(args.split_input / 'input_image.aimodel', 'SplitInput/input_image.aimodel', split)
    (contents / 'tokenizer').mkdir()
    for source in args.tokenizer.glob('*.json'):
        shutil.copyfile(source, contents / 'tokenizer' / source.name)
    (contents / 'licenses').mkdir()
    for source in args.licenses.iterdir():
        if source.is_file(): shutil.copyfile(source, contents / 'licenses' / source.name)
    assert (contents / 'licenses/FLUX3-LICENSE.md').exists()
    assert (contents / 'licenses/FLUX3-NOTICE.md').exists()
    assert (contents / 'licenses/QWEN3-VL-LICENSE').exists()
    notice = (contents / 'licenses/FLUX3-NOTICE.md').read_text()
    notice += '\n\nModified version: converted to CoreAI INT4 Linear weights, BF16 DiT computation, '
    notice += '512px text-to-image graphs, grouped blocks and sliced image-input projection. '
    notice += 'Not an official or endorsed Black Forest Labs conversion.\n'
    (contents / 'NOTICE.md').write_text(notice)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Experiments/Flux3CoreAI'))
    from models import text_position_inputs
    cos, sin, _ = text_position_inputs(160, 160)
    cos.float().numpy().astype('<f4').tofile(contents / 'text-cos.f32')
    sin.float().numpy().astype('<f4').tofile(contents / 'text-sin.f32')
    config = {'formatVersion': 1, 'revision': REVISION, 'textLength': 160, 'imageTokens': 1024,
              'bnMean': plan['bn_mean'], 'bnVar': plan['bn_var'], 'bnEps': plan['bn_eps'],
              'schedule16': plan['caption']['schedule'], 'assetPaths': paths,
              'imageBlocks': [g['component'] for g in groups if g['mode'] == 'image'],
              'textBlocks': [g['component'] for g in groups if g['mode'] == 'text'],
              'sharedBlocks': [g['component'] for g in groups if g['mode'] == 'shared']}
    (contents / 'runtime-config.json').write_text(json.dumps(config, indent=2) + '\n')
    files = [{'path': str(f.relative_to(contents)), 'bytes': f.stat().st_size, 'sha256': digest(f)}
             for f in sorted(contents.rglob('*')) if f.is_file()]
    catalog = {'revision': REVISION, 'modelID': 'flux3-klein', 'width': 512, 'height': 512, 'files': files}
    catalog_path = args.output / 'flux3-catalog-manifest.json'
    catalog_path.write_text(json.dumps(catalog, indent=2) + '\n')
    stream = Fragments(args.output)
    with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=3, allowZip64=True) as archive:
        for index, entry in enumerate(files):
            info = zipfile.ZipInfo(ROOT + entry['path'], date_time=(2026, 10, 18, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            info._compresslevel = 3
            with (contents / entry['path']).open('rb') as source, archive.open(info, 'w', force_zip64=True) as output:
                shutil.copyfileobj(source, output, 1 << 20)
            print(json.dumps({'file': index + 1, 'of': len(files), 'path': entry['path']}), flush=True)
    stream.finish_part()
    download = {'revision': REVISION, 'modelID': 'flux3-klein', 'archiveBytes': stream.position,
                'installedBytes': sum(f['bytes'] for f in files), 'archiveSHA256': stream.archive_hash.hexdigest(),
                'manifestSHA256': digest(catalog_path), 'fragments': stream.parts}
    (args.output / 'flux3-download-manifest.json').write_text(json.dumps(download, indent=2) + '\n')
    print(json.dumps({'complete': True, 'archiveBytes': stream.position, 'installedBytes': download['installedBytes'],
                      'archiveSHA256': download['archiveSHA256'], 'fragments': len(stream.parts)}), flush=True)


if __name__ == '__main__': main()
