# iPhone 14 / 6 GB retest

On 2026-10-14, **iPhone 14 / A15 / iOS 27.2 (24B5099f)** completed five real FLUX.2 Klein 4B images at **512×512, four steps**, with on-device Qwen encoding and the unchanged mandatory six-view safety gate. The phone reports **5,986,615,296 bytes of RAM**.

This is an isolated development app with a lower test RAM guard, bundled verified assets, asset-summary metadata lookup and Apple's **Extended Virtual Addressing** entitlement. The production app's eight-GB guard, engine and distributed model bytes remain unchanged. This is not an App Store release or validation of every six-GB device/OS.

## Loading configurations

| Configuration | Result |
| --- | --- |
| Lower guard + ordinary metadata + warm policy | SIGABRT / `std::bad_alloc` during transformer metadata specialization; no generation |
| Lower guard + asset-summary metadata + warm policy | Qwen preparation passed; transformer loading aborted; no image |
| Same, with public `expectFrequentReshapes` hint | Qwen preparation passed; transformer loading aborted; no image |
| Summary metadata + Extended Virtual Addressing | **Five approved images; repeat/idle/full-release pixel parity passed** |

All four signed Release builds embedded the same 17 SHA-verified generation files and compulsory classifier. The successful app was checked to contain `com.apple.developer.kernel.extended-virtual-addressing = true` and no `com.apple.developer.kernel.increased-memory-limit` entitlement. Apple's [documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.extended-virtual-addressing) describes the capability as a larger addressable space, including benefits for mapped GPU assets. It does not add physical RAM.

A separate debugger run observed an **80,216,064-byte / 76.5-MiB** allocator request immediately before the same `ConcatMatmul` / `concatDenseElementsAttr` abort. Symbol-entry registers and the aligned-new caller disassembly confirmed the size and alignment arguments. This is substantially below the phone's 3-GiB single Metal buffer maximum, so the earlier failure should not be characterized as proof of a single oversized GPU buffer. The successful entitlement experiment supports address-space constraints as a relevant cause; it does not isolate every compiler/allocator detail. See [allocation evidence](allocation-diagnostic.json).

An initial debugger regexp also matched `deallocateResource`; its pointer-valued records were rejected and are excluded from all allocation evidence. The reproduction script now anchors the actual allocation symbol and disables prologue skipping. Debugger timings are excluded.

## Successful generation series

| Operation | Seconds including safety and PNG writing | Prepared at start |
| --- | ---: | --- |
| Initial prompt preparation, measured separately | 47.43 | — |
| First image after preparation | 110.70 | Yes |
| Same prompt and seed again | 57.82 | No; real warning triggered cleanup |
| Changed prompt | 61.28 | Yes |
| Generation after 32-second idle | 43.77 | Yes |
| Generation after full release | 61.56 | No |

The first image includes newly compiled transformer loading (~59.04 s) and function loading (~7.73 s). Subsequent images are much faster but remain slower than the previous iPhone 17 cases; those use a different GPU, OS and cache/retention state. A genuine system memory warning during the first diffusion was handled without cancelling the checked image, and the next repeat started unprepared. Thermal state moved from nominal to fair; low power stayed off. These five cases are not five independent cold-start trials or a matched Bonsai speed benchmark.

Apple/mug seed 42 pixels match within the repeat; robot seed 43 pixels match after idle and full release. A15, A19 and M2 hashes differ. Matching model files and integer seeds across hardware does not prove bit-identical pixels.

![Checked output generated on iPhone 14](first.png)
![Checked robot output generated on iPhone 14](changed-prompt.png)

## Memory counters

| Maximum over the completed CSV | Bytes | GiB |
| --- | ---: | ---: |
| Sampled physical footprint | 1,186,959,240 | 1.105 |
| Kernel lifetime footprint maximum | 1,187,319,688 | 1.106 |
| Resident memory | 3,639,754,752 | 3.390 |
| Default-device Metal resource allocation | 5,598,511,104 | 5.214 |

These counters overlap and **must not be summed**. Metal resource allocation is not a direct physical-RAM reading. This table covers the original five-image series. Requested sampling interval was 50 ms; 8,286 samples were recovered with a maximum actual gap of 0.783 s. Even this can miss spikes. Available process-memory budget never fell below 2,034,266,232 bytes in these samples. These readings do not establish a smaller minimum RAM.

## Recorded generation and warning regression

Two later single-image launches also completed with the original seed-42 apple pixels, bringing the recorded total to seven checked images. Disk compilation caches were already populated. They are separate auxiliary cases, not additional independent cold-start trials.

| Case | Preparation, separate | Generation including safety/PNG | USB recording | Warning injection |
| --- | ---: | ---: | --- | --- |
| `extended-recorded-002` | 7.54 s | 45.47 s; app UI 45.2 s | Yes | Ten-second driver timeout; injection **did not happen** |
| `extended-warning-003` | 7.85 s | 45.67 s | No | **Injected during diffusion at step 1; checked output completed and prepared state reset** |

A real system warning was observed in the recorded case despite the missed synthetic injection. The driver wait was extended from ten to sixty seconds for the subsequent regression. Its UIKit notification is not artificial memory pressure. No shipping engine/safety change was made. The single-image reports' repeat/idle parity fields are false because those comparisons were not scheduled; each output hash was separately compared against the original five-image series and matched.

[Auxiliary timing CSV](auxiliary-timings.csv) and the two directories contain complete memory traces and events filtered to each launch's uptime interval. [Actual iPhone 14 demo](../../../media/iphone14-flux2-demo.mp4) is a 30-second excerpt showing generation progress and the approved image at normal elapsed time. It does not show the whole 45.2-second generation or the separate preparation period.

## Files and reproduction

- [Summary](summary.json), [timings CSV](timings.csv), [final actual app screen](final-ui.png).
- Each configuration directory contains its report, source provenance, runtime/lifecycle events, complete `memory.csv` and recomputed CSV maxima. Reports from aborted runs are incomplete snapshots; use the complete recovered CSV for their last observations.
- Prepare a fresh copy with `scripts/prepare_phone_probe.py --keep-warm --metadata-summary --extended-virtual-addressing --bundle-id com.tasuku.sdxlcoremltest.YOURPROBE --destination /absolute/fresh/path`, optionally adding a known-safe reference image. See [device driver instructions](../../../scripts/device-probe/README.md).
- Build with `LOCAL_FLUX_EMBED_MODELS=YES`, normal development signing and the intended device, then launch with `--device-smoke`. Use a fresh retrieval directory for every run and inspect the signed entitlements rather than assuming a requested capability was applied.

Bonsai Studio 0.4.0 / build 11 completed an exploratory 256px image and four 512px images on this phone. Ternary reported 88.3 / 107.0 seconds; Binary reported 86.3 / 86.1 seconds. These are app result labels with different internal timing/cache boundaries. The seed-42 cases use the common apple prompt; Ternary's four-step setting was captured, while Binary's four steps were requested with the prior setting retained. See [the app comparison](../bonsai-iphone14/README.md) for evidence and limitations. The FLUX reuse cases were faster in these observations; there is no general quality, memory or speed superiority claim.
