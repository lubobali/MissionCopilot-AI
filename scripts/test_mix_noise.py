"""Noisy test audio must hit the noise level it claims, measured by code, or the noise rounds of
spike #14 compare engines at levels nobody checked."""

import math

import pytest
from mix_noise import mix, rms, road_noise, snr_db

pytestmark = pytest.mark.unit


def tone(n: int, amplitude: float = 8000.0) -> list[float]:
    return [amplitude * math.sin(2 * math.pi * 440 * i / 16000) for i in range(n)]


@pytest.mark.parametrize("target", [20.0, 10.0, 5.0, 0.0])
def test_mix_hits_the_requested_signal_to_noise_ratio(target):
    speech = tone(16000, amplitude=1000)  # quiet enough that the mix never needs to be scaled
    noise = road_noise(16000, seed=1)

    mixed = mix(speech, noise, target)
    added = [m - s for m, s in zip(mixed, speech, strict=True)]

    assert snr_db(speech, added) == pytest.approx(target, abs=0.01)


def test_mix_keeps_the_length_of_the_speech_and_loops_short_noise():
    mixed = mix(tone(16000), road_noise(1000, seed=1), 10.0)

    assert len(mixed) == 16000


def test_mix_never_clips_past_16_bit():
    mixed = mix(tone(16000, amplitude=32000), road_noise(16000, seed=1), 0.0)

    assert max(abs(x) for x in mixed) <= 32767


def test_road_noise_is_repeatable_and_not_silent():
    assert road_noise(500, seed=7) == road_noise(500, seed=7)
    assert rms(road_noise(500, seed=7)) > 0


def test_silent_noise_is_refused():
    with pytest.raises(ValueError, match="silent"):
        mix(tone(100), [0.0] * 100, 10.0)
