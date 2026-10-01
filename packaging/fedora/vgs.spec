# The release package of COPR vanillagreen/vgs. Build its source RPM with
# packaging/fedora/srpm.sh from a checkout at the release tag:
# docs/architecture/distribution-fedora.md. The dependency block is the
# same in vgs-git.spec; scripts/check-packaging.js holds both to the
# requirement data and the preflight floor.

Name:           vgs
Version:        0.1.0
Release:        1%{?dist}
Summary:        Desktop shell for Hyprland on Quickshell
License:        MIT AND OFL-1.1 AND ISC
URL:            https://github.com/vanillagreencom/vgs
Source0:        %{url}/releases/download/v%{version}/vgs-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  python3

# begin runtime dependencies
Requires:       quickshell >= 0.3.1
Requires:       hyprland >= 0.56
Requires:       nodejs >= 1:18
Requires:       python3
Requires:       git
Requires:       util-linux-core
Requires:       util-linux
Requires:       pipewire-utils
Recommends:     xdg-terminal-exec
Recommends:     gum
Recommends:     fzf
Recommends:     bluez
Recommends:     less
Recommends:     libnotify
Recommends:     cronie
Recommends:     xdg-utils
Recommends:     curl
Recommends:     libsecret
Recommends:     bubblewrap
Recommends:     uv
Recommends:     glib2
Recommends:     systemd
Recommends:     iproute
Recommends:     ImageMagick
Conflicts:      vgs-shell
# end runtime dependencies

%description
VGS is a desktop shell for Hyprland, built on Quickshell. A small fixed core
starts the shell, talks to Hyprland, hosts surfaces and loads plugins; the
bar, its widgets, every panel and every background service are plugins.

%prep
%autosetup -n vgs-%{version}

%build

%install
DESTDIR=%{buildroot} PREFIX=%{_prefix} packaging/install-system.sh

%check
scripts/check-install-tree.sh %{buildroot} %{_prefix}

%files
%license %{_datadir}/licenses/vgs/LICENSE
%doc %{_datadir}/doc/vgs/README.md
%dir %{_datadir}/licenses/vgs
%dir %{_datadir}/doc/vgs
%{_bindir}/vgsh
%{_datadir}/vgs/

%changelog
* Mon Sep 28 2026 Brad <brad@vanillagreen.com> - 0.1.0-1
- First release of VGS v2 as vgs
