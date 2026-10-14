# Bonsai Studio on the same six-GB iPhone 14

On 2026-10-14, the released **Bonsai Studio 0.4.0 / build 11** was tested on **iPhone 14 / A15 / iOS 27.2 (24B5099f)**, reporting 5,986,615,296 bytes of physical RAM. Both binary and ternary models were downloaded through the app. The app's Settings showed a default **128px VAE tile**, with no observed change to that setting.

This is an initial same-device app comparison with [the separate FLUX probe](../iphone14-retest/README.md), not a controlled model benchmark or a quality-ranking study. Each app retains its own safety behavior. Only FLUX exposes the mandatory six-view gate and the instrumented memory counters used in its report.

## Common prompt and observed settings

> A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography.

Both tested 512px Ternary cases used four steps. In the first case, the parameter field contained 42 but **Lock seed was off**, so the actual generated seed was 4031663144. The next case captured **512×512 / steps 4 / seed 42 / Lock seed on** together, and the result confirms seed 42. Matching integer seeds across runtimes does not make the initial random noise equivalent.

| App and operation | Dimensions | Steps | Actual seed | Seconds | Timing source |
| --- | --- | ---: | ---: | ---: | --- |
| FLUX initial preparation | 512×512 | 4 | 42 | 47.43 | Probe; separate from first image |
| FLUX first image after preparation | 512×512 | 4 | 42 | 110.70 | Probe; includes transformer compilation, six safety views and PNG writing |
| FLUX same-prompt repeat | 512×512 | 4 | 42 | 57.82 | Probe; real memory warning had released retained resources |
| FLUX later recorded image after separate 7.54 s preparation | 512×512 | 4 | 42 | 45.2 UI / 45.47 probe | App label / probe including PNG; disk compilation caches reused |
| Bonsai Ternary exploratory default | 256×256 | Not captured | 915212167 | 44.9 | App result label |
| Bonsai Ternary first 512px after 256px | 512×512 | 4 | 4031663144 | 88.3 | App result label |
| Bonsai Ternary next 512px | 512×512 | 4 | 42 | 107.0 | App result label |
| Bonsai Binary first after model switch | 512×512 | 4 requested* | 42 | 86.3 | App result label |
| Bonsai Binary same-prompt repeat | 512×512 | 4 requested* | 42 | 86.1 | App result label |

Both Binary and Ternary completed 512px generation on this phone. *Four steps were requested for Binary, retaining the prior verified parameter in the same app session; a separate Binary step-count screen was not captured. The recording shows the Binary model label, actual resolution and seed. These results do not establish execution speed for other devices or configurations.

## Evidence and interpretation

- [Machine-readable observations](summary.json) and [timings CSV](timings.csv) preserve dimensions, step/seed evidence, cache sequence and limitations.
- [Binary model and generation](binary-model-and-generation.png), [first result](binary-512-first-result.png) and [repeat result](binary-512-repeat-result.png).
- [Ternary seed-42 recording](ternary-512-seed42-realtime.mp4): 130 seconds at normal elapsed time, including parameters, generation and result.
- [Binary first seed-42 recording](binary-512-seed42-realtime.mp4): 125 seconds at normal elapsed time, including model selection, generation and result.
- [First 512px parameters](ternary-512-initial-parameters.png) and [its actual result](ternary-512-random-seed-result.png).
- [Locked-seed parameters](ternary-512-parameters.png) and [seed-42 result](ternary-512-seed42-result.png).
- [Exploratory 256px result](ternary-256-result.png); excluded from paired 512px comparisons.

The FLUX repeat was faster than these observed Ternary and Binary results. This is a narrow observation, not a general speed winner: FLUX's initial preparation and first compilation are separate, prompts in the other FLUX cases differ, the apps have different cache/retention and moderation behavior, and USB recording was active only for Bonsai. Both apps were connected by USB; Bonsai's exact thermal/low-power state was not instrumented. Runs were sequential, not interleaved, and no retail-app cache purge was performed.

The full recordings were made from the physical phone's QuickTime USB screen input at 1170×2532. Published evidence contains only the test app and synthetic test prompt. Any short exported clips preserve normal elapsed time with trimming/resizing only; no synthetic frames or speed-up are used. Full source recordings remain local.

The App Store description and PrismML's published Mac payload/average-memory numbers are [related-work context](../../../Experiments/FluxMemoryRetest/README.md), not measurements of this phone. The released Bonsai build cannot incorporate the FLUX probe's sampler; no matched memory advantage is claimed. One prompt and a few outputs do not establish an image-quality winner. iPhone 17 comparison remains a separate future test.
