# Memory and six-GB device retest

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

`component <asset.aimodel> <gpu|reshape|cpu|summary> <fresh-output-directory>` isolates asset/function loading without running or saving an image. Component load success is not inference success. `reshape` tests Apple's public `SpecializationOptions.expectFrequentReshapes` hint; its effect on the iPhone allocation failure is unverified. It is not a guaranteed low-memory option.

Prepare a separate `--variant reshape` copy to run full checked generation with asset-summary metadata lookup and the hint enabled only for the 512px transformer. `summary` tests just the metadata lookup. Compare these against baseline on the same hardware/prompts/seeds, recording preparation separately and verifying output hashes/safety. The copies carry source provenance and never overwrite prior output directories. Run inference and builds sequentially on the 8 GB development Mac.

## iPhone 14 retest when connected

The current source has already failed on iPhone 14 / A15 / iOS 27.2 during MPSGraph's `ConcatMatmul` / `concatDenseElementsAttr` buffer allocation. This was `std::bad_alloc` / SIGABRT, not a confirmed jetsam event. Requested allocation size is unknown. RAM, GPU buffer constraints and OS compiler behavior remain confounded.

Prepare three independent cases using `scripts/prepare_phone_probe.py`:

1. Baseline lower-guard copy with `--keep-warm`.
2. The same with `--metadata-summary`.
3. The same with `--frequent-reshapes` (implies summary lookup).

Use a fresh destination and distinct probe bundle for each. The production eight-GB guard remains unchanged. The test view model's lower guard and bundled asset location are deliberate overrides; its inference/safety behavior is preserved. Warm tests now include preparation, repeat, changed prompt, idle and full-release cases. The per-launch `memory-*.csv` is named in `Documents/DeviceValidation/report.json`.

Build the isolated copies with `LOCAL_FLUX_EMBED_MODELS=YES` for device development, use your signing team, install, and launch with `--device-smoke`. The generic iOS compile check without this variable proves compilation only and contains no generation weights. Do not distribute these experimental copies. There is no claim of six-GB success until actual loading and all checked generations finish on the phone.

If a native allocation abort persists, optional `scripts/device-probe/large-allocation.lldb` captures requested large allocations from the ARM64 C++ member call. It has not been exercised on the absent phone; validate symbol locations and the call signature before using register values. A missing breakpoint location is not evidence of no large allocations. Debugger runs are diagnostic, not timing runs.

The earlier MiM two-chunk experiment is another possible fallback. It completed on a Mac, but changed final latents slightly and sequential loading slowed generation. Those historical results are not this app's iPhone measurements. Investigate splitting only if the simpler loading options still fail; do not silently replace model bytes in the app or reuse the original model's checksum manifest for modified assets.

## Bonsai comparison conditions

PrismML reports 512px generation in 9.4 seconds on **iPhone 17 Pro Max**, and publishes average active-memory figures for its binary/ternary variants. Our existing 11–14 second results use **iPhone 17**, include six safety checks and distinguish preparation/cache state. These do not establish a speed or memory winner. [Official report](https://prismml.com/news/bonsai-image-4b)

| Item | Current FLUX CoreAI app | Bonsai binary | Bonsai ternary |
| --- | --- | --- | --- |
| Transformer representation | Converted 4-bit | Binary + FP16 scales/projections | Ternary + FP16 scales/projections |
| Transformer files | 2.180 GB | Published 0.93 GB | Published 1.21 GB |
| Generation payload | Verified 4.044 GB | Published 3.42 GB | Published 3.88 GB |
| Published average active memory at 512px | Not measured with their definition | 1.50 GB | 1.96 GB |
| Six-GB iPhone execution | Not demonstrated | Not established by the cited report | Not established by the cited report |
| Same-device quality comparison | Pending | Pending | Pending |

Bonsai has smaller transformer payloads. Potential advantages of the current app—lower-device support if validated, quality at a comparable cost, and a measured safety-inclusive native pipeline—need actual matched testing. Higher nominal weight precision alone is not proof of better image quality. `fixtures.json` defines common prompts/seeds; original noise may differ by runtime. Measure each model on the same device, resolution, steps, power/thermal state and preparation/cache policy. Apply the same input/output safety gate to both, and report any refusal. Include multiple outputs and blind prompt-following/quality review before asserting superiority.
