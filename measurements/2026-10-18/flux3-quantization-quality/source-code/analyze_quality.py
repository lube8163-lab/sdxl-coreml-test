#!/usr/bin/env python3
"""Verify gated CUDA results and make lossless comparison sheets and distances."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("run", type=Path)
p.add_argument("--cases", type=Path, required=True)
a = p.parse_args()
report = json.loads((a.run / "summary.json").read_text())
manifest = json.loads(a.cases.read_text())
assert hashlib.sha256(a.cases.read_bytes()).hexdigest() == report["gpu_comparison"]["cases_sha256"]
modes = ["original", "dit-int4", "all-int4"]
expected = {f'{case["id"]}-seed{seed}-{mode}' for case in manifest["cases"]
            for seed in manifest["seeds"] for mode in modes}
receipts = {item["label"]: item for item in report["safety_receipts"]}
assert len(receipts) == len(report["safety_receipts"]) and set(receipts) == expected
assert report["expected_images"] == len(expected)
for label, receipt in receipts.items():
    if not receipt["approved"]:
        assert not (a.run / "images" / (label + ".png")).exists()
        continue
    path = a.run / "images" / receipt["filename"]
    assert path.name == label + ".png"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == receipt["sha256"]
    assert len(receipt["decisions"]) == 6
    for view in receipt["decisions"]:
        assert all(math.isfinite(view[k]) and 0 <= view[k] <= 1 for k in ("sfw", "nsfw", "nsfl"))
        assert view["sfw"] >= .90 and view["nsfw"] + view["nsfl"] <= .10
    with Image.open(path) as image:
        assert image.size == (512, 512)
assert report["approved_images"] == sum(item["approved"] for item in receipts.values())

distances = report["gpu_comparison"]["distances"]
metrics = ["pixel_mae_0_to_1", "psnr_db", "ssim", "latent_relative_rmse"]
assert len(distances) == len(manifest["cases"]) * len(manifest["seeds"]) * 2
pixel_metrics_rechecked = 0
for item in distances:
    base = f'{item["case_id"]}-seed{item["seed"]}-original'
    changed = f'{item["case_id"]}-seed{item["seed"]}-{item["mode"]}'
    if not receipts[base]["approved"] or not receipts[changed]["approved"]:
        continue
    def pixels(label):
        with Image.open(a.run / "images" / receipts[label]["filename"]) as image:
            return np.asarray(image.convert("RGB"), dtype=np.float32) / 255
    difference = pixels(base) - pixels(changed)
    mae = float(np.mean(np.abs(difference)))
    psnr = float(-10 * np.log10(max(float(np.mean(difference ** 2)), 1e-20)))
    assert math.isclose(mae, item["pixel_mae_0_to_1"], abs_tol=1e-7)
    assert math.isclose(psnr, item["psnr_db"], abs_tol=1e-4)
    pixel_metrics_rechecked += 1
aggregates = {}
for mode in modes[1:]:
    values = [item for item in distances if item["mode"] == mode]
    assert len(values) == len(expected) // 3
    aggregates[mode] = {}
    for key in metrics:
        field = [item[key] for item in values]
        assert all(math.isfinite(value) for value in field)
        aggregates[mode][key] = {"mean": statistics.mean(field), "median": statistics.median(field),
                                 "min": min(field), "max": max(field)}
summary = {"scope": report["scope"], "expected_images": len(expected),
           "approved_images": report["approved_images"], "comparisons_per_quantized_mode": len(expected) // 3,
           "pixel_metric_pairs_rechecked_on_saved_pngs": pixel_metrics_rechecked,
           "distance_aggregates": aggregates,
           "interpretation": "Distances from matching original-weight images; not quality percentages or human preference scores."}
(a.run / "distance-summary.json").write_text(json.dumps(summary, indent=2) + "\n")

font = ImageFont.load_default(size=22)
small = ImageFont.load_default(size=18)
tile, margin, header, row_label = 384, 20, 76, 34
titles = ["Original BF16 weights", "DiT INT4 weights", "TE + DiT INT4 weights"]
for seed in manifest["seeds"]:
    width = margin * 2 + tile * 3
    height = header + (tile + row_label) * len(manifest["cases"]) + margin
    canvas = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(canvas)
    draw.text((margin, 8), f"FLUX.3 / common FP32 math / 512px / 16 steps / seed {seed}", fill="black", font=font)
    for column, title in enumerate(titles):
        draw.text((margin + column * tile, 45), title, fill="black", font=small)
    for row, case in enumerate(manifest["cases"]):
        y = header + row * (tile + row_label)
        draw.text((margin, y + 7), case["id"], fill="black", font=small)
        for column, mode in enumerate(modes):
            label = f'{case["id"]}-seed{seed}-{mode}'
            x = margin + column * tile
            if receipts[label]["approved"]:
                with Image.open(a.run / "images" / receipts[label]["filename"]) as image:
                    canvas.paste(image.convert("RGB").resize((tile, tile), Image.Resampling.LANCZOS), (x, y + row_label))
            else:
                draw.rectangle((x, y + row_label, x + tile - 1, y + row_label + tile - 1), fill="#eeeeee")
                draw.text((x + 20, y + row_label + tile // 2), "Withheld by safety gate", fill="black", font=small)
    canvas.save(a.run / f"comparison-seed{seed}.png")

lines = ["| Case | Seed | Quantized weights | MAE (0-1) | PSNR dB | SSIM | Latent relative RMSE |",
         "| --- | ---: | --- | ---: | ---: | ---: | ---: |"]
for item in distances:
    lines.append(f'| {item["case_id"]} | {item["seed"]} | {item["mode"]} | {item["pixel_mae_0_to_1"]:.4f} | {item["psnr_db"]:.2f} | {item["ssim"]:.4f} | {item["latent_relative_rmse"]:.4f} |')
(a.run / "distances.md").write_text("\n".join(lines) + "\n")
print(json.dumps(summary, indent=2))
