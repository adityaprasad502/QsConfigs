import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root
    property bool barOpen: true
    property bool appGridOpen: false
    property real topBarMediaWidth: 440
    property bool crosshairOpen: false
    property bool sidebarLeftOpen: false
    property bool sidebarRightOpen: false
    property bool mediaControlsOpen: false
    property bool osdBrightnessOpen: false
    property bool osdVolumeOpen: false
    property bool oskOpen: false
    property bool overlayOpen: false
    property bool overviewOpen: false
    property bool regionSelectorOpen: false
    property bool searchOpen: false
    property bool screenLocked: false
    property bool screenLockContainsCharacters: false
    property bool screenUnlockFailed: false
    property bool screenTranslatorOpen: false
    property bool sessionOpen: false
    property bool superDown: false
    property bool superReleaseMightTrigger: true
    property bool wallpaperSelectorOpen: false
    property bool workspaceShowNumbers: false

    onSidebarRightOpenChanged: {
        if (GlobalStates.sidebarRightOpen) {
            Notifications.timeoutAll();
            Notifications.markAllRead();
        }
    }

    GlobalShortcut {
        name: "workspaceNumber"
        description: "Hold to show workspace numbers, release to show icons"

        onPressed: {
            root.superDown = true
        }
        onReleased: {
            root.superDown = false
        }
    }

    GlobalShortcut {
        name: "appGridToggle"
        description: "Toggle application grid"

        onPressed: {
            root.appGridOpen = !root.appGridOpen
        }
    }

    signal appGridRefreshUpdatesRequested()

    IpcHandler {
        target: "appGrid"

        function toggle(): void {
            root.appGridOpen = !root.appGridOpen
        }
        function open(): void {
            root.appGridOpen = true
        }
        function close(): void {
            root.appGridOpen = false
        }
        function refreshUpdates(): void {
            root.appGridRefreshUpdatesRequested();
        }
    }

    function triggerScreenSnip(): void {
        root.sidebarRightOpen = false;
        screenSnipTimer.restart();
    }

    Timer {
        id: screenSnipTimer
        interval: 350
        repeat: false
        onTriggered: {
            root.regionSelectorOpen = true;
        }
    }

    function triggerColorPicker(): void {
        root.sidebarRightOpen = false;
        colorPickerTimer.restart();
    }

    Timer {
        id: colorPickerTimer
        interval: 350
        repeat: false
        onTriggered: {
            Quickshell.execDetached(["hyprpicker", "-a"]);
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (root.superDown) {
                root.superReleaseMightTrigger = false;
            }
        }
    }
}
