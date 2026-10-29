pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root
    property bool visible: false
    property int revision: 0
    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property var realPlayers: MprisController.players
    readonly property var meaningfulPlayers: {
        root.revision;
        return filterDuplicatePlayers(realPlayers);
    }
    readonly property real osdWidth: Appearance.sizes.osdWidth
    readonly property real widgetWidth: !Config.options.bar.vertical && GlobalStates.topBarMediaWidth > 100 ? GlobalStates.topBarMediaWidth : Appearance.sizes.mediaControlsWidth
    readonly property real widgetHeight: Appearance.sizes.mediaControlsHeight
    property real popupRounding: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1
    property list<real> visualizerPoints: []

    function filterDuplicatePlayers(players) {
        if (!players || !players.length) return [];
        let filtered = [];
        let used = new Set();

        for (let i = 0; i < players.length; ++i) {
            if (used.has(i))
                continue;
            let p1 = players[i];
            if (!p1) continue;

            let title1 = (p1.trackTitle || "").trim().toLowerCase();
            let artist1 = (p1.trackArtist || "").trim();
            let isPlaying1 = p1.isPlaying || p1.playbackState === MprisPlaybackState.Playing;
            if (!isPlaying1 && (title1 === "" || title1 === "untitled") && artist1 === "") {
                continue;
            }

            // Exclude zombie players or KDE Connect mirroring Spotify when native Spotify is present
            let dbus1 = (p1.dbusName || "").toLowerCase();
            let isKde1 = dbus1.includes("kdeconnect");
            let identity1 = (p1.identity || "").toLowerCase();
            if (isKde1 && identity1.includes("spotify") && MprisController.hasActiveDesktopSpotify) {
                continue;
            }
            let len1 = p1.length || 0;
            let pos1 = p1.position || 0;
            if (isKde1 && len1 > 0 && pos1 >= (len1 - 1.0)) {
                continue;
            }

            let group = [i];
            let cTitle1 = StringUtils.cleanMusicTitle(p1.trackTitle).toLowerCase();

            for (let j = i + 1; j < players.length; ++j) {
                let p2 = players[j];
                if (!p2) continue;
                let cTitle2 = StringUtils.cleanMusicTitle(p2.trackTitle).toLowerCase();
                let titleMatch = cTitle1 && cTitle2 && (cTitle1 === cTitle2 || (cTitle1.length > 3 && (cTitle1.includes(cTitle2) || cTitle2.includes(cTitle1))));
                let timeMatch = p1.length > 5 && p2.length > 5 && Math.abs(p1.length - p2.length) <= 3 && Math.abs(p1.position - p2.position) <= 3;
                if (titleMatch || timeMatch) {
                    group.push(j);
                }
            }

            let bestIdx = group[0];
            let bestScore = -1;
            for (let g = 0; g < group.length; g++) {
                let idx = group[g];
                let p = players[idx];
                let score = 0;
                if (p.isPlaying || p.playbackState === MprisPlaybackState.Playing) score += 100;
                if (p.trackArtUrl && p.trackArtUrl.length > 0) score += 50;
                if (!((p.dbusName || "").toLowerCase().includes("kdeconnect"))) score += 30;
                if (p.length > 0) score += 20;
                if (p.trackArtist && p.trackArtist.length > 0) score += 10;
                if (score > bestScore) {
                    bestScore = score;
                    bestIdx = idx;
                }
            }

            filtered.push(players[bestIdx]);
            group.forEach(idx => used.add(idx));
        }

        if (filtered.length === 0 && root.activePlayer) {
            filtered.push(root.activePlayer);
        }

        filtered.sort((a, b) => {
            if (a === root.activePlayer) return -1;
            if (b === root.activePlayer) return 1;
            let scoreA = MprisController.getPlayerScore(a);
            let scoreB = MprisController.getPlayerScore(b);
            if (scoreA !== scoreB) return scoreB - scoreA;
            return 0;
        });

        return filtered;
    }

    Process {
        id: cavaProc
        running: mediaControlsLoader.active
        onRunningChanged: {
            if (!cavaProc.running) {
                root.visualizerPoints = [];
            }
        }
        command: ["cava", "-p", `${FileUtils.trimFileProtocol(Directories.scriptPath)}/cava/raw_output_config.txt`]
        stdout: SplitParser {
            onRead: data => {
                // Parse `;`-separated values into the visualizerPoints array
                let points = data.split(";").map(p => parseFloat(p.trim())).filter(p => !isNaN(p));
                root.visualizerPoints = points;
            }
        }
    }

    Loader {
        id: mediaControlsLoader
        active: GlobalStates.mediaControlsOpen
        onActiveChanged: {
            if (mediaControlsLoader.active) {
                root.revision++;
            }
            if (!mediaControlsLoader.active && root.realPlayers.length === 0) {
                GlobalStates.mediaControlsOpen = false;
            }
        }

        sourceComponent: PanelWindow {
            id: panelWindow
            visible: true

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            implicitWidth: root.widgetWidth
            implicitHeight: playerColumnLayout.implicitHeight
            color: "transparent"
            WlrLayershell.namespace: "quickshell:mediaControls"

            anchors {
                top: !Config.options.bar.bottom || Config.options.bar.vertical
                bottom: Config.options.bar.bottom && !Config.options.bar.vertical
                left: !(Config.options.bar.vertical && Config.options.bar.bottom)
                right: Config.options.bar.vertical && Config.options.bar.bottom
            }
            margins {
                top: Config.options.bar.vertical ? ((panelWindow.screen.height / 2) - widgetHeight * 1.5) : Appearance.sizes.barHeight
                bottom: Appearance.sizes.barHeight
                left: Config.options.bar.vertical ? Appearance.sizes.barHeight : ((Config.options.bar.cornerStyle === 1 ? Appearance.sizes.hyprlandGapsOut : 0) + Appearance.rounding.screenRounding)
                right: Appearance.sizes.barHeight
            }

            mask: Region {
                item: playerColumnLayout
            }

            Component.onCompleted: {
                GlobalFocusGrab.addDismissable(panelWindow);
            }
            Component.onDestruction: {
                GlobalFocusGrab.removeDismissable(panelWindow);
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    GlobalStates.mediaControlsOpen = false;
                }
            }

            ColumnLayout {
                id: playerColumnLayout
                anchors.fill: parent
                spacing: -Appearance.sizes.elevationMargin // Shadow overlap okay

                Repeater {
                    model: ScriptModel {
                        values: root.meaningfulPlayers
                    }
                    delegate: PlayerControl {
                        required property MprisPlayer modelData
                        player: modelData
                        visualizerPoints: root.visualizerPoints
                        implicitWidth: root.widgetWidth
                        implicitHeight: root.widgetHeight
                        radius: root.popupRounding
                    }
                }

                Item {
                    // No player placeholder
                    Layout.alignment: {
                        if (panelWindow.anchors.left)
                            return Qt.AlignLeft;
                        if (panelWindow.anchors.right)
                            return Qt.AlignRight;
                        return Qt.AlignHCenter;
                    }
                    Layout.leftMargin: Appearance.sizes.hyprlandGapsOut
                    Layout.rightMargin: Appearance.sizes.hyprlandGapsOut
                    visible: root.meaningfulPlayers.length === 0
                    implicitWidth: placeholderBackground.implicitWidth + Appearance.sizes.elevationMargin
                    implicitHeight: placeholderBackground.implicitHeight + Appearance.sizes.elevationMargin

                    StyledRectangularShadow {
                        target: placeholderBackground
                    }

                    Rectangle {
                        id: placeholderBackground
                        anchors.centerIn: parent
                        color: Appearance.colors.colLayer0
                        radius: root.popupRounding
                        property real padding: 20
                        implicitWidth: placeholderLayout.implicitWidth + padding * 2
                        implicitHeight: placeholderLayout.implicitHeight + padding * 2

                        ColumnLayout {
                            id: placeholderLayout
                            anchors.centerIn: parent

                            StyledText {
                                text: Translation.tr("No active player")
                                font.pixelSize: Appearance.font.pixelSize.large
                            }
                            StyledText {
                                color: Appearance.colors.colSubtext
                                text: Translation.tr("Make sure your player has MPRIS support\nor try turning off duplicate player filtering")
                                font.pixelSize: Appearance.font.pixelSize.small
                            }
                        }
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "mediaControls"

        function toggle(): void {
            mediaControlsLoader.active = !mediaControlsLoader.active;
            if (mediaControlsLoader.active)
                Notifications.timeoutAll();
        }

        function close(): void {
            mediaControlsLoader.active = false;
        }

        function open(): void {
            mediaControlsLoader.active = true;
            Notifications.timeoutAll();
        }
    }

    GlobalShortcut {
        name: "mediaControlsToggle"
        description: "Toggles media controls on press"

        onPressed: {
            GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen;
        }
    }
    GlobalShortcut {
        name: "mediaControlsOpen"
        description: "Opens media controls on press"

        onPressed: {
            GlobalStates.mediaControlsOpen = true;
        }
    }
    GlobalShortcut {
        name: "mediaControlsClose"
        description: "Closes media controls on press"

        onPressed: {
            GlobalStates.mediaControlsOpen = false;
        }
    }
}
