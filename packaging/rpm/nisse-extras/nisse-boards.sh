# SPDX-License-Identifier: GPL-2.0-or-later
# /etc/profile.d/nisse-boards.sh (ledger N-514a): what the board families put in /opt, found by every user. Nothing here does anything for a family
# that was not ticked in setup.
if [ -f /opt/esp-idf/export.sh ]; then
    export IDF_PATH=/opt/esp-idf IDF_TOOLS_PATH=/opt/espressif
    # ESP-IDF's own way in: type get_idf, then idf.py works in that terminal
    get_idf() { . /opt/esp-idf/export.sh; }
fi
if [ -d /opt/pico-sdk ]; then
    export PICO_SDK_PATH=/opt/pico-sdk
fi
