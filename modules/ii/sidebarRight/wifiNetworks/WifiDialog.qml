import qs
import qs.services
import qs.services.network
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell

WindowDialog {
    id: root
    backgroundHeight: 600

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        WindowDialogTitle {
            text: Translation.tr("Connect to Wi-Fi")
            Layout.fillWidth: true
        }

        RippleButton {
            id: refreshButton
            implicitWidth: 32
            implicitHeight: 32
            buttonRadius: 16
            colBackground: "transparent"
            colBackgroundHover: Appearance.colors.colLayer1Hover
            colRipple: Appearance.colors.colLayer1Active
            enabled: !Network.wifiScanning
            onClicked: Network.rescanWifi()

            StyledToolTip {
                text: Translation.tr("Rescan Wi-Fi networks")
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: "refresh"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnSurface
            }
        }
    }

    WindowDialogSeparator {
        visible: !Network.wifiScanning
    }

    StyledIndeterminateProgressBar {
        visible: Network.wifiScanning
        Layout.fillWidth: true
        Layout.topMargin: -8
        Layout.bottomMargin: -8
        Layout.leftMargin: -Appearance.rounding.large
        Layout.rightMargin: -Appearance.rounding.large
    }

    ColumnLayout {
        visible: Network.friendlyWifiNetworks.length === 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.margins: 20
        spacing: 8

        Item { Layout.fillHeight: true }

        MaterialSymbol {
            Layout.alignment: Qt.AlignHCenter
            text: Network.wifiScanning ? "wifi_find" : "wifi_off"
            iconSize: 40
            color: Appearance.colors.colSubtext
        }

        StyledText {
            Layout.alignment: Qt.AlignHCenter
            text: Network.wifiScanning ? Translation.tr("Scanning for networks...") : Translation.tr("No networks found")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
        }

        Item { Layout.fillHeight: true }
    }

    StyledListView {
        visible: Network.friendlyWifiNetworks.length > 0
        Layout.fillHeight: true
        Layout.fillWidth: true
        Layout.topMargin: -15
        Layout.bottomMargin: -16
        Layout.leftMargin: -Appearance.rounding.large
        Layout.rightMargin: -Appearance.rounding.large

        clip: true
        spacing: 0
        animateAppearance: false

        model: ScriptModel {
            values: Network.friendlyWifiNetworks
        }
        delegate: WifiNetworkItem {
            required property WifiAccessPoint modelData
            wifiNetwork: modelData
            width: ListView.view.width
        }
    }

    WindowDialogSeparator {}

    WindowDialogButtonRow {
        DialogButton {
            buttonText: Translation.tr("Details")
            onClicked: {
                Quickshell.execDetached(["bash", "-c", `${Network.ethernet ? Config.options.apps.networkEthernet : Config.options.apps.network}`]);
                GlobalStates.sidebarRightOpen = false;
            }
        }

        Item {
            Layout.fillWidth: true
        }

        DialogButton {
            buttonText: Translation.tr("Done")
            onClicked: root.dismiss()
        }
    }
}
