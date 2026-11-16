# SPDX-License-Identifier: GPL-2.0-or-later
# N-406a spike (see docs/avatar-wiring-spike.md). Run in the build VM: bash tools/spike/NAME.sh (needs the rpms from the Reproduce section).
set -u
cd ~/spike406
rm -rf r406 rb && mkdir -p r406 rb
sudo rpm --root ~/spike406/r406 --initdb
echo "== 1. install the real plasma-workspace into a throwaway rpm database (--justdb): its file list is recorded, nothing is unpacked"
sudo rpm -ivh --root ~/spike406/r406 --justdb --nodeps --noscripts plasma-workspace-*.rpm 2>&1 | tail -2

mk() {  # name release sourcefile-content destpath
    name=$1; rel=$2; dest=$3; content=$4
    d=rb/$name-$rel; mkdir -p $d
    printf '%s' "$content" > $d/payload
    cat > $d/$name.spec <<EOF
Name: $name
Version: 1
Release: $rel
Summary: spike
License: GPL-2.0-or-later
BuildArch: noarch
%description
spike
%install
install -Dpm 0644 $PWD/$d/payload %{buildroot}$dest
%files
$dest
EOF
    rpmbuild -bb --quiet --define "_topdir $PWD/rb/top" $d/$name.spec >/dev/null 2>&1
}
mk nisse-avatars-conflict 1 "/usr/share/plasma/avatars/Konqi.png" "gnome picture"
echo "== 2. a package that ships a file with the same path but other content, installed over it"
sudo rpm -ivh --root ~/spike406/r406 --nodeps --noscripts rb/top/RPMS/noarch/nisse-avatars-conflict-1-1.noarch.rpm 2>&1 | tail -4
echo "== 2b. the same with --replacefiles (what a build must never rely on)"
sudo rpm -ivh --root ~/spike406/r406 --nodeps --noscripts --replacefiles rb/top/RPMS/noarch/nisse-avatars-conflict-1-1.noarch.rpm 2>&1 | tail -2
