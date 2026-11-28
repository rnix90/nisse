# SPDX-License-Identifier: GPL-2.0-or-later
# /etc/profile.d/nisse-rust.sh (ledger N-513): what `cargo install` puts in ~/.cargo/bin is found, once Rust has been set up.
if [ -d "$HOME/.cargo/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.cargo/bin:"*) ;;
        *) PATH="$PATH:$HOME/.cargo/bin"; export PATH ;;
    esac
fi
