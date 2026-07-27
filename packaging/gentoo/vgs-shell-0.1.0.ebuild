EAPI=8

inherit go-module systemd

DESCRIPTION="VanillaGreen desktop shell for Hyprland and Niri"
HOMEPAGE="https://github.com/vanillagreencom/vgs"
SRC_URI="https://github.com/vanillagreencom/vgs/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/vgs-${PV}"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~arm64"
RDEPEND="app-misc/jq dev-lang/python gui-apps/quickshell"
BDEPEND="dev-lang/go"

src_compile() {
	cd backend || die
	go build -mod=vendor -buildvcs=false -trimpath -ldflags="-s -w -X vshell/backend/internal/registry.cliVersion=${PV}" -o "${T}/vshell-backend" ./cmd/vshell-backend || die
}

src_install() {
	DESTDIR="${D}" PREFIX=/usr VGS_BACKEND_BINARY="${T}/vshell-backend" packaging/install-system.sh || die
}