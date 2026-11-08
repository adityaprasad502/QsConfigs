import QtQuick
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    name: Translation.tr("Internet")
    statusText: {
        if (Network.ethernet) return Network.networkName || Translation.tr("Ethernet");
        if (!Network.wifiEnabled || Network.wifiStatus === "disabled") return Translation.tr("Off");
        if (Network.wifiStatus === "connecting") return Translation.tr("Connecting...");
        if (Network.wifiStatus === "connected") return Network.networkName || Translation.tr("Connected");
        return Translation.tr("Disconnected");
    }
    tooltipText: Translation.tr("%1 | Right-click to configure").arg(statusText)
    icon: Network.materialSymbol

    toggled: Network.wifiStatus !== "disabled"
    mainAction: () => Network.toggleWifi()
    hasMenu: true
}
