"""The app's navigation stays one kind on the way to a mission (#125, found on the iPhone).

SwiftUI shows pages opened by a value (`NavigationLink(..., value:)`) under the pages opened by
a destination closure (`NavigationLink(...) { ... }`). On the iPhone "Open mission" pushed the
workspace under the Missions page (opened by a closure): nothing seemed to happen, and Back
revealed it. So every page on the way to a mission is opened by a value, and all their
destinations are declared at the stack's root, the home screen.
"""

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

APP = Path(__file__).resolve().parents[1] / "ios" / "MissionCopilot"
ROOT_FILE = APP / "App" / "ContentView.swift"


def _swift():
    return {path: path.read_text(encoding="utf-8") for path in APP.rglob("*.swift")}


def test_every_value_destination_is_declared_at_the_root():
    declared = {path for path, text in _swift().items() if ".navigationDestination(" in text}

    assert declared == {ROOT_FILE}


def test_the_missions_page_is_opened_by_a_value_like_the_mission_inside_it():
    home = ROOT_FILE.read_text(encoding="utf-8")

    assert re.search(r'NavigationLink\("Missions", value: ', home)
    assert not re.search(r'NavigationLink\("Missions"\)\s*\{', home)
    assert ".navigationDestination(for: MissionLink.self)" in home
