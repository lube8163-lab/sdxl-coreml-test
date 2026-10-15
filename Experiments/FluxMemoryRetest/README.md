# Memory and six-GB device retest

Historical baseline: the results below compare against the October 14 production source with an eight-GB guard. The current app adopts summary metadata and Extended Virtual Addressing and lowers its minimum to six GB. Current probe scripts inherit that configuration; use [the recorded October 14 source snapshot](https://github.com/lube8163-lab/sdxl-coreml-test/tree/56430e7ce79f278875e0aa2765ec31f66e360928) to reproduce the original baseline. Historical result files and model bytes are preserved.

This experiment reuses the app's generation library and mandatory six-view gate. It does not change the shipping RAM guard, mathematical model, server assets or app UI. Mac results cannot establish six-GB iPhone support: the Mac can swap, and GPU/OS/process limits differ.

`MemorySampler` captures `task_vm_info.phys_footprint`, resident memory, the task ledger's process-lifetime footprint high-water mark and default-device Metal resource allocation on a separate serial queue, every 50 ms. It also records actual maximum sample gaps. It does not rely on the main actor being free during native compilation. The counters overlap; do not add them. Metal counts can omit allocations associated with other device objects. Even 50 ms sampling can miss spikes, and the final lifetime peak cannot be read after a fatal native abort. CSV writes occur throughout the test so an aborted process leaves observations before termination.

## Mac reproduction

Use regular, catalog-verified model copies in `artifacts/flux2-klein-4b-512`, rather than the original experiment's symlink-based directory. Compile the mandatory safety package for macOS:

```sh
xcrun coremlcompiler compile SDXLCoreMLTest/Resources/ImageSafetyClassifier.mlpackage /tmp/flux-retest-safety
python3 scripts/prepare_memory_retest.py --variant baseline --destination /tmp/flux-retest-baseline
swift build --package-path /tmp/flux-retest-baseline/Experiments/FluxMemoryRetest \
  --scratch-path /tmp/flux-retest-build -c release -j 2
```

Run the built `FluxMemoryRetest` executable in its scratch directory's `out/Products/Release` (or `swift build --show-bin-path`). `generate <model-directory> <safety.mlmodelc> <fresh-output-directory>` measures prompt preparation, first image and cached repeat with seed 42. Timings include six-view classification and exclude PNG writing. Only checked images are saved. Prior on-disk CoreAI compilation caches may already exist.

`component <asset.aimodel> <gpu|reshape|cpu|summary> <fresh-output-directory>` isolates asset/function loading without running or saving an image. Component load success is not inference success. `reshape` tests Apple's public `SpecializationOptions.expectFrequentReshapes` hint; the connected iPhone 14 case still aborted during transformer loading. It is not a guaranteed low-memory option.

Prepare a separate `--variant reshape` copy to run full checked generation with asset-summary metadata lookup and the hint enabled only for the 512px transformer. `summary` tests just the metadata lookup. Compare these against baseline on the same hardware/prompts/seeds, recording preparation separately and verifying output hashes/safety. The copies carry source provenance and never overwrite prior output directories. Run inference and builds sequentially on the 8 GB development Mac.

## Connected iPhone 14 retest

The initial source failed on iPhone 14 / A15 / iOS 27.2 during MPSGraph's `ConcatMatmul` / `concatDenseElementsAttr` buffer allocation. This was `std::bad_alloc` / SIGABRT, not a confirmed jetsam event. The later [connected retest](../../measurements/2026-10-14/iphone14-retest/README.md) repeated the three cases below, observed a validated 76.5-MiB allocation argument in a separate debugger run, and completed five checked images after adding Extended Virtual Addressing to the summary-metadata copy. That public entitlement does not add physical RAM. Production guard/model bytes remain unchanged.

Prepare three independent cases using `scripts/prepare_phone_probe.py`:

1. Baseline lower-guard copy with `--keep-warm`.
2. The same with `--metadata-summary`.
3. The same with `--frequent-reshapes` (implies summary lookup).

The fourth case uses `--keep-warm --metadata-summary --extended-virtual-addressing`. This was the successful configuration on the tested iPhone 14.

Use a fresh destination and distinct probe bundle for each. The production eight-GB guard remains unchanged. The test view model's lower guard and bundled asset location are deliberate overrides; its inference/safety behavior is preserved. Warm tests now include preparation, repeat, changed prompt, idle and full-release cases. The per-launch `memory-*.csv` is named in `Documents/DeviceValidation/report.json`.

Build the isolated copies with `LOCAL_FLUX_EMBED_MODELS=YES` for device development, use your signing team, install, and launch with `--device-smoke`. The generic iOS compile check without this variable proves compilation only and contains no generation weights. These experimental copies are separate from the shipping app. Six-GB execution has been demonstrated for the successful configuration on this device/OS; broader device and release support still require validation.

If a native allocation abort persists, optional `scripts/device-probe/large-allocation.lldb` captures requested large allocations from the ARM64 C++ member call. The current symbol is anchored to exclude deallocation and thunks; prologue skipping is disabled. The entry/caller signature was validated on this phone, but still verify locations and argument meanings on another OS. A missing breakpoint location is not evidence of no large allocations. Debugger runs are diagnostic, not timing runs.

The earlier MiM two-chunk experiment is another possible fallback. It completed on a Mac, but changed final latents slightly and sequential loading slowed generation. Those historical results are not this app's iPhone measurements. Investigate splitting only if the simpler loading options still fail; do not silently replace model bytes in the app or reuse the original model's checksum manifest for modified assets.

## Bonsai comparison conditions

PrismML reports 512px generation in 9.4 seconds on **iPhone 17 Pro Max**, and publishes average active-memory figures for its binary/ternary variants. Our existing 11–14 second results use **iPhone 17**, include six safety checks and distinguish preparation/cache state. These do not establish a speed or memory winner. [Official report](https://prismml.com/news/bonsai-image-4b)

| Item | Current FLUX CoreAI app | Bonsai binary | Bonsai ternary |
| --- | --- | --- | --- |
| Transformer representation | Converted 4-bit | Binary + FP16 scales/projections | Ternary + FP16 scales/projections |
| Transformer files | 2.180 GB | Published 0.93 GB | Published 1.21 GB |
| Generation payload | Verified 4.044 GB | Published 3.42 GB | Published 3.88 GB |
| Published average active memory at 512px | Not measured with their definition | 1.50 GB | 1.96 GB |
| Six-GB iPhone execution | Five-image series plus two later checked 512px images in an isolated iPhone 14 copy; shipping guard remains 8 GB | Two observed 512px images on the same iPhone 14 | Two observed 512px images and one exploratory 256px image on the same iPhone 14 |
| Same-device quality comparison | Pending | Pending | Pending |

The October 14 shipping snapshot kept its eight-GB guard; current source uses a six-GB minimum, as described in the [current reproduction guide](../../docs/flux2-iphone-reproduction.md). A separate summary-metadata/Extended Virtual Addressing development copy completed five 512px/four-step images on the six-GB iPhone 14; see the retest above. Its subsequent cases took 43.77–61.56 seconds, including the compulsory safety gate and PNG writing. First image after separate preparation was 110.70 seconds with new transformer compilation. These are not a matched Bonsai benchmark.

[Bonsai Studio 0.4.0 / build 11](https://apps.apple.com/jp/app/bonsai-studio-by-prismml/id6767042620) was installed on the same iPhone 14. Both binary and ternary models were downloaded; the live app Settings exposes both choices and a default 128px VAE tile. Its displayed payload estimates are ~3.4 GB binary and ~3.6 GB ternary, rather than the Mac payload figures in the table. The App Store description advertises ternary and ~12-second 512px generation on iPhone 17 Pro, with eight GB recommended. [The same-device app observations](../../measurements/2026-10-14/bonsai-iphone14/README.md) record Ternary 512px results of 88.3 / 107.0 seconds and Binary results of 86.3 / 86.1 seconds, using the common apple prompt. Ternary's four-step setting was captured; Binary's four steps were requested with the prior setting retained, without a separate step-count screen. The seed-42 cases have matching prompt/resolution/seed. An exploratory Ternary 256px case reported 44.9 seconds and is excluded from the 512px comparison. Cache, thermal, recording and internal moderation/timing boundaries differ, so a general quality/speed winner remains unestablished.

The later [same-iPhone-17 observations](../../measurements/2026-10-14/bonsai-iphone17/README.md) record Ternary at 42.6 / 24.7 seconds and Binary at 25.6 / 24.2 seconds, followed by a separately recorded **14.3-second Binary generation**. All five times are corroborated by the app Library screenshot. Four steps were human configured and confirmed after the added case; a step-count frame was not retained. The original four-case recording failed, and the added case used a reconnected recording setup. Its faster time narrows the observed gap with FLUX; comparisons must include it and distinguish preparation, cache, safety and timing scope.

For the released-app comparison, measure button-to-image display with each app's own moderation/safety overhead, recording the model selection, dimensions, steps/seed if exposed, VAE tile, cold/warm status, charging/thermal state, and refusals. Do not label the Bonsai app's internal safety pipeline equivalent to our six-view classifier unless verified. Its retail build cannot take this app's memory sampler, so avoid presenting differently defined memory counters as a matched memory benchmark.

Bonsai has smaller transformer payloads. Quality at a comparable cost and the measured safety-inclusive native pipeline are possible advantages to investigate with matched testing. The FLUX six-GB result establishes feasibility on the tested device, not an advantage over Bonsai. Higher nominal weight precision alone is not proof of better image quality. `fixtures.json` defines common prompts/seeds; original noise may differ by runtime. Measure each model on the same device, resolution, steps, power/thermal state and preparation/cache policy. For a controlled model-level comparison, apply the same input/output safety gate to both and report any refusal; the released-app comparison retains each app's own gate. Include multiple outputs and blind prompt-following/quality review before asserting superiority.
