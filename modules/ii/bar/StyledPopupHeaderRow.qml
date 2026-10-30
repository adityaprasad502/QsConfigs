import QtQuick
import qs.modules.common
import qs.modules.common.widgets

Row {
    id: root
    required property var icon
    required property var label
    spacing: 5

    property bool iconIsMaterial: true

    Item {
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: root.iconIsMaterial ? materialIcon.implicitWidth : textIcon.implicitWidth
        implicitHeight: root.iconIsMaterial ? materialIcon.implicitHeight : textIcon.implicitHeight

        MaterialSymbol {
            id: materialIcon
            anchors.centerIn: parent
            fill: 0
            font.weight: Font.DemiBold
            text: root.icon
            iconSize: Appearance.font.pixelSize.large
            color: Appearance.colors.colOnSurfaceVariant
            visible: root.iconIsMaterial
        }
        
        StyledText {
            id: textIcon
            anchors.centerIn: parent
            text: root.icon
            font.weight: Font.DemiBold
            font.pixelSize: Appearance.font.pixelSize.large
            color: Appearance.colors.colOnSurfaceVariant
            visible: !root.iconIsMaterial
        }
    }

    StyledText {
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        font {
            weight: Font.DemiBold
            pixelSize: Appearance.font.pixelSize.normal
        }
        color: Appearance.colors.colOnSurfaceVariant
    }
}