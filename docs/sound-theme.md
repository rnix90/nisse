# The sound theme (N-414)

Bert approved the set on 2026-11-19, by ear. The submission asked for "a playful two-note sound that feels like something you might
hear out in the scandinavian wilderness; a mischievous sound" (`sounds/request-nisse-login-sound`).

## How it was chosen

`tools/art/sounds.py` builds every sound from numpy and scipy, with no samples, so the result is reproducible byte for byte and has
no license baggage (54 tests in `tools/art/tests/test_sounds.py`). Three voices were made for the login sound:

| Voice | What it is |
|---|---|
| A | a breathy wooden flute, then a small bell a fourth higher |
| B | two sung herding calls (kulning), the second a fifth up, sliding into place |
| C | two plucked wooden notes (a kantele or a wooden xylophone), a quick hop up a sixth |

Bert chose **C**. Then the other events were made in the same voice, and Bert asked to hear them lower to decide the master pitch:
the original, two semitones down and four down. He chose **two semitones down** (`MASTER_SHIFT = -2` in the script; every note in the
theme is the original pitch moved down by it).

## The six sounds

All are mono, 16 bit, 48 kHz WAV in `assets/audio/theme/`. The quieter events sit lower than the login sound, so nothing startles.

| File | Shape | Level | Length |
|---|---|---|---|
| `login.wav` | two notes, a quick hop up a sixth | -6 dBFS | 2.5 s |
| `logout.wav` | the same two notes hopping back down, softer | -9 dBFS | 2.0 s |
| `notification.wav` | a grace note and one bright pluck | -9 dBFS | 1.5 s |
| `needs-you.wav` | three notes climbing, the last held: a question that waits | -7 dBFS | 2.2 s |
| `error.wav` | two low dull notes sagging down, not scolding (the lowest event) | -9 dBFS | 1.5 s |
| `volume.wav` | one tiny tick | -13 dBFS | 0.7 s |

The contour carries the meaning: arriving and attention go up, leaving and trouble go down.

## What the tests guard (an ear cannot)

Each file is deterministic, finite, free of DC offset, exactly at its stated level, starts at zero and ends in silence (no click on
login), within its length limit, and holds every note it says it holds (checked in the spectrum; a mutation that played the wrong pitch
for the second note was caught). The contours (up for login, notification and needs-you; down for logout and error) and the error
sound being the lowest are tested too.

## Regenerate

    python tools/art/sounds.py --theme [--shift SEMITONES] [--out DIR]     the theme (default out: assets/audio/login-candidates)
    python tools/art/sounds.py [--out DIR]                                 the three login candidates A, B and C

The committed theme is `--theme --out assets/audio/theme`.

## Handed on

N-506 ships the files and sets the sound theme (login at GATE 3; Bert's ear check on the real session), and N-415 packages
`assets/audio/theme/` with the approved art. The other five events are wired where each exists: logout in the session teardown,
`notification` and `needs-you` in the panel's notice and approval paths (N-205, N-207), `error` for failures and `volume` for the
volume-feedback tick.
