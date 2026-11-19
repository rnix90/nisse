#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The nisse login sound (ledger N-414): a playful two-note sound that feels like something heard in the Scandinavian wilderness,
mischievous. Procedural synthesis, no samples: numpy builds each note from sine partials, noise and filters, so the sound is
reproducible byte for byte and carries no license baggage.

Three variants, one per voice, so Bert can compare them by ear:

    a-flute-and-bell   a breathy wooden flute, then a small bell a fourth higher
    b-kulning-call     two airy sung calls (the herding call of the Nordic hills), the second a fifth up, sliding into place
    c-plucked-wood     two plucked notes (a kantele, a wooden xylophone), the second a sixth up

    python tools/art/sounds.py [--out DIR]      writes DIR/<variant>.wav (default assets/audio/login-candidates)
    python tools/art/sounds.py --theme [--shift SEMITONES] [--out DIR]   writes the sound theme in the chosen voice (C), one wav per event
"""
import pathlib
import sys
import wave

import numpy as np
from scipy import signal

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "assets" / "audio" / "login-candidates"
SR = 48000
PEAK = 0.5            # -6 dBFS: a login sound should never startle


def _t(seconds):
    return np.arange(int(round(seconds * SR))) / SR


def _smooth(x):
    return x * x * (3 - 2 * x)


def _env(n, attack, release, hold_to=None):
    """Smooth attack, flat body, smooth release over the last `release` seconds."""
    e = np.ones(n)
    a = max(1, int(attack * SR))
    r = max(1, int(release * SR))
    e[:a] = _smooth(np.linspace(0, 1, a))
    e[n - r:] *= _smooth(np.linspace(1, 0, r))
    return e


def _hz_phase(freq):
    return 2 * np.pi * np.cumsum(freq) / SR


def _bandpass(x, lo, hi):
    sos = signal.butter(2, [lo, hi], btype="band", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def _add(mix, note, start):
    i = int(round(start * SR))
    mix[i:i + len(note)] += note[:len(mix) - i]


def _reverb(x, rng, rt60=1.1, wet=0.22, predelay=0.014):
    """A small outdoor space: decaying noise, dark, mixed in behind the dry sound."""
    n = int(rt60 * 1.3 * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-6.9 * t / rt60)
    sos = signal.butter(1, 5200, btype="low", fs=SR, output="sos")
    ir = signal.sosfilt(sos, ir)
    ir /= np.sqrt(np.sum(ir ** 2))
    ir = np.concatenate([np.zeros(int(predelay * SR)), ir])
    tail = signal.fftconvolve(x, ir)
    out = np.zeros(len(tail))
    out[:len(x)] += x * (1 - wet)
    out += tail * wet * 1.6
    return out


def _finish(x, peak=PEAK):
    """Remove DC, fade the very end so nothing clicks, then set the peak."""
    x = x - np.mean(x)
    f = min(int(0.25 * SR), len(x) // 2)
    x[-f:] *= _smooth(np.linspace(1, 0, f))
    x[:int(0.003 * SR)] *= np.linspace(0, 1, int(0.003 * SR))
    return x * (peak / np.max(np.abs(x)))


# ---- voices
def flute(freq, dur, rng):
    """Wooden flute: a pure tone with a little air in it, a scoop up into the pitch and a late, gentle vibrato."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = freq * (1 - 0.035 * np.exp(-t / 0.05)) * (1 + 0.004 * np.sin(2 * np.pi * 5.2 * t) * np.clip((t - 0.08) / 0.1, 0, 1))
    ph = _hz_phase(f)
    tone = sum(a * np.sin(k * ph) for k, a in ((1, 1.0), (2, 0.2), (3, 0.07), (4, 0.025)))
    air = _bandpass(rng.standard_normal(n), freq * 1.5, freq * 4.0) * (0.06 + 0.5 * np.exp(-t / 0.05) * 0.1)
    e = _env(n, 0.045, 0.16)
    return (tone + air * 4) * e


def bell(freq, dur):
    """A small bell: inharmonic partials, each fading at its own speed."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for ratio, amp, decay in ((1.0, 1.0, 0.85), (2.0, 0.45, 0.55), (2.76, 0.32, 0.38), (5.4, 0.16, 0.22), (8.93, 0.07, 0.12)):
        out += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / decay)
    out *= np.clip(t / 0.002, 0, 1)
    return out


def _formants(x, vowel):
    table = {"a": ((800, 90), (1150, 110), (2900, 160)), "i": ((330, 70), (2300, 140), (3000, 180))}[vowel]
    out = np.zeros_like(x)
    for (f0, bw), gain in zip(table, (1.0, 0.7, 0.35)):
        b, a = signal.iirpeak(f0, f0 / bw, fs=SR)
        out += gain * signal.lfilter(b, a, x)
    return out


def sung_call(freq_from, freq_to, dur, glide):
    """A kulning-style call: a bright glottal tone through two vowels (a toward i), sliding from one pitch up to the next."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    w = _smooth(np.clip(t / glide, 0, 1))
    f = freq_from + (freq_to - freq_from) * w
    f = f * (1 + 0.006 * np.sin(2 * np.pi * 5.6 * t) * np.clip((t - 0.1) / 0.15, 0, 1))
    ph = _hz_phase(f)
    source = sum(np.sin(k * ph) / k ** 1.1 for k in range(1, 22) if k * freq_to < 12000)
    mix = np.clip(t / dur * 1.4, 0, 1)
    voiced = (1 - mix) * _formants(source, "a") + mix * _formants(source, "i")
    return voiced * _env(n, 0.03, 0.22) * (0.8 + 0.2 * np.exp(-t / 0.2))


def pluck(freq, dur, rng, damp=0.5):
    """Karplus-Strong string with a woody body: a plucked kantele or a hollow xylophone bar."""
    n = int(dur * SR)
    period = int(round(SR / freq))
    burst = rng.standard_normal(period)
    burst = signal.lfilter([0.5, 0.5], [1], burst)
    buf = list(burst)
    out = np.zeros(n)
    k = 0
    keep = 0.9955
    for i in range(n):
        j = k % period
        nxt = (buf[j] + buf[(j + 1) % period]) * 0.5 * keep if i > 0 else buf[j]
        out[i] = buf[j]
        buf[j] = nxt
        k += 1
    body = _bandpass(out, 300, 1700) * 0.5 + out * 0.5
    t = np.arange(n) / SR
    return body * np.exp(-t / (0.55 + damp * 0.3)) * np.clip(t / 0.002, 0, 1)


# ---- the variants: (start second, length, pitch in Hz) for each of the two notes
G5, C6 = 783.99, 1046.50
A5, E6 = 880.00, 1318.51
C5, A5B = 523.25, 880.00

VARIANTS = {
    "a-flute-and-bell": {
        "title": "A. wooden flute, then a small bell a fourth higher",
        "notes": [(0.0, 0.36, G5), (0.27, 1.0, C6)],
    },
    "b-kulning-call": {
        "title": "B. two sung herding calls, the second a fifth up, sliding into place",
        "notes": [(0.0, 0.46, A5), (0.40, 0.95, E6)],
    },
    "c-plucked-wood": {
        "title": "C. two plucked wooden notes, a quick hop up a sixth",
        "notes": [(0.0, 0.9, C5), (0.19, 1.2, A5B)],
    },
}


def render(name):
    rng = np.random.default_rng(414)
    notes = VARIANTS[name]["notes"]
    mix = np.zeros(int(2.9 * SR))
    (s1, d1, f1), (s2, d2, f2) = notes
    if name == "a-flute-and-bell":
        _add(mix, flute(f1, d1, rng), s1)
        _add(mix, bell(f2, d2) * 0.7, s2)
    elif name == "b-kulning-call":
        _add(mix, sung_call(f1 * 0.94, f1, d1, 0.07) * 0.9, s1)
        _add(mix, sung_call(f1, f2, d2, 0.12), s2)
    elif name == "c-plucked-wood":
        _add(mix, pluck(f1, d1, rng), s1)
        _add(mix, pluck(f2, d2, rng) * 0.9, s2)
    else:
        raise KeyError(name)
    mix = mix[:int(2.0 * SR)]
    return _finish(_reverb(mix, rng)[:int(2.3 * SR)])


# ---- the sound theme: Bert chose voice C (plucked wood) for the login sound on 2026-11-19; every other event speaks in it.
# (start second, length, pitch in Hz) per note; `peak` is dBFS (quieter events sit lower so none startles); `damp` shortens the ring.
# MASTER_SHIFT: Bert heard the set at the original pitch, two and four semitones down, and chose two down (2026-11-19).
MASTER_SHIFT = -2


def _m(freq):
    return round(freq * 2 ** (MASTER_SHIFT / 12), 2)


G4, A3, C4 = 392.00, 220.00, 261.63
D6, E6B = 1174.66, 1318.51
THEME = {
    "login": {"title": "login: a quick hop up a sixth (the approved voice C)",
              "notes": [(0.0, 0.9, _m(C5)), (0.19, 1.2, _m(A5B))], "peak": -6.0, "damp": 0.5, "max_s": 2.6, "tail": 1.1},
    "logout": {"title": "logout: the same two notes, hopping back down, softer",
               "notes": [(0.0, 0.8, _m(A5B)), (0.21, 1.0, _m(C5))], "peak": -9.0, "damp": 0.4, "max_s": 2.2, "tail": 0.8},
    "notification": {"title": "notification: one bright pluck with a tiny grace note before it",
                     "notes": [(0.0, 0.3, _m(D6)), (0.09, 0.9, _m(E6B))], "peak": -9.0, "damp": 0.2, "max_s": 1.6, "tail": 0.5},
    "needs-you": {"title": "needs you: three notes climbing, the last held, a question that waits",
                  "notes": [(0.0, 0.5, _m(C5)), (0.14, 0.6, _m(G5)), (0.30, 1.1, _m(D6))], "peak": -7.0, "damp": 0.45, "max_s": 2.4, "tail": 0.8},
    "error": {"title": "error: two low dull notes sagging down, not scolding",
              "notes": [(0.0, 0.6, _m(G4)), (0.17, 0.8, _m(A3))], "peak": -9.0, "damp": -0.3, "max_s": 1.8, "tail": 0.5},
    "volume": {"title": "volume: one tiny tick",
               "notes": [(0.0, 0.25, _m(A5B))], "peak": -13.0, "damp": -0.4, "max_s": 0.8, "tail": 0.4},
}


def render_theme(name, semitones=0):
    spec = THEME[name]
    shift = 2 ** (semitones / 12)
    rng = np.random.default_rng(414)
    mix = np.zeros(int(3.0 * SR))
    for k, (start, dur, freq) in enumerate(spec["notes"]):
        _add(mix, pluck(freq * shift, dur, rng, damp=spec["damp"]) * (0.9 if k else 1.0), start)
    last_end = max(s + d for s, d, _ in spec["notes"])
    tail = spec["tail"]
    mix = mix[:int((last_end + 0.1) * SR)]
    x = _reverb(mix, rng, rt60=0.5 if name == "volume" else 1.1)[:int((last_end + tail) * SR)]
    return _finish(x, 10 ** (spec["peak"] / 20))


def write_wav(dest, x):
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with wave.open(dest if not isinstance(dest, pathlib.Path) else str(dest), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else OUT
    out.mkdir(parents=True, exist_ok=True)
    if "--theme" in argv:
        semis = int(argv[argv.index("--shift") + 1]) if "--shift" in argv else 0
        for name in THEME:
            x = render_theme(name, semitones=semis)
            write_wav(out / f"{name}.wav", x)
            print(f"{name}: {len(x) / SR:.2f} s, peak {20 * np.log10(np.max(np.abs(x))):.1f} dBFS")
        return 0
    for name in VARIANTS:
        x = render(name)
        write_wav(out / f"{name}.wav", x)
        print(f"{name}: {len(x) / SR:.2f} s, peak {20 * np.log10(np.max(np.abs(x))):.1f} dBFS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
