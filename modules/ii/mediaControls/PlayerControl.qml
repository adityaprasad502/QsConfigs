pragma ComponentBehavior: Bound
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.widgets
import qs.services
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Widgets

Item { // Player instance
    id: root
    required property MprisPlayer player
    property string artUrl: player?.trackArtUrl ?? ""
    property string artDownloadLocation: Directories.coverArt
    property string artFileName: Qt.md5(artUrl)
    property string artFilePath: `${artDownloadLocation}/${artFileName}`
    property color artDominantColor: {
        if (!colorQuantizer || !colorQuantizer.colors || colorQuantizer.colors.length === 0) {
            return Appearance.colors.colPrimary;
        }
        let best = Appearance.colors.colPrimary;
        let bestScore = -1;
        for (let i = 0; i < colorQuantizer.colors.length; i++) {
            let c = colorQuantizer.colors[i];
            if (!c) continue;
            let sat = c.hslSaturation;
            let light = c.hslLightness;
            if (light < 0.08 || light > 0.94) continue;
            let score = sat * 2.2 + (1.0 - Math.abs(light - 0.5));
            if (score > bestScore && sat > 0.16) {
                bestScore = score;
                best = c;
            }
        }
        return bestScore > 0 ? best : Appearance.colors.colPrimary;
    }
    property bool downloaded: MprisController.isArtCached(root.artUrl) || (root.artUrl.length > 0 && root.artUrl.startsWith("file://"))
    readonly property bool isLive: MprisController.isLive(root.player)
    property list<real> visualizerPoints: []
    property real maxVisualizerValue: 850 // Max value in the data points
    property int visualizerSmoothing: 1 // Number of points to average for smoothing
    property real radius
    property real lastKnownPosition: 0
    property real lastKnownTimestamp: 0
    property real interpolatedPosition: root.player?.position || 0

    Connections {
        target: root.player
        function onPositionChanged() {
            root.lastKnownPosition = root.player?.position || 0;
            root.lastKnownTimestamp = Date.now();
            root.interpolatedPosition = root.lastKnownPosition;
        }
        function onPlaybackStateChanged() {
            root.lastKnownPosition = root.player?.position || 0;
            root.lastKnownTimestamp = Date.now();
            root.interpolatedPosition = root.lastKnownPosition;
        }
    }

    Timer {
        interval: 33
        repeat: true
        running: root.player?.isPlaying && root.visible
        onTriggered: {
            let pos = root.player?.position || 0;
            let elapsedSec = (Date.now() - root.lastKnownTimestamp) / 1000.0;
            if (Math.abs(pos - (root.lastKnownPosition + elapsedSec)) > 1.5) {
                root.lastKnownPosition = pos;
                root.lastKnownTimestamp = Date.now();
                elapsedSec = 0;
            }
            let len = root.player?.length || 0;
            if (len > 0) {
                root.interpolatedPosition = Math.min(len, root.lastKnownPosition + elapsedSec);
            } else {
                root.interpolatedPosition = root.lastKnownPosition + elapsedSec;
            }
        }
    }

    property string displayedArtFilePath: {
        if (!root.downloaded && !(root.artUrl && root.artUrl.startsWith("file://"))) return "";
        if (root.artUrl && root.artUrl.startsWith("file://")) return root.artUrl;
        return Qt.resolvedUrl(artFilePath);
    }

    Connections {
        target: MprisController
        function onArtPreloaded(url, path) {
            if (url === root.artUrl) {
                root.downloaded = true;
            }
        }
    }

    Component.onCompleted: {
        if (root.artUrl && !root.downloaded) {
            if (MprisController.isArtCached(root.artUrl)) {
                root.downloaded = true;
            } else {
                MprisController.preloadArt(root.artUrl);
                coverArtDownloader.targetFile = root.artUrl;
                coverArtDownloader.artFilePath = root.artFilePath;
                coverArtDownloader.running = true;
            }
        }
    }

    component TrackChangeButton: RippleButton {
        id: trackChangeBtn
        implicitWidth: 26
        implicitHeight: 26
        buttonRadius: 13
        padding: 0

        property var iconName
        colBackground: "transparent"
        colBackgroundHover: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.18)
        colRipple: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.30)

        contentItem: Item {
            MaterialSymbol {
                anchors.centerIn: parent
                iconSize: 20
                fill: 1
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: trackChangeBtn.hovered ? blendedColors.colPrimary : blendedColors.colSubtext
                text: trackChangeBtn.iconName

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }
        }
    }

    Timer { // Force update for revision
        running: root.player?.playbackState == MprisPlaybackState.Playing
        interval: Config.options.resources.updateInterval
        repeat: true
        onTriggered: {
            root.player.positionChanged()
        }
    }

    onArtFilePathChanged: {
        if (root.artUrl.length == 0) {
            root.artDominantColor = Appearance.colors.colPrimary;
            root.downloaded = false;
            return;
        }

        if (MprisController.isArtCached(root.artUrl)) {
            root.downloaded = true;
            return;
        }

        MprisController.preloadArt(root.artUrl);

        // Binding does not work in Process
        coverArtDownloader.targetFile = root.artUrl 
        coverArtDownloader.artFilePath = root.artFilePath
        // Download
        root.downloaded = false
        coverArtDownloader.running = true
    }

    Process { // Cover art downloader
        id: coverArtDownloader
        property string targetFile: root.artUrl
        property string artFilePath: root.artFilePath
        command: [ "bash", "-c", `mkdir -p '${Directories.coverArt}' && { [ -f '${artFilePath}' ] || curl -4 -sSL '${StringUtils.shellSingleQuoteEscape(targetFile)}' -o '${artFilePath}'; }` ]
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                MprisController.cachedArt[root.artUrl] = root.artFilePath;
                root.downloaded = true;
            }
        }
    }

    ColorQuantizer {
        id: colorQuantizer
        source: root.displayedArtFilePath
        depth: 2 // 2^2 = 4 colors
        rescaleSize: 16
    }

    TextMetrics {
        id: lyricMeasure
        font.family: Appearance?.font?.family?.main ?? ""
        font.pixelSize: Appearance?.font?.pixelSize?.small ?? 15
        font.variableAxes: Appearance?.font?.variableAxes?.main ?? ({})
    }

    readonly property real artAverageLightness: {
        if (!colorQuantizer || !colorQuantizer.colors || colorQuantizer.colors.length === 0) return 0.35;
        let sum = 0;
        let count = 0;
        for (let i = 0; i < colorQuantizer.colors.length; i++) {
            let c = colorQuantizer.colors[i];
            if (c) {
                sum += c.hslLightness;
                count++;
            }
        }
        return count > 0 ? (sum / count) : 0.35;
    }
    readonly property real _scrimBoost: Math.max(0, (root.artAverageLightness - 0.42) * 0.45)

    property QtObject blendedColors: AdaptedMaterialScheme {
        color: artDominantColor
    }

    StyledRectangularShadow {
        target: background
    }
    Rectangle { // Background
        id: background
        anchors.fill: parent
        anchors.margins: Appearance.sizes.elevationMargin
        color: blendedColors.colLayer0
        radius: root.radius

        // Clipped backdrop (ambient blur, gradient, visualizer) isolated to avoid texture downsampling on UI
        Item {
            id: backdropContainer
            anchors.fill: parent
            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: backdropContainer.width
                    height: backdropContainer.height
                    radius: background.radius
                }
            }

            // Vibrant ambient blur of the album art across the backdrop
            StyledImage {
                id: blurredArt
                anchors.fill: parent
                source: root.displayedArtFilePath
                fillMode: Image.PreserveAspectCrop
                cache: false
                antialiasing: true
                asynchronous: true
                visible: root.displayedArtFilePath !== ""
                opacity: Math.max(0.54, 0.72 - root._scrimBoost * 0.7)

                layer.enabled: true
                layer.effect: MultiEffect {
                    source: blurredArt
                    saturation: 1.32
                    brightness: 0.01
                    blurEnabled: true
                    blurMax: 60
                    blur: 0.78
                }
            }

            // Gentle contrast scrim preserving album-art glow while keeping typography crisp
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0.0
                        color: ColorUtils.applyAlpha(blendedColors.colLayer0, Math.min(0.36, 0.16 + root._scrimBoost * 0.65))
                    }
                    GradientStop {
                        position: 0.45
                        color: ColorUtils.applyAlpha(blendedColors.colLayer0, Math.min(0.52, 0.34 + root._scrimBoost * 0.65))
                    }
                    GradientStop {
                        position: 1.0
                        color: ColorUtils.applyAlpha(blendedColors.colLayer0, Math.min(0.66, 0.52 + root._scrimBoost * 0.40))
                    }
                }
            }

            // Subtle ambient wave visualizer dancing in the lower backdrop
            WaveVisualizer {
                id: visualizerCanvas
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: parent.height * 0.55
                live: root.player?.isPlaying
                opacity: 0.26
                points: root.visualizerPoints
                maxVisualizerValue: root.maxVisualizerValue
                smoothing: root.visualizerSmoothing
                color: blendedColors.colPrimary
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (root.player && MprisController.activePlayer !== root.player) {
                    MprisController.setActivePlayer(root.player);
                }
            }
        }

        RowLayout {
            id: mainRow
            anchors.fill: parent
            anchors.margins: 13
            spacing: 14

            Rectangle { // Dedicated album art thumbnail
                id: artBackground
                Layout.fillHeight: true
                implicitWidth: height
                radius: Appearance.rounding.small
                color: ColorUtils.transparentize(blendedColors.colLayer1, 0.5)

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: artBackground.width
                        height: artBackground.height
                        radius: artBackground.radius
                    }
                }

                StyledImage { // Art image
                    id: mediaArt
                    anchors.fill: parent
                    source: root.displayedArtFilePath
                    fillMode: Image.PreserveAspectCrop
                    cache: false
                    antialiasing: true
                    asynchronous: true
                }

                Rectangle {
                    id: appIconBadge
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.margins: 5
                    width: 22
                    height: 22
                    radius: Appearance.rounding.full
                    color: ColorUtils.applyAlpha(blendedColors.colLayer0, 0.88)
                    visible: appIconImage.status === Image.Ready && appIconImage.source != ""

                    IconImage {
                        id: appIconImage
                        anchors.centerIn: parent
                        implicitSize: 14
                        asynchronous: true
                        source: {
                            let entry = root.player?.desktopEntry || root.player?.identity || "";
                            return Quickshell.iconPath(AppSearch.guessIcon(entry), "");
                        }
                    }
                }
            }

            ColumnLayout { // Info & controls right of album art
                id: infoColumn
                Layout.fillHeight: true
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    id: titleRow
                    Layout.fillWidth: true
                    spacing: 8

                    Item {
                        id: titleMarqueeContainer
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        implicitHeight: trackTitleText.implicitHeight
                        clip: true

                        readonly property bool isOverflowing: width > 0 && trackTitleText.implicitWidth > width + 5
                        readonly property string rawTitle: root.player?.trackTitle || "Untitled"

                        onRawTitleChanged: {
                            marqueeAnim.stop();
                            marqueeRow.x = 0;
                            if (isOverflowing)
                                marqueeAnim.start();
                        }
                        onIsOverflowingChanged: {
                            if (!isOverflowing) {
                                marqueeAnim.stop();
                                marqueeRow.x = 0;
                            } else {
                                marqueeAnim.restart();
                            }
                        }

                        Row {
                            id: marqueeRow
                            spacing: 40
                            x: 0

                            StyledText {
                                id: trackTitleText
                                font.pixelSize: Appearance.font.pixelSize.large
                                color: blendedColors.colOnLayer0
                                textFormat: Text.PlainText
                                text: titleMarqueeContainer.rawTitle
                            }

                            StyledText {
                                visible: titleMarqueeContainer.isOverflowing && marqueeAnim.running
                                font.pixelSize: Appearance.font.pixelSize.large
                                color: blendedColors.colOnLayer0
                                textFormat: Text.PlainText
                                text: titleMarqueeContainer.rawTitle
                            }

                            SequentialAnimation on x {
                                id: marqueeAnim
                                running: titleMarqueeContainer.isOverflowing && root.visible
                                loops: Animation.Infinite
                                PauseAnimation { duration: 1800 }
                                NumberAnimation {
                                    from: 0
                                    to: -(trackTitleText.implicitWidth + marqueeRow.spacing)
                                    duration: Math.max(3000, trackTitleText.implicitWidth * 28)
                                }
                            }
                        }
                    }

                    // Right-side sync controls: session device latency toggle + per-song offset stepper
                    RowLayout {
                        id: syncControlsRow
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        spacing: 6
                        visible: LyricsService.isSupportedPlayer(root.player) && root.player === LyricsService.activePlayer && LyricsService.lyricLines.length > 0

                        property real _latencyWheelAccum: 0
                        property real _offsetWheelAccum: 0

                        function _consumeWheel(event, isLatency) {
                            let dy = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y;
                            if (!dy) return;
                            let accum = isLatency ? _latencyWheelAccum : _offsetWheelAccum;
                            if ((dy > 0 && accum < 0) || (dy < 0 && accum > 0)) accum = 0;
                            let stepDelta = 0;
                            if (Math.abs(dy) >= 60) {
                                accum = 0;
                                stepDelta = dy > 0 ? 5 : -5;
                            } else {
                                accum += dy;
                                if (Math.abs(accum) >= 60) {
                                    stepDelta = accum > 0 ? 5 : -5;
                                    accum = 0;
                                }
                            }
                            if (isLatency) _latencyWheelAccum = accum;
                            else _offsetWheelAccum = accum;
                            if (stepDelta !== 0) {
                                if (isLatency) LyricsService.adjustDeviceLatency(stepDelta);
                                else LyricsService.adjustLyricsOffset(stepDelta);
                            }
                        }

                        RippleButton {
                            id: deviceLatencyBtn
                            readonly property bool showMs: LyricsService.deviceLatencyEnabled || LyricsService.deviceLatencyMs !== 0
                            Layout.alignment: Qt.AlignVCenter
                            toggled: LyricsService.deviceLatencyEnabled
                            implicitHeight: 26
                            implicitWidth: showMs ? (latencyBtnRow.implicitWidth + 16) : 26
                            buttonRadius: 13
                            padding: 0
                            colBackground: ColorUtils.applyAlpha(blendedColors.colLayer1, 0.64)
                            colBackgroundHover: ColorUtils.applyAlpha(ColorUtils.mix(blendedColors.colLayer1, blendedColors.colOnLayer0, 0.86), 0.86)
                            colBackgroundToggled: blendedColors.colPrimary
                            colBackgroundToggledHover: ColorUtils.mix(blendedColors.colPrimary, blendedColors.colOnLayer0, 0.88)
                            colRipple: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.30)
                            colRippleToggled: ColorUtils.applyAlpha(blendedColors.colOnPrimary, 0.25)
                            downAction: () => LyricsService.toggleDeviceLatency()
                            altAction: () => LyricsService.resetDeviceLatency()
                            middleClickAction: () => LyricsService.resetDeviceLatency()
                            wheelAction: (event) => syncControlsRow._consumeWheel(event, true)

                            Behavior on implicitWidth {
                                NumberAnimation {
                                    duration: 180
                                    easing.type: Easing.OutCubic
                                }
                            }

                            contentItem: Item {
                                clip: true

                                RowLayout {
                                    id: latencyBtnRow
                                    anchors.centerIn: parent
                                    spacing: 4

                                    MaterialSymbol {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: LyricsService.isHeadphoneSink ? "headphones" : "speaker"
                                        iconSize: 15
                                        fill: deviceLatencyBtn.toggled ? 1 : 0
                                        color: deviceLatencyBtn.toggled
                                            ? blendedColors.colOnPrimary
                                            : (deviceLatencyBtn.hovered ? blendedColors.colOnLayer0 : ColorUtils.applyAlpha(blendedColors.colOnLayer0, 0.82))

                                        Behavior on color {
                                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                        }
                                    }

                                    StyledText {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: deviceLatencyBtn.showMs
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        font.family: Appearance.font.family.numbers
                                        font.weight: deviceLatencyBtn.toggled ? Font.DemiBold : Font.Medium
                                        color: deviceLatencyBtn.toggled
                                            ? blendedColors.colOnPrimary
                                            : (deviceLatencyBtn.hovered ? blendedColors.colOnLayer0 : ColorUtils.applyAlpha(blendedColors.colOnLayer0, 0.80))
                                        text: LyricsService.deviceLatencyMs + "ms"

                                        Behavior on color {
                                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                        }
                                    }
                                }
                            }

                            StyledToolTip {
                                text: LyricsService.deviceLatencyEnabled
                                    ? `${LyricsService.audioSinkName} • ${LyricsService.deviceLatencyMs}ms active (session)\nScroll: ±5ms • Click: Disable • Right-click: Reset`
                                    : `${LyricsService.audioSinkName} • Latency off${LyricsService.deviceLatencyMs > 0 ? ` (${LyricsService.deviceLatencyMs}ms detected)` : ""}\nClick: Enable • Scroll: ±5ms`
                            }
                        }

                        // Per-song lyrics sync offset (scroll ±5ms, click to reset)
                        RippleButton {
                            id: lyricsOffsetBtn
                            Layout.alignment: Qt.AlignVCenter
                            toggled: LyricsService.lyricsOffsetMs !== 0
                            implicitHeight: 26
                            implicitWidth: LyricsService.lyricsOffsetMs !== 0 ? (offsetBtnRow.implicitWidth + 16) : 26
                            buttonRadius: 13
                            padding: 0
                            colBackground: ColorUtils.applyAlpha(blendedColors.colLayer1, 0.64)
                            colBackgroundHover: ColorUtils.applyAlpha(ColorUtils.mix(blendedColors.colLayer1, blendedColors.colOnLayer0, 0.86), 0.86)
                            colBackgroundToggled: blendedColors.colPrimary
                            colBackgroundToggledHover: ColorUtils.mix(blendedColors.colPrimary, blendedColors.colOnLayer0, 0.88)
                            colRipple: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.30)
                            colRippleToggled: ColorUtils.applyAlpha(blendedColors.colOnPrimary, 0.25)
                            downAction: () => LyricsService.resetLyricsOffset()
                            altAction: () => LyricsService.resetLyricsOffset()
                            middleClickAction: () => LyricsService.resetLyricsOffset()
                            wheelAction: (event) => syncControlsRow._consumeWheel(event, false)

                            Behavior on implicitWidth {
                                NumberAnimation {
                                    duration: 180
                                    easing.type: Easing.OutCubic
                                }
                            }

                            contentItem: Item {
                                clip: true

                                RowLayout {
                                    id: offsetBtnRow
                                    anchors.centerIn: parent
                                    spacing: 4

                                    MaterialSymbol {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: "lyrics"
                                        iconSize: 15
                                        fill: lyricsOffsetBtn.toggled ? 1 : 0
                                        color: lyricsOffsetBtn.toggled
                                            ? blendedColors.colOnPrimary
                                            : (lyricsOffsetBtn.hovered ? blendedColors.colOnLayer0 : ColorUtils.applyAlpha(blendedColors.colOnLayer0, 0.82))

                                        Behavior on color {
                                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                        }
                                    }

                                    StyledText {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: LyricsService.lyricsOffsetMs !== 0
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        font.family: Appearance.font.family.numbers
                                        font.weight: Font.DemiBold
                                        color: blendedColors.colOnPrimary
                                        text: (LyricsService.lyricsOffsetMs > 0 ? "+" : "") + LyricsService.lyricsOffsetMs + "ms"
                                    }
                                }
                            }

                            StyledToolTip {
                                text: LyricsService.lyricsOffsetMs !== 0
                                    ? `Song offset: ${(LyricsService.lyricsOffsetMs > 0 ? "+" : "") + LyricsService.lyricsOffsetMs}ms (saved)\nScroll: ±5ms • Click: Reset to 0ms`
                                    : "Song offset: 0ms (saved per track)\nScroll: ±5ms"
                            }
                        }
                    }

                    RippleButton {
                        id: playPauseButton
                        Layout.alignment: Qt.AlignVCenter
                        property real size: 32
                        implicitWidth: size
                        implicitHeight: size
                        padding: 0
                        downAction: () => root.player.togglePlaying();

                        buttonRadius: size / 2
                        colBackground: root.player?.isPlaying ? blendedColors.colPrimary : blendedColors.colSecondaryContainer
                        colBackgroundHover: root.player?.isPlaying ? blendedColors.colPrimaryHover : blendedColors.colPrimary
                        colRipple: root.player?.isPlaying ? blendedColors.colPrimaryActive : blendedColors.colSecondaryContainerActive

                        contentItem: Item {
                            MaterialSymbol {
                                anchors.centerIn: parent
                                iconSize: 20
                                fill: 1
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: {
                                    if (root.player?.isPlaying) {
                                        return blendedColors.colOnPrimary;
                                    } else {
                                        return playPauseButton.hovered ? blendedColors.colOnPrimary : blendedColors.colOnSecondaryContainer;
                                    }
                                }
                                text: root.player?.isPlaying ? "pause" : "play_arrow"

                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                }
                            }
                        }
                    }
                }

                // Full-width artist / album row spanning beneath the title
                Item {
                    id: artistMarqueeContainer
                    Layout.fillWidth: true
                    implicitHeight: trackArtistText.implicitHeight
                    clip: true

                    readonly property bool isOverflowing: width > 0 && trackArtistText.implicitWidth > width + 5
                    readonly property string rawSubtitle: {
                        let artist = MprisController.getPlayerArtists(root.player);
                        let album = root.player?.trackAlbum || "";
                        let title = root.player?.trackTitle || "";
                        if (artist && album && album !== title && !title.includes(album) && artist !== album && !artist.includes(album)) {
                            return `${artist} • ${album}`;
                        }
                        return artist || album;
                    }

                    onRawSubtitleChanged: {
                        artistMarqueeAnim.stop();
                        artistMarqueeRow.x = 0;
                        if (isOverflowing)
                            artistMarqueeAnim.start();
                    }
                    onIsOverflowingChanged: {
                        if (!isOverflowing) {
                            artistMarqueeAnim.stop();
                            artistMarqueeRow.x = 0;
                        } else {
                            artistMarqueeAnim.restart();
                        }
                    }

                    Row {
                        id: artistMarqueeRow
                        spacing: 40
                        x: 0

                        StyledText {
                            id: trackArtistText
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: blendedColors.colSubtext
                            textFormat: Text.PlainText
                            text: artistMarqueeContainer.rawSubtitle
                        }

                        StyledText {
                            visible: artistMarqueeContainer.isOverflowing && artistMarqueeAnim.running
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: blendedColors.colSubtext
                            textFormat: Text.PlainText
                            text: artistMarqueeContainer.rawSubtitle
                        }

                        SequentialAnimation on x {
                            id: artistMarqueeAnim
                            running: artistMarqueeContainer.isOverflowing && root.visible
                            loops: Animation.Infinite
                            PauseAnimation { duration: 2200 }
                            NumberAnimation {
                                from: 0
                                to: -(trackArtistText.implicitWidth + artistMarqueeRow.spacing)
                                duration: Math.max(3000, trackArtistText.implicitWidth * 28)
                            }
                        }
                    }
                }

                Item {
                    Layout.fillHeight: true
                }

                StyledText {
                    id: popupNextLyric
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: LyricsService.lyricLines.length > 0
                        ? ColorUtils.applyAlpha(blendedColors.colOnLayer0, 0.94)
                        : blendedColors.colSubtext
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    clip: true

                    readonly property int totalWordCount: {
                        let lines = LyricsService.lyricLines;
                        if (!lines || lines.length === 0) return 0;
                        let count = 0;
                        for (let i = 0; i < lines.length; i++) {
                            let txt = lines[i]?.text;
                            if (!txt || txt === "♪") continue;
                            let tokens = txt.trim().split(/\s+/);
                            for (let j = 0; j < tokens.length; j++) {
                                let w = tokens[j].replace(/[\s.,\-_~*+=!?\u2026\u2014\u2013\u2018-\u201f\u2022\u00b7\u266a\u266b\u266c\u3001\u3002\uff0c\uff01\uff1f\u300a\u300b()\[\]{}<>\/\\|:;'"`^#@&%$¡¿]+/g, "");
                                if (w.length > 0) count++;
                            }
                        }
                        return count;
                    }

                    readonly property string rawNextLyric: {
                        if (root.player !== LyricsService.activePlayer || !LyricsService.isSupportedPlayer(root.player)) return "";
                        if (LyricsService.lyricLines.length > 0) {
                            if (LyricsService.nextLyricLine && LyricsService.nextLyricLine.length > 0) {
                                return LyricsService.nextLyricLine;
                            }
                            let lineCount = LyricsService.lyricLines.length;
                            let totalLines = lineCount + (lineCount === 1 ? " line" : " lines");
                            let wordCount = popupNextLyric.totalWordCount;
                            let totalWords = wordCount > 0 ? (wordCount + (wordCount === 1 ? " word" : " words")) : "";
                            let syncType = LyricsService.hasWordSync ? "Word-synced" : "Line-synced";
                            let source = LyricsService.lyricsSourceDisplayName;
                            let offsetInfo = LyricsService.lyricsOffsetMs !== 0
                                ? ((LyricsService.lyricsOffsetMs > 0 ? "+" : "") + LyricsService.lyricsOffsetMs + "ms")
                                : "";

                            let stats = [totalLines];
                            if (totalWords) stats.push(totalWords);
                            stats.push(syncType);
                            if (source) stats.push(source);
                            if (offsetInfo) stats.push(offsetInfo);

                            return "♫ " + stats.join(" • ");
                        }
                        if (LyricsService.loading) return "Fetching lyrics…";
                        return "No lyrics available";
                    }

                    property string clippedNextLyric: ""

                    function _updateClippedLyric() {
                        let rawText = popupNextLyric.rawNextLyric;
                        if (!rawText || infoColumn.width <= 0) {
                            popupNextLyric.clippedNextLyric = rawText || "";
                            return;
                        }
                        let totalInset = Math.min(72, infoColumn.width * 0.22);
                        let allocated = Math.max(80, infoColumn.width - totalInset);
                        let grace = 18; // Allow ~2-3 extra characters rather than awkward truncation

                        lyricMeasure.text = rawText;
                        if (lyricMeasure.advanceWidth <= allocated + grace) {
                            popupNextLyric.clippedNextLyric = rawText;
                            return;
                        }

                        let words = rawText.trim().split(/\s+/);
                        if (words.length <= 1) {
                            popupNextLyric.clippedNextLyric = rawText;
                            return;
                        }

                        let lo = 1;
                        let hi = words.length - 1;
                        let best = "";
                        while (lo <= hi) {
                            let mid = (lo + hi) >> 1;
                            let candidate = words.slice(0, mid).join(" ").replace(/[\s•,;:\-–—]+$/, "");
                            if (!candidate) {
                                lo = mid + 1;
                                continue;
                            }
                            let clipped = candidate + "...";
                            lyricMeasure.text = clipped;
                            if (lyricMeasure.advanceWidth <= allocated) {
                                best = clipped;
                                lo = mid + 1;
                            } else {
                                hi = mid - 1;
                            }
                        }
                        popupNextLyric.clippedNextLyric = best || rawText;
                    }

                    onRawNextLyricChanged: _updateClippedLyric()
                    Component.onCompleted: _updateClippedLyric()

                    Connections {
                        target: infoColumn
                        function onWidthChanged() {
                            popupNextLyric._updateClippedLyric();
                        }
                    }

                    text: clippedNextLyric
                }

                RowLayout {
                    id: controlRow
                    Layout.fillWidth: true
                    implicitHeight: 28
                    spacing: 6

                    TrackChangeButton {
                        Layout.alignment: Qt.AlignVCenter
                        iconName: "skip_previous"
                        downAction: () => root.player?.previous()
                    }

                    StyledText {
                        id: trackTimeLeft
                        Layout.preferredWidth: 36
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignRight
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: blendedColors.colSubtext
                        elide: Text.ElideRight
                        text: {
                            if (root.isLive) {
                                return StringUtils.friendlyTimeForSeconds(root.player?.position);
                            }
                            let len = root.player?.length || 0;
                            let pos = root.interpolatedPosition || root.player?.position || 0;
                            return StringUtils.friendlyTimeForSeconds(len > 0 ? Math.min(len, pos) : pos);
                        }
                    }

                    Item {
                        id: progressBarContainer
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        implicitHeight: Math.max(sliderLoader.implicitHeight, progressBarLoader.implicitHeight, 24)

                        Loader {
                            id: sliderLoader
                            anchors.fill: parent
                            active: (root.player?.canSeek ?? false) && !root.isLive
                            sourceComponent: StyledSlider {
                                configuration: StyledSlider.Configuration.Wavy
                                highlightColor: blendedColors.colPrimary
                                trackColor: blendedColors.colSecondaryContainer
                                handleColor: blendedColors.colPrimary
                                value: root.interpolatedPosition / root.player?.length
                                onMoved: {
                                    let newPos = value * root.player.length;
                                    root.player.position = newPos;
                                    root.lastKnownPosition = newPos;
                                    root.lastKnownTimestamp = Date.now();
                                    root.interpolatedPosition = newPos;
                                }
                            }
                        }

                        Loader {
                            id: progressBarLoader
                            anchors {
                                verticalCenter: parent.verticalCenter
                                left: parent.left
                                right: parent.right
                            }
                            active: !(root.player?.canSeek ?? false) || root.isLive
                            sourceComponent: StyledProgressBar {
                                wavy: root.player?.isPlaying
                                highlightColor: blendedColors.colPrimary
                                trackColor: blendedColors.colSecondaryContainer
                                value: (root.isLive && (root.player?.length || 0) <= 0) ? 1 : (root.interpolatedPosition / (root.player?.length || 1))
                            }
                        }
                    }

                    StyledText {
                        id: trackTimeRight
                        Layout.preferredWidth: 36
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignLeft
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: blendedColors.colSubtext
                        elide: Text.ElideRight
                        text: root.isLive ? Translation.tr("live") : StringUtils.friendlyTimeForSeconds(root.player?.length)
                    }

                    TrackChangeButton {
                        Layout.alignment: Qt.AlignVCenter
                        iconName: "skip_next"
                        downAction: () => root.player?.next()
                    }
                }
            }
        }
    }
}