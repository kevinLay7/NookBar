#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
codesign --verify --deep --strict build/NookBar.app
plutil -lint Resources/Info.plist
build/NookBar.app/Contents/MacOS/NookBar --diagnose | python3 -c '
import json, sys
report = json.load(sys.stdin)
assert isinstance(report["macOS"], str) and report["macOS"]
for field in ("accessibilityGranted", "frameworkAvailable", "configurationAvailable", "activationAvailable", "invalidationAvailable"):
    assert isinstance(report[field], bool), field
print(json.dumps(report, indent=2))
print("Diagnostics smoke check passed; hiding behavior remains untested.")
'
