# FLUX.3 in ローカル画像生成 (development)

The 2026-10-18 development source adds FLUX.3 to the main app's model selection,
download installer and checked generation path. The App Store release and MiM
remain unchanged. A separately signed Preview app is used for physical validation.

## User flow

- FLUX.2 remains the initial choice and uses its existing four-step sampler.
- “変更” opens model management. Each model shows download size, installed size,
  supported steps and whether it is already saved.
- Selecting an unavailable model opens its download preparation screen. Download
  starts only after the user taps its button. Wi-Fi is the default.
- A partial download belongs to its model revision and can resume after pausing,
  backgrounding or relaunch. Installing another model preserves existing models.
- Cancelling the check of an already installed model resumes file verification
  without downloading the archive again. Start/pause controls stay at the bottom
  of the preparation screen while its details scroll.
- FLUX.3 exposes 4 / 8 / 16 steps as 高速 / 標準 / じっくり. The initial setting is
  four steps. More steps can change composition and detail; they are not a
  guarantee of a better result for every prompt and seed.
- Model-specific step choices are remembered. An approved image retains its own
  model, steps, prompt and seed when the current settings change.
- Unselected downloaded model files can be deleted after confirmation. Images
  remain temporary in-memory results, with existing Photos/Share actions.

## Package and storage

| | FLUX.2 Klein 4B | FLUX.3 Image Klein |
| --- | ---: | ---: |
| Download bytes | 3,542,141,404 | 4,925,833,766 |
| Installed model bytes | 4,043,710,174 | 5,764,051,319 |
| Initial free-space requirement | about 9 GB | about 13 GB |
| Files | 17 | 144 |
| Download fragments | 18 | 25 |

The free-space check includes a conservative compilation-cache allowance, not just
model weights. Actual cache size can vary. The safety classifier stays bundled;
both sets of generation weights are excluded from the default app build.

FLUX.3 revision: `coreai-flux3-512-int4-dd2ae0a-v1`.
Archive SHA-256: `15608f44e7e41c0d1e3aafbb972de7a973986aed58d462a340c33b2afdb99638`.
Public [download manifest](https://pub-41a85dcbeaae42d58c317781ea160d68.r2.dev/CoreAI/generation/flux3-klein-512-int4-dd2ae0a-v1/flux3-download-manifest.json)
and [file catalog](https://pub-41a85dcbeaae42d58c317781ea160d68.r2.dev/CoreAI/generation/flux3-klein-512-int4-dd2ae0a-v1/flux3-catalog-manifest.json).
The same pinned manifests are resources of `Vendor/LocalImageGeneration`.
The new prefix does not replace FLUX.2 or a MiM model catalog.

The installer verifies the complete archive SHA-256 and every uncompressed file's
size and SHA-256 before activation. It uses staging, cancellation checks, path and
symlink rejection, atomic activation/rollback and backup exclusion. A successful
installation removes the archive. Launch checks the installed hashes again.

## Native generation

`Flux3Runtime.swift` replaces the experimental fixture inputs with offline Qwen
tokenization and seed-derived noise for the user's actual prompt. Seven English,
Japanese and emoji tokenization cases match the pinned Python tokenizer exactly.
The graph accepts at most 160 tokens including chat formatting. Long input is
rejected with guidance to shorten it, rather than silently truncated.

The runtime retains the measured grouped-block route and text precomputation.
It subsamples the verified 16-step schedule across the full 1-to-0 interval for
eight or four steps. Text models and large tensors are released before the pinned
image/shared blocks; all heavy functions are released on completion/error.
The preview supports 512px text-to-image, not arbitrary resolution or editing.

Both models run the same compulsory prompt filter and fail-closed six-view image
classifier before an image reaches the view model, Photos, sharing or a result
cache. Unsupported steps, missing classifier, invalid output and cancellation
cannot return a checked result. There is no safety-disable switch.

## Reproduction and licenses

Use the build commands in the main README. The app downloads its pinned assets;
no Python conversion is needed to use the development app on an iPhone.

To preserve a released installation and its data, create a separate Preview copy:

```sh
python3 scripts/prepare_model_preview.py --destination /tmp/local-image-preview
xcodebuild -project /tmp/local-image-preview/SDXLCoreMLTest.xcodeproj \
  -scheme LocalImageGenerationDevice -configuration Release \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -derivedDataPath /tmp/local-image-preview-build -jobs 2 build-for-testing
```

Set your own signing team and use your own `--bundle-id` ending in `.preview`
where necessary. The copy changes only bundle identifiers/display name and has
separate model downloads and preferences. Its local packages link to this checkout;
rebuild after editing them. `ModelSelectionFlows` contains the physical download,
relaunch/resume, generation, step-selection and safety/cancellation UI checks.
Run its numbered methods sequentially on a development installation. The older
`prepare_phone_probe.py` remains an explicitly FLUX.2-only bundled-assets benchmark.

If the device's XCTest automation service cannot initialize, an isolated native
driver is also available with `--model-validation-driver`. Build and install that
copy, then launch it with `--model-selection-validation`. It calls the real setup
and view-model methods, pauses after receiving more than 8 MB, and records its
state in `Documents/ModelSelectionValidation/report.json`. Terminate and relaunch
the same bundle with the same flag to resume the actual download, install, run
the three step counts, and check refusal/cancellation/model switching. This is
explicitly a startup-driver test, not a UI tap test. Restore a normal Preview
build after validation; the model downloads/preferences remain in its separate
container.

To rebuild a distribution package from locally converted assets, use
`scripts/package_flux3_model.py` with `--models`, `--split-input`, `--tokenizer`,
`--licenses` and a fresh `--output` directory. It verifies conversion receipts,
omits duplicate ungrouped DiT weights and writes a ZIP64 stream directly to 200 MB
fragments. Conversion tools and the earlier benchmark protocol are in
`Experiments/Flux3CoreAI` and the dated measurement directories. A rebuild must
use a new revision and immutable prefix if any package bytes change.

`scripts/upload_generation_package.py` accepts a prepared package and an
authorized Cloudflare account/bucket/new prefix. It reuses matching immutable
objects, never replaces mismatching bytes, and verifies each public GET's full
size and SHA-256. Credentials are supplied by the local Wrangler login and are
not committed. Uploading is separate from App Store submission.

FLUX.3 uses the [FLUX Kommunity License](https://huggingface.co/black-forest-labs/flux-3-image-klein/blob/main/LICENSE.md),
including conditions on commercial use. Full terms and modification/attribution
notices are available inside model setup and bundled with the model. Review the
original terms for a future commercial release. This conversion is not endorsed
by Black Forest Labs. Qwen3-VL and the reference code retain their Apache-2.0 terms.

Physical app validation is recorded separately from the earlier fixed-caption
probe timings; those timings must not be described as arbitrary-prompt app results.
See the [dated integration record](../measurements/2026-10-18/flux3-app-model-selection/README.md).
