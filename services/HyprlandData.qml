pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * Provides access to some Hyprland data not available in Quickshell.Hyprland.
 */
Singleton {
    id: root
    property var windowList: []
    property var addresses: []
    property var windowByAddress: ({})
    property var workspaces: []
    property var workspaceIds: []
    property var workspaceById: ({})
    property var activeWorkspace: null
    property var monitors: []
    property var layers: ({})

    // Convenient stuff

    property bool _pendingClientsUpdate: false
    property bool _pendingMonitorsUpdate: false
    property bool _pendingLayersUpdate: false
    property bool _pendingWorkspacesUpdate: false
    property bool _pendingActiveWorkspaceUpdate: false

    function toplevelsForWorkspace(workspace) {
        return ToplevelManager.toplevels.values.filter(toplevel => {
            const address = `0x${toplevel.HyprlandToplevel?.address}`;
            var win = HyprlandData.windowByAddress[address];
            return win?.workspace?.id === workspace;
        })
    }

    function hyprlandClientsForWorkspace(workspace) {
        return root.windowList.filter(win => win?.workspace?.id === workspace);
    }

    function clientForToplevel(toplevel) {
        if (!toplevel || !toplevel.HyprlandToplevel) {
            return null;
        }
        const address = `0x${toplevel?.HyprlandToplevel?.address}`;
        return root.windowByAddress[address];
    }

    // Internals

    function updateWindowList() {
        if (getClients.running) {
            root._pendingClientsUpdate = true;
            return;
        }
        getClients.running = true;
    }

    function updateLayers() {
        if (getLayers.running) {
            root._pendingLayersUpdate = true;
            return;
        }
        getLayers.running = true;
    }

    function updateMonitors() {
        if (getMonitors.running) {
            root._pendingMonitorsUpdate = true;
            return;
        }
        getMonitors.running = true;
    }

    function updateWorkspaces() {
        if (getWorkspaces.running) {
            root._pendingWorkspacesUpdate = true;
        } else {
            getWorkspaces.running = true;
        }
        if (getActiveWorkspace.running) {
            root._pendingActiveWorkspaceUpdate = true;
        } else {
            getActiveWorkspace.running = true;
        }
    }

    function updateAll() {
        updateWindowList();
        updateMonitors();
        updateLayers();
        updateWorkspaces();
    }

    function biggestWindowForWorkspace(workspaceId) {
        const windowsInThisWorkspace = HyprlandData.windowList.filter(w => w?.workspace?.id == workspaceId);
        return windowsInThisWorkspace.reduce((maxWin, win) => {
            const maxArea = (maxWin?.size?.[0] ?? 0) * (maxWin?.size?.[1] ?? 0);
            const winArea = (win?.size?.[0] ?? 0) * (win?.size?.[1] ?? 0);
            return winArea > maxArea ? win : maxWin;
        }, null);
    }

    Component.onCompleted: {
        updateAll();
    }

    Timer {
        id: updateDebounce
        interval: 50
        repeat: false
        onTriggered: root.updateAll()
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            // console.log("Hyprland raw event:", event.name);
            if (["openlayer", "closelayer", "screencast"].includes(event.name)) return;
            updateDebounce.restart()
        }

        function onFocusedWorkspaceChanged() {
            updateDebounce.restart();
        }

        function onActiveToplevelChanged() {
            updateDebounce.restart();
        }
    }

    Connections {
        target: Hyprland.workspaces
        function onValuesChanged() {
            updateDebounce.restart();
        }
    }

    Connections {
        target: Hyprland.toplevels
        function onValuesChanged() {
            updateDebounce.restart();
        }
    }

    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() {
            updateDebounce.restart();
        }
    }

    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        onExited: {
            if (root._pendingClientsUpdate) {
                root._pendingClientsUpdate = false;
                getClients.running = true;
            }
        }
        stdout: StdioCollector {
            id: clientsCollector
            onStreamFinished: {
                const raw = clientsCollector.text.trim();
                if (!raw) return;
                try {
                    const parsed = JSON.parse(raw);
                    if (!Array.isArray(parsed)) return;
                    root.windowList = parsed;
                    const tempWinByAddress = {};
                    for (let i = 0; i < root.windowList.length; ++i) {
                        const win = root.windowList[i];
                        tempWinByAddress[win.address] = win;
                    }
                    root.windowByAddress = tempWinByAddress;
                    root.addresses = root.windowList.map(win => win.address);
                } catch (e) {
                    console.warn("[HyprlandData] Failed to parse clients JSON:", e);
                }
            }
        }
    }

    Process {
        id: getMonitors
        command: ["hyprctl", "monitors", "-j"]
        onExited: {
            if (root._pendingMonitorsUpdate) {
                root._pendingMonitorsUpdate = false;
                getMonitors.running = true;
            }
        }
        stdout: StdioCollector {
            id: monitorsCollector
            onStreamFinished: {
                const raw = monitorsCollector.text.trim();
                if (!raw) return;
                try {
                    const parsed = JSON.parse(raw);
                    if (Array.isArray(parsed)) root.monitors = parsed;
                } catch (e) {
                    console.warn("[HyprlandData] Failed to parse monitors JSON:", e);
                }
            }
        }
    }

    Process {
        id: getLayers
        command: ["hyprctl", "layers", "-j"]
        onExited: {
            if (root._pendingLayersUpdate) {
                root._pendingLayersUpdate = false;
                getLayers.running = true;
            }
        }
        stdout: StdioCollector {
            id: layersCollector
            onStreamFinished: {
                const raw = layersCollector.text.trim();
                if (!raw) return;
                try {
                    root.layers = JSON.parse(raw);
                } catch (e) {
                    console.warn("[HyprlandData] Failed to parse layers JSON:", e);
                }
            }
        }
    }

    Process {
        id: getWorkspaces
        command: ["hyprctl", "workspaces", "-j"]
        onExited: {
            if (root._pendingWorkspacesUpdate) {
                root._pendingWorkspacesUpdate = false;
                getWorkspaces.running = true;
            }
        }
        stdout: StdioCollector {
            id: workspacesCollector
            onStreamFinished: {
                const raw = workspacesCollector.text.trim();
                if (!raw) return;
                try {
                    const rawWorkspaces = JSON.parse(raw);
                    if (!Array.isArray(rawWorkspaces)) return;
                    // Filter out invalid workspace ids (e.g. lock-screen temp workspace 2147483647 - N)
                    root.workspaces = rawWorkspaces.filter(ws => ws.id >= 1 && ws.id <= 100);
                    const tempWorkspaceById = {};
                    for (let i = 0; i < root.workspaces.length; ++i) {
                        const ws = root.workspaces[i];
                        tempWorkspaceById[ws.id] = ws;
                    }
                    root.workspaceById = tempWorkspaceById;
                    root.workspaceIds = root.workspaces.map(ws => ws.id);
                } catch (e) {
                    console.warn("[HyprlandData] Failed to parse workspaces JSON:", e);
                }
            }
        }
    }

    Process {
        id: getActiveWorkspace
        command: ["hyprctl", "activeworkspace", "-j"]
        onExited: {
            if (root._pendingActiveWorkspaceUpdate) {
                root._pendingActiveWorkspaceUpdate = false;
                getActiveWorkspace.running = true;
            }
        }
        stdout: StdioCollector {
            id: activeWorkspaceCollector
            onStreamFinished: {
                const raw = activeWorkspaceCollector.text.trim();
                if (!raw) return;
                try {
                    root.activeWorkspace = JSON.parse(raw);
                } catch (e) {
                    console.warn("[HyprlandData] Failed to parse activeworkspace JSON:", e);
                }
            }
        }
    }
}
