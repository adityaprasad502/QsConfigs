import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Services.Mpris

Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property string cleanedTitle: StringUtils.cleanMusicTitle(activePlayer?.trackTitle) || Translation.tr("No media")

    property list<real> visualizerPoints: []

    onWidthChanged: {
        if (root.width > 100) {
            GlobalStates.topBarMediaWidth = root.width;
        }
    }
    Component.onCompleted: {
        if (root.width > 100) {
            GlobalStates.topBarMediaWidth = root.width;
        }
    }

    // State helpers
    readonly property bool isPlaying: activePlayer?.playbackState === MprisPlaybackState.Playing
    readonly property bool isPaused: activePlayer != null && !root.isPlaying
    readonly property bool hasMedia: activePlayer != null && (root.isPlaying || (StringUtils.cleanMusicTitle(activePlayer?.trackTitle) || "") !== "")
    readonly property bool hasLyrics: root.hasMedia && root.isPlaying && ((LyricsService.currentLyricLine && LyricsService.currentLyricLine.length > 0) || LyricsService.lyricLines.length > 0)
    readonly property bool isLive: {
        if (!activePlayer || !root.hasMedia) return false;
        let len = activePlayer?.length || 0;
        let canSeek = activePlayer?.canSeek ?? false;
        return len <= 0 || !canSeek;
    }

    Process {
        id: cavaProc
        running: root.isPlaying
        onRunningChanged: {
            if (!cavaProc.running) {
                root.visualizerPoints = [];
            }
        }
        command: ["cava", "-p", `${FileUtils.trimFileProtocol(Directories.scriptPath)}/cava/raw_output_config.txt`]
        stdout: SplitParser {
            onRead: data => {
                let points = data.split(";").map(p => parseFloat(p.trim())).filter(p => !isNaN(p));
                root.visualizerPoints = points;
            }
        }
    }


    implicitHeight: Appearance.sizes.barHeight

    Timer {
        running: root.isPlaying
        interval: 1000
        repeat: true
        onTriggered: activePlayer.positionChanged()
    }

    // Background pill
    Rectangle {
        id: bgContainer
        anchors.fill: parent
        anchors.topMargin: 4
        anchors.bottomMargin: 4
        radius: Appearance.rounding.small
        color: Config.options?.bar.borderless ? "transparent" : (hoverArea.containsMouse ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1)
        
        border.width: 0

        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // Clipped visualizer container matching pill border radius curve
        Item {
            id: visualizerContainer
            anchors.fill: parent
            anchors.leftMargin: 0
            anchors.rightMargin: 0
            anchors.topMargin: 1
            anchors.bottomMargin: 1

            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: visualizerContainer.width
                    height: visualizerContainer.height
                    radius: bgContainer.radius
                }
            }

            WaveVisualizer {
                id: visualizerBg
                anchors.fill: parent
                layer.enabled: false
                visible: opacity > 0
                opacity: (root.isPlaying && !GlobalStates.mediaControlsOpen && root.visualizerPoints.length > 0) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                live: root.isPlaying && !GlobalStates.mediaControlsOpen
                points: root.visualizerPoints
                maxVisualizerValue: 850
                smoothing: 1
                color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
            }
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton | Qt.RightButton | Qt.LeftButton
        onDoubleClicked: (event) => {
            if (event.button === Qt.LeftButton) {
                GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen;
            }
        }
        onPressed: (event) => {
            if (event.button === Qt.MiddleButton) {
                if (root.hasMedia && activePlayer) activePlayer.togglePlaying();
            } else if (event.button === Qt.BackButton) {
                if (root.hasMedia && activePlayer) activePlayer.previous();
            } else if (event.button === Qt.ForwardButton || event.button === Qt.RightButton) {
                if (root.hasMedia && activePlayer) activePlayer.next();
            } else if (event.button === Qt.LeftButton) {
                if (root.hasMedia) GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen;
                else GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen;
            }
        }
    }

    RowLayout {
        id: rowLayout
        spacing: 10
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 14

        // Contextual icon: quote sparkle / play-pause progress / paused
        Item {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 20
            implicitHeight: 20

            // Quote icon (no player active)
            StyledText {
                id: quoteIcon
                anchors.centerIn: parent
                text: "󰣇"
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colSubtext
                visible: !root.hasMedia
                opacity: visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            }

            // Circular progress with play/pause (player active)
            ClippedFilledCircularProgress {
                id: mediaCircProg
                anchors.centerIn: parent
                visible: root.hasMedia
                opacity: visible ? 1 : 0
                lineWidth: Appearance.rounding.unsharpen
                value: root.isLive ? 1 : (activePlayer?.position / activePlayer?.length)
                implicitSize: 20
                colPrimary: Appearance.colors.colSubtext
                enableAnimation: false

                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                Item {
                    anchors.centerIn: parent
                    width: mediaCircProg.implicitSize
                    height: mediaCircProg.implicitSize

                    MaterialSymbol {
                        anchors.centerIn: parent
                        fill: 1
                        text: root.isPlaying ? "pause" : "play_arrow"
                        iconSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }

        Item {
            id: topBarTextContainer
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: topBarMusicText.implicitHeight
            clip: true

            readonly property string displayText: {
                if (!root.hasMedia) {
                    return "Everything happens for a reason";
                }
                if (root.hasLyrics && LyricsService.currentLyricLine && LyricsService.currentLyricLine.length > 0) {
                    if (LyricsService.hasWordSync) {
                        return LyricsService.currentLyricLineDim || LyricsService.currentLyricLineRich || LyricsService.currentLyricLine;
                    }
                    return LyricsService.currentLyricLineRich || LyricsService.currentLyricLine;
                }
                let artistStr = MprisController.getPlayerArtists(activePlayer);
                let baseInfo = `${cleanedTitle}${artistStr ? ' • ' + artistStr : ''}`;
                if (LyricsService.isSupportedPlayer(activePlayer)) {
                    if (LyricsService.loading) {
                        return `${baseInfo} • ${LyricsService.loadingStatus}`;
                    }
                    if (LyricsService.lyricLines.length === 0) {
                        return LyricsService.hasUnsyncedLyrics ? `${baseInfo} • Unsynced lyrics` : `${baseInfo} • No lyrics`;
                    }
                }
                return baseInfo;
            }

            readonly property bool isOverflowing: width > 0 && topBarMusicText.implicitWidth > width + 5

            property string lastPlainLine: ""
            onDisplayTextChanged: {
                let currentPlain = root.hasLyrics ? LyricsService.currentLyricLine : displayText;
                if (currentPlain !== lastPlainLine) {
                    lastPlainLine = currentPlain;
                    topBarMarqueeAnim.stop();
                    topBarMarqueeRow.x = 0;
                    if (isOverflowing)
                        topBarMarqueeAnim.start();
                } else if (!topBarMarqueeAnim.running && isOverflowing) {
                    topBarMarqueeAnim.restart();
                }
            }
            onIsOverflowingChanged: {
                if (!isOverflowing) {
                    topBarMarqueeAnim.stop();
                    topBarMarqueeRow.x = 0;
                } else {
                    topBarMarqueeAnim.restart();
                }
            }

            Row {
                id: topBarMarqueeRow
                spacing: 36
                x: 0

                StyledText {
                    id: topBarMusicText
                    textFormat: root.hasLyrics ? Text.StyledText : Text.PlainText
                    color: Appearance.colors.colSubtext
                    text: topBarTextContainer.displayText

                    Item {
                        id: lyricClipOverlay
                        visible: root.hasLyrics && LyricsService.hasWordSync && LyricsService.currentLineProgress > 0
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Math.min(parent.implicitWidth, Math.max(0, parent.implicitWidth * LyricsService.currentLineProgress))
                        clip: true

                        StyledText {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: topBarMusicText.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                        }
                    }

                    Item {
                        id: multilineSlideOverlay
                        visible: root.hasLyrics && !LyricsService.hasWordSync && LyricsService.currentLineProgress > 0
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        x: Math.round(parent.implicitWidth * LyricsService.activeLineStartFraction)
                        width: Math.round(parent.implicitWidth * (LyricsService.activeLineEndFraction - LyricsService.activeLineStartFraction))
                        clip: true

                        Behavior on x {
                            enabled: LyricsService.allowHighlightSlide
                            NumberAnimation {
                                duration: 240
                                easing.type: Easing.OutCubic
                            }
                        }

                        Behavior on width {
                            enabled: LyricsService.allowHighlightSlide
                            NumberAnimation {
                                duration: 240
                                easing.type: Easing.OutCubic
                            }
                        }

                        StyledText {
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            x: -multilineSlideOverlay.x
                            width: topBarMusicText.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                        }
                    }
                }

                StyledText {
                    id: topBarMusicTextDup
                    visible: topBarTextContainer.isOverflowing && topBarMarqueeAnim.running
                    textFormat: root.hasLyrics ? Text.StyledText : Text.PlainText
                    color: Appearance.colors.colSubtext
                    text: visible ? topBarTextContainer.displayText : ""

                    Item {
                        id: lyricClipOverlayDup
                        visible: root.hasLyrics && LyricsService.hasWordSync && LyricsService.currentLineProgress > 0
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Math.min(parent.implicitWidth, Math.max(0, parent.implicitWidth * LyricsService.currentLineProgress))
                        clip: true

                        StyledText {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: topBarMusicTextDup.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                        }
                    }

                    Item {
                        id: multilineSlideOverlayDup
                        visible: multilineSlideOverlay.visible
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        x: multilineSlideOverlay.x
                        width: multilineSlideOverlay.width
                        clip: true

                        StyledText {
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            x: -multilineSlideOverlayDup.x
                            width: topBarMusicTextDup.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                        }
                    }
                }

                SequentialAnimation on x {
                    id: topBarMarqueeAnim
                    running: topBarTextContainer.isOverflowing
                    loops: Animation.Infinite
                    PauseAnimation { duration: 1800 }
                    NumberAnimation {
                        from: 0
                        to: -(topBarMusicText.implicitWidth + topBarMarqueeRow.spacing)
                        duration: Math.max(3000, topBarMusicText.implicitWidth * 25)
                    }
                }
            }
        }

        StyledText {
            id: trackTimeText
            visible: root.hasMedia && (root.isLive || (activePlayer?.length || 0) > 0)
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: {
                if (root.isLive) return Translation.tr("live");
                let pos = Math.max(0, activePlayer?.position || 0);
                let len = Math.max(0, activePlayer?.length || 0);
                let rem = Math.max(0, len - pos);
                return `-${StringUtils.friendlyTimeForSeconds(rem)}`;
            }
        }
    }
}
