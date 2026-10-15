# Version 1.1 build 6 release check

[Summary](summary.json) · [Physical event/state evidence](device-validation.json) · [Image-safety cases](image-safety-regression.json) · [Photos validation](photos-validation.json) · [Screenshot provenance](screenshots.json)

The isolated development copy uses the current production view model, Photos handler, model installation, six-GB guard and four-step 512px generator. The driver is not included in the uploaded archive. This is native handler/inference coverage, with real OS lifecycle notifications and human-operated Photos permission settings; it is not an XCTest tap run.

## Output-safety correction

Revision `swiftformer-1d648298-sixviews-all-sfw90-v2` requires **every** view to return SFW >= 0.90 and combined NSFW + NSFL <= 0.10, as well as complete, finite, normalized probabilities. The full frame can no longer override an uncertain crop.

The earlier rule approved a known adult-nudity artwork whose full-frame SFW score was 0.9057, despite a crop returning only 0.5400 SFW. Its earlier crop veto required 0.90 unsafe probability. The current rule refuses that case. An uncertain crop is deliberately refused even when the cause could be a benign texture.

Four local, known-content artworks (three adult-nudity cases and one graphic-violence case) were refused on **Mac and iPhone 14 / iOS 27.2**, using the real classifier. A benign FLUX still-life fixture was approved on both. Source URLs, hashes, licensing/attribution and Mac scores are recorded in the case JSON; raw unsafe fixtures are not published or displayed by the app. This small, selected matrix does not estimate NSFW/NSFL false-negative rates.

All four ordinary examples—still life, landscape, robot and watercolor cat—then completed real generation on iPhone 14 with seed 42 and the new gate. The summary preserves all six decisions and checked pixel hashes. Nine safety test functions pass, including 54 blocked and 20 ordinary prompts, incomplete/invalid results, uncertain crops, missing/corrupt models and cancellation. The unchanged generation/optimization/installer tests had previously passed 15 functions.

## Photos and OS lifecycle

Actual add-only authorization and Photos writes succeeded. After the human changed Photos access to None, saving showed the permission explanation and Settings option while retaining the checked image, original prompt and seed. After permission restoration, the current build saved another checked image successfully. Existing Photos contents were never read.

At diffusion step 2, Device Hub's Home control moved the app into the background. The observed background interval was approximately 21.8 seconds. Returning to the same process cancelled the new operation; the preceding landscape's image ID, pixel hash, prompt and seed were unchanged. Generating again succeeded. No lifecycle notification was synthesized for this check. Forced memory-pressure termination and reboot recovery were not tested; results remain temporary and must be saved before process termination.

## Store screenshots

Five current-UI screenshots are in `StoreMetadata/screenshots/1.1/`. They were rendered directly from the actual iPhone 14 app window at **1284×2778** for store export. They are not measurements on a physical 6.5-inch device. The final RGB PNG encoding removes an otherwise fully opaque alpha channel, preserves dimensions/color profile, and introduces at most 1/255 channel rounding. No invented controls or substituted generated results were used. The case JSON records file hashes.

The earlier [build 5 usability run](../app-readiness/README.md) remains a dated record of its 43 assertions and older gate. The new evidence here supersedes its open Photos/background/image-fixture items without relabelling those earlier results.
