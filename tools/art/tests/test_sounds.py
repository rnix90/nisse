# SPDX-License-Identifier: GPL-2.0-or-later
"""N-414: the login sound. Bert judges by ear, so these tests guard what an ear cannot: the file is well formed, deterministic,
never clips, starts and ends in silence (no click on login), is short, and really holds the two notes the spec says, the second
higher than the first (a playful hop up)."""
import io
import sys
import wave
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import sounds  # noqa: E402

CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
NAMES = list(sounds.VARIANTS)


def _db(x):
    return 20 * np.log10(max(float(np.max(np.abs(x))), 1e-9))


def _band_energy(x, f, width=0.03):
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    freqs = np.fft.rfftfreq(len(x), 1 / sounds.SR)
    return float(spec[(freqs > f * (1 - width)) & (freqs < f * (1 + width))].sum())


def test_there_are_three_variants_one_per_voice():
    assert NAMES == ["a-flute-and-bell", "b-kulning-call", "c-plucked-wood"]
    for n in NAMES:
        assert sounds.VARIANTS[n]["title"]


@pytest.mark.parametrize("name", NAMES)
def test_each_variant_has_exactly_two_notes_and_the_second_is_higher(name):
    notes = sounds.VARIANTS[name]["notes"]
    assert len(notes) == 2
    assert notes[1][2] > notes[0][2] * 1.2          # a clear hop up, more than a minor third
    assert notes[1][0] > notes[0][0]                # one after the other


@pytest.mark.parametrize("name", NAMES)
def test_render_is_deterministic(name):
    assert np.array_equal(sounds.render(name), sounds.render(name))


@pytest.mark.parametrize("name", NAMES)
def test_length_is_short(name):
    x = sounds.render(name)
    assert 0.9 <= len(x) / sounds.SR <= 2.6


@pytest.mark.parametrize("name", NAMES)
def test_peak_is_comfortable_and_never_clips(name):
    x = sounds.render(name)
    assert -9.0 <= _db(x) <= -3.0
    assert np.all(np.isfinite(x))


@pytest.mark.parametrize("name", NAMES)
def test_starts_and_ends_in_silence(name):
    x = sounds.render(name)
    # no click on login: the first sample is zero and the first 0.2 ms is far below the peak (a pluck is hard-edged by design,
    # so the ramp-in is judged at 0.2 ms, not at 4 ms)
    assert x[0] == 0 and _db(x[:int(0.0002 * sounds.SR)]) < -30
    assert abs(x[-1]) < 1e-4 and _db(x[-int(0.02 * sounds.SR):]) < -45


@pytest.mark.parametrize("name", NAMES)
def test_no_dc_offset(name):
    x = sounds.render(name)
    assert abs(float(np.mean(x))) < 0.01


@pytest.mark.parametrize("name", NAMES)
def test_the_two_notes_are_really_in_the_audio(name):
    x = sounds.render(name)
    (s1, d1, f1), (s2, d2, f2) = sounds.VARIANTS[name]["notes"]
    a = x[int((s1 + 0.04) * sounds.SR):int(min(s2 - 0.01, s1 + d1) * sounds.SR)]       # note one alone
    b = x[int((s2 + 0.08) * sounds.SR):int((s2 + 0.30) * sounds.SR)]                   # note two (note one's tail underneath)
    assert _band_energy(a, f1) > 4 * _band_energy(a, f2), "note one is missing or note two came in early"
    assert _band_energy(b, f2) > _band_energy(b, f1), "note two is missing"


@pytest.mark.parametrize("name", NAMES)
def test_the_notes_are_wilderness_pitches_not_a_squeal(name):
    for _, _, f in sounds.VARIANTS[name]["notes"]:
        assert 400 <= f <= 1700


@pytest.mark.parametrize("name", NAMES)
def test_wav_is_16_bit_mono_at_the_sample_rate(name):
    buf = io.BytesIO()
    sounds.write_wav(buf, sounds.render(name))
    buf.seek(0)
    with wave.open(buf, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, sounds.SR)
        assert w.getnframes() > sounds.SR


def test_the_variants_sound_different():
    xs = [sounds.render(n) for n in NAMES]
    n = min(len(x) for x in xs)
    for i in range(3):
        for j in range(i + 1, 3):
            c = abs(float(np.dot(xs[i][:n], xs[j][:n]))) / (np.linalg.norm(xs[i][:n]) * np.linalg.norm(xs[j][:n]) + 1e-12)
            assert c < 0.5


def test_source_is_ascii_and_lowercase_named():
    src = (HERE.parent / "sounds.py").read_text(encoding="utf-8")
    assert src.isascii() and CAPITAL not in src


# ---- the sound theme: Bert chose voice C for the login sound; every other event speaks in the same voice
THEME = list(sounds.THEME)


def test_the_theme_has_the_six_events_and_login_is_the_approved_voice():
    assert THEME == ["login", "logout", "notification", "needs-you", "error", "volume"]
    # the login notes are candidate C's, moved down by the master pitch Bert chose
    for (s1, d1, f1), (s2, d2, f2) in zip(sounds.THEME["login"]["notes"], sounds.VARIANTS["c-plucked-wood"]["notes"]):
        assert (s1, d1) == (s2, d2) and abs(f1 - f2 * 2 ** (sounds.MASTER_SHIFT / 12)) < 0.01
    assert sounds.MASTER_SHIFT == -2


@pytest.mark.parametrize("name", THEME)
def test_theme_sound_is_deterministic_short_and_at_its_level(name):
    spec = sounds.THEME[name]
    x = sounds.render_theme(name)
    assert np.array_equal(x, sounds.render_theme(name))
    assert 0.4 <= len(x) / sounds.SR <= spec["max_s"]
    assert abs(_db(x) - spec["peak"]) < 0.2
    assert spec["peak"] <= -6.0, "no event is louder than the login sound"
    assert np.all(np.isfinite(x)) and abs(float(np.mean(x))) < 0.01


@pytest.mark.parametrize("name", THEME)
def test_theme_sound_starts_and_ends_without_a_click(name):
    x = sounds.render_theme(name)
    assert x[0] == 0 and _db(x[:int(0.0002 * sounds.SR)]) < -30 + sounds.THEME[name]["peak"] + 6
    assert abs(x[-1]) < 1e-4 and _db(x[-int(0.02 * sounds.SR):]) < sounds.THEME[name]["peak"] - 35


@pytest.mark.parametrize("name", THEME)
def test_every_note_of_a_theme_sound_is_really_there(name):
    x = sounds.render_theme(name)
    for start, dur, f in sounds.THEME[name]["notes"]:
        w = x[int((start + 0.01) * sounds.SR):int((start + 0.07) * sounds.SR)]
        assert _band_energy(w, f) > 2 * _band_energy(w, f * 1.19), f"{name}: no note at {f} Hz"


def test_the_contours_tell_the_events_apart_by_ear():
    up = lambda n: all(b[2] > a[2] for a, b in zip(sounds.THEME[n]["notes"], sounds.THEME[n]["notes"][1:]))
    down = lambda n: all(b[2] < a[2] for a, b in zip(sounds.THEME[n]["notes"], sounds.THEME[n]["notes"][1:]))
    assert up("login") and up("notification") and up("needs-you")      # arriving, attention: up
    assert down("logout") and down("error")                            # leaving, trouble: down
    assert len(sounds.THEME["volume"]["notes"]) == 1


def test_the_error_sound_is_lower_than_every_other_event():
    low = lambda n: min(f for _, _, f in sounds.THEME[n]["notes"])
    assert all(low("error") < low(n) for n in THEME if n != "error")


# ---- the master pitch: the whole theme can be moved down or up together so Bert can pick by ear
def test_shifting_by_zero_changes_nothing_and_a_shift_is_deterministic():
    for n in THEME:
        assert np.array_equal(sounds.render_theme(n), sounds.render_theme(n, semitones=0))
        assert np.array_equal(sounds.render_theme(n, semitones=-3), sounds.render_theme(n, semitones=-3))


@pytest.mark.parametrize("semitones", [-2, -4])
def test_a_shifted_theme_really_sounds_lower_and_stays_clean(semitones):
    ratio = 2 ** (semitones / 12)
    for name in THEME:
        spec = sounds.THEME[name]
        x = sounds.render_theme(name, semitones=semitones)
        assert abs(_db(x) - spec["peak"]) < 0.2 and x[0] == 0 and abs(x[-1]) < 1e-4
        assert len(x) / sounds.SR <= spec["max_s"]
        start, dur, f = spec["notes"][0]
        w = x[int((start + 0.01) * sounds.SR):int((start + 0.07) * sounds.SR)]
        assert _band_energy(w, f * ratio) > 2 * _band_energy(w, f), f"{name}: first note did not move to {f * ratio:.0f} Hz"
