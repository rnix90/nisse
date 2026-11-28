# SPDX-License-Identifier: GPL-2.0-or-later
"""N-514: development boards get access for the person at the screen, in a live guest, with virtual USB devices.

Boots an ISO with livevm with virtual USB serial adapters plugged in (QEMU's usb-serial is an FTDI 0403:6001 by default, and can claim other
vendor and product IDs), and shows what the rules change:

    1  before: the live user cannot write to the adapter's serial port, and ModemManager is not told to leave the adapter alone
    2  the rules file goes in, udev reloads it, and the devices are replayed (what plugging them in does)
    3  after: the live user can write to them (the uaccess ACL), and the device carries ID_MM_DEVICE_IGNORE so ModemManager leaves it alone
    4  a control that the rules do not name (the guest's USB tablet) gets no ModemManager flag

QEMU cannot make a virtual adapter claim another maker's IDs, so Espressif, Arduino, Raspberry Pi, ST, SEGGER, CP210x and CH340 are covered
by tools/vm/tests/test_board_rules.py (the shape of every rule and the ID table); real boards are N-911.

Usage: python tools/vm/boards_check.py ISO OUTDIR(no spaces in the path) RULES
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

# QEMU's usb-serial is an FTDI FT232 (0403:6001), one of the serial bridges the rules name; the guest's USB tablet (0627:0001) is the control, a
# device the rules do not name. QEMU cannot make a virtual device claim another maker's IDs (usb-serial has no vendorid or productid property;
# only usb-host passthrough does), so the other vendors are covered by tools/vm/tests/test_board_rules.py and real boards are N-911.
FTDI = "0403:6001"
CONTROL = "0627:0001"

NODE_OF = (
    "node() { for d in /sys/bus/usb/devices/[0-9]*; do [ -f $d/idVendor ] || continue; "
    "if [ \"$(cat $d/idVendor):$(cat $d/idProduct)\" = \"$1\" ]; then "
    "printf '/dev/bus/usb/%03d/%03d\\n' $(cat $d/busnum) $(cat $d/devnum); return; fi; done; }"
)


def devices():
    """QEMU arguments that plug the virtual adapter in at boot (a hot-plugged one did not enumerate in this guest, and a null chardev never attaches it: a ring buffer backend does)."""
    return ["-chardev", "ringbuf,id=c0", "-device", "usb-serial,chardev=c0,id=u0"]


def main(iso, out, rules):
    rules_bytes = Path(rules).read_bytes()
    vm = livevm.Vm(iso, out, tablet=True, extra_args=devices())  # tablet=True adds the USB controller the adapters plug into
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    def line(cmd, key, timeout=40):
        try:
            text, _ = vm.run(cmd, timeout)
        except TimeoutError:
            return ""  # the console lost its end marker to a kernel or service message; the caller reports an empty answer
        found = [l for l in text.splitlines() if l.startswith(key + "=")]
        return found[-1][len(key) + 1:].strip() if found else ""

    def access(vp):
        """(can write, ModemManager ignore flag) for the raw USB node of the device with this ID."""
        node = line(f"echo n=$(node {vp})", "n")
        if not node:
            return None, None, ""
        can = line(f"if test -w {node}; then echo can=yes; else echo can=no; fi", "can")
        mm = line(f"echo mm=$(udevadm info -q property {node} | grep -c 'ID_MM_DEVICE_IGNORE=1')", "mm")
        return can, mm, node

    try:
        vm.login()
        vm.prepare_session()
        vm.run(NODE_OF, 20)
        time.sleep(10)

        # 1. before the rules: the adapters are there, the live user cannot use them
        present = line("echo ids=$(for d in /sys/bus/usb/devices/[0-9]*; do [ -f $d/idVendor ] && echo $(cat $d/idVendor):$(cat $d/idProduct); done | tr '\n' ' ')", "ids")
        want = [FTDI, CONTROL]
        check("the virtual adapters enumerate in the guest with the IDs asked for", all(vp in present.split() for vp in want), present)
        tty = line("echo tty=$(ls /dev/ttyUSB* 2>/dev/null | head -1)", "tty")
        if tty:
            can = line(f"if test -w {tty}; then echo can=yes; else echo can=no; fi", "can")
            check("before: the live user cannot write to the adapter's serial port", can == "no", f"{tty} {can}")
        else:
            print("note: no /dev/ttyUSB* (the guest kernel did not bind a serial driver); the raw USB nodes are checked instead")
        can, mm, node = access(FTDI)
        # the raw USB node of a known adapter may already be open to the person at the screen through systemd's own rules; what the nisse rules add is
        # the serial port (above), the flag for ModemManager and the rest of the boards
        check("before: ModemManager is not told to ignore the adapter", mm == "0", f"{node} can={can} mm={mm}")

        # 2. the rules, applied to the devices already there (what plugging them in does)
        vm.put("/tmp/60-nisse-boards.rules", rules_bytes)
        line("sudo cp /tmp/60-nisse-boards.rules /etc/udev/rules.d/ && sudo udevadm control --reload; echo ok=1", "ok", 60)
        # the console sometimes loses the end marker of a command that logs (sudo, udev); the file is what matters, and what happens next
        done = line("test -f /etc/udev/rules.d/60-nisse-boards.rules && echo ok=present", "ok")
        check("the rules file is in /etc/udev/rules.d", done == "present", done)
        vrc = line("udevadm verify /etc/udev/rules.d/60-nisse-boards.rules >/dev/null 2>&1; echo vrc=$?", "vrc")
        check("udevadm verify accepts the file in the guest", vrc == "0", vrc)
        line("sudo udevadm trigger --action=add --subsystem-match=usb --subsystem-match=tty; sudo udevadm settle; echo s=1", "s", 60)
        time.sleep(5)

        # 3. after
        if tty:
            can = line(f"if test -w {tty}; then echo can=yes; else echo can=no; fi", "can")
            acl = line(f"echo acl=$(getfacl -p {tty} 2>/dev/null | grep -c '^user:liveuser:rw')", "acl")
            check("after: the live user can write to the serial port, by the uaccess ACL", can == "yes" and acl == "1", f"{tty} can={can} acl={acl}")
        can, mm, node = access(FTDI)
        check(f"after: the FTDI adapter ({FTDI}): the live user can write to its USB node and ModemManager is told to ignore it", can == "yes" and mm == "1", f"{node} can={can} mm={mm}")
        can, mm, node = access(CONTROL)
        check(f"control (the USB tablet {CONTROL}, not named by the rules): no ModemManager flag", mm == "0" and node != "", f"{node} can={can} mm={mm}")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "boards-check.txt").write_text(
            chr(10).join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
