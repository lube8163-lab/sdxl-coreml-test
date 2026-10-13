# Physical-device measurements, 2026-10-13/14

These are short development runs, not a distribution-build benchmark or a safety-effectiveness study. Device identifiers, private crash-report contents and unrelated device screens are excluded.

| File | Scope |
| --- | --- |
| `iphone17-device-validation.json` | Two completed five-image runs plus a memory-warning regression, production generation engine in an isolated signed app copy; historic bundled asset location. Includes stage memory samples, safety scores, source provenance and failures. |
| `iphone17-measurements.csv` | Eleven checked images from those runs. Preparation is separate in JSON. No USB recording during these timing runs. |
| `first-download-device-validation.json` | Actual model download, pause/resume, initial hashing failure, preserved archive, successful patched installation and two checked images. |
| `downloaded-model-measurements.csv` | Different prompt cases using downloaded assets, while USB recording: UI times 23.0 / 16.7 seconds; driver observation includes its polling overhead. |
| `first-download-memory.csv` | Patched installation/generation process footprint sampled approximately every 250 ms, best-effort main-actor schedule. |
| `downloaded-model-source-provenance.json` | Hashes of the production sources used by the download startup driver. |
| `iphone14-device-validation.json` | Normal 8 GB refusal; isolated lower-guard GPU, metadata-summary and CPU experiments. No image was generated. |
| `iphone17-timings.svg` / `.png` | Plot of the two comparable completed timing runs. |
| PNGs | Actual app UI and checked output. `current-9gb` files show the final storage guidance. Earlier download-test screenshots retain their original 8 GB wording and partial-download resume button. |

The first successful download/generation run preceded the cache-budget refinement from 8 GB to about 9 GB; historical source hashes and screenshots are retained. Current onboarding was captured separately without initiating another model download. `normal-startup-validation.json` records the ordinary startup and measured disk cache.

The benchmark's initial preparation is not a cold first-ever CoreAI compilation measurement. Runtime/OS caches may already be populated. Times include six safety views, but not preparation unless explicitly labeled. Stage and 250 ms physical-footprint samples can miss peaks. Metal counters are separate metrics; neither should be interpreted as total model memory or minimum RAM.

RAM guard: `physicalMemory >= 7_500_000_000` bytes. iPhone 17: 8,045,641,728 bytes, A19 GPU, iOS 27.0.1 / 24A446. iPhone 14: 5,986,615,296 bytes, A15 GPU, iOS 27.2 / 24B5099f. Different OS/GPU/RAM prevent isolating the failed phone's root cause. No increased-memory-limit entitlement is used.

The UIKit memory-warning regression delivers a notification, not artificial allocation pressure. The download failure was an actual process-memory-limit termination; only a summary of the app's own crash is retained. XCTest's runner timed out before a case started, so the physical results are not claimed as successful XCTest UI tests. A test-only startup driver invokes production methods; actual screens, network, models and classifier are exercised.

## Reproduce download/setup validation

Prepare the small classifier first, then create a separate copy. The shipping app contains no test launch flags. A new probe bundle has separate storage and downloads 3.54 GB; leave the phone foreground on Wi-Fi with about 9 GB free. Inspect destination source and provenance before signing.

```sh
python3 scripts/prepare_safety_assets.py
python3 scripts/prepare_setup_probe.py --destination /tmp/local-setup-probe
xcodebuild -project /tmp/local-setup-probe/SDXLCoreMLTest.xcodeproj \
  -scheme SDXLCoreMLTest -configuration Release -jobs 2 \
  -destination 'id=YOUR_DEVICE_ID' -derivedDataPath /tmp/local-setup-build build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  /tmp/local-setup-build/Build/Products/Release-iphoneos/SDXLCoreMLTest.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID --console \
  com.tasuku.sdxlcoremltest.setupprobe --setup-validation
```

Use your signing team. Reports/checked images appear in the probe's `Documents/FirstDownloadValidation`. `--bundle-id` can explicitly reuse this app's development installation and owned downloaded assets; it will replace that installed development app, so the separate default is preferable for a fresh reproduction.

## Legacy bundled generation probe

`scripts/prepare_phone_probe.py --shipping-configuration` preserves the production generation engine/guard/resource policy, but overrides the view model's asset location to local bundled weights and replaces startup UI with the generation driver. Build the copy with `LOCAL_FLUX_EMBED_MODELS=YES`, after `scripts/prepare_flux_assets.py` supplies local, hash-pinned assets. It is an isolated experiment, not a release configuration or a downloader test. Without `--shipping-configuration`, the separate copy lowers the RAM guard and uses release-after-generation for the failed 6 GB experiments. Runtime-summary/CPU options are explicitly experimental.

The JSON retains provenance from the measured historical versions. Current source includes the later installer/UI; source hashes therefore differ. The model bytes, mathematical generation configuration and safety policy used in those measurements are documented, rather than presenting historical timings as a new build's repeated test.

## Recordings

`../../media/iphone17-flux2-demo.mp4`: actual iPhone screen via QuickTime USB input, trimmed from 83.5 seconds to 26 seconds. `../../media/iphone17-model-download.mp4`: 15 seconds of actual download progress. Both are silent 720×1280 / 30 fps, with normal elapsed time. No synthetic frames, interpolation, speed-up, or unrelated device content is included. `scripts/export_device_video.swift` uses AVFoundation for file-only trimming/resizing.
