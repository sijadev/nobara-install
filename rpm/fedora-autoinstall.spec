Name:           fedora-autoinstall
Version:        1.0
Release:        1%{?dist}
Summary:        Fedora Workstation Autoinstall — First-Boot Provisioning Scripts
License:        MIT
URL:            https://github.com/sijadev/fedora-autoinstall

# Quellen sind das Repo-Verzeichnis selbst.
# Bauen: rpmbuild -bb --define "_sourcedir ." fedora-autoinstall.spec
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       bash >= 5
Requires:       systemd
Requires:       dnf
Requires:       flatpak

%description
Erstellt und installiert alle First-Boot/First-Login Provisioning-Scripts
für ein frisch installiertes Fedora Workstation System.

Enthält:
  - fedora-first-boot.sh   (root, systemd, einmalig beim ersten Boot)
  - fedora-first-login.sh  (user, GNOME-Autostart, einmalig beim ersten Login)
  - fedora-provision.sh    (root, Profil-Auswahl via Welcome-Dialog)
  - welcome-dialog.sh      (user, GNOME-App)
  - fedora-first-boot.service (systemd unit)
  - fedora-provision.desktop  (GNOME App-Menü Eintrag)

%prep
%autosetup

%install
install -d %{buildroot}/usr/local/share/%{name}/scripts
install -d %{buildroot}/usr/local/share/%{name}/systemd
install -d %{buildroot}/usr/local/sbin
install -d %{buildroot}/usr/local/bin
install -d %{buildroot}/etc/systemd/system
install -d %{buildroot}/usr/share/applications

# Scripts
install -m 0755 scripts/first-boot.sh   %{buildroot}/usr/local/share/%{name}/scripts/
install -m 0755 scripts/first-login.sh  %{buildroot}/usr/local/share/%{name}/scripts/
install -m 0755 scripts/welcome-dialog.sh %{buildroot}/usr/local/share/%{name}/scripts/
install -m 0644 scripts/fedora-provision.desktop %{buildroot}/usr/local/share/%{name}/scripts/

# Provision script
install -m 0755 scripts/fedora-provision.sh     %{buildroot}/usr/local/share/%{name}/

# Systemd units
install -m 0644 systemd/fedora-first-boot.service %{buildroot}/usr/local/share/%{name}/systemd/
install -m 0644 systemd/fedora-first-boot.service %{buildroot}/etc/systemd/system/
install -m 0644 systemd/vllm@.container           %{buildroot}/usr/local/share/%{name}/systemd/
install -m 0644 systemd/vllm-router.service       %{buildroot}/usr/local/share/%{name}/systemd/

# Symlinks: share → standard Pfade
ln -sf /usr/local/share/%{name}/scripts/first-boot.sh   %{buildroot}/usr/local/sbin/fedora-first-boot.sh
ln -sf /usr/local/share/%{name}/scripts/first-login.sh  %{buildroot}/usr/local/bin/fedora-first-login.sh
ln -sf /usr/local/share/%{name}/scripts/welcome-dialog.sh %{buildroot}/usr/local/bin/fedora-welcome-dialog.sh
ln -sf /usr/local/share/%{name}/fedora-provision.sh     %{buildroot}/usr/local/sbin/fedora-provision.sh

# Desktop-Datei
install -m 0644 scripts/fedora-provision.desktop %{buildroot}/usr/share/applications/

%post
systemctl enable fedora-first-boot.service 2>/dev/null || :
update-desktop-database /usr/share/applications 2>/dev/null || :

%preun
if [ $1 -eq 0 ]; then
    systemctl disable fedora-first-boot.service 2>/dev/null || :
    systemctl stop    fedora-first-boot.service 2>/dev/null || :
fi

%files
/usr/local/share/%{name}/
/usr/local/sbin/fedora-first-boot.sh
/usr/local/sbin/fedora-provision.sh
/usr/local/bin/fedora-first-login.sh
/usr/local/bin/fedora-welcome-dialog.sh
/etc/systemd/system/fedora-first-boot.service
/usr/share/applications/fedora-provision.desktop

%changelog
* Sun May 18 2026 Copilot <copilot@github.com> - 1.0-1
- Initial package
