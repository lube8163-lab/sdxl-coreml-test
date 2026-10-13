# Third-Party Notices

The repository-authored application code, scripts, and documentation are
licensed under the MIT License in `LICENSE`.

## Apple Core ML Stable Diffusion

`Vendor/StableDiffusionLocal` contains source derived from Apple's
`ml-stable-diffusion` project:

- https://github.com/apple/ml-stable-diffusion
- License: MIT
- Copyright (c) 2024 Apple Inc.

The upstream license is included at
`Vendor/StableDiffusionLocal/LICENSE.md` and continues to apply to those files.

Stable Diffusion checkpoints, converted Core ML packages, Hugging Face assets,
and other downloaded model artifacts are not covered by this repository's MIT
License. They remain governed by their respective upstream licenses and terms.

## Apple CoreAI diffusion runtime

`Vendor/MimCoreAIFlux` derives from Apple's `coreai-models` runtime at
`97a14be40bb1c5b95badb08b8532530443d62d26`, under BSD 3-Clause. See its
`LICENSE` and the app's `Resources/CoreAIRuntimeNotices.txt` for the original
terms. Adaptations include a dedicated 512px model entrypoint, stage unloading,
bounded CPU conditioning reuse and optional denoiser retention.

## Downloaded FLUX.2 assets

The original [FLUX.2 Klein 4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)
is by Black Forest Labs, under Apache-2.0. The text encoder is Qwen3 by Alibaba
Cloud. Our distributed bytes derive from
[dushandz's CoreAI conversion](https://huggingface.co/dushandz/FLUX.2-klein-4B-CoreAI/tree/a7f65cdd6b2c8e2616dab3887efd0ae6ce983e44),
revision `a7f65cdd6b2c8e2616dab3887efd0ae6ce983e44`.

The existing 512px `half` transformer graph and required helpers were extracted
and the entrypoint renamed `main`; converted 4-bit weights were retained. The
text encoder and half VAE decoder were retained; 1024px and image-to-image
assets were omitted. This is a modified derivative, not a new quantization or
retraining. The app ships attribution, change notices and Apache-2.0 terms in
`Resources/ModelLicenseNotices.txt`. No generation weights are committed here.

## Safety classifier

The compiled classifier comes from
[InspiratioNULL/image-safety-classifier-s-CoreML](https://huggingface.co/InspiratioNULL/image-safety-classifier-s-CoreML),
revision `1d6482987f783eb431458a2501cd6f59db6c8e6d`, under MIT. It derives
from Owen Elliott's classifier and SwiftFormer (Apache-2.0). Attribution and
license text are in the app's `Resources/ImageSafetyNotices.txt`.

## Swift packages

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), 0.9.20, MIT.
- [swift-transformers](https://github.com/huggingface/swift-transformers),
  revision `91286f231bffb9d01998c7e99a8cc760b9e41546`, Apache-2.0.
- [swift-jinja](https://github.com/huggingface/swift-jinja), 2.5.1, Apache-2.0.
- [swift-collections](https://github.com/apple/swift-collections), 1.7.3,
  Apache-2.0 with Runtime Library Exception.

The lock files identify the exact resolved revisions. Upstream license terms
continue to apply; the repository MIT license does not replace them.
