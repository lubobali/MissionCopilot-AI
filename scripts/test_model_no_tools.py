"""The on-device model gets no tools (threat T08, #63, #136).

ModelRequest has no field for tools, so FieldModel cannot pass any. This guard covers the rest of
the app: no Swift file may hand the model a tool or keep a chat history, and the tokenizer bridge
passes `tools: nil` to the chat template whatever it is given.
"""

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

APP = Path(__file__).resolve().parents[1] / "ios" / "MissionCopilot"
BRIDGE = APP / "Platform" / "AI" / "TokenizerBridge.swift"
# An argument label `tools:` followed by anything but nil, outside a type declaration.
TOOLS_ARGUMENT = re.compile(r"\btools:(?!\s*nil\b)(?!\s*\[\[String)")


def _swift() -> dict[Path, str]:
    return {path: path.read_text(encoding="utf-8") for path in APP.rglob("*.swift")}


def offending(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if TOOLS_ARGUMENT.search(line)]


def test_a_tool_argument_is_found():
    assert offending("session.respond(to: prompt, tools: [weather])") == [
        "session.respond(to: prompt, tools: [weather])"
    ]
    assert offending("UserInput(prompt: p, tools: nil)") == []
    assert offending("tools: [[String: any Sendable]]?,") == []


def test_no_swift_file_in_the_app_passes_the_model_a_tool():
    found = {path.name: offending(text) for path, text in _swift().items() if offending(text)}

    assert found == {}


def test_the_bridge_never_passes_tools_on():
    text = BRIDGE.read_text(encoding="utf-8")

    assert "applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)" in text


def test_no_chat_session_keeps_a_history():
    # ChatSession remembers earlier turns; the app asks each question fresh (FieldModel).
    users = [path.name for path, text in _swift().items() if "ChatSession(" in text]

    assert users == []
