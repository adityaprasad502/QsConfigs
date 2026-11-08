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

        property var iconName
        colBackground: "transparent"
        colBackgroundHover: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.18)
        colRipple: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.30)

        contentItem: MaterialSymbol {
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
                opacity: 0.65

                layer.enabled: true
                layer.effect: MultiEffect {
                    source: blurredArt
                    saturation: 1.35
                    brightness: 0.04
                    blurEnabled: true
                    blurMax: 70
                    blur: 0.90
                }
            }

            // Smooth contrast gradient: luminous ambient tint on left, gentle scrim on right for crisp text contrast
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0.0
                        color: ColorUtils.applyAlpha(blendedColors.colLayer0, 0.18)
                    }
                    GradientStop {
                        position: 0.40
                        color: ColorUtils.applyAlpha(blendedColors.colLayer0, 0.42)
                    }
                    GradientStop {
                        position: 1.0
                        color: ColorUtils.applyAlpha(blendedColors.colLayer0, 0.62)
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
                opacity: 0.32
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
            spacing: 16

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

            ColumnLayout { // Info & controls
                id: infoColumn
                Layout.fillHeight: true
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 12

                    // Track title & artist
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: 2

                        Item {
                            id: titleMarqueeContainer
                            Layout.fillWidth: true
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
                    }

                    // Lyrics sync offset stepper, aligned with the title block
                    Rectangle {
                        id: offsetPill
                        Layout.alignment: Qt.AlignTop | Qt.AlignRight
                        visible: LyricsService.isSupportedPlayer(root.player) && root.player === LyricsService.activePlayer && LyricsService.lyricLines.length > 0
                        implicitWidth: offsetRow.implicitWidth + 10
                        implicitHeight: 26
                        radius: height / 2
                        color: LyricsService.lyricsOffsetMs !== 0
                            ? ColorUtils.applyAlpha(blendedColors.colPrimary, 0.16)
                            : ColorUtils.applyAlpha(blendedColors.colLayer1, 0.45)

                        RowLayout {
                            id: offsetRow
                            anchors.centerIn: parent
                            spacing: 2

                            RippleButton {
                                id: offsetMinusBtn
                                implicitWidth: 20
                                implicitHeight: 20
                                buttonRadius: 10
                                colBackground: "transparent"
                                colBackgroundHover: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.22)
                                colRipple: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.35)
                                downAction: () => LyricsService.adjustLyricsOffset(-50)
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "remove"
                                    iconSize: 15
                                    fill: 1
                                    color: offsetMinusBtn.hovered
                                        ? blendedColors.colPrimary
                                        : (LyricsService.lyricsOffsetMs !== 0 ? blendedColors.colPrimary : blendedColors.colOnLayer0)

                                    Behavior on color {
                                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                    }
                                }
                            }

                            StyledText {
                                id: offsetLabel
                                Layout.preferredWidth: 44
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                font.family: Appearance.font.family.numbers
                                font.weight: Font.Medium
                                color: offsetLabelMouse.containsMouse
                                    ? blendedColors.colPrimary
                                    : (LyricsService.lyricsOffsetMs !== 0 ? blendedColors.colPrimary : blendedColors.colSubtext)
                                text: LyricsService.lyricsOffsetMs === 0 ? "0ms" : ((LyricsService.lyricsOffsetMs > 0 ? "+" : "") + LyricsService.lyricsOffsetMs + "ms")

                                Behavior on color {
                                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                }

                                MouseArea {
                                    id: offsetLabelMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: LyricsService.resetLyricsOffset()
                                }
                            }

                            RippleButton {
                                id: offsetPlusBtn
                                implicitWidth: 20
                                implicitHeight: 20
                                buttonRadius: 10
                                colBackground: "transparent"
                                colBackgroundHover: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.22)
                                colRipple: ColorUtils.applyAlpha(blendedColors.colPrimary, 0.35)
                                downAction: () => LyricsService.adjustLyricsOffset(50)
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "add"
                                    iconSize: 15
                                    fill: 1
                                    color: offsetPlusBtn.hovered
                                        ? blendedColors.colPrimary
                                        : (LyricsService.lyricsOffsetMs !== 0 ? blendedColors.colPrimary : blendedColors.colOnLayer0)

                                    Behavior on color {
                                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                                    }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.RightButton | Qt.MiddleButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton) {
                                    LyricsService.resetLyricsOffset();
                                }
                            }
                        }

                        HoverHandler {
                            id: pillHover
                        }

                        WheelHandler {
                            onWheel: (event) => {
                                if (event.angleDelta.y > 0) LyricsService.adjustLyricsOffset(50);
                                else if (event.angleDelta.y < 0) LyricsService.adjustLyricsOffset(-50);
                            }
                        }

                        StyledToolTip {
                            extraVisibleCondition: pillHover.hovered
                            alternativeVisibleCondition: pillHover.hovered
                            text: "Lyrics sync offset (Scroll: ±50ms, click ±0ms to reset)"
                        }
                    }
                }

                Item {
                    Layout.fillHeight: true
                }

                StyledText {
                    id: popupNextLyric
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: LyricsService.lyricLines.length > 0
                        ? ColorUtils.applyAlpha(blendedColors.colOnLayer0, 0.90)
                        : ColorUtils.applyAlpha(blendedColors.colSubtext, 0.80)
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    text: {
                        if (root.player !== LyricsService.activePlayer || !LyricsService.isSupportedPlayer(root.player)) return "";
                        if (LyricsService.lyricLines.length > 0) {
                            if (LyricsService.nextLyricLine && LyricsService.nextLyricLine.length > 0) {
                                return LyricsService.nextLyricLine;
                            }
                            let syncType = LyricsService.hasWordSync ? "Word-synced" : "Line-synced";
                            let totalLines = LyricsService.lyricLines.length + " lines";
                            let source = LyricsService.lyricsSourceDisplayName;
                            let offsetInfo = LyricsService.lyricsOffsetMs !== 0
                                ? ((LyricsService.lyricsOffsetMs > 0 ? "+" : "") + LyricsService.lyricsOffsetMs + "ms")
                                : "";

                            let stats = [totalLines, syncType];
                            if (source) stats.push(source);
                            if (offsetInfo) stats.push(offsetInfo);

                            return "♫ " + stats.join(" • ");
                        }
                        if (LyricsService.loading) return "Fetching lyrics…";
                        return "No lyrics available";
                    }
                }

                RowLayout {
                    id: controlRow
                    Layout.fillWidth: true
                    implicitHeight: 40
                    spacing: 8

                    StyledText {
                        id: trackTimeLeft
                        Layout.preferredWidth: 40
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignLeft
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
                        Layout.preferredWidth: 40
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignRight
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: blendedColors.colSubtext
                        elide: Text.ElideRight
                        text: root.isLive ? Translation.tr("live") : StringUtils.friendlyTimeForSeconds(root.player?.length)
                    }

                    TrackChangeButton {
                        Layout.alignment: Qt.AlignVCenter
                        iconName: "skip_previous"
                        downAction: () => root.player?.previous()
                    }

                    RippleButton {
                        id: playPauseButton
                        Layout.alignment: Qt.AlignVCenter
                        property real size: 40
                        implicitWidth: size
                        implicitHeight: size
                        downAction: () => root.player.togglePlaying();

                        buttonRadius: size / 2
                        colBackground: root.player?.isPlaying ? blendedColors.colPrimary : blendedColors.colSecondaryContainer
                        colBackgroundHover: root.player?.isPlaying ? blendedColors.colPrimaryHover : blendedColors.colPrimary
                        colRipple: root.player?.isPlaying ? blendedColors.colPrimaryActive : blendedColors.colSecondaryContainerActive

                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            iconSize: 24
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