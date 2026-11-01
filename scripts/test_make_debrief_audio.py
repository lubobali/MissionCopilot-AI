"""The voice debrief scripts must tell the demo dataset's story, and every key fact in the answer
key must be in the script text. If the dataset changes, these fail until the audio is rebuilt."""

import json
from pathlib import Path

import pytest
from make_debrief_audio import answer_key, debrief

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[1]
DATA = json.loads((ROOT / "docs" / "demo" / "kandor-rural-roads.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("language", ["en", "fr"])
def test_every_key_fact_is_in_the_script(language):
    script = debrief(DATA, language)
    text = script.text.lower()

    for fact in script.facts:
        assert fact.spoken.lower() in text, fact


@pytest.mark.parametrize("language", ["en", "fr"])
def test_script_is_about_two_minutes_and_says_it_is_fictional(language):
    script = debrief(DATA, language)
    words = len(script.text.split())

    assert 200 <= words <= 330  # 80 to 90 s with the Mac voices, about 2 minutes read aloud
    assert "fictional" in script.text.lower() or "fictif" in script.text.lower()


def test_facts_come_from_the_dataset():
    facts = {f.name: f.value for f in debrief(DATA, "en").facts}

    assert facts["roadWidthMeasured"] == "4.9 m"
    assert facts["roadWidthSpec"] == "7 m"
    assert facts["kmBuilt"] == "32"
    assert facts["kmTotal"] == "64 km"
    assert facts["invoiceAmount"] == "480000"
    assert facts["paidPercent"] == "85 percent"


def test_both_languages_carry_the_same_facts():
    english = {f.name: f.value for f in debrief(DATA, "en").facts}
    french = {f.name: f.value for f in debrief(DATA, "fr").facts}

    assert english == french


def test_committed_answer_key_matches_the_dataset():
    # Catches a dataset edit without rebuilding: run scripts/make_debrief_audio.py, then commit.
    committed = ROOT / "docs" / "demo" / "audio" / "answer-key.json"
    assert json.loads(committed.read_text(encoding="utf-8")) == answer_key(DATA)
