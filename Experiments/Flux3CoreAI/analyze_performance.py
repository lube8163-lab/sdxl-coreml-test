#!/usr/bin/env python3
"""Summarize native CoreAI wall-clock phases; inference await is not GPU-only time."""

import argparse
import collections
import hashlib
import json
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("run", type=Path)
parser.add_argument("--baseline", type=Path)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
report = json.loads((args.run / "report.json").read_text())
events = [json.loads(line) for line in (args.run / "component-timings.jsonl").read_text().splitlines() if line.strip()]
phases = collections.defaultdict(list)
for item in events:
    phases[item["phase"]].append(item)
summary = {"label": report.get("experiment_label"), "stage": report["stage"], "complete_image": report.get("image_saved", False), "pin_count": report.get("pinned_heavy_block_count"), "pinned_shared_groups": report.get("pinned_shared_group_count", 0), "cache_capacity": report.get("model_cache_capacity"), "execution_kind": report.get("execution_kind"), "sampled_peak_footprint_bytes": report.get("sampled_peak_physical_footprint_bytes"), "phases": {}}
for phase, items in phases.items():
    totals = {name: sum(item[name + "_seconds"] for item in items) for name in ["model_load", "function_load", "eviction", "inference_await", "total"]}
    summary["phases"][phase] = {"calls": len(items), "cache_hits": sum(item["cache_hit"] for item in items), "seconds": totals, "thermal_state_counts": dict(collections.Counter(item["thermal_state"] for item in items))}
denoising = phases.get("denoising", [])
by_component = collections.defaultdict(list)
for item in denoising:
    by_component[item["component"]].append(item)
summary["denoising_component_means_seconds"] = {
    name: {field: statistics.mean(item[field + "_seconds"] for item in items) for field in ["model_load", "function_load", "eviction", "inference_await", "total"]}
    for name, items in sorted(by_component.items())
}
steps = report.get("step_records", [])
summary["completed_steps"] = len(steps)
if len(steps) > 1:
    summary["steps_2_onward_median_seconds"] = statistics.median(item["seconds"] for item in steps[1:])
    summary["steps_2_onward_mean_seconds"] = statistics.mean(item["seconds"] for item in steps[1:])
for key in ["text_encoding_seconds", "text_precompute_seconds", "denoising_seconds", "vae_seconds", "image_sha256",
            "steps", "seed", "fixture_profile", "sampling_schedule", "input_safety_seconds",
            "safety_preparation_seconds", "output_safety_seconds", "run_to_saved_seconds"]:
    if key in report: summary[key] = report[key]
if all(key in report for key in ["text_encoding_seconds", "denoising_seconds", "vae_seconds"]):
    summary["three_stage_seconds"] = sum(report[key] for key in ["text_encoding_seconds", "denoising_seconds", "vae_seconds"])
    summary["model_pipeline_seconds"] = summary["three_stage_seconds"] + report.get("text_precompute_seconds", 0)
if report.get("image_saved"):
    image = args.run / report["image_filename"]
    assert hashlib.sha256(image.read_bytes()).hexdigest() == report["image_sha256"]
    assert report["image_approved"] and len(report["safety_decisions"]) == 6
    for decision in report["safety_decisions"]:
        values = [decision[key] for key in ["sfw", "nsfw", "nsfl"]]
        assert all(math.isfinite(value) and 0 <= value <= 1 for value in values)
        assert abs(sum(values) - 1) < 0.02
        assert decision["sfw"] >= 0.90 and decision["nsfw"] + decision["nsfl"] <= 0.10
    summary["six_view_safety_verified"] = True
if args.baseline and report.get("image_saved"):
    baseline = json.loads((args.baseline / "report.json").read_text())
    summary["baseline_label"] = baseline.get("experiment_label")
    summary["baseline_denoising_seconds"] = baseline["denoising_seconds"]
    summary["baseline_image_sha256_match"] = report["image_sha256"] == baseline["image_sha256"]
    summary["denoising_speedup"] = baseline["denoising_seconds"] / report["denoising_seconds"]
    if "model_pipeline_seconds" in summary:
        baseline_pipeline=sum(baseline[key] for key in ["text_encoding_seconds","denoising_seconds","vae_seconds"]) + baseline.get("text_precompute_seconds",0)
        summary["baseline_model_pipeline_seconds"]=baseline_pipeline
        summary["model_pipeline_speedup"]=baseline_pipeline/summary["model_pipeline_seconds"]
summary["measurement_scope"] = "Wall time inside model constructor, function load and awaited function.run. run may include runtime scheduling and synchronization; it is not isolated GPU kernel time."
if args.output:
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
