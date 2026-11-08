import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

WindowDialog {
    id: root
    backgroundHeight: 600

    Timer {
        id: discoveryTimeoutTimer
        interval: 10000
        repeat: false
        running: Bluetooth.defaultAdapter?.discovering ?? false
        onTriggered: {
            if (Bluetooth.defaultAdapter) {
                Bluetooth.defaultAdapter.discovering = false;
            }
        }
    }

    Connections {
        target: Bluetooth.defaultAdapter ?? null
        function onDiscoveringChanged() {
            if (Bluetooth.defaultAdapter?.discovering) {
                discoveryTimeoutTimer.restart();
            } else {
                discoveryTimeoutTimer.stop();
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        WindowDialogTitle {
            text: Translation.tr("Bluetooth devices")
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
            enabled: Bluetooth.defaultAdapter?.enabled ?? false
            onClicked: {
                if (Bluetooth.defaultAdapter) {
                    Bluetooth.defaultAdapter.discovering = true;
                }
            }

            StyledToolTip {
                text: Translation.tr("Scan for Bluetooth devices")
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
        visible: !(Bluetooth.defaultAdapter?.discovering ?? false)
    }

    StyledIndeterminateProgressBar {
        visible: Bluetooth.defaultAdapter?.discovering ?? false
        Layout.fillWidth: true
        Layout.topMargin: -8
        Layout.bottomMargin: -8
        Layout.leftMargin: -Appearance.rounding.large
        Layout.rightMargin: -Appearance.rounding.large
    }

    ColumnLayout {
        visible: BluetoothStatus.friendlyDeviceList.length === 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.margins: 20
        spacing: 8

        Item { Layout.fillHeight: true }

        MaterialSymbol {
            Layout.alignment: Qt.AlignHCenter
            text: (Bluetooth.defaultAdapter?.discovering ?? false) ? "bluetooth_searching" : "bluetooth_disabled"
            iconSize: 40
            color: Appearance.colors.colSubtext
        }

        StyledText {
            Layout.alignment: Qt.AlignHCenter
            text: (Bluetooth.defaultAdapter?.discovering ?? false) ? Translation.tr("Searching for devices...") : Translation.tr("No Bluetooth devices found")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
        }

        Item { Layout.fillHeight: true }
    }

    StyledListView {
        visible: BluetoothStatus.friendlyDeviceList.length > 0
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
            values: BluetoothStatus.friendlyDeviceList
        }
        delegate: BluetoothDeviceItem {
            required property BluetoothDevice modelData
            device: modelData
            anchors {
                left: parent?.left
                right: parent?.right
            }
        }
    }

    WindowDialogSeparator {}

    WindowDialogButtonRow {
        DialogButton {
            buttonText: Translation.tr("Details")
            onClicked: {
                Quickshell.execDetached(["bash", "-c", `${Config.options.apps.bluetooth}`]);
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
