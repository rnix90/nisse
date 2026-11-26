#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# dracut module: the nisse boot screen's words are set in Nunito (ledger N-501a).
# Plymouth's text plugin has no font search: it reads one fixed file, /usr/share/fonts/Plymouth.ttf, which plymouth-populate-initrd
# (dracut's 45plymouth module) makes a link to the system's default font. This module runs after it (46) and puts the theme's
# static Regular Nunito there instead. inst_simple never replaces a file that already exists, so the link is removed first.

# called by dracut
check() {
    [[ -f "${dracutsysrootdir-}/usr/share/plymouth/themes/nisse/Nunito-Regular.ttf" ]] || return 1
    return 0
}

# called by dracut
depends() {
    echo plymouth
    return 0
}

# called by dracut
install() {
    rm -f "${initdir}/usr/share/fonts/Plymouth.ttf"
    inst_simple /usr/share/plymouth/themes/nisse/Nunito-Regular.ttf /usr/share/fonts/Plymouth.ttf
}
