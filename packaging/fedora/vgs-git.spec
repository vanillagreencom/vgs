# The development package of COPR vanillagreen/vgs, built from main.
# packaging/fedora/srpm.sh writes the source RPM: it prepends the two
# definitions this file reads, vgs_version (0.1.0^<count>.git<hash>, the
# RPM form of `vgsh --version` in the checkout) and vgs_commit (the full
# commit), packs that commit as Source0, and appends the one %changelog
# entry. The dependency block is the same in vgs.spec;
# scripts/check-packaging.js holds both to the requirement data and the
# preflight floor.

%{!?vgs_version:%{error:vgs-git builds through packaging/fedora/srpm.sh, which defines vgs_version}}
%{!?vgs_commit:%{error:vgs-git builds through packaging/fedora/srpm.sh, which defines vgs_commit}}

Name:           vgs-git
Version:        %{vgs_version}
Release:        1%{?dist}
Summary:        Desktop shell for Hyprland on Quickshell, development version
License:        MIT AND OFL-1.1 AND ISC
URL:            https://github.com/vanillagreencom/vgs
Source0:        %{url}/archive/%{vgs_commit}/vgs-%{vgs_commit}.tar.gz
BuildArch:      noarch

BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  python3

Provides:       vgs = %{version}
Conflicts:      vgs

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
Recommends:     wl-clipboard
Recommends:     playerctl
Recommends:     wireplumber
Recommends:     cronie
Recommends:     xdg-utils
Recommends:     curl
Recommends:     libsecret
Recommends:     bubblewrap
Recommends:     uv
Recommends:     glib2
Recommends:     systemd
Recommends:     iproute
Recommends:     tmux
Recommends:     ImageMagick
Conflicts:      vgs-shell
# end runtime dependencies

%description
VGS is a desktop shell for Hyprland, built on Quickshell. A small fixed core
starts the shell, talks to Hyprland, hosts surfaces and loads plugins; the
bar, its widgets, every panel and every background service are plugins.

This package follows the main branch. It provides and conflicts with vgs.

%prep
%autosetup -n vgs-%{vgs_commit}

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
