import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import qs.modules.ii.bar as Bar

MouseArea {
    id: root
    implicitHeight: column.implicitHeight + 8
    implicitWidth: Appearance.sizes.verticalBarWidth
    hoverEnabled: !Config.options.bar.tooltips.clickToShow

    TextMetrics {
        id: speedNumberMetrics
        text: "888.8"
        font.pixelSize: Appearance.font.pixelSize.smaller
        font.weight: Font.Bold
    }
    TextMetrics {
        id: speedUnitMetrics
        text: "Mbps"
        font.pixelSize: Appearance.font.pixelSize.smallest
    }

    Column {
        id: column
        spacing: 2
        anchors.centerIn: parent

        // Download speed
        Row {
            spacing: 3
            anchors.horizontalCenter: parent.horizontalCenter

            MaterialSymbol {
                text: "arrow_downward"
                iconSize: Appearance.font.pixelSize.smaller
                color: ResourceUsage.networkRxSpeed > 1024 ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                anchors.verticalCenter: rxItem.verticalCenter
            }

            Item {
                id: rxItem
                width: Math.ceil(speedNumberMetrics.advanceWidth) + 2 + Math.ceil(speedUnitMetrics.advanceWidth)
                height: rxNumberText.implicitHeight

                StyledText {
                    id: rxNumberText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: Appearance.colors.colOnLayer1
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Bold
                    text: ResourceUsage.formatNetworkSpeed(ResourceUsage.networkRxSpeed).split(" ")[0]
                }
                StyledText {
                    anchors.left: rxNumberText.right
                    anchors.leftMargin: 2
                    anchors.baseline: rxNumberText.baseline
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    text: ResourceUsage.formatNetworkSpeed(ResourceUsage.networkRxSpeed).split(" ")[1]
                }
            }
        }

        // Upload speed
        Row {
            spacing: 3
            anchors.horizontalCenter: parent.horizontalCenter

            MaterialSymbol {
                text: "arrow_upward"
                iconSize: Appearance.font.pixelSize.smaller
                color: ResourceUsage.networkTxSpeed > 1024 ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                anchors.verticalCenter: txItem.verticalCenter
            }

            Item {
                id: txItem
                width: Math.ceil(speedNumberMetrics.advanceWidth) + 2 + Math.ceil(speedUnitMetrics.advanceWidth)
                height: txNumberText.implicitHeight

                StyledText {
                    id: txNumberText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: Appearance.colors.colOnLayer1
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Bold
                    text: ResourceUsage.formatNetworkSpeed(ResourceUsage.networkTxSpeed).split(" ")[0]
                }
                StyledText {
                    anchors.left: txNumberText.right
                    anchors.leftMargin: 2
                    anchors.baseline: txNumberText.baseline
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    text: ResourceUsage.formatNetworkSpeed(ResourceUsage.networkTxSpeed).split(" ")[1]
                }
            }
        }
    }

    Bar.NetworkSpeedPopup {
        hoverTarget: root
    }
}
