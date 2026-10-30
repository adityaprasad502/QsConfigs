import qs.modules.ii.bar.weather
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Item { // Bar content region
    id: root

    property var screen: root.QsWindow.window?.screen
    property real useShortenedForm: (Appearance.sizes.barHellaShortenScreenWidthThreshold >= screen?.width) ? 2 : (Appearance.sizes.barShortenScreenWidthThreshold >= screen?.width) ? 1 : 0

    // Background shadow
    Loader {
        active: Config.options.bar.showBackground && Config.options.bar.cornerStyle === 1 && Config.options.bar.floatStyleShadow
        anchors.fill: barBackground
        sourceComponent: StyledRectangularShadow {
            anchors.fill: undefined
            target: barBackground
        }
    }
    // Background
    Rectangle {
        id: barBackground
        anchors {
            fill: parent
            margins: Config.options.bar.cornerStyle === 1 ? (Appearance.sizes.hyprlandGapsOut) : 0
        }
        color: Config.options.bar.showBackground ? Appearance.colors.colLayer0 : "transparent"
        radius: Config.options.bar.cornerStyle === 1 ? Appearance.rounding.windowRounding : 0
        border.width: Config.options.bar.cornerStyle === 1 ? 1 : 0
        border.color: Appearance.colors.colLayer0Border
    }

    // ============ LEFT: Media (fills from left edge to workspaces) ============
    FocusedScrollMouseArea {
        id: barLeftSideMouseArea

        anchors {
            top: parent.top
            bottom: parent.bottom
            left: parent.left
            right: middleSection.left
            rightMargin: 6
        }
        implicitHeight: Appearance.sizes.baseBarHeight

        onScrollDown: Audio.decrementVolume()
        onScrollUp: Audio.incrementVolume()
        onMovedAway: GlobalStates.osdVolumeOpen = false

        ScrollHint {
            reveal: barLeftSideMouseArea.hovered
            icon: "volume_up"
            tooltipText: Translation.tr("Scroll to change volume")
            side: "left"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }

        Media {
            anchors.fill: parent
            anchors.leftMargin: Appearance.rounding.screenRounding
            anchors.rightMargin: 0
        }
    }

    // ============ CENTER: Workspaces (always centered) ============
    Row {
        id: middleSection
        anchors {
            top: parent.top
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 4

        BarGroup {
            id: middleCenterGroup
            anchors.verticalCenter: parent.verticalCenter
            padding: workspacesWidget.widgetPadding ?? 5

            Workspaces {
                id: workspacesWidget
                Layout.fillHeight: true
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onPressed: event => {
                        if (event.button === Qt.RightButton) {
                            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
                        }
                    }
                }
            }
        }
    }

    // ============ RIGHT: DateTime, Stats, Utils, Weather, RightSidebar ============
    FocusedScrollMouseArea {
        id: barRightSideMouseArea

        anchors {
            top: parent.top
            bottom: parent.bottom
            left: middleSection.right
            leftMargin: 6
            right: parent.right
        }
        implicitWidth: rightSectionRowLayout.implicitWidth
        implicitHeight: Appearance.sizes.baseBarHeight

        onScrollDown: Brightness.decreaseBrightness()
        onScrollUp: Brightness.increaseBrightness()
        onMovedAway: GlobalStates.osdBrightnessOpen = false
        onPressed: event => {
            if (event.button === Qt.LeftButton) {
                GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
            }
        }

        ScrollHint {
            reveal: barRightSideMouseArea.hovered
            icon: Hyprsunset.gamma === 100 ? "light_mode" : "wb_twilight"
            tooltipText: Translation.tr("Scroll to change brightness")
            side: "right"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
        }

        RowLayout {
            id: rightSectionRowLayout
            anchors.fill: parent
            spacing: 0
            layoutDirection: Qt.RightToLeft

            RippleButton { // Right sidebar button
                id: rightSidebarButton

                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                Layout.rightMargin: Appearance.rounding.screenRounding
                Layout.fillWidth: false

                implicitWidth: indicatorsRowLayout.implicitWidth + 8 * 2
                implicitHeight: Appearance.sizes.baseBarHeight - 8

                buttonRadius: Appearance.rounding.small
                colBackground: Appearance.colors.colLayer1
                colBackgroundHover: Appearance.colors.colLayer1Hover
                colRipple: Appearance.colors.colLayer1Active
                colBackgroundToggled: Appearance.colors.colSecondaryContainer
                colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                colRippleToggled: Appearance.colors.colSecondaryContainerActive
                toggled: GlobalStates.sidebarRightOpen
                property color colText: toggled ? Appearance.m3colors.m3onSecondaryContainer : Appearance.colors.colOnLayer0

                Behavior on colText {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                onPressed: {
                    GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
                }

                RowLayout {
                    id: indicatorsRowLayout
                    anchors.centerIn: parent
                    property real realSpacing: 15
                    spacing: 0

                    SysTray {
                        id: sysTrayItem
                        visible: root.useShortenedForm === 0
                        Layout.fillWidth: false
                        Layout.fillHeight: true
                        Layout.preferredWidth: visible ? implicitWidth : 0
                        invertSide: Config?.options.bar.bottom
                        showSeparator: false
                        Layout.rightMargin: 4
                    }

                    Revealer {
                        reveal: Audio.sink?.audio?.muted ?? false
                        Layout.fillHeight: true
                        Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
                        Behavior on Layout.rightMargin {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        MaterialSymbol {
                            text: "volume_off"
                            iconSize: Appearance.font.pixelSize.larger
                            color: rightSidebarButton.colText
                        }
                    }
                    Revealer {
                        reveal: Audio.source?.audio?.muted ?? false
                        Layout.fillHeight: true
                        Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
                        Behavior on Layout.rightMargin {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        MaterialSymbol {
                            text: "mic_off"
                            iconSize: Appearance.font.pixelSize.larger
                            color: rightSidebarButton.colText
                        }
                    }
                    HyprlandXkbIndicator {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.rightMargin: indicatorsRowLayout.realSpacing
                        color: rightSidebarButton.colText
                    }
                    Revealer {
                        reveal: Notifications.silent || Notifications.unread > 0
                        Layout.alignment: Qt.AlignVCenter
                        Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
                        implicitHeight: reveal ? notificationUnreadCount.implicitHeight : 0
                        implicitWidth: reveal ? notificationUnreadCount.implicitWidth : 0
                        Behavior on Layout.rightMargin {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        NotificationUnreadCount {
                            id: notificationUnreadCount
                        }
                    }
                    MaterialSymbol {
                        text: Network.materialSymbol
                        iconSize: Appearance.font.pixelSize.larger
                        color: rightSidebarButton.colText
                    }
                    MaterialSymbol {
                        Layout.leftMargin: indicatorsRowLayout.realSpacing
                        visible: BluetoothStatus.available
                        text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
                        iconSize: Appearance.font.pixelSize.larger
                        color: rightSidebarButton.colText
                    }
                    BatteryIndicator {
                        visible: Battery.available
                        Layout.alignment: Qt.AlignVCenter
                        Layout.leftMargin: 8
                    }
                    Repeater {
                        model: KdeConnect.devices.length
                        delegate: Revealer {
                            readonly property var device: KdeConnect.devices[index]
                            reveal: device ? device.reachable : false
                            Layout.alignment: Qt.AlignVCenter
                            Layout.leftMargin: reveal ? 4 : 0
                            Behavior on Layout.leftMargin {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            PhoneBatteryIndicator {
                                phone: device
                            }
                        }
                    }
                }
            }



            Item { Layout.fillWidth: true; Layout.fillHeight: true }

            // DateTime + Weather
            MouseArea {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: clockGroupContent.implicitWidth + 8
                implicitHeight: Appearance.sizes.baseBarHeight

                onPressed: {
                    GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
                }

                Rectangle {
                    id: clockGroupContent
                    anchors.centerIn: parent
                    color: Config.options?.bar.borderless ? "transparent" : Appearance.colors.colLayer1
                    radius: Appearance.rounding.small
                    implicitWidth: clockRow.implicitWidth + 16
                    implicitHeight: Appearance.sizes.baseBarHeight - 8

                    RowLayout {
                        id: clockRow
                        anchors.centerIn: parent
                        spacing: 0
                        
                        ClockWidget {
                            showDate: (Config.options.bar.verbose && root.useShortenedForm < 2)
                            Layout.alignment: Qt.AlignVCenter
                        }

                        StyledText {
                            visible: Config.options.bar.weather.enable
                            Layout.alignment: Qt.AlignVCenter
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            text: " • "
                        }

                        Loader {
                            active: Config.options.bar.weather.enable
                            Layout.alignment: Qt.AlignVCenter
                            Layout.rightMargin: 4
                            sourceComponent: WeatherBar {}
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: utilButtonsGroup.visible
            }

            // Utils
            BarGroup {
                id: utilButtonsGroup
                Layout.alignment: Qt.AlignVCenter
                visible: Config.options.bar.verbose && root.useShortenedForm === 0 && utilButtonsItem.implicitWidth > 8
                Layout.preferredWidth: visible ? implicitWidth : 0

                UtilButtons {
                    id: utilButtonsItem
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            Item { Layout.fillWidth: true; Layout.fillHeight: true }

            // Network Speed
            BarGroup {
                id: networkSpeedGroup
                Layout.alignment: Qt.AlignVCenter

                NetworkSpeedMeter {
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            Item { Layout.fillWidth: true; Layout.fillHeight: true }

            // Stats (Resources)
            BarGroup {
                id: resourcesGroup
                Layout.alignment: Qt.AlignVCenter

                Resources {
                    alwaysShowAllResources: true
                }
            }

            // Removed spacer to allow Resources to anchor to the left edge
        }
    }
}
