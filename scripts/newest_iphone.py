"""Print the id of an iPhone simulator on the newest iOS runtime installed (CI, story #68).

The runner's simulator list changes over time and is not sorted; an app that needs iOS 26 cannot
run on an older simulator listed first. Reads `xcrun simctl list devices available -j` on stdin.

Usage: xcrun simctl list devices available -j | python3 scripts/newest_iphone.py
"""

import json
import re
import sys

RUNTIME = re.compile(r"\.iOS-(\d+)-(\d+)")


def newest_iphone(listing: dict) -> str:
    candidates = []
    for runtime, devices in listing["devices"].items():
        match = RUNTIME.search(runtime)
        iphones = [d["udid"] for d in devices if d["name"].startswith("iPhone")]
        if match and iphones:
            candidates.append(((int(match.group(1)), int(match.group(2))), iphones[0]))
    if not candidates:
        raise SystemExit("no iPhone simulator found")
    return max(candidates)[1]


if __name__ == "__main__":
    print(newest_iphone(json.load(sys.stdin)))
