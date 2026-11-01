#!/usr/bin/env bash
# Runs the spike #15 tests on an iOS Simulator (Vision reads docs/demo/scans); used by prek and CI.
# Usage: test.sh [xcodebuild destination], default the iPhone 13 Pro Max simulator.
set -euo pipefail
destination="${1:-platform=iOS Simulator,name=iPhone 13 Pro Max}"
cd "$(dirname "$0")"
xcodebuild test -scheme DocumentLab -destination "$destination" -quiet
