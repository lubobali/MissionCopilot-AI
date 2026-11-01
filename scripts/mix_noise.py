"""Make noisy copies of a voice debrief for spike #14, at a noise level measured by code.

Writes <out>/<name>-quiet.m4a, <name>-road-10db.m4a and <name>-cafe-10db.m4a: the voice alone, with
low traffic rumble, and with other people talking (macOS voices), each 10 dB below the voice. The
mixing is pure and tested; decoding and the babble need macOS `afconvert` and `say`.

The input is a private recording (a cloned voice), so the outputs stay out of the repo.
Run: uv run --directory backend python ../scripts/mix_noise.py <voice.mp3> <out dir> <name>
"""

import math
import random
import subprocess  # noqa: S404 - fixed macOS tools, paths from the command line
import sys
import tempfile
import wave
from array import array
from pathlib import Path

RATE = 16000
PEAK = 32767
BABBLE = {
    "Daniel": "The train to the airport leaves at nine, so we should pack tonight and sleep early.",
    "Karen": "I think the soup needs more salt, but the bread from the corner shop is really good.",
    "Moira": "My sister moved to a new flat last week and the neighbours are very friendly.",
    "Fred": "Did you watch the match on Saturday? The second half was much better than the first.",
}


def rms(samples: list[float]) -> float:
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0.0


def snr_db(speech: list[float], noise: list[float]) -> float:
    return 20 * math.log10(rms(speech) / rms(noise))


def road_noise(n: int, seed: int) -> list[float]:
    """Brown noise: most energy low, like traffic rumble. Repeatable for a seed."""
    rng = random.Random(seed)  # noqa: S311 - test noise, not security
    out, level = [], 0.0
    for _ in range(n):
        level = 0.995 * level + rng.uniform(-1, 1)  # leaky, so it does not drift away
        out.append(level)
    return out


def mix(speech: list[float], noise: list[float], target_snr_db: float) -> list[float]:
    """Speech plus noise scaled so the ratio is exactly target_snr_db. Short noise is looped. If the
    sum would clip, both are scaled down together, which keeps the ratio."""
    noise_rms = rms(noise)
    if noise_rms == 0:
        raise ValueError("noise is silent")
    gain = rms(speech) / (noise_rms * 10 ** (target_snr_db / 20))
    mixed = [s + gain * noise[i % len(noise)] for i, s in enumerate(speech)]
    peak = max(abs(x) for x in mixed)
    return [x * PEAK / peak for x in mixed] if peak > PEAK else mixed


def read_wav(path: Path) -> list[float]:  # pragma: no cover - file I/O
    with wave.open(str(path)) as w:
        return [float(x) for x in array("h", w.readframes(w.getnframes()))]


def write_m4a(samples: list[float], path: Path) -> None:  # pragma: no cover - macOS tools
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "mix.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(array("h", (round(x) for x in samples)).tobytes())
        run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "32000", str(wav), str(path)])


def decode(path: Path, tmp: Path) -> list[float]:  # pragma: no cover - macOS tools
    wav = tmp / (path.stem + ".wav")
    run(["/usr/bin/afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(path), str(wav)])
    return read_wav(wav)


def babble(tmp: Path) -> list[float]:  # pragma: no cover - macOS tools
    """Four people talking at once, each at the same level."""
    voices = []
    for voice, text in BABBLE.items():
        aiff = tmp / f"{voice}.aiff"
        run(["/usr/bin/say", "-v", voice, "-o", str(aiff), text])
        samples = decode(aiff, tmp)
        level = rms(samples)
        voices.append([x / level for x in samples])
    length = max(len(v) for v in voices)
    return [sum(v[i % len(v)] for v in voices) for i in range(length)]


def run(command: list[str]) -> None:  # pragma: no cover
    subprocess.run(command, check=True)  # noqa: S603 - fixed macOS tools


def main(voice: Path, out: Path, name: str) -> None:  # pragma: no cover
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        speech = decode(voice, tmp)
        rounds = {
            "quiet": speech,
            "road-10db": mix(speech, road_noise(RATE * 10, seed=14), 10.0),
            "cafe-10db": mix(speech, babble(tmp), 10.0),
        }
        for label, samples in rounds.items():
            write_m4a(samples, out / f"{name}-{label}.m4a")
            print(f"{name}-{label}.m4a  {len(samples) / RATE:.0f} s")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
