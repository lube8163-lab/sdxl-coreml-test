#!/usr/bin/env python3
"""Control only the isolated release-validation driver through its owned files."""
import argparse
import json
from pathlib import Path
import subprocess
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("action", choices=["generate", "select", "capture", "inputTop", "save", "dismissAlert", "openPhotoSettings", "showSettings", "hideSettings", "checkFixtures", "report"])
p.add_argument("--example", choices=["stillLife", "landscape", "robot", "illustration"])
p.add_argument("--label")
p.add_argument("--device", required=True, help="Connected test-device identifier; never stored in published evidence.")
p.add_argument("--evidence", type=Path, required=True)
a = p.parse_args()
a.evidence.mkdir(parents=True, exist_ok=True)
base = ["xcrun", "devicectl", "device", "copy"]
domain = ["--device", a.device, "--domain-type", "appDataContainer", "--domain-identifier", "com.tasuku.sdxlcoremltest", "--timeout", "30"]
if a.action == "report":
    target = a.evidence / "physical-report.json"
    subprocess.run(base + ["from"] + domain + ["--source", "Documents/ReleaseReadinessValidation/report.json", "--destination", str(target)], check=True, stdout=subprocess.DEVNULL)
    d = json.loads(target.read_text())
    for row in d["records"][-3:]:
        print(json.dumps(row, ensure_ascii=False))
else:
    c = {"id": str(uuid.uuid4()), "action": a.action, "example": a.example, "label": a.label}
    target = a.evidence / "device-command.json"
    target.write_text(json.dumps(c) + "\n")
    subprocess.run(base + ["to"] + domain + ["--source", str(target), "--destination", "Documents/ReleaseReadinessValidation/command.json"], check=True, stdout=subprocess.DEVNULL)
    print(json.dumps(c))
