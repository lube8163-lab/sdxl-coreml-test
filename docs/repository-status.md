# Repository maintenance — 2026-10-18

The current project is **Local Image Generation for iPhone**, using FLUX.2 and
FLUX.3. SDXL/Stable Diffusion conversion scripts remain historical research.
The Xcode project and bundle identifiers retain their existing names.

## Repository name and public links

The `sdxl-coreml-test` repository name is retained for now. Its `/docs` directory
publishes the privacy/support site at
`https://lube8163-lab.github.io/sdxl-coreml-test/`. GitHub repository renaming does
not redirect project-site URLs; see [GitHub's documentation](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository).
A future rename to `local-image-generation` requires an independent plan to keep
those existing URLs working. A second source repository is unnecessary now.

## Consolidated source

The `codex/flux3-iphone-report` work at
`dc47a98de40ff9cf897df177cd1c6eb419354b8a` brings FLUX.3 conversion/reproduction,
the optional native app runtime/model selection, and dated measurement evidence
onto the main development line. The historical branch remains available for
article links. Existing `main` history is preserved.

The model-selection [integration report](flux3-app-integration.md) and
[dated evidence](../measurements/2026-10-18/flux3-app-model-selection/README.md)
state device, safety, download and UI-driver boundaries. Development-source
publication is separate from App Store submission, approval or distribution.

## Local files and subsequent work

Do not force-push an older local branch over `main`. Start future work from
`origin/main`, commit source changes on a topic branch, and merge a checked PR.
The original Mac checkout is still an older research branch with uncommitted
files; it is preserved while iCloud recovery is incomplete.

The October 18 audit also found locally listed compatibility probes, desktop
experiments and work logs that could not all be read from iCloud. Their presence
is not a completed GitHub backup. Earlier teacher-dataset work remains on
`codex/teacher-dataset-app`; it is not silently promoted into the current app.

Weights, model packages, signing material and build products stay outside Git.
Run `scripts/prepare_safety_assets.py` before building. The compulsory safety
package is pinned and verified; generation models are installed by the app.
