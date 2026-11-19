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

## How it is wired (all done in N-414, nothing left for later but the ear check)

The sounds are a freedesktop sound theme, so KDE finds each one by the name it already asks for. Facts verified in the Fedora 44
packages (Plasma 6.8.3): `plasma-workspace.target` wants `plasma-startupsound.service`, whose program plays `desktop-login` through
libcanberra using the theme in `kdeglobals` `[Sounds] Theme` (default `ocean`); the exit event plays `desktop-logout`; the volume
feedback plays `audio-volume-change`; error events play `dialog-error` and `dialog-error-serious`; libcanberra looks for `.oga`,
`.ogg` and `.wav` files; `libnotificationmanager` has a `playSoundHint` (only the symbol is verified; that Plasma honors the panel's `sound-name` hint is settled by ear at GATE 3).

| Piece | What it does |
|---|---|
| `nisse-sounds` (`packaging/rpm/nisse-sounds`) | installs `/usr/share/sounds/nisse` with the six files and the names in `assets/audio/theme/names.txt`; the theme inherits ocean and freedesktop, so any event nisse does not voice still plays Plasma's own sound |
| `assets/theme/xdg/kdeglobals` (`nisse-lookandfeel` 0.2-5, requires `nisse-sounds`) | `[Sounds] Theme=nisse`, the system default for every new user |
| the panel (`DesktopNotify`) | the approval notice carries the `sound-name` hint `nisse-needs-you` (a unit test reads the message; the approvals e2e test checks it on the bus) |

Which name each sound answers to (`names.txt`; the first name is the real file, the rest are links): login = `desktop-login`;
logout = `desktop-logout`; notification = `message-new-instant`, `message-new-email`; needs-you = `nisse-needs-you`, `dialog-question`,
`message-attention`; error = `dialog-error`, `dialog-error-serious`, `dialog-error-critical`; volume = `audio-volume-change`.

Checks: `tools/art/tests/test_sound_package.py` (manifest, names Plasma asks for, index, default, build and image wiring),
`tests/rpm/test_nisse_sounds.sh` (the built RPM: every name resolves to a real WAV, the files are the approved ones),
`tests/rpm/test_lookandfeel.sh`, `panel/tests/tst_notify.cpp`, and in the image `tests/iso/test_iso_contents.sh` (queued for the next
ISO rebuild: theme, names, the default, and that the startup-sound service is present and not masked).

Not wired because the event does not exist yet: a sound for a finished AI turn (the panel only badges it, N-207).

**Bert's ear check on the real session (login, logout, a needs-you notice, an error, a volume key press) is at GATE 3.**
