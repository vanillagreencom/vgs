%global debug_package %{nil}

Name:           vgs-shell
Version:        0.1.0
Release:        1%{?dist}
Summary:        VanillaGreen desktop shell for Hyprland and Niri
AutoReqProv:     no
License:        MIT
URL:            https://github.com/vanillagreencom/vgs
Source0:        %{url}/releases/download/v%{version}/vgs-%{version}-source.tar.gz
BuildRequires:  golang
Requires:       quickshell
Requires:       jq
Requires:       python3
Requires:       bash
Requires:       coreutils
Requires:       systemd

%description
VGS is a Quickshell desktop shell for Hyprland and Niri.

%prep
%autosetup -n vgs-%{version}
sed -i 's|^#!/bin/env bash$|#!/usr/bin/env bash|' \
  config/vshell/nvim/colorschemes/tokyonight.nvim/scripts/{build,docs}

%build
cd backend
go build -mod=vendor -buildvcs=false -trimpath -ldflags='-s -w -X vshell/backend/internal/registry.cliVersion=%{version}' -o ../vshell-backend ./cmd/vshell-backend

%install
DESTDIR=%{buildroot} VGS_BACKEND_BINARY="$PWD/vshell-backend" packaging/install-system.sh

%files
%license LICENSE
%doc README.md
%{_bindir}/vshell
/usr/lib/vshell/
/usr/lib/systemd/user/vshell.service

%changelog
* Sun Jul 26 2026 Brad <brad@vanillagreen> - 0.1.0-1
- Initial package