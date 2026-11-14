# SPDX-License-Identifier: GPL-2.0-or-later
# Live-session driver (from the N-105 look spike, made a tool by N-113). Boots the Nisse ISO under QEMU on the Windows
# host with the serial console on a TCP port, logs in as liveuser (empty password), runs shell commands in the guest and
# takes screenshots through the QEMU monitor. The screenshot regression harness (regress.py) is built on it.
# Gotchas found with it: the live session locks itself after about 5 minutes idle (prepare_session turns Autolock off),
# loginctl unlock-sessions asks polkit and swallows the next typed characters, and sudo needs a password in the live
# session (extract RPMs into the home folder instead).
"""Live-session driver: boot the Nisse ISO, log in over serial, run commands, take screenshots."""
import base64
import random
import re
import socket
import subprocess
import threading
import time
from pathlib import Path

# What a graphical command needs when it is started from the serial console instead of from the Plasma session.
SESSION_ENV = """
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export WAYLAND_DISPLAY=wayland-0
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=KDE
export KDE_FULL_SESSION=true
export XDG_DATA_DIRS=$HOME/.local/share:/usr/local/share:/usr/share
"""
# No lock screen, no dimming, no screen off while the harness takes its time.
QUIET_SESSION = (
    "kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false; "
    "kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false; "
    "kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false; "
    "kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false; true"
)

QEMU_DIR = Path("C:/Program Files/qemu")
ESC = chr(27)
OSC = re.compile(ESC + r"\][^" + ESC + r"]*" + ESC + r"\\")
CSI = re.compile(ESC + r"\[[0-9;?]*[A-Za-z]")


def clean(t):
    return CSI.sub("", OSC.sub("", t)).replace(chr(13), "")


class Vm:
    def __init__(self, iso, out, mem=6144):
        self.out = Path(out)
        self.out.mkdir(parents=True, exist_ok=True)
        self.buf = ""
        self.lock = threading.Lock()
        self.serial_port = random.randint(20000, 30000)
        self.mon_port = self.serial_port + 1
        vars_file = self.out / "OVMF_VARS.fd"
        vars_file.write_bytes((QEMU_DIR / "share" / "edk2-i386-vars.fd").read_bytes())
        cmd = [
            str(QEMU_DIR / "qemu-system-x86_64.exe"), "-machine", "q35", "-accel", "whpx,kernel-irqchip=off", "-cpu", "max",
            "-smp", "4", "-m", str(mem),
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={(QEMU_DIR / 'share' / 'edk2-x86_64-code.fd').as_posix()}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_file.as_posix()}",
            "-cdrom", str(iso), "-boot", "d",
            "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
            "-monitor", f"tcp:127.0.0.1:{self.mon_port},server,nowait",
            "-serial", f"tcp:127.0.0.1:{self.serial_port},server,nowait",
            "-display", "none",
        ]
        self.proc = subprocess.Popen(cmd, creationflags=0x08000000)
        self.sock = self._connect(self.serial_port)
        threading.Thread(target=self._reader, daemon=True).start()

    def _connect(self, port):
        for _ in range(100):
            try:
                return socket.create_connection(("127.0.0.1", port), timeout=5)
            except OSError:
                time.sleep(0.3)
        raise RuntimeError(f"cannot connect to {port}")

    def _reader(self):
        self.sock.settimeout(None)
        while True:
            try:
                data = self.sock.recv(4096)
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.buf += data.decode("utf-8", "replace")

    def monitor(self, line):
        s = self._connect(self.mon_port)
        s.sendall((line + "\n").encode())
        time.sleep(0.5)
        s.close()

    def keys_to_grub(self):
        """Fedora's menu defaults to the slow media check: press Up until Start Nisse, then Enter."""
        self.expect("BdsDxe: starting", 90)
        s = self._connect(self.mon_port)
        for _ in range(15):
            s.sendall(b"sendkey up\n")
            time.sleep(1)
        s.sendall(b"sendkey ret\n")
        time.sleep(1)
        s.close()

    def expect(self, text, timeout=300):
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                i = self.buf.find(text)
                if i >= 0:
                    seen = self.buf[: i + len(text)]
                    self.buf = self.buf[i + len(text):]
                    return seen
            time.sleep(0.3)
        raise TimeoutError(f"{text!r} not seen in {timeout}s; tail: {self.buf[-300:]!r}")

    def send(self, text):
        self.sock.sendall(text.encode())

    def run(self, cmd, timeout=120):
        """Run a shell command on the serial console; return (output, exit code)."""
        tag = f"__D{random.randint(100000, 999999)}__"
        pat = re.compile(tag + r"(\d+)" + "__")
        with self.lock:
            self.buf = ""
        self.send(f"{cmd}\necho {tag}$?__\n")
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                text = clean(self.buf)
            m = pat.search(text)
            if m:
                return text[: m.start()], int(m.group(1))
            time.sleep(0.3)
        raise TimeoutError(f"command timed out: {cmd[:80]!r}; tail: {clean(self.buf)[-300:]!r}")

    def put(self, remote_path, data):
        b64 = base64.b64encode(data).decode()
        self.run(": > /tmp/_put.b64")
        for i in range(0, len(b64), 600):
            self.run(f"printf %s '{b64[i:i+600]}' >> /tmp/_put.b64")
        self.run(f"mkdir -p \"$(dirname {remote_path})\" && base64 -d /tmp/_put.b64 > {remote_path}")

    def shot(self, name):
        path = (self.out / name).resolve()
        self.monitor(f"screendump {path.as_posix()} -f png")
        time.sleep(2)
        return path

    def sh(self, cmd, timeout=90):
        """Run a command with the Plasma session environment (see SESSION_ENV); needs prepare_session first."""
        return self.run(". /tmp/env.sh; " + cmd, timeout)

    def bg(self, cmd):
        """Start a graphical program detached, with the session environment."""
        self.run(f". /tmp/env.sh; nohup {cmd} >/dev/null 2>&1 &", 20)

    def login(self, boot_timeout=420):
        """Pick the live entry in GRUB, wait for the serial login prompt, log in as liveuser."""
        self.keys_to_grub()
        self.expect("login:", boot_timeout)
        self.send("liveuser\n")
        time.sleep(4)
        self.run("export HOME=/home/liveuser; unset XDG_CONFIG_DIRS; cd ~", 30)

    def prepare_session(self, desktop_timeout=240):
        """Wait for the Plasma desktop, then write the environment file and switch off lock, dim and screen off."""
        self.put("/tmp/env.sh", SESSION_ENV.encode())
        end = time.time() + desktop_timeout
        while time.time() < end:
            _, code = self.run("pgrep -x plasmashell >/dev/null", 20)
            if code == 0:
                break
            time.sleep(3)
        else:
            raise TimeoutError("plasmashell did not start")
        time.sleep(15)  # the panel and the wallpaper finish loading after the shell process exists
        self.sh(QUIET_SESSION, 30)

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass
        subprocess.run(["taskkill", "/F", "/PID", str(self.proc.pid)], capture_output=True)
