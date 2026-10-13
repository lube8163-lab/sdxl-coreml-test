# FLUX.2 on an 8 GB iPhone: reporting scope and related work

Checked on 2026-10-14. A standard iPhone 17 with 8 GB RAM performs on-device Qwen prompt encoding, FLUX.2 Klein 4B generation and six mandatory safety checks, with measured reuse/idle/release behavior. This is useful physical-device evidence. That assessment is an inference, not a world-first claim or a new model/runtime invention.

## Existing work

| Primary source | What it establishes | Difference from this report |
| --- | --- | --- |
| [dushandz CoreAI conversion](https://huggingface.co/dushandz/FLUX.2-klein-4B-CoreAI) | Existing int4 conversion with eight entrypoints; published 512px measurements use a 64 GB M1 Max Mac. | This is our source. We reuse its weights and report a dedicated 512px path on an 8 GB iPhone. |
| [Aether FLUX.2 card](https://huggingface.co/aether-models/flux2-klein-4b) | Existing iOS/macOS CoreAI assets, 8-bit weights, split denoiser and iPhone18,2 verification using increased-memory-limit entitlement. | Prior iPhone work exists. Model, device, entitlement and memory definitions differ. |
| [mlboydaisuke CoreAI export](https://huggingface.co/mlboydaisuke/FLUX.2-klein-4B-CoreAI) | Another export and documented platform/memory constraints. | Its current card is macOS oriented; it does not demonstrate the same standard 8 GB iPhone configuration. |
| [mlx-flux2-swift](https://github.com/icakinser/mlx-flux2-swift) | Native Swift/MLX FLUX.2 and staged loading; concrete README build/run requirements target Apple Silicon Macs. | Relevant prior work. Mac results cannot be substituted for iPhone measurements. |
| [Author's social announcement](https://www.reddit.com/r/LocalLLM/comments/1v35ecu/hey_everyone_after_a_few_months_of_work_im/) | Native Swift project and potential iOS integration discussed by its author. | Possible iOS use does not prove this particular configuration. |
| [CoreAI model zoo](https://github.com/john-rocky/coreai-model-zoo) | Existing CoreAI examples and model work. | SDK/examples alone do not prove this app's device behavior. |

GitHub, Hugging Face and public social searches were reviewed. X search did not yield a usable primary report for the exact 8 GB configuration. Coverage is incomplete; search absence is not proof of priority. The upstream conversion card's broad OS claim is not this app's minimum: the app requires iOS 27.0.1.

## Supported claims and limits

- iPhone 17, iPhone18,3, A19 GPU, 8,045,641,728 bytes RAM, iOS 27.0.1 / 24A446.
- 512×512, four steps, GPU-preferred CoreAI, converted int4 weights, no increased-memory-limit entitlement.
- Full local text-to-image path and six safety views before output. Safety costs are included in generation timing.
- Prepared-prompt generation 13.97–14.34 seconds; cached repeat 10.98–11.36 seconds in two short runs. Preparation is separate; first-ever compilation and arbitrary prompts are not covered by these numbers.
- Fixed-seed pixel parity after repeat, idle and full release. Changing the seed changes pixels. This is model reuse, with no image inference cache.
- Actual resumable 3.54 GB download, SHA-verified 4.04 GB installation and two approved images from downloaded bytes. Apple-fixture pixels match the earlier bundled model.
- A 6 GB iPhone 14 failed even with a lowered guard. The root cause was not fully isolated.

JSON/CSV distinguish stage samples, 250 ms samples and timings. Process footprint is not total GPU memory or a minimum RAM guarantee. The recorded robot case reports 16.7 seconds in the UI and differs from the cached-repeat benchmark. A startup driver automates real actions; the failed XCTest runner is not reported as a UI-test pass. Broad classifier effectiveness and App Review acceptance have not been established.

Apple's [maximum-build-size reference](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/) lists a 4 GB uncompressed iOS/iPadOS app limit. The bundled development app measured about 4.07 GB decimal (3.79 GiB), near that boundary; this is not an App Store archive validation. Excluding generation models yields a roughly 30 MB development app and an explicit first-use download. No App Store upload was performed.

## Short posts — drafts only

### Japanese

8GBのiPhone 17でFLUX.2 Klein 4Bをオンデバイス実行。512×512・4ステップ、安全チェック込みで準備後約14秒／同じプロンプトの連続生成約11秒。実機録画・測定CSV・ソースを公開しました。Apple CoreAIとdushandz氏の変換モデルを使用しています。
https://github.com/lube8163-lab/sdxl-coreml-test

Optional reply: モデルは初回に3.54GBダウンロード、以後は入力・生成・安全確認まで端末内で完結します。動画のロボット例は別プロンプトで16.7秒。6GBのiPhone 14は今回の構成では生成に成功していません。測定条件と未検証範囲も公開しています。

### English

FLUX.2 Klein 4B on an 8GB iPhone 17: 512px, 4 steps, local prompt encoding + safety checks. ~14s after prep, ~11s cached repeat. Device video, CSV & code. Built on Apple CoreAI + dushandz's conversion.
https://github.com/lube8163-lab/sdxl-coreml-test

Optional reply: Initial model download: 3.54 GB; inference then runs locally. The recorded robot takes 16.7s with a different prompt. A 6 GB iPhone 14 failed in this configuration. Conditions and limits are documented; this is not a first-ever claim.

Attach `media/iphone17-flux2-demo.mp4` to the main post. It is 26 seconds, silent, 720×1280, 30 fps, with only trimming/resizing and no speed-up. `media/iphone17-model-download.mp4` is an optional second clip. Neither post has been sent.
