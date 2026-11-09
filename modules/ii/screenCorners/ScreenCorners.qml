import qs
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: screenCorners
    readonly property Toplevel activeWindow: ToplevelManager.activeToplevel
    property var actionForCorner: ({
        [RoundCorner.CornerEnum.TopLeft]: () => GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen,
        [RoundCorner.CornerEnum.BottomLeft]: () => GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen,
        [RoundCorner.CornerEnum.TopRight]: () => GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen,
        [RoundCorner.CornerEnum.BottomRight]: () => GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen
    })

    component CornerPanelWindow: PanelWindow {
        id: cornerPanelWindow
        property var brightnessMonitor: Brightness.getMonitorForScreen(screen)
        property bool fullscreen
        readonly property bool showFakeRounding: (Config.options.appearance.fakeScreenRounding === 1 || (Config.options.appearance.fakeScreenRounding === 2 && !fullscreen))
        visible: showFakeRounding || sidebarCornerOpenInteractionLoader.active
        property var corner

        Component.onCompleted: {
            GlobalFocusGrab.addPersistent(cornerPanelWindow);
        }
        Component.onDestruction: {
            GlobalFocusGrab.removePersistent(cornerPanelWindow);
        }

        exclusionMode: ExclusionMode.Ignore
        mask: Region {
            item: sidebarCornerOpenInteractionLoader.active ? sidebarCornerOpenInteractionLoader : null
        }
        WlrLayershell.namespace: "quickshell:screenCorners"
        WlrLayershell.layer: WlrLayer.Overlay
        color: "transparent"

        anchors {
            top: cornerWidget.isTopLeft || cornerWidget.isTopRight
            left: cornerWidget.isBottomLeft || cornerWidget.isTopLeft
            bottom: cornerWidget.isBottomLeft || cornerWidget.isBottomRight
            right: cornerWidget.isTopRight || cornerWidget.isBottomRight
        }
        margins {
            right: (Config.options.interactions.deadPixelWorkaround.enable && cornerPanelWindow.anchors.right) * -1
            bottom: (Config.options.interactions.deadPixelWorkaround.enable && cornerPanelWindow.anchors.bottom) * -1
        }

        implicitWidth: cornerWidget.implicitWidth
        implicitHeight: cornerWidget.implicitHeight

        RoundCorner {
            id: cornerWidget
            anchors.fill: parent
            corner: cornerPanelWindow.corner
            color: cornerPanelWindow.showFakeRounding ? "#000000" : "transparent"
            rightVisualMargin: (Config.options.interactions.deadPixelWorkaround.enable && cornerPanelWindow.anchors.right) * 1
            bottomVisualMargin: (Config.options.interactions.deadPixelWorkaround.enable && cornerPanelWindow.anchors.bottom) * 1

            implicitSize: Appearance.rounding.screenRounding
            implicitHeight: Math.max(implicitSize, sidebarCornerOpenInteractionLoader.implicitHeight)
            implicitWidth: Math.max(implicitSize, sidebarCornerOpenInteractionLoader.implicitWidth)

            Loader {
                id: sidebarCornerOpenInteractionLoader
                z: -1
                active: {
                    if (!Config.options.sidebar.cornerOpen.enable) return false;
                    if (cornerPanelWindow.fullscreen) return false;
                    return (Config.options.sidebar.cornerOpen.bottom == cornerWidget.isBottom);
                }
                anchors {
                    top: (cornerWidget.isTopLeft || cornerWidget.isTopRight) ? parent.top : undefined
                    bottom: (cornerWidget.isBottomLeft || cornerWidget.isBottomRight) ? parent.bottom : undefined
                    left: (cornerWidget.isLeft) ? parent.left : undefined
                    right: (cornerWidget.isTopRight || cornerWidget.isBottomRight) ? parent.right : undefined
                }

                sourceComponent: FocusedScrollMouseArea {
                    id: mouseArea
                    implicitWidth: Config.options.sidebar.cornerOpen.cornerRegionWidth
                    implicitHeight: Config.options.sidebar.cornerOpen.cornerRegionHeight
                    hoverEnabled: true

                    property bool cornerEndTriggered: false
                    property real lastAutoTriggerMs: 0

                    onExited: {
                        mouseArea.cornerEndTriggered = false;
                    }
                    onPositionChanged: mouse => {
                        if (!Config.options.sidebar.cornerOpen.clicklessCornerEnd) return;
                        const verticalOffset = Math.min(
                            Config.options.sidebar.cornerOpen.clicklessCornerVerticalOffset,
                            Math.max(0, mouseArea.height - 2)
                        );
                        const correctX = (cornerWidget.isRight && mouse.x >= mouseArea.width - 2) || (cornerWidget.isLeft && mouse.x <= 2);
                        const correctY = mouseArea.height <= 2
                            ? true
                            : ((cornerWidget.isTop && mouse.y > verticalOffset) || (cornerWidget.isBottom && mouse.y < mouseArea.height - verticalOffset));
                        if (correctX && correctY && !mouseArea.cornerEndTriggered) {
                            mouseArea.cornerEndTriggered = true;
                            mouseArea.lastAutoTriggerMs = Date.now();
                            screenCorners.actionForCorner[cornerPanelWindow.corner]();
                        }
                    }
                    onEntered: {
                        if (Config.options.sidebar.cornerOpen.clickless) {
                            mouseArea.lastAutoTriggerMs = Date.now();
                            screenCorners.actionForCorner[cornerPanelWindow.corner]();
                        }
                    }
                    onPressed: {
                        if (Date.now() - mouseArea.lastAutoTriggerMs < 350) return;
                        screenCorners.actionForCorner[cornerPanelWindow.corner]();
                    }
                    onScrollDown: {
                        if (!Config.options.sidebar.cornerOpen.valueScroll)
                            return;
                        if (cornerWidget.isLeft)
                            Brightness.decreaseBrightness()
                        else {
                            const currentVolume = Audio.value;
                            const step = currentVolume < 0.1 ? 0.01 : 0.02 || 0.2;
                            Audio.sink.audio.volume -= step;
                        }
                    }
                    onScrollUp: {
                        if (!Config.options.sidebar.cornerOpen.valueScroll)
                            return;
                        if (cornerWidget.isLeft)
                            Brightness.increaseBrightness()
                        else {
                            const currentVolume = Audio.value;
                            const step = currentVolume < 0.1 ? 0.01 : 0.02 || 0.2;
                            Audio.sink.audio.volume = Math.min(1, Audio.sink.audio.volume + step);
                        }
                    }
                    onMovedAway: {
                        if (!Config.options.sidebar.cornerOpen.valueScroll)
                            return;
                        if (cornerWidget.isLeft)
                            GlobalStates.osdBrightnessOpen = false;
                        else
                            GlobalStates.osdVolumeOpen = false;
                    }

                    Rectangle {
                        id: visualizeRegionIndicator
                        anchors.fill: parent
                        color: ColorUtils.mix(Appearance.colors.colOnLayer0, Appearance.colors.colOnSecondaryContainer, 0.55)
                        opacity: 0.35
                        visible: Config.options.sidebar.cornerOpen.visualize
                    }

                    Shape {
                        id: edgeHoverIndicator
                        readonly property bool curved: cornerPanelWindow.showFakeRounding && cornerWidget.implicitSize > 0
                        readonly property real cornerRadius: curved ? cornerWidget.implicitSize : 0
                        readonly property real visualRightMargin: cornerWidget.isRight ? cornerWidget.rightVisualMargin : 0
                        readonly property real visualBottomMargin: cornerWidget.isBottom ? cornerWidget.bottomVisualMargin : 0
                        readonly property real triggerWidth: Math.max(2, mouseArea.width - visualRightMargin)
                        readonly property real triggerHeight: Math.max(1, mouseArea.height - visualBottomMargin)
                        readonly property real strokeWidth: Math.min(2, triggerHeight)
                        readonly property real edgeOffset: strokeWidth / 2
                        readonly property real arcRadius: Math.max(0, cornerRadius - edgeOffset)
                        readonly property real innerSpanD: Math.min(width - 2, Math.max(2, triggerWidth - 2))
                        readonly property bool startsInCurve: curved && innerSpanD < cornerRadius && arcRadius > 0
                        readonly property real startOffsetDeg: startsInCurve
                            ? Math.min(75, Math.asin(Math.min(1, (cornerRadius - innerSpanD) / arcRadius)) * 180 / Math.PI)
                            : 0
                        readonly property real sweepDeg: curved
                            ? (startsInCurve ? Math.min(75 - startOffsetDeg, 18) : 42)
                            : 0
                        readonly property real arcCenterX: cornerWidget.isLeft ? cornerRadius : (width - cornerRadius)
                        readonly property real arcCenterY: cornerWidget.isTop ? cornerRadius : (height - cornerRadius)
                        readonly property real arcStartAngle: {
                            if (cornerWidget.isTopLeft) return -90 - startOffsetDeg;
                            if (cornerWidget.isTopRight) return -90 + startOffsetDeg;
                            if (cornerWidget.isBottomLeft) return 90 + startOffsetDeg;
                            return 90 - startOffsetDeg;
                        }
                        readonly property real arcSweepAngle: {
                            if (cornerWidget.isTopLeft || cornerWidget.isBottomRight) return -sweepDeg;
                            return sweepDeg;
                        }
                        readonly property real flatEndD: curved ? cornerRadius : 2
                        readonly property real lineEndX: startsInCurve
                            ? (arcCenterX + arcRadius * Math.cos(arcStartAngle * Math.PI / 180))
                            : (cornerWidget.isLeft ? flatEndD : (width - flatEndD))
                        readonly property real lineEndY: startsInCurve
                            ? (arcCenterY + arcRadius * Math.sin(arcStartAngle * Math.PI / 180))
                            : (cornerWidget.isTop ? edgeOffset : (height - edgeOffset))

                        anchors {
                            top: cornerWidget.isTop ? parent.top : undefined
                            bottom: cornerWidget.isBottom ? parent.bottom : undefined
                            left: cornerWidget.isLeft ? parent.left : undefined
                            right: cornerWidget.isRight ? parent.right : undefined
                            rightMargin: visualRightMargin
                            bottomMargin: visualBottomMargin
                        }
                        width: Math.max(triggerWidth, cornerRadius)
                        height: Math.max(triggerHeight, cornerRadius)
                        layer.enabled: true
                        layer.smooth: true
                        preferredRendererType: Shape.CurveRenderer
                        opacity: mouseArea.containsMouse ? 0.65 : 0.0
                        visible: opacity > 0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: 120
                                easing.type: Easing.OutCubic
                            }
                        }

                        ShapePath {
                            id: indicatorPath
                            strokeColor: ColorUtils.mix(Appearance.colors.colOnLayer0, Appearance.colors.colOnSecondaryContainer, 0.55)
                            strokeWidth: edgeHoverIndicator.strokeWidth
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            fillColor: "transparent"

                            startX: edgeHoverIndicator.startsInCurve
                                ? edgeHoverIndicator.lineEndX
                                : (cornerWidget.isLeft ? edgeHoverIndicator.innerSpanD : (edgeHoverIndicator.width - edgeHoverIndicator.innerSpanD))
                            startY: edgeHoverIndicator.startsInCurve
                                ? edgeHoverIndicator.lineEndY
                                : (cornerWidget.isTop ? edgeHoverIndicator.edgeOffset : (edgeHoverIndicator.height - edgeHoverIndicator.edgeOffset))

                            PathLine {
                                x: edgeHoverIndicator.lineEndX
                                y: edgeHoverIndicator.lineEndY
                            }

                            PathAngleArc {
                                moveToStart: false
                                centerX: edgeHoverIndicator.curved ? edgeHoverIndicator.arcCenterX : edgeHoverIndicator.lineEndX
                                centerY: edgeHoverIndicator.curved ? edgeHoverIndicator.arcCenterY : edgeHoverIndicator.lineEndY
                                radiusX: edgeHoverIndicator.curved ? edgeHoverIndicator.arcRadius : 0
                                radiusY: edgeHoverIndicator.curved ? edgeHoverIndicator.arcRadius : 0
                                startAngle: edgeHoverIndicator.curved ? edgeHoverIndicator.arcStartAngle : 0
                                sweepAngle: edgeHoverIndicator.arcSweepAngle
                            }
                        }
                    }
                }
            }
        }
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: monitorScope
            required property var modelData
            property HyprlandMonitor monitor: Hyprland.monitorFor(modelData)

            // Hide when fullscreen
            property list<HyprlandWorkspace> workspacesForMonitor: Hyprland.workspaces.values.filter(workspace => workspace.monitor && workspace.monitor.name == monitor.name)
            property var activeWorkspaceWithFullscreen: workspacesForMonitor.filter(workspace => ((workspace.toplevels.values.filter(window => window.wayland?.fullscreen)[0] != undefined) && workspace.active))[0]
            property bool fullscreen: activeWorkspaceWithFullscreen != undefined

            CornerPanelWindow {
                screen: modelData
                corner: RoundCorner.CornerEnum.TopLeft
                fullscreen: monitorScope.fullscreen
            }
            CornerPanelWindow {
                screen: modelData
                corner: RoundCorner.CornerEnum.TopRight
                fullscreen: monitorScope.fullscreen
            }
            CornerPanelWindow {
                screen: modelData
                corner: RoundCorner.CornerEnum.BottomLeft
                fullscreen: monitorScope.fullscreen
            }
            CornerPanelWindow {
                screen: modelData
                corner: RoundCorner.CornerEnum.BottomRight
                fullscreen: monitorScope.fullscreen
            }
        }
    }
}
