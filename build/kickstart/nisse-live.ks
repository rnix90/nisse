# SPDX-License-Identifier: GPL-2.0-or-later
# Nisse changes on top of the vendored Fedora KDE live kickstart. build/build-iso.sh appends this
# file to build/kickstart/fedora-live-kde.flat.ks (minus fedora-release-kde) and replaces
# @NISSE_REPO@ with the local repo URL.
repo --name=nisse --baseurl=@NISSE_REPO@ --cost=100

%packages
nisse-release
nisse-release-common
nisse-branding
nisse-fonts-nunito
nisse-hw
nisse-firstboot
nisse-daemon
nisse-panel
-fedora-release-kde
-fedora-release-identity-kde-desktop
-fedora-release-common
-fedora-logos
generic-logos
%end
