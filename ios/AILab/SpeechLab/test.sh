#!/usr/bin/env bash
# Runs the spike #14 scoring tests on an iOS Simulator (reads docs/demo/audio/answer-key.json); used by
# prek and CI. Usage: test.sh [xcodebuild destination], default the iPhone 13 Pro Max simulator.
set -euo pipefail
destination="${1:-platform=iOS Simulator,name=iPhone 13 Pro Max}"
cd "$(dirname "$0")"
xcodebuild test -scheme SpeechLab -destination "$destination" -quiet
