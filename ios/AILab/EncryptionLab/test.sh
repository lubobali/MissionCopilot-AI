#!/usr/bin/env bash
# Runs all spike #16 tests on an iOS Simulator; used by the prek hook and by CI.
# Usage: test.sh [xcodebuild destination], default the iPhone 13 Pro Max simulator.
set -euo pipefail
destination="${1:-platform=iOS Simulator,name=iPhone 13 Pro Max}"
cd "$(dirname "$0")"

# SQLCipher database tests: plain package tests, no app needed.
xcodebuild test -scheme EncryptionLab -destination "$destination" -quiet

# Keychain tests: need a signed host app, so they run in Host/.
cd Host
xcodegen generate -q
xcodebuild test -project EncryptionLabHost.xcodeproj -scheme EncryptionLabHost -destination "$destination" -quiet
