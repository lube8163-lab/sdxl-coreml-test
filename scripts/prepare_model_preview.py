#!/usr/bin/env python3
"""Copy the main app into a separate development bundle; default has no test hooks."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--bundle-id', default='com.tasuku.sdxlcoremltest.preview')
    parser.add_argument('--model-validation-driver', action='store_true',
                        help='Append the isolated model-selection download/generation driver; not a tap test.')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\.preview', args.bundle_id):
        parser.error('Use a separate development bundle identifier ending in .preview.')
    root = Path(__file__).resolve().parents[1]
    dest = args.destination.resolve()
    if dest.exists() or dest.is_relative_to(root):
        parser.error('Use a fresh directory outside the repository.')
    dest.mkdir(parents=True)
    for name in ['SDXLCoreMLTest', 'LocalImageGenerationUITests']:
        subprocess.run(['/bin/cp', '-cR', str(root / name), str(dest / name)], check=True)
    shutil.copytree(root / 'SDXLCoreMLTest.xcodeproj', dest / 'SDXLCoreMLTest.xcodeproj',
                    ignore=shutil.ignore_patterns('xcuserdata', '*.xcuserstate'))
    for name in ['Vendor', 'scripts']:
        (dest / name).symlink_to(root / name, target_is_directory=True)
    project = dest / 'SDXLCoreMLTest.xcodeproj/project.pbxproj'
    value = project.read_text()
    for old, new in [('com.tasuku.sdxlcoremltest', args.bundle_id),
                     ('com.tasuku.sdxlcoremltest.uitests', args.bundle_id + '.uitests')]:
        original = 'PRODUCT_BUNDLE_IDENTIFIER = ' + old + ';'
        assert value.count(original) == 2
        value = value.replace(original, 'PRODUCT_BUNDLE_IDENTIFIER = ' + new + ';')
    project.write_text(value)
    info = dest / 'SDXLCoreMLTest/Info.plist'
    value = plistlib.loads(info.read_bytes())
    value['CFBundleDisplayName'] = 'ローカル画像生成 Preview'
    info.write_bytes(plistlib.dumps(value, sort_keys=False))
    if args.model_validation_driver:
        bootstrap = dest / 'SDXLCoreMLTest/SDXLCoreMLTestApp.swift'
        value = bootstrap.read_text()
        original = 'if welcomeCompleted { setup.inspectInstallation() }'
        # Only the initial .task changes; welcome/scene callbacks keep production behavior.
        anchor = '.task {\n                    ' + original
        assert value.count(anchor) == 1
        value = value.replace(anchor, '.task {\n                    if CommandLine.arguments.contains("--model-selection-validation") { ModelSelectionValidation.start(self) }\n                    else ' + original)
        bootstrap.write_text(value + '\n' + (root / 'scripts/device-probe/ModelSelectionValidation.swift').read_text())
    sources = list((root / 'SDXLCoreMLTest').glob('*.swift'))
    sources += list((root / 'Vendor/LocalImageGeneration/Sources/LocalImageGeneration').glob('*.swift'))
    (dest / 'preview-provenance.json').write_text(json.dumps({
        'scope': ('Main app UI/setup/VM/runtime with an isolated startup validation driver.' if args.model_validation_driver
                  else 'Main app Swift sources copied unchanged; different bundle/display name; no startup test hooks.'),
        'bundle_id': args.bundle_id,
        'source_root': str(root),
        'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        'local_packages_are_live_symlinks': True,
        'model_validation_driver': args.model_validation_driver,
        'validation_driver_sha256': (hashlib.sha256((root / 'scripts/device-probe/ModelSelectionValidation.swift').read_bytes()).hexdigest()
                                     if args.model_validation_driver else None),
        'app_store_actions': False
    }, indent=2) + '\n')
    print(dest)


if __name__ == '__main__':
    main()
