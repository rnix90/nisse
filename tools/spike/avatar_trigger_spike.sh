# SPDX-License-Identifier: GPL-2.0-or-later
# N-406a spike (see docs/avatar-wiring-spike.md). Run in the build VM: bash tools/spike/NAME.sh (needs the rpms from the Reproduce section).
set -u
cd ~/spike406
rm -rf rb2 && mkdir -p rb2
T=$PWD/rb2/top
AV=/usr/share/plasma/avatars
IC=/usr/share/icons/hicolor/scalable/apps

fake() {  # release
cat > rb2/fake-$1.spec <<EOF
Name: fake-workspace
Version: 1
Release: $1
Summary: stands in for plasma-workspace and plasma-welcome-fedora
License: GPL-2.0-or-later
BuildArch: noarch
%description
spike
%install
mkdir -p %{buildroot}$AV %{buildroot}$IC
printf 'konqi original' > "%{buildroot}$AV/Konqi.png"
printf 'katie original' > "%{buildroot}$AV/Katie.png"
printf 'photo stays' > "%{buildroot}$AV/Cat.png"
printf 'fedora sticker' > %{buildroot}$IC/fedora-loves-kde.svg
%files
"$AV/Konqi.png"
"$AV/Katie.png"
"$AV/Cat.png"
$IC/fedora-loves-kde.svg
EOF
rpmbuild -bb --quiet --define "_topdir $T" rb2/fake-$1.spec >/dev/null 2>&1
}

cat > rb2/nisse.spec <<'EOF'
Name: nisse-avatars-spike
Version: 1
Release: 1
Summary: spike of the replacement mechanism
License: GPL-2.0-or-later
BuildArch: noarch
%description
spike
%install
mkdir -p %{buildroot}/usr/share/plasma/avatars %{buildroot}/usr/share/nisse/art
printf 'gnome artist' > "%{buildroot}/usr/share/plasma/avatars/Artist gnome.png"
printf 'nisse sticker' > %{buildroot}/usr/share/nisse/art/fedora-loves-kde.svg
%files
"/usr/share/plasma/avatars/Artist gnome.png"
/usr/share/nisse/art/fedora-loves-kde.svg
%transfiletriggerin -- /usr/share/plasma/avatars /usr/share/icons/hicolor/scalable/apps
while IFS= read -r f; do
    case "$f" in
    */Konqi.png|*" Konqi.png"|*/Katie.png) rm -f -- "$f" ;;
    */fedora-loves-kde.svg) install -pm 0644 /usr/share/nisse/art/fedora-loves-kde.svg "$f" ;;
    esac
done
EOF
rpmbuild -bb --quiet --define "_topdir $T" rb2/nisse.spec >/dev/null 2>&1
fake 1; fake 2
ls $T/RPMS/noarch/

show() { echo "   avatars: $(ls $AV | tr '\n' ',')"; echo "   sticker: $(cat $IC/fedora-loves-kde.svg 2>/dev/null)"; }
clean() { sudo rpm -e fake-workspace nisse-avatars-spike 2>/dev/null; sudo rm -rf $AV; sudo rm -f $IC/fedora-loves-kde.svg; }
clean
echo "== A. the original package is there first, then nisse's package arrives"
sudo rpm -ivh $T/RPMS/noarch/fake-workspace-1-1.noarch.rpm >/dev/null 2>&1; show
sudo rpm -ivh $T/RPMS/noarch/nisse-avatars-spike-1-1.noarch.rpm 2>&1 | tail -1; show
echo "== C. the original package is updated (its files come back, the trigger fires again)"
sudo rpm -Uvh $T/RPMS/noarch/fake-workspace-1-2.noarch.rpm 2>&1 | tail -1; show
echo "== D. rpm -V of the original package after the trigger"
sudo rpm -V fake-workspace 2>&1 | head -5
clean
echo "== B. nisse's package is there first, then the original package arrives (the order inside an image build is not fixed)"
sudo rpm -ivh $T/RPMS/noarch/nisse-avatars-spike-1-1.noarch.rpm >/dev/null 2>&1
sudo rpm -ivh $T/RPMS/noarch/fake-workspace-1-1.noarch.rpm 2>&1 | tail -1; show
echo "== E. both in ONE transaction (what dnf does when it builds an image)"
clean
sudo rpm -ivh $T/RPMS/noarch/fake-workspace-1-1.noarch.rpm $T/RPMS/noarch/nisse-avatars-spike-1-1.noarch.rpm 2>&1 | tail -2; show
clean
echo cleaned
