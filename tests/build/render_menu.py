# SPDX-License-Identifier: GPL-2.0-or-later
"""Fills in the nisse live ISO's GRUB menu template the way kiwi does and prints the result, for tests/build/test_kiwi_description.sh to run
through grub2-script-check.

grub2-script-check cannot parse a function defined inside an if (real GRUB can, and boots this template: the N-502 photos), so the platform
block that defines load_video is swapped for one plain definition; everything else is checked as it is.

    python tests/build/render_menu.py TEMPLATE
"""
import string
import sys

template = string.Template(open(sys.argv[1], encoding="ascii").read())
out = template.substitute(search_params="--file --set=root /boot/0x12345678", terminal_output="console", boot_timeout="10",
                          boot_timeout_style="menu", bootpath="/boot/x86_64/loader", kernel_file="linux", initrd_file="initrd",
                          boot_options="quiet root=live:CDLABEL=nisse-0.2 rd.live.image")
start = out.index('if [ "$grub_platform"')
end = out.index("\nfi\n", start) + 4
print(out[:start] + 'function load_video {\n\tinsmod all_video\n}\nset basicgfx="nomodeset"\n' + out[end:])
