# Bonsai Studio on the same eight-GB iPhone 17

On 2026-10-14/15, **Bonsai Studio 0.4.0 / build 11** was tested on the same **iPhone 17 / A19 / iOS 27.0.1 (24A446)** used for the [earlier FLUX measurements](../README.md). Both Binary and Ternary weights were downloaded through the released app. The retained Settings frame shows **128px VAE tiles**. Physical RAM was 8,045,641,728 bytes in the earlier FLUX probe; Bonsai process memory was not instrumented.

These are sequential app observations, not a controlled model benchmark. The FLUX reference prompt was:

> A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography.

A later audit of the retained **24.2-second and 14.3-second Binary screens** on October 16 found this actual input:

> A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft light, realistic photography.

The word `window` is absent. The earlier report described a common prompt too strongly. These are near-condition app observations, not text-identical FLUX/Bonsai pairs. The original movie of the first four cases was not retained, and the full prompt cannot be independently read from every Library thumbnail. We preserve the observed times while recording that evidence limit.

## Observed images and times

| Model and operation | Dimensions | Seed | Requested steps | App-reported seconds |
| --- | --- | ---: | ---: | ---: |
| Ternary, first observed image after download/setup | 512×512 | 42 | 4 | 42.6 |
| Ternary, same-session repeat | 512×512 | 42 | 4 | 24.7 |
| Binary, first image after switching model | 512×512 | 42 | 4 | 25.6 |
| Binary, same-session repeat | 512×512 | 42 | 4 | 24.2 |
| Binary, added third image after reconnecting recording | 512×512 | 42 | 4 | **14.3** |

All five images completed. Four steps and Lock seed on were configured by the human operator. After the added generation, the operator opened Parameters and confirmed **Steps = 4** without changing it. No retained Parameters frame independently shows the step count; dimensions, generated seed and elapsed time were visible in the result screens. Matching integer seeds across runtimes does not make their initial random noise equivalent.

The original four times were observed live in Device Hub. Its concurrent QuickTime movie failed when stopped and was not recovered. A later **direct phone screenshot of the app Library corroborates all five elapsed times and resolutions**, and the 24.2-second Binary result has a separate screenshot. After closing Device Hub and reselecting QuickTime's phone streams, a short recording was saved and decoded successfully; the added third Binary generation was then recorded successfully. These setup changes are documented, rather than treating the failed original movie as retained evidence.

## Retained evidence

- [All five results in the physical phone's Library](library-five-results.png).
- [Binary repeat, 24.2 seconds](binary-512-repeat-result.png).
- [Added Binary generation, 14.3 seconds](binary-512-recorded-third-result.png).
- [Binary selected and 128px VAE setting](binary-model-and-vae-setting.png).
- [Added Binary generation recording](binary-512-recorded-third-realtime.mp4): 45 seconds at normal elapsed time, including model/settings, generation and result. Source seconds 108–153 of a 280.27-second physical-phone USB recording; silent 720×1280 / 30 fps, with trimming/resizing only.
- [Machine-readable observations](summary.json) and [timings CSV](timings.csv).

The app Library contains only these five synthetic test images. Public evidence excludes device identifiers, unrelated app screens and private host paths. Full source recordings remain local. No synthetic frames or speed-up are used.

## Comparison with FLUX

The earlier same-phone FLUX probe used the reference apple prompt, 512px, four steps and seed 42; the retained Bonsai Binary prompt differs as documented above. Its two completed runs measured **13.97 / 14.34 seconds after separate 5.69 / 3.95-second preparation**, and **10.98 / 11.36 seconds for cached repeats**. Those generation times include six output safety views; preparation is excluded. They were not USB-recorded, and first-ever disk compilation is not covered by those numbers.

The **14.3-second added Bonsai Binary result matters**: comparing only its earlier 24–26-second results would overstate a FLUX speed advantage on iPhone 17. FLUX's cached repeat observations are lower, but the apps differ in prompt preparation, retention/cache policy, safety behavior, recording setup and internal timing boundaries. The cause of Bonsai's faster added case was not isolated. The retail app's thermal state, power mode and memory counters were not instrumented.

This supports a limited same-device timing report. It does not establish a general speed, image-quality or memory winner. Keep the separate [six-GB iPhone 14 observations](../bonsai-iphone14/README.md) and the [FLUX experimental six-GB execution](../iphone14-retest/README.md) distinct.
