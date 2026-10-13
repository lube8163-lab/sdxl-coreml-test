# MiM CoreAI FLUX runtime

This local Swift package adapts Apple's CoreAI diffusion runtime under the included BSD 3-Clause license. The upstream baseline is `97a14be40bb1c5b95badb08b8532530443d62d26`; it was brought into MiM from the physically tested runtime in `work/iphone17-vlm-flux-2026-10-11/Runtime`. Original source headers and license terms are preserved. The app bundles the same Apple license in `CoreAIRuntimeNotices.txt`.

MiM changes:

- Load the derived single-function 512px transformer without preloading a larger entrypoint.
- Unload the heavy transformer, text encoder and VAE between stages and after use.
- Reuse tokenizer/metadata and up to three text-conditioning entries on CPU.
- Save a one-use CPU checkpoint at diffusion boundaries or after text preparation, then resume the same configuration and random state after photo analysis.
- Reject overlong Qwen prompts rather than silently truncating them.
- Compile the runtime only where CoreAI is available outside Simulator; Simulator remains usable for the app's UI.

The direct app dependency pins swift-transformers to `91286f231bffb9d01998c7e99a8cc760b9e41546`. This package contains runtime source only. Downloaded weights and per-file pinned hashes are managed by `CoreAIFluxAssets` and the model installer.

Original model: https://huggingface.co/black-forest-labs/FLUX.2-klein-4B

Converted source: https://huggingface.co/dushandz/FLUX.2-klein-4B-CoreAI/tree/a7f65cdd6b2c8e2616dab3887efd0ae6ce983e44

The 512px asset is a derivative of that converted source with its half function extracted as main; weights stay 4-bit. This is not a new official iOS export. See the repository's `measurements/2026-10-14` report for physical-device evidence.

## Local Image Generation port (2026-10-13)

This copy is used by the Local Image Generation app through `Vendor/LocalImageGeneration`. The app checks prompts before generation and uses a mandatory six-view Core ML output classifier; no image preview is exposed before that gate. swift-transformers is pinned to the MiM revision. The app and Swift package lock files record the tested transitive dependency versions (swift-collections 1.7.3 and swift-jinja 2.5.1). Generation models are downloaded after consent from MiM's distribution server and checked by archive and per-file SHA256. Only the small safety classifier is compiled into the app. The default build excludes FLUX weights.

Local runtime changes omit the iOS-only available-process-memory metric on macOS, expose cancellable prompt preparation, bound the CPU conditioning cache to three LRU entries / 45 MiB, and add a typed `keepDenoiserLoaded` configuration (default false). The owning app enables retention only in suitable power/thermal conditions and enforces a 30-second idle deadline. The text encoder and VAE still unload after their stages. An uncached prompt unloads the transformer before text encoding. Mathematical inference, model weights and checkpoint/resume behavior stay the same. Measurements from older MiM probes must not be reported as this app's iPhone performance.
