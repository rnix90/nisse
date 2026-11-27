# SPDX-License-Identifier: GPL-2.0-or-later
"""N-505: nisse's Plasma splash, photographed in a live Plasma session with the real ksplashqml.

Boots an ISO with livevm, puts the built nisse-lookandfeel package in (over the guest's network, the host is 10.0.2.2 to it), then:

    1  the system default names the splash: a clean home reads ksplashrc as org.nisse.desktop
    2  `ksplashqml org.nisse.desktop --test` is photographed in a burst (every 0.12 s): its test run is about a second long and the splash fades
       in over most of it, so the real timing only shows the first moments: the Ink window appears at once, covering the screen
    3  the same splash, with only its timing changed (a copy of the installed one under ~/.local, the fade made 40 ms and the stage 5 fade
       removed, so the picture is whole for a few frames), is photographed in a burst in the dark look and again in the light look (the light
       color scheme is applied first: the one splash file takes its colors from the scheme); the frames that pass tools/vm/splash_check.py
       are counted and the comet ring must have turned between two of them

The package is the one just built (`tools/rpm/build-rpm.sh nisse-lookandfeel` in the build VM, pulled to out/lock-e2e/).

Usage: python tools/vm/splash_vm_check.py ISO OUTDIR(no spaces in the path) RPM
"""
import functools
import http.server
import socketserver
import sys
import threading
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402
import splash_check  # noqa: E402

PORT = 8768
XAUTH = "XAUTHORITY=$(ls /run/user/1000/xauth_* | head -1)"
TEST_THEME = "org.nisse.splashtest"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def burst(vm, out, prefix, theme, count=44):
    """Start ksplashqml in test mode and take `count` screendumps 0.12 s apart; return their paths."""
    sock = vm._connect(vm.mon_port)
    vm.sh(f"( env {XAUTH} ksplashqml {theme} --test --window --nofork > /tmp/ks.log 2>&1 ) > /dev/null 2>&1 &", 20)
    paths = []
    for k in range(count):
        path = Path(out) / f"{prefix}-{k:02d}.png"
        sock.sendall(("screendump " + path.as_posix() + " -f png\n").encode())
        paths.append(path)
        time.sleep(0.12)
    time.sleep(3)
    sock.close()
    return paths


def ring_angle(path, look):
    """Where the comet's head is, as an angle round the middle (the ring's pixels' mean direction is not enough: it is the tail's mass)."""
    img = splash_check.Image.open(path).convert("RGB")
    a = np.asarray(img).astype(int)
    h, w = a.shape[:2]
    ring = splash_check._close(a, splash_check.LOOKS[look]["ring"], 26)
    ys, xs = np.nonzero(ring)
    if len(xs) < 200:
        return None
    return float(np.degrees(np.arctan2(ys.mean() - h / 2, xs.mean() - w / 2)))


def main(iso, out, rpm):
    rpm = Path(rpm).resolve()
    server = serve(rpm.parent)
    vm = livevm.Vm(iso, out)
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        time.sleep(60)

        text, _ = vm.run(f"curl -sf -o /tmp/laf.rpm http://10.0.2.2:{PORT}/{rpm.name} && echo fetched $(wc -c < /tmp/laf.rpm)", 120)
        check("the package reaches the guest", "fetched" in text, text.strip()[-40:])
        text, _ = vm.run("sudo rpm -Uvh --force --nodeps /tmp/laf.rpm 2>&1 | tail -3; rpm -q nisse-lookandfeel", 120)
        check("the package installs in the live session", rpm.stem.replace(".noarch", "") in text, text.strip()[-80:])
        text, _ = vm.run("env -i HOME=/tmp/nohome XDG_CONFIG_HOME=/tmp/nohome/.config "
                         "XDG_CONFIG_DIRS=/etc/xdg:/usr/share/kde-settings/kde-profile/default/xdg "
                         "kreadconfig6 --file ksplashrc --group KSplash --key Theme", 30)
        check("a new user's system default is nisse's splash", "org.nisse.desktop" in text.split("\n", 1)[-1], text.strip()[-60:])

        # the real run: the Ink window comes up and covers the screen
        frames = burst(vm, out, "30-real", "org.nisse.desktop")
        covered = 0
        for p in frames:
            a = np.asarray(splash_check.Image.open(p).convert("RGB")).astype(int)
            covered += int((np.abs(a - np.array(splash_check.INK)).max(axis=2) <= 6).mean() > 0.99)
        check("the real ksplashqml shows nisse's splash (the Ink window covers the screen)", covered >= 2, f"{covered} of {len(frames)} frames")

        # the splash with only its timing changed: whole for a few frames
        vm.sh(f"D=$HOME/.local/share/plasma/look-and-feel/{TEST_THEME}; rm -rf $D; mkdir -p $D; cp -r /usr/share/plasma/look-and-feel/org.nisse.desktop/. $D/; "
              f"sed -i 's/duration: Kirigami.Units.veryLongDuration \\* 2/duration: 40/; s/stage == 5/stage == 99/' $D/contents/splash/Splash.qml; "
              f"sed -i 's/\"org.nisse.desktop\"/\"{TEST_THEME}\"/' $D/metadata.json; grep -c 'duration: 40' $D/contents/splash/Splash.qml", 40)
        for look, scheme in (("dark", "NisseEmber"), ("light", "NisseEmberLight")):
            vm.sh(f"plasma-apply-colorscheme {scheme} 2>&1 | tail -1", 60)
            time.sleep(6)
            frames = burst(vm, out, f"31-{look}", TEST_THEME)
            good = [p for p in frames if splash_check.check_splash(splash_check.Image.open(p), look).ok]
            check(f"the {look} splash is whole in some frames: the n and the comet ring, nothing else", len(good) >= 2, f"{len(good)} of {len(frames)} frames")
            if good:
                best = Path(out) / f"32-splash-{look}.png"
                best.write_bytes(good[len(good) // 2].read_bytes())
            angles = [x for x in (ring_angle(p, look) for p in good) if x is not None]
            check(f"the {look} comet turns between frames", len(angles) >= 2 and max(angles) - min(angles) > 8, f"{[round(x) for x in angles[:8]]}")
            vm.sh("pkill -x ksplashqml; true", 20)
            time.sleep(3)
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "splash-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
