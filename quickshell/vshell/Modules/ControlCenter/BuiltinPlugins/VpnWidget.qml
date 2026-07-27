import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    Ref {
        service: NetworkBackendService
    }

    readonly property bool vpnActivating: NetworkBackendService.vpnIsBusy || NetworkBackendService.activeState === "activating"
    readonly property bool vpnActivated: NetworkBackendService.connected && NetworkBackendService.activeState === "activated"

    ccWidgetIcon: "vpn_key"
    ccWidgetPrimaryText: I18n.tr("VPN")
    ccWidgetSecondaryText: {
        if (vpnActivating)
            return I18n.tr("Connecting…");
        if (!vpnActivated)
            return I18n.tr("Disconnected");
        const names = NetworkBackendService.activeNames || [];
        if (names.length <= 1)
            return names[0] || I18n.tr("Connected");
        return names[0] + " +" + (names.length - 1);
    }
    ccWidgetIsActive: vpnActivated

    onCcWidgetToggled: NetworkBackendService.toggleVpn()

    ccDetailContent: Component {
        VpnDetailContent {
            listHeight: 260
        }
    }
}
