pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

RippleButton {
    id: root
    property string iconText
    property string label
    property bool isHighlighted: false
    property bool isDestructive: false
    signal triggered()
    signal hoveredAction()

    Layout.fillWidth: true
    implicitHeight: 34
    buttonRadius: Appearance.rounding.small
    colBackground: isHighlighted ? (isDestructive ? ColorUtils.transparentize(Appearance.m3colors.m3error, 0.8) : Appearance.colors.colLayer3Hover) : "transparent"
    colBackgroundHover: isDestructive ? ColorUtils.transparentize(Appearance.m3colors.m3error, 0.8) : Appearance.colors.colLayer3Hover
    colRipple: isDestructive ? ColorUtils.transparentize(Appearance.m3colors.m3error, 0.6) : Appearance.colors.colPrimaryContainerActive

    onHoveredChanged: {
        if (hovered) root.hoveredAction();
    }

    onClicked: root.triggered()

    Rectangle {
        anchors.fill: parent
        radius: root.buttonRadius
        color: "transparent"
        border.width: 1
        border.color: root.isDestructive ? Appearance.m3colors.m3error : Appearance.colors.colPrimary
        visible: root.isHighlighted
        opacity: 0.8
        z: 2
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        spacing: 12

        MaterialSymbol {
            text: root.iconText
            iconSize: 18
            color: root.isDestructive ? Appearance.m3colors.m3error : Appearance.colors.colPrimary
        }

        StyledText {
            Layout.fillWidth: true
            text: root.label
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: root.isHighlighted ? Font.DemiBold : Font.Normal
            color: root.isDestructive ? Appearance.m3colors.m3error : Appearance.m3colors.m3onSurface
            elide: Text.ElideRight
        }
    }
}
