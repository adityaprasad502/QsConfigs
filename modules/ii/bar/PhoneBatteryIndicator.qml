import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

MouseArea {
    id: root

    property var phone: null
    readonly property real percentage: Math.max(0, (phone?.charge ?? 0)) / 100
    readonly property bool isCharging: phone?.isCharging ?? false
    readonly property bool isLow: percentage <= Config.options.battery.low / 100 && (phone?.charge ?? -1) >= 0

    implicitWidth: batteryProgress.implicitWidth
    implicitHeight: batteryProgress.implicitHeight

    hoverEnabled: !Config.options.bar.tooltips.clickToShow
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton

    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton && root.phone?.reachable) {
            KdeConnect.findPhone(root.phone.id);
        }
    }

    ClippedProgressBar {
        id: batteryProgress
        anchors.centerIn: parent
        value: root.percentage
        highlightColor: (root.isLow && !root.isCharging)
            ? Appearance.m3colors.m3error
            : Appearance.colors.colOnSecondaryContainer

        Item {
            anchors.centerIn: parent
            width: batteryProgress.valueBarWidth
            height: batteryProgress.valueBarHeight

            RowLayout {
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    bottom: parent.bottom
                    bottomMargin: (parent.height - height) / 2
                }
                spacing: 0

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: -2
                    Layout.rightMargin: -2
                    fill: 1
                    text: "bolt"
                    iconSize: Appearance.font.pixelSize.smaller
                    visible: root.isCharging && root.percentage < 1
                }
                StyledText {
                    Layout.alignment: Qt.AlignVCenter
                    font: batteryProgress.font
                    text: (root.phone?.charge ?? -1) >= 0 ? batteryProgress.text : "?"
                }
            }
        }
    }

    PhoneBatteryPopup {
        hoverTarget: root
        phone: root.phone
    }
}
