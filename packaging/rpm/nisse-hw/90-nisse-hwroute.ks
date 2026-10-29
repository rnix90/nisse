# SPDX-License-Identifier: GPL-2.0-or-later
# Read by the Anaconda installer (/usr/share/anaconda/post-scripts/*ks) when installing from the Nisse live image.
# Installs the kernel and drivers this machine needs. A failure (for example no network yet) must not stop the
# installation: the nisse-hwroute service retries on first boot.
%post
/usr/bin/nisse-hwroute >> /var/log/nisse-hwroute-install.log 2>&1 || echo "nisse-hwroute: will retry on first boot" >> /var/log/nisse-hwroute-install.log
%end
