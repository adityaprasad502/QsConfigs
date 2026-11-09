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
    readonly property bool isLive: MprisController.isLive(activePlayer)
    readonly property bool isFinished: MprisController.isFinished(activePlayer)
    readonly property bool isPlaying: activePlayer?.playbackState === MprisPlaybackState.Playing && !root.isFinished
    readonly property bool isPaused: activePlayer != null && !root.isPlaying && !root.isFinished
    readonly property bool hasMedia: activePlayer != null && !root.isFinished && (root.isPlaying || (StringUtils.cleanMusicTitle(activePlayer?.trackTitle) || "") !== "")
    readonly property bool hasLyrics: root.hasMedia && root.isPlaying && ((LyricsService.currentLyricLine && LyricsService.currentLyricLine.length > 0) || LyricsService.lyricLines.length > 0)
    readonly property color placeholderColor: ColorUtils.mix(Appearance.colors.colSubtext, Appearance.colors.colLayer0, 0.70)

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
                color: root.placeholderColor
                visible: !root.hasMedia
                opacity: visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            }

            // Circular progress ring with play/pause (player active)
            CircularProgress {
                id: mediaCircProg
                anchors.centerIn: parent
                visible: root.hasMedia
                opacity: visible ? 0.80 : 0
                lineWidth: 2
                value: root.isLive ? 1 : (activePlayer?.position / activePlayer?.length)
                implicitSize: 20
                colPrimary: Appearance.colors.colPrimary
                colSecondary: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.6)
                enableAnimation: false
                gapAngle: 0
                scale: hoverArea.containsMouse ? 1.08 : 1.0

                Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                MaterialSymbol {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: 1
                    fill: 1
                    text: root.isPlaying ? "pause" : "play_arrow"
                    iconSize: 12
                    color: Appearance.colors.colOnLayer0
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
            readonly property real endMargin: 20
            readonly property real maxScroll: Math.max(0, topBarMusicText.implicitWidth - width + endMargin)
            readonly property real anchorX: width * 0.40

            property real minFollowerX: 0
            property string lastLineKey: ""

            readonly property real targetScrollX: {
                if (!root.hasLyrics || !isOverflowing) return 0;
                let activeX = LyricsService.hasWordSync
                    ? LyricsService.currentSweepX
                    : (topBarMusicText.implicitWidth * (LyricsService.currentLineProgress || 0));
                if (activeX <= anchorX) return 0;
                let scroll = -(activeX - anchorX);
                return Math.max(-maxScroll, scroll);
            }

            function triggerTrackMarquee() {
                topBarMarqueeAnim.stop();
                topBarMarqueeRow.x = 0;
                if (!isOverflowing || root.hasLyrics) return;
                marqueePauseAnim.duration = 1800;
                marqueeScrollAnim.duration = Math.max(3000, topBarMusicText.implicitWidth * 25);
                marqueeScrollAnim.from = 0;
                marqueeScrollAnim.to = -(topBarMusicText.implicitWidth + topBarMarqueeRow.spacing);
                marqueeScrollAnim.easing.type = Easing.Linear;
                topBarMarqueeAnim.restart();
            }

            FrameAnimation {
                id: marqueeFollower
                running: root.hasLyrics && topBarTextContainer.isOverflowing && root.isPlaying
                onTriggered: {
                    let activeX = LyricsService.hasWordSync
                        ? LyricsService.currentSweepX
                        : (topBarMusicText.implicitWidth * (LyricsService.currentLineProgress || 0));

                    // At the start of the line (first 40%), stay strictly anchored at 0
                    if (activeX <= topBarTextContainer.anchorX) {
                        topBarTextContainer.minFollowerX = 0;
                        if (Math.abs(topBarMarqueeRow.x) > 0.05) {
                            let dt = Math.max(0.001, Math.min(0.05, frameTime));
                            topBarMarqueeRow.x = topBarMarqueeRow.x * Math.exp(-12.0 * dt);
                        } else {
                            topBarMarqueeRow.x = 0;
                        }
                        return;
                    }

                    // Active vocal passed 40%: monotonic forward tracking
                    let rawTarget = topBarTextContainer.targetScrollX;
                    if (rawTarget < topBarTextContainer.minFollowerX) {
                        topBarTextContainer.minFollowerX = rawTarget;
                    }

                    let forwardTarget = topBarTextContainer.minFollowerX;
                    let current = topBarMarqueeRow.x;
                    let diff = forwardTarget - current;

                    if (Math.abs(diff) < 0.1) {
                        topBarMarqueeRow.x = forwardTarget;
                    } else {
                        let dt = Math.max(0.001, Math.min(0.05, frameTime));
                        // Soft, cinematic gimbal follower: responsive yet buttery smooth
                        let speed = 7.0;
                        let step = diff * (1.0 - Math.exp(-speed * dt));
                        topBarMarqueeRow.x = current + step;
                    }
                }
            }

            onDisplayTextChanged: {
                let currentKey = root.hasLyrics
                    ? `${LyricsService.currentGroupStartIdx}:${LyricsService.currentLyricLine}`
                    : displayText;
                if (currentKey !== lastLineKey) {
                    lastLineKey = currentKey;
                    minFollowerX = 0;
                    topBarMarqueeRow.x = 0;
                    if (!root.hasLyrics && isOverflowing) {
                        triggerTrackMarquee();
                    }
                }
            }
            onIsOverflowingChanged: {
                if (!isOverflowing) {
                    minFollowerX = 0;
                    topBarMarqueeRow.x = 0;
                    topBarMarqueeAnim.stop();
                } else if (!root.hasLyrics && !topBarMarqueeAnim.running) {
                    triggerTrackMarquee();
                }
            }

            Connections {
                target: root
                function onHasLyricsChanged() {
                    topBarTextContainer.minFollowerX = 0;
                    topBarMarqueeRow.x = 0;
                    if (!root.hasLyrics && topBarTextContainer.isOverflowing) {
                        topBarTextContainer.triggerTrackMarquee();
                    } else {
                        topBarMarqueeAnim.stop();
                    }
                }
            }

            Connections {
                target: LyricsService
                function onCurrentGroupStartIdxChanged() {
                    topBarTextContainer.minFollowerX = 0;
                    topBarMarqueeRow.x = 0;
                }
                function onSeekEpochChanged() {
                    topBarTextContainer.minFollowerX = 0;
                    topBarMarqueeRow.x = 0;
                }
            }

            Row {
                id: topBarMarqueeRow
                spacing: 36
                x: 0
                layer.enabled: topBarTextContainer.isOverflowing
                layer.smooth: true

                StyledText {
                    id: topBarMusicText
                    textFormat: root.hasLyrics ? Text.StyledText : Text.PlainText
                    color: root.hasLyrics ? ColorUtils.mix(Appearance.colors.colSubtext, Appearance.colors.colLayer0, 0.48) : (root.hasMedia ? Appearance.colors.colSubtext : ColorUtils.mix(Appearance.colors.colSubtext, Appearance.colors.colLayer0, 0.70))
                    text: topBarTextContainer.displayText
                    font.weight: Font.Normal
                    font.variableAxes: ({ "wght": 400 })

                    Item {
                        id: lyricPastOverlay
                        visible: root.hasLyrics && LyricsService.hasWordSync && LyricsService.currentPastWidth > 0.5
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        x: 0
                        width: Math.min(parent.implicitWidth,
                            Math.max(0, LyricsService.currentPastWidth > 2.0 ? LyricsService.currentPastWidth - 1.2 : LyricsService.currentPastWidth))
                        clip: true

                        StyledText {
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            x: 0
                            width: topBarMusicText.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                            font.weight: Font.Normal
                            font.variableAxes: ({ "wght": 400 })
                        }
                    }

                    Item {
                        id: lyricClipOverlay
                        readonly property real rawStartX: LyricsService.currentLeadStartX
                        readonly property real snappedX: Math.floor(rawStartX)
                        visible: root.hasLyrics && LyricsService.hasWordSync
                            && LyricsService.currentLeadWidth > 0 && LyricsService.currentLeadProgress > 0
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        x: snappedX
                        width: Math.min(parent.implicitWidth - x,
                            Math.max(0, (rawStartX - x) + LyricsService.currentLeadWidth * LyricsService.currentLeadProgress))
                        clip: true
                        layer.enabled: true
                        layer.smooth: true
                        layer.effect: OpacityMask {
                            maskSource: Item {
                                width: lyricClipOverlay.width
                                height: lyricClipOverlay.height
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.right: leadFade.left
                                    color: "#ffffff"
                                }
                                Rectangle {
                                    id: leadFade
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.right: parent.right
                                    width: Math.min(8, Math.min(parent.width, Math.max(0, (1.0 - LyricsService.currentLeadProgress) * 40)))
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#ffffff" }
                                        GradientStop { position: 1.0; color: "#00ffffff" }
                                    }
                                }
                            }
                        }

                        StyledText {
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            x: -lyricClipOverlay.x
                            width: topBarMusicText.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                            font.weight: Font.Normal
                            font.variableAxes: ({ "wght": 400 })
                        }
                    }

                    Item {
                        id: lyricBgClipOverlay
                        readonly property real rawStartX: LyricsService.currentBgStartX
                        readonly property real snappedX: Math.floor(rawStartX)
                        visible: root.hasLyrics && LyricsService.hasWordSync && LyricsService.currentLineHasBg
                            && LyricsService.currentBgWidth > 0 && LyricsService.currentBgProgress > 0
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        x: snappedX
                        width: Math.min(parent.implicitWidth - x,
                            Math.max(0, (rawStartX - x) + LyricsService.currentBgWidth * LyricsService.currentBgProgress))
                        clip: true
                        layer.enabled: true
                        layer.smooth: true
                        layer.effect: OpacityMask {
                            maskSource: Item {
                                width: lyricBgClipOverlay.width
                                height: lyricBgClipOverlay.height
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.right: bgFade.left
                                    color: "#ffffff"
                                }
                                Rectangle {
                                    id: bgFade
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.right: parent.right
                                    width: Math.min(8, Math.min(parent.width, Math.max(0, (1.0 - LyricsService.currentBgProgress) * 40)))
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#ffffff" }
                                        GradientStop { position: 1.0; color: "#00ffffff" }
                                    }
                                }
                            }
                        }

                        StyledText {
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            x: -lyricBgClipOverlay.x
                            width: topBarMusicText.implicitWidth
                            textFormat: Text.StyledText
                            text: visible ? LyricsService.currentLyricLineLit : ""
                            font.weight: Font.Normal
                            font.variableAxes: ({ "wght": 400 })
                        }
                    }

                    Item {
                        id: multilineSlideOverlay
                        visible: root.hasLyrics && !LyricsService.hasWordSync && LyricsService.isMultiLineGroup && LyricsService.currentLineProgress > 0
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
                            font.weight: Font.Normal
                            font.variableAxes: ({ "wght": 400 })
                        }
                    }
                }

                StyledText {
                    id: topBarMusicTextDup
                    visible: !root.hasLyrics && topBarTextContainer.isOverflowing && topBarMarqueeAnim.running
                    color: Appearance.colors.colSubtext
                    text: visible ? topBarTextContainer.displayText : ""
                }

                SequentialAnimation {
                    id: topBarMarqueeAnim
                    running: false
                    paused: running && !root.isPlaying
                    loops: Animation.Infinite
                    PauseAnimation {
                        id: marqueePauseAnim
                        duration: 1800
                    }
                    NumberAnimation {
                        id: marqueeScrollAnim
                        target: topBarMarqueeRow
                        property: "x"
                        from: 0
                        to: 0
                        duration: 3000
                        easing.type: Easing.Linear
                    }
                }
            }
        }

        StyledText {
            id: trackTimeText
            visible: root.hasMedia && (root.isLive || (activePlayer?.length || 0) > 0)
            Layout.alignment: Qt.AlignVCenter
            Layout.leftMargin: 10
            Layout.preferredWidth: 46
            horizontalAlignment: Text.AlignRight
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
