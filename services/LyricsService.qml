pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs
import qs.modules.common
import qs.modules.common.functions
import "lyrics/lyrics_parser.js" as LyricsParser
import "lyrics/vocal_sweep.js" as VocalSweep
import "lyrics/lyrics_grouping.js" as LyricsGrouping

/**
 * Lyrics service.
 *
 * Fetching: word-synced (python providers) and line-synced lookups run in parallel, so plain/line-synced
 * lyrics show up immediately and are upgraded to word-synced ones if/when those arrive.
 *
 * Playback: the sync loop only does cheap numeric work per tick. Rich-text strings are rebuilt only
 * when the visible state (line / mode / countdown second) actually changes. The loop runs per frame
 * only while a word sweep is animating; otherwise it sleeps until the next line is due.
 */
Singleton {
    id: root

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    property string currentTrackName: ""
    property string currentArtistName: ""

    property int currentFetchId: 0
    property bool loading: false
    property string loadingStatus: ""
    property string lyricsSource: ""
    readonly property string lyricsSourceDisplayName: {
        let s = (lyricsSource || "").toLowerCase();
        if (s.includes("src4")) return "Apple Music";
        if (s.includes("src5") || s.includes("amll")) return "AMLL DB";
        if (s.includes("src1") || s.includes("kugou")) return "Kugou Music";
        if (s.includes("src2") || s.includes("qq")) return "QQ Music";
        if (s.includes("src3") || s.includes("netease")) return "NetEase Music";
        if (s.includes("lrc") || s.includes("lrclib")) return "LRCLIB";
        return s ? s : (hasWordSync ? "Apple Music" : "LRCLIB");
    }
    property string currentLyricLine: ""
    property string currentLyricLineRich: ""
    property string currentLyricLineDim: ""
    property string currentLyricLineLit: ""
    property real currentLineProgress: 0.0
    property real currentLineDuration: 0.0
    // Independent per-track reveal geometry for word-synced lines. Background vocals
    // sweep on their own clock instead of waiting for the foreground to finish.
    property real currentLeadProgress: 0.0
    property real currentBgProgress: 0.0
    property real currentLeadStartX: 0.0
    property real currentLeadWidth: 0.0
    property real currentBgStartX: 0.0
    property real currentBgWidth: 0.0
    property real currentPastWidth: 0.0
    property bool currentLineHasBg: false
    property real currentSweepX: 0.0
    property int currentGroupStartIdx: -1
    property bool isMultiLineGroup: false
    property bool allowHighlightSlide: false
    property real activeLineStartFraction: 0.0
    property real activeLineEndFraction: 1.0
    property string nextLyricLine: ""
    property var lyricLines: [] // Array of { time: seconds, text: string, ... }
    property var lyricGroupIndex: [] // Precomputed group for each line index
    property bool hasUnsyncedLyrics: false
    property bool hasWordSync: false

    property real lastKnownPosition: 0
    property real lastKnownTimestamp: 0
    property real lastMprisPos: -1
    property real lastWordSyncPos: 0
    property int seekEpoch: 0
    property real syncLeadSeconds: 0.16 // Lead time in seconds (switches to next line slightly earlier)

    readonly property real firstLineLead: 1.0
    readonly property real negativeCacheSeconds: 5400
    readonly property int maxCacheEntries: 40

    // Display modes (see tick())
    readonly property int mIntro: 0
    readonly property int mMark: 1
    readonly property int mWait: 2
    readonly property int mSing: 3
    readonly property int mOutro: 4
    readonly property int mEndHoldLast: 5
    readonly property int mEndFallback: 6
    readonly property int mEndHoldMuted: 7

    // Sync-loop state
    property int _rawIdx: -1
    property int _mMode: -1
    property int _mIdx: -2
    property int _mRem: -1
    property bool _mStarted: false
    property var _curGroup: null
    property real _progScale: 1.0
    property bool _sweeping: false
    property int _slowInterval: 100
    readonly property bool _playing: activePlayer?.playbackState === MprisPlaybackState.Playing

    // Quickshell native system palette integration: zero hardcoded colors
    readonly property color _colLitBase: Appearance?.colors?.colOnLayer1 ?? Appearance?.colors?.colOnLayer0 ?? "#cbc5ca"
    readonly property color _colSubtextBase: Appearance?.colors?.colSubtext ?? "#948f94"
    readonly property color _colLayerBg: Appearance?.colors?.colLayer0 ?? "#161515"

    // Active sung words use Quickshell's native bar foreground (colOnLayer1, matching clock and active bar items)
    readonly property string colLitHex: (Appearance?.colors?.colOnLayer1 ?? "#cbc5ca").toString()
    readonly property string colActiveHex: colLitHex

    // Upcoming lyrics use a slightly darker shade of native subtext for clear, comfortable contrast
    readonly property string colUpcomingHex: ColorUtils.mix(root._colSubtextBase, root._colLayerBg, 0.48).toString()

    // Past sung lyrics gently soften further
    readonly property string colPastHex: ColorUtils.mix(root._colSubtextBase, root._colLayerBg, 0.32).toString()

    readonly property string colBulletHex: ColorUtils.mix(root._colSubtextBase, root._colLayerBg, 0.35).toString()
    readonly property string colTimerHex: root.colUpcomingHex
    readonly property string colWaitingGroupHex: root.colUpcomingHex
    readonly property string colWaitingSingleHex: root.colUpcomingHex

    // Background vocal harmonies: seamlessly follow system palette
    readonly property string colBgLitHex: ColorUtils.mix(root.colLitHex, root._colLayerBg, 0.75).toString()
    readonly property string colBgUpcomingHex: ColorUtils.mix(root._colSubtextBase, root._colLayerBg, 0.36).toString()
    readonly property string colBgPastHex: ColorUtils.mix(root._colSubtextBase, root._colLayerBg, 0.24).toString()

    // Anything baked into the cached rich-text strings; a change forces a rebuild
    readonly property string displaySig: colPastHex + colUpcomingHex + colLitHex + colBulletHex + colTimerHex
        + colWaitingGroupHex + colWaitingSingleHex + colBgLitHex + colBgPastHex + colBgUpcomingHex + trackInfoRich
    onDisplaySigChanged: {
        root._mMode = -1;
        Qt.callLater(root.tick);
    }

    // How much of a gentle S-curve is blended over the whole word (0 = none, 1 = full smoothstep)
    readonly property real wordEaseMix: 0.3

    function vocalEase(t, dur, chainedPrev, chainedNext) {
        return VocalSweep.vocalEase(t, dur, chainedPrev, chainedNext);
    }

    function escapeXml(s) {
        return LyricsGrouping.escapeXml(s);
    }

    function formatLineRich(rawText, mainCol, bgCol) {
        return LyricsGrouping.formatLineRich(rawText, mainCol, bgCol || root.colBgLitHex, root.colBulletHex);
    }

    // Precomputed track title + artist strings
    readonly property string trackInfoPlain: {
        let rawTitle = activePlayer?.trackTitle || "";
        let tName = StringUtils.cleanMusicTitle(rawTitle) || rawTitle;
        let tArtist = MprisController.getPlayerArtists(activePlayer);
        return (tName && tArtist) ? `${tName} • ${tArtist}` : (tName || tArtist);
    }
    readonly property string trackInfoRich: {
        let rawTitle = activePlayer?.trackTitle || "";
        let tName = root.escapeXml(StringUtils.cleanMusicTitle(rawTitle) || rawTitle);
        let tArtist = root.escapeXml(MprisController.getPlayerArtists(activePlayer));
        return (tName && tArtist)
            ? `<font color="${root.colActiveHex}">${tName}</font><font color="${root.colBulletHex}"> • </font><font color="${root.colActiveHex}">${tArtist}</font>`
            : `<font color="${root.colActiveHex}">${tName || tArtist}</font>`;
    }

    // ------------------------------------------------------------------------------------------
    // Cache (insertion-ordered eviction; negative results expire). The python helper additionally
    // keeps a persistent on-disk cache, so this one only avoids respawning it within a session.
    // ------------------------------------------------------------------------------------------
    property var lyricCache: ({})
    property var _cacheOrder: []

    function _cachePut(key, value) {
        if (!(key in root.lyricCache)) {
            root._cacheOrder.push(key);
            if (root._cacheOrder.length > root.maxCacheEntries) {
                delete root.lyricCache[root._cacheOrder.shift()];
            }
        }
        root.lyricCache[key] = value;
    }

    // ------------------------------------------------------------------------------------------
    // Lyrics offset calibration (in milliseconds, positive = earlier, negative = later)
    // ------------------------------------------------------------------------------------------
    property int lyricsOffsetMs: 0
    readonly property real lyricsOffsetSec: lyricsOffsetMs / 1000.0
    // Set once the user calibrates the current track, so a late fetch result can't
    // overwrite the offset with the value it read from cache when it started.
    property bool _offsetDirty: false
    // Snapshot of what to persist, so a track change during the save debounce
    // can't write the offset onto the wrong song.
    property string _offsetSaveTitle: ""
    property string _offsetSaveArtist: ""
    property int _offsetSaveMs: 0

    function adjustLyricsOffset(deltaMs) {
        root.setLyricsOffset(root.lyricsOffsetMs + deltaMs);
    }

    function setLyricsOffset(ms) {
        let clamped = Math.max(-10000, Math.min(10000, Math.round(ms)));
        if (root.lyricsOffsetMs === clamped) return;
        root.lyricsOffsetMs = clamped;
        root._offsetDirty = true;
        root._forceSyncRefresh();

        let tName = StringUtils.cleanMusicTitle(root.currentTrackName) || root.currentTrackName || activePlayer?.trackTitle || "";
        let tArtist = root.currentArtistName || activePlayer?.trackArtist || "";
        let cacheKey = (tName + "___" + tArtist).toLowerCase();
        if (root.lyricCache[cacheKey]) {
            root.lyricCache[cacheKey].offset_ms = clamped;
        }

        root._offsetSaveTitle = tName;
        root._offsetSaveArtist = tArtist;
        root._offsetSaveMs = clamped;
        offsetSaveDebounce.restart();
    }

    function resetLyricsOffset() {
        root.setLyricsOffset(0);
    }

    Timer {
        id: offsetSaveDebounce
        interval: 500
        repeat: false
        onTriggered: {
            if (!root._offsetSaveTitle) return;
            offsetSaveProc.command = [
                "python3",
                Quickshell.shellPath("scripts/lyrics/fetch_lyrics.py"),
                "--set-offset",
                root._offsetSaveTitle,
                root._offsetSaveArtist,
                String(root._offsetSaveMs),
                root._cacheDir
            ];
            offsetSaveProc.running = true;
        }
    }

    Process {
        id: offsetSaveProc
        running: false
    }

    // ------------------------------------------------------------------------------------------
    // Playback device latency compensation (session-only RAM cache per audio sink; never saved)
    // Positive latency delays lyrics slightly to match wireless / buffered playback output.
    // ------------------------------------------------------------------------------------------
    readonly property var _audioSink: Audio.sink
    readonly property string audioSinkKey: (root._audioSink && root._audioSink.ready)
        ? (root._audioSink.name || root._audioSink.description || "default")
        : ""
    readonly property string audioSinkName: root._audioSink
        ? (root._audioSink.nickname || root._audioSink.description || root._audioSink.name || "Audio Device")
        : "Audio Device"
    readonly property bool isBluetoothSink: {
        let s = root._audioSink;
        if (!s) return false;
        let codec = s.properties ? (s.properties["api.bluez5.codec"] || "") : "";
        if (codec !== "") return true;
        let info = ((s.name || "") + " " + (s.description || "") + " " + (s.nickname || "")).toLowerCase();
        return /bluez|bluetooth|a2dp/.test(info);
    }
    readonly property bool isHeadphoneSink: {
        if (root.isBluetoothSink) return true;
        let s = root._audioSink;
        if (!s) return false;
        let info = ((s.name || "") + " " + (s.description || "") + " " + (s.nickname || "")).toLowerCase();
        return /headset|headphone|earbud|neckband|airpods|buds|wireless/.test(info);
    }

    property var _deviceLatencyCache: ({}) // sinkKey -> { enabled: bool, latencyMs: int, manual: bool }
    property bool deviceLatencyEnabled: true
    property int deviceLatencyMs: 0
    property int reportedDeviceLatencyMs: 0
    property bool _hasManualDeviceLatency: false
    property bool _hasPwLatency: false
    property int _btRetryAttempt: 0
    readonly property int activeDeviceLatencyMs: deviceLatencyEnabled ? deviceLatencyMs : 0
    readonly property real activeDeviceLatencySec: activeDeviceLatencyMs / 1000.0

    function _applyReportedLatency(ms, probedKey, fromPipeWire) {
        if (!probedKey || probedKey !== root.audioSinkKey) return;
        let cleanMs = Math.max(0, Math.round(ms));
        if (fromPipeWire && cleanMs > 0) root._hasPwLatency = true;
        root.reportedDeviceLatencyMs = cleanMs;
        if (!root._hasManualDeviceLatency) {
            let changed = root.deviceLatencyMs !== cleanMs;
            root.deviceLatencyMs = cleanMs;
            if (probedKey in root._deviceLatencyCache) {
                root._saveDeviceLatencyToMemory();
            }
            if (changed && root.deviceLatencyEnabled) {
                root._forceSyncRefresh();
            }
        }
    }

    function _extractSinkLatencyMs(pwObjects, targetKey) {
        if (!Array.isArray(pwObjects)) return 0;
        let maxNsFromNode = (obj) => {
            let lats = obj?.info?.params?.Latency;
            if (!Array.isArray(lats)) return 0;
            let bestNs = 0;
            for (let i = 0; i < lats.length; i++) {
                let entry = lats[i];
                if (!entry) continue;
                if (entry.direction && entry.direction !== "Input") continue;
                let ns = Number(entry.minNs) || 0;
                if (ns > bestNs) bestNs = ns;
            }
            return bestNs;
        };

        let targetNs = 0;
        for (let i = 0; i < pwObjects.length; i++) {
            let obj = pwObjects[i];
            if (!obj || obj.type !== "PipeWire:Interface:Node") continue;
            let props = obj.info?.props;
            if (!props) continue;
            if (props["node.name"] === targetKey || props["node.description"] === targetKey) {
                let ns = maxNsFromNode(obj);
                if (ns > targetNs) targetNs = ns;
            }
        }

        if (targetNs === 0 && /jamesdsp|easyeffects/i.test(targetKey || "")) {
            let fallbackNs = 0;
            for (let i = 0; i < pwObjects.length; i++) {
                let obj = pwObjects[i];
                if (!obj || obj.type !== "PipeWire:Interface:Node") continue;
                let props = obj.info?.props;
                if (!props || props["media.class"] !== "Audio/Sink") continue;
                let st = obj.info?.state;
                if (st !== "running" && st !== "idle") continue;
                let ns = maxNsFromNode(obj);
                if (st === "running" && ns > targetNs) targetNs = ns;
                else if (ns > fallbackNs) fallbackNs = ns;
            }
            if (targetNs === 0) targetNs = fallbackNs;
        }

        return targetNs > 0 ? Math.max(0, Math.round(targetNs / 1000000)) : 0;
    }

    function _bluetoothAddressForSink(pwObjects) {
        let s = root._audioSink;
        let addr = (s && s.properties) ? String(s.properties["api.bluez5.address"] || "") : "";
        if (addr) return addr;
        let m = (root.audioSinkKey || "").match(/([0-9A-Fa-f]{2}(?:[_:][0-9A-Fa-f]{2}){5})/);
        if (m) return m[1];
        if (Array.isArray(pwObjects) && /jamesdsp|easyeffects/i.test(root.audioSinkKey || "")) {
            let fallbackAddr = "";
            for (let i = 0; i < pwObjects.length; i++) {
                let obj = pwObjects[i];
                if (!obj || obj.type !== "PipeWire:Interface:Node") continue;
                let props = obj.info?.props;
                if (!props || props["media.class"] !== "Audio/Sink") continue;
                let bAddr = String(props["api.bluez5.address"] || "");
                if (!bAddr) continue;
                if (obj.info?.state === "running") return bAddr;
                if (!fallbackAddr && obj.info?.state === "idle") fallbackAddr = bAddr;
            }
            if (fallbackAddr) return fallbackAddr;
        }
        return "";
    }

    function _isProbingBluetoothOrDsp() {
        return root.isBluetoothSink || /jamesdsp|easyeffects/i.test(root.audioSinkKey || "");
    }

    function _scheduleBtRetryIfNeeded() {
        if (!root._isProbingBluetoothOrDsp()) return;
        if (root._hasPwLatency || root._btRetryAttempt >= 3) return;
        let delays = [800, 1800, 3500];
        btLatencyRetryTimer.interval = delays[root._btRetryAttempt] || 3500;
        root._btRetryAttempt++;
        btLatencyRetryTimer.restart();
    }

    function _probeSinkLatency() {
        let key = root.audioSinkKey;
        if (!key) {
            btLatencyRetryTimer.stop();
            root._hasPwLatency = false;
            root.reportedDeviceLatencyMs = 0;
            return;
        }
        probeSinkLatencyProc.targetSinkKey = key;
        if (probeSinkLatencyProc.running) probeSinkLatencyProc.running = false;
        probeSinkLatencyProc.running = true;
    }

    Timer {
        id: btLatencyRetryTimer
        repeat: false
        onTriggered: {
            if (root.audioSinkKey && root._isProbingBluetoothOrDsp()) {
                root._probeSinkLatency();
            }
        }
    }

    Process {
        id: probeSinkLatencyProc
        property string targetSinkKey: ""
        command: ["pw-dump"]
        stdout: StdioCollector {
            onStreamFinished: {
                let probedKey = probeSinkLatencyProc.targetSinkKey;
                if (!probedKey || probedKey !== root.audioSinkKey) return;
                let parsed = null;
                let ms = 0;
                try {
                    parsed = JSON.parse(text);
                    ms = root._extractSinkLatencyMs(parsed, probedKey);
                } catch (e) {
                    ms = 0;
                }
                if (ms > 0) {
                    btLatencyRetryTimer.stop();
                    root._applyReportedLatency(ms, probedKey, true);
                    return;
                }
                let btAddr = root._bluetoothAddressForSink(parsed);
                if (root.isBluetoothSink || btAddr !== "") {
                    probeBtDbusProc.targetSinkKey = probedKey;
                    probeBtDbusProc.command = [
                        "bash", "-c",
                        "pat='fd[0-9]+$'; " +
                        "if [ -n \"$1\" ]; then suff=\"${1//:/_}\"; pat=\"dev_${suff}(/.*)?/fd[0-9]+$\"; fi; " +
                        "for p in $(busctl tree --list org.bluez 2>/dev/null | grep -E \"$pat\"); do " +
                        "  v=$(busctl get-property org.bluez \"$p\" org.bluez.MediaTransport1 Delay 2>/dev/null | awk '{print $2}'); " +
                        "  if [ -n \"$v\" ] && [ \"$v\" -gt 0 ] 2>/dev/null; then echo $(( (v + 5) / 10 )); exit 0; fi; " +
                        "done; echo 0",
                        "--", btAddr
                    ];
                    if (probeBtDbusProc.running) probeBtDbusProc.running = false;
                    probeBtDbusProc.running = true;
                } else {
                    if (!root._hasPwLatency) {
                        root._applyReportedLatency(0, probedKey, false);
                    }
                    root._scheduleBtRetryIfNeeded();
                }
            }
        }
    }

    Process {
        id: probeBtDbusProc
        property string targetSinkKey: ""
        stdout: StdioCollector {
            onStreamFinished: {
                let probedKey = probeBtDbusProc.targetSinkKey;
                if (!probedKey || probedKey !== root.audioSinkKey) return;
                let ms = parseInt((text || "").trim()) || 0;
                if (ms > root.reportedDeviceLatencyMs) {
                    root._applyReportedLatency(ms, probedKey, false);
                } else if (root.reportedDeviceLatencyMs === 0) {
                    root._applyReportedLatency(0, probedKey, false);
                }
                root._scheduleBtRetryIfNeeded();
            }
        }
    }

    on_PlayingChanged: {
        if (root._playing && root._isProbingBluetoothOrDsp() && !root._hasPwLatency) {
            root._btRetryAttempt = 0;
            btLatencyRetryTimer.interval = 600;
            btLatencyRetryTimer.restart();
        }
    }

    function _saveDeviceLatencyToMemory() {
        let key = root.audioSinkKey || "default";
        let cache = Object.assign({}, root._deviceLatencyCache);
        cache[key] = {
            enabled: root.deviceLatencyEnabled,
            latencyMs: root.deviceLatencyMs,
            manual: root._hasManualDeviceLatency
        };
        root._deviceLatencyCache = cache;
    }

    function _loadDeviceLatencyFromMemory() {
        let key = root.audioSinkKey || "default";
        let entry = root._deviceLatencyCache[key];
        btLatencyRetryTimer.stop();
        root._btRetryAttempt = 0;
        root._hasPwLatency = false;
        root.reportedDeviceLatencyMs = 0;
        if (entry) {
            root.deviceLatencyEnabled = Boolean(entry.enabled);
            root._hasManualDeviceLatency = Boolean(entry.manual);
            root.deviceLatencyMs = Math.max(0, parseInt(entry.latencyMs) || 0);
        } else {
            root.deviceLatencyEnabled = true;
            root._hasManualDeviceLatency = false;
            root.deviceLatencyMs = 0;
        }
        root._probeSinkLatency();
        root._forceSyncRefresh();
    }

    function _forceSyncRefresh() {
        root.lastWordSyncPos = -1;
        root._rawIdx = -1;
        root.seekEpoch++;
        Qt.callLater(root.tick);
    }

    function toggleDeviceLatency() {
        let nextEnabled = !root.deviceLatencyEnabled;
        root.deviceLatencyEnabled = nextEnabled;
        root._saveDeviceLatencyToMemory();
        if (nextEnabled && !root._hasManualDeviceLatency && !root._hasPwLatency) {
            root._probeSinkLatency();
        }
        root._forceSyncRefresh();
    }

    function adjustDeviceLatency(deltaMs) {
        if (!root.deviceLatencyEnabled && root.deviceLatencyMs <= 0 && deltaMs <= 0) {
            return;
        }
        root._hasManualDeviceLatency = true;
        root.setDeviceLatency(root.deviceLatencyMs + deltaMs, true);
    }

    function setDeviceLatency(ms, enable) {
        let clamped = Math.max(0, Math.min(2000, Math.round(ms)));
        let nextEnabled = enable !== undefined ? Boolean(enable) : root.deviceLatencyEnabled;
        if (root.deviceLatencyMs === clamped && root.deviceLatencyEnabled === nextEnabled) return;
        root._hasManualDeviceLatency = true;
        root.deviceLatencyMs = clamped;
        root.deviceLatencyEnabled = nextEnabled;
        root._saveDeviceLatencyToMemory();
        root._forceSyncRefresh();
    }

    function resetDeviceLatency() {
        let key = root.audioSinkKey || "default";
        if (key in root._deviceLatencyCache) {
            let cache = Object.assign({}, root._deviceLatencyCache);
            delete cache[key];
            root._deviceLatencyCache = cache;
        }
        btLatencyRetryTimer.stop();
        root._btRetryAttempt = 0;
        root._hasManualDeviceLatency = false;
        root._hasPwLatency = false;
        root.deviceLatencyEnabled = true;
        root.deviceLatencyMs = root.reportedDeviceLatencyMs;
        root._probeSinkLatency();
        root._forceSyncRefresh();
    }

    onAudioSinkKeyChanged: {
        if (root.audioSinkKey) {
            root._loadDeviceLatencyFromMemory();
        }
    }

    // ------------------------------------------------------------------------------------------
    // Fetching (scripts/lyrics/fetch_lyrics.py streams JSON lines: lrc -> word -> exit)
    // ------------------------------------------------------------------------------------------
    property var _job: null          // { id, key, gotWord, shown, best, definiteNone }
    property var _fetchProc: null
    readonly property string _cacheDir: FileUtils.trimFileProtocol(`${Directories.cache}/lyrics`)

    // One Process per request so a late exit of a cancelled request can never be mistaken for the current one
    Component {
        id: fetchProcComp
        Process {
            id: proc
            property int jobId: 0
            stdout: SplitParser {
                onRead: data => root._onFetchLine(proc.jobId, data)
            }
            stderr: SplitParser {
                onRead: data => {
                    if (data && data.trim()) console.warn("[Lyrics] fetch:", data);
                }
            }
            onExited: (exitCode, exitStatus) => {
                let id = proc.jobId;
                proc.destroy();
                root._onFetchExit(id);
            }
        }
    }

    function _abortAll() {
        if (root._fetchProc) {
            root._fetchProc.jobId = -1;
            root._fetchProc.running = false;
            root._fetchProc = null;
        }
        root._job = null;
    }

    function _resetSyncState() {
        root._rawIdx = -1;
        root._mMode = -1;
        root._mIdx = -2;
        root._mRem = -1;
        root._mStarted = false;
        root._curGroup = null;
        root._progScale = 1.0;
        root._sweeping = false;
        root._slowInterval = 100;
        root.seekEpoch++;
    }

    function _clearDisplay() {
        root.lyricLines = [];
        root.lyricGroupIndex = [];
        root.hasUnsyncedLyrics = false;
        root.hasWordSync = false;
        root.currentLyricLine = "";
        root.currentLyricLineRich = "";
        root.currentLyricLineDim = "";
        root.currentLyricLineLit = "";
        root.currentLineProgress = 0.0;
        root.currentLineDuration = 0.0;
        root.currentLeadProgress = 0.0;
        root.currentBgProgress = 0.0;
        root.currentLeadStartX = 0.0;
        root.currentLeadWidth = 0.0;
        root.currentBgStartX = 0.0;
        root.currentBgWidth = 0.0;
        root.currentPastWidth = 0.0;
        root.currentLineHasBg = false;
        root.currentSweepX = 0.0;
        root.currentGroupStartIdx = -1;
        root.isMultiLineGroup = false;
        root.allowHighlightSlide = false;
        root.activeLineStartFraction = 0.0;
        root.activeLineEndFraction = 1.0;
        root.nextLyricLine = "";
        root.lyricsSource = "";
        root._resetSyncState();
    }

    function fetchLyrics(track, artist) {
        root._abortAll();
        let myFetchId = ++root.currentFetchId;
        root._clearDisplay();

        if (!track || track === "") {
            root.loading = false;
            root.loadingStatus = "";
            return;
        }

        root.loading = true;
        root.loadingStatus = "Searching…";

        let cleanTrack = StringUtils.cleanMusicTitle(track) || track;
        let cleanArtist = artist || "";
        let cacheKey = (cleanTrack + "___" + cleanArtist).toLowerCase();

        let cached = root.lyricCache[cacheKey];
        if (cached) {
            if (!cached.none) {
                console.warn("[Lyrics] session cache hit:", `"${cleanTrack}" - "${cleanArtist}"`);
                root.loading = false;
                root.loadingStatus = "";
                if (!root._offsetDirty)
                    root.lyricsOffsetMs = cached.offset_ms || 0;
                root.parseLyricsResponse(cached);
                return;
            }
            if ((Date.now() - cached.ts) / 1000.0 < root.negativeCacheSeconds) {
                root.loading = false;
                root.loadingStatus = "";
                return;
            }
        }

        let rawTrackId = (activePlayer?.metadata ? (activePlayer.metadata["mpris:trackid"] || activePlayer.metadata["xesam:url"]) : "") || "";
        let spotifyMatch = String(rawTrackId).match(/track[:/]([a-zA-Z0-9]{22})/);
        let spotifyId = spotifyMatch ? spotifyMatch[1] : "";

        root._job = { id: myFetchId, key: cacheKey, gotWord: false, shown: false, best: null, definiteNone: false };
        let proc = fetchProcComp.createObject(root, { jobId: myFetchId });
        proc.command = [
            "python3",
            Quickshell.shellPath("scripts/lyrics/fetch_lyrics.py"),
            cleanTrack,
            cleanArtist,
            String(Math.round(activePlayer?.length || 0)),
            root._cacheDir,
            activePlayer?.trackAlbum || "",
            spotifyId
        ];
        root._fetchProc = proc;
        proc.running = true;
    }

    function _onFetchLine(id, line) {
        let job = root._job;
        if (!job || id !== root.currentFetchId || id !== job.id || !line) return;
        let ev;
        try {
            ev = JSON.parse(line);
        } catch (e) {
            return;
        }

        if (ev.offset_ms !== undefined && !root._offsetDirty) {
            root.lyricsOffsetMs = parseInt(ev.offset_ms) || 0;
        }

        if (ev.src) {
            root.lyricsSource = ev.src;
        }

        if (ev.k === "word") {
            if (!ev.text) return;
            let parsed = root.parseLyricsString(ev.text);
            if (parsed.length > 0 && parsed.some(function(l) { return l.isWordSynced; })) {
                job.gotWord = true;
                job.best = { syncedLyrics: ev.text, lines: parsed, hasWordSync: true, offset_ms: root.lyricsOffsetMs };
                root.precompileAndSetLyrics(parsed, true);
            }
        } else if (ev.k === "lrc") {
            if (job.gotWord) return;
            let data = { syncedLyrics: ev.synced || "", plainLyrics: ev.plain || "", offset_ms: root.lyricsOffsetMs };
            job.best = data;
            job.shown = true;
            root.parseLyricsResponse(data);
        } else if (ev.k === "none") {
            job.definiteNone = true;
        }
    }

    function _onFetchExit(id) {
        let job = root._job;
        if (!job || id !== root.currentFetchId || id !== job.id) return;
        root._fetchProc = null;
        root.loading = false;
        root.loadingStatus = "";
        if (job.best) root._cachePut(job.key, job.best);
        else if (job.definiteNone) root._cachePut(job.key, { none: true, ts: Date.now() });
        root._job = null;
    }

    function parseLyricsString(synced) {
        let title = StringUtils.cleanMusicTitle(root.currentTrackName) || root.currentTrackName || activePlayer?.trackTitle || "";
        let artist = root.currentArtistName || activePlayer?.trackArtist || "";
        let album = activePlayer?.trackAlbum || "";
        return LyricsParser.parseLyricsString(synced, title, artist, album);
    }

    function precompileAndSetLyrics(parsed, hasWordSync) {
        root._resetSyncState();
        if (!parsed || parsed.length === 0) {
            root.lyricLines = [];
            root.lyricGroupIndex = [];
            root.hasWordSync = false;
            root.loading = false;
            root.loadingStatus = "";
            return;
        }
        root.bulletPixelWidth = root.measurePixelWidth(" • ");
        for (let i = 0; i < parsed.length; i++) {
            root.precompileLineMetrics(parsed[i]);
        }
        root.lyricLines = parsed;
        root.hasWordSync = hasWordSync;
        root.hasUnsyncedLyrics = false;
        root.buildGroupIndex();
        root.loading = false;
        root.loadingStatus = "";
        Qt.callLater(root.tick);
    }

    function parseLyricsResponse(data) {
        if (!data) return;
        let parsed = null;

        if (data.lines && Array.isArray(data.lines) && data.lines.length > 0) {
            parsed = data.lines;
        }

        if ((!parsed || parsed.length === 0) && data.syncedLyrics && data.syncedLyrics.length > 0) {
            try {
                parsed = root.parseLyricsString(data.syncedLyrics);
                if (parsed && parsed.length > 0) data.lines = parsed; // reuse on cache hits
            } catch(e) {}
        }

        root.hasUnsyncedLyrics = (!parsed || parsed.length === 0) && ((data.plainLyrics && data.plainLyrics.length > 0) || (data.syncedLyrics && data.syncedLyrics.length > 0));
        if (parsed && parsed.length > 0) {
            root.precompileAndSetLyrics(parsed, parsed.some(function(l) { return l.isWordSynced; }));
        } else {
            root.lyricLines = [];
            root.lyricGroupIndex = [];
            root.hasWordSync = false;
        }
    }

    function isSupportedPlayer(player) {
        if (!player) return false;
        let id = (player.identity || "").toLowerCase();
        let entry = (player.desktopEntry || "").toLowerCase();
        let bus = (player.dbusName || "").toLowerCase();
        return id.includes("spotify") || entry.includes("spotify") || bus.includes("spotify");
    }

    // ------------------------------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------------------------------
    function syncAudioPosition(rawPos, forceSnap) {
        let now = Date.now();
        if (forceSnap || root.lastKnownTimestamp === 0 || root.lastMprisPos < 0) {
            root.lastMprisPos = rawPos;
            root.lastKnownPosition = rawPos;
            root.lastKnownTimestamp = now;
            root.lastWordSyncPos = rawPos;
            root._rawIdx = -1;
            return;
        }

        if (rawPos === root.lastMprisPos) {
            // MPRIS position unchanged; local clock extrapolates smoothly via Date.now()
            return;
        }

        // Fresh reading from audio player
        let elapsed = (now - root.lastKnownTimestamp) / 1000.0;
        let estimatedPos = root.lastKnownPosition + elapsed;
        let diff = rawPos - estimatedPos;

        root.lastMprisPos = rawPos;

        if (Math.abs(diff) > 0.4) {
            // Seeked or track jumped
            root.lastKnownPosition = rawPos;
            root.lastKnownTimestamp = now;
            root.lastWordSyncPos = rawPos;
            root._rawIdx = -1;
            root.seekEpoch++;
        } else if (Math.abs(diff) >= 0.04) {
            // Direct drift reconciliation
            root.lastKnownPosition = rawPos;
            root.lastKnownTimestamp = now;
        }
    }

    function syncTrackChange() {
        let newTitle = activePlayer?.trackTitle || "";
        let newArtist = MprisController.getPlayerArtists(activePlayer);
        if (newTitle === root.currentTrackName && newArtist === root.currentArtistName) return;

        root.currentTrackName = newTitle;
        root.currentArtistName = newArtist;
        root.lyricsOffsetMs = 0;
        root._offsetDirty = false;
        let initPos = activePlayer?.position || 0;
        root.lastMprisPos = initPos;
        root.lastKnownPosition = initPos;
        root.lastKnownTimestamp = Date.now();
        root.lastWordSyncPos = initPos;
        root.seekEpoch++;

        // Title/artist/length usually update in quick succession; wait for them to settle
        // before spawning any network/process work.
        root._abortAll();
        root.currentFetchId++;
        root._clearDisplay();
        if (root.isSupportedPlayer(activePlayer) && newTitle !== "") {
            root.loading = true;
            root.loadingStatus = "Searching…";
            fetchDebounce.restart();
        } else {
            fetchDebounce.stop();
            root.loading = false;
            root.loadingStatus = "";
        }
    }

    Timer {
        id: fetchDebounce
        interval: 250
        onTriggered: root.fetchLyrics(root.currentTrackName, root.currentArtistName)
    }

    Connections {
        target: activePlayer
        function onTrackTitleChanged() { root.syncTrackChange(); }
        function onTrackArtistChanged() { root.syncTrackChange(); }
        function onTrackArtistsChanged() { root.syncTrackChange(); }
        function onPlaybackStateChanged() {
            if (activePlayer?.playbackState === MprisPlaybackState.Playing) {
                root.syncAudioPosition(activePlayer?.position || 0, true);
            } else {
                if (root.lastKnownTimestamp > 0) {
                    root.lastKnownPosition += (Date.now() - root.lastKnownTimestamp) / 1000.0;
                }
                root.lastKnownTimestamp = 0;
                root.lastMprisPos = -1;
            }
        }
        function onPositionChanged() {
            root.syncAudioPosition(activePlayer?.position || 0, false);
        }
    }

    Connections {
        target: MprisController
        function onActivePlayerChanged() { root.syncTrackChange(); }
        function onTrackChanged() { root.syncTrackChange(); }
    }

    // ------------------------------------------------------------------------------------------
    // Text metrics (line widths are measured eagerly, per-word bounds lazily)
    // ------------------------------------------------------------------------------------------
    TextMetrics {
        id: lyricMetrics
        font.family: Appearance?.font?.family?.main ?? ""
        font.pixelSize: Appearance?.font?.pixelSize?.small ?? 15
        font.variableAxes: Appearance?.font?.variableAxes?.main ?? ({})
    }

    Text {
        id: styledMetrics
        visible: false
        renderType: Text.NativeRendering
        font.hintingPreference: Font.PreferDefaultHinting
        font.family: Appearance?.font?.family?.main ?? ""
        font.pixelSize: Appearance?.font?.pixelSize?.small ?? 15
        font.variableAxes: Appearance?.font?.variableAxes?.main ?? ({})
        textFormat: Text.StyledText
    }

    property real bulletPixelWidth: 0
    property var _repeatSuffixCache: ({})
    property int _metricsRev: 0

    Connections {
        target: Appearance?.font ?? null
        function onPixelSizeChanged() { root.refreshFontMetrics(); }
        function onFamilyChanged() { root.refreshFontMetrics(); }
    }

    function refreshFontMetrics() {
        root._metricsRev++;
        root.bulletPixelWidth = root.measurePixelWidth(" • ");
        root._repeatSuffixCache = ({});
        root.recompileAllMetrics();
    }

    function measurePixelWidth(str) {
        if (!str) return 0;
        lyricMetrics.text = str;
        return lyricMetrics.advanceWidth;
    }

    function getRepeatSuffixWidth(suffix) {
        if (!suffix) return 0;
        let cached = root._repeatSuffixCache[suffix];
        if (cached !== undefined) return cached;
        let w = root.measurePixelWidth(suffix);
        root._repeatSuffixCache[suffix] = w;
        return w;
    }

    function precompileLineMetrics(line) {
        VocalSweep.precompileLineMetrics(line, root._metricsRev, root.measurePixelWidth);
    }

    function _computeBounds(line) {
        return VocalSweep.computeBounds(line, root.measurePixelWidth);
    }

    function recompileAllMetrics() {
        let lines = root.lyricLines;
        if (!lines || lines.length === 0) return;
        for (let i = 0; i < lines.length; i++) {
            root.precompileLineMetrics(lines[i]);
        }
        root.buildGroupIndex();
    }

    function _sweepWordSubset(words, bounds, totalW, baseStartX, currentSec, lineRefKey, line) {
        return VocalSweep.sweepWordSubset(words, bounds, totalW, baseStartX, currentSec, lineRefKey, line);
    }

    function getLineSweepFraction(line, currentSec) {
        return VocalSweep.getLineSweepFraction(line, currentSec, root.measurePixelWidth);
    }

    function _lineTrackData(line, track) {
        return VocalSweep.lineTrackData(line, track);
    }

    function getLineTrackProgress(line, track, currentSec) {
        return VocalSweep.getLineTrackProgress(line, track, currentSec, root.measurePixelWidth);
    }

    function getGroupLineStartX(g, lineIdx, lines) {
        return VocalSweep.getGroupLineStartX(g, lineIdx, lines, root._getGroupBounds);
    }

    function calculateGroupSweep(currGroup, currIdx, currentSec) {
        return VocalSweep.calculateGroupSweep(currGroup, currIdx, currentSec, root.lyricLines, root.bulletPixelWidth, root.measurePixelWidth);
    }

    function _getGroupBounds(g, lines) {
        return LyricsGrouping.computeGroupBounds(
            g, lines, root._metricsRev, root.colBulletHex,
            root.colLitHex, root.colBgLitHex, styledMetrics, root.formatLineRich
        );
    }

    function buildGroupIndex() {
        let lines = root.lyricLines;
        if (!lines || lines.length === 0) {
            root.lyricGroupIndex = [];
            return;
        }
        let bulletW = root.bulletPixelWidth > 0 ? root.bulletPixelWidth : root.measurePixelWidth(" • ");
        root.bulletPixelWidth = bulletW;
        let maxAllowedPx = Math.max(160, (GlobalStates?.topBarMediaWidth ?? 440) - 135);
        root.lyricGroupIndex = LyricsGrouping.buildGroupIndex(lines, bulletW, maxAllowedPx, root.precompileLineMetrics);
        root._mMode = -1;
    }

    Timer {
        id: groupIndexDebounce
        interval: 150
        running: false
        onTriggered: {
            if (root.lyricLines.length > 0) {
                root.buildGroupIndex();
                root.tick();
            }
        }
    }

    Connections {
        target: GlobalStates
        function onTopBarMediaWidthChanged() {
            groupIndexDebounce.restart()
        }
    }

    // ------------------------------------------------------------------------------------------
    // Sync loop
    // ------------------------------------------------------------------------------------------
    // Per-frame only while a word sweep is animating
    FrameAnimation {
        id: sweepAnimation
        running: root._playing && root.lyricLines.length > 0 && root._sweeping
        onTriggered: root.tick()
    }

    // Otherwise sleeps until (roughly) the next line is due
    Timer {
        interval: root._slowInterval
        repeat: true
        running: root._playing && root.lyricLines.length > 0 && !root._sweeping
        onTriggered: root.tick()
    }

    // Last line whose time <= pos (or -1 before the first line's lead-in). O(1) for normal playback.
    function _findLineIdx(lines, pos) {
        return LyricsGrouping.findLineIdx(lines, pos, root.firstLineLead, root._rawIdx);
    }

    function _tagged(tag) {
        if (root.trackInfoPlain) {
            return {
                plain: `${root.trackInfoPlain} ${tag}`,
                rich: `${root.trackInfoRich} <font color="${root.colTimerHex}">${tag}</font>`
            };
        }
        return { plain: tag, rich: `<font color="${root.colTimerHex}">${tag}</font>` };
    }

    function _lastRealLine(lines, fromIdx) {
        return LyricsGrouping.lastRealLine(lines, fromIdx);
    }

    // Builds all text-ish state for the given display state. Only called when that state changes.
    function _rebuildDisplay(mode, currIdx, remaining, started) {
        let lines = root.lyricLines;
        let groups = root.lyricGroupIndex;
        let timerCol = root.colTimerHex;

        let line = "", rich = "", dim = "", lit = "";
        let nextText = "";
        let groupKey = -1;
        let isMulti = false;
        let startFrac = 0.0, endFrac = 1.0;
        let curGroup = null;
        let progScale = 1.0;
        let lineDur = 0.0;

        if (currIdx < 0) {
            // Before the first line
            nextText = groups[0].text;
            lineDur = remaining > 0 ? remaining : 4.0;
            if (remaining > 0) {
                let t = root._tagged(`(Intro ♪ ${remaining}s)`);
                line = t.plain;
                rich = t.rich;
            } else {
                line = root.trackInfoPlain || "";
                rich = root.trackInfoRich || "";
            }
            dim = rich;
            lit = rich;
        } else {
            let g = groups[currIdx];
            curGroup = g;
            let isSingle = g.startIdx === g.endIdx;
            isMulti = !isSingle;
            let rawText = lines[g.startIdx].text;
            let hasNext = g.nextStartIdx < lines.length;
            if (hasNext) nextText = groups[g.nextStartIdx].text;
            if (g && g.startIdx >= 0 && g.startIdx < lines.length) {
                let startSec = lines[g.startIdx].time || 0.0;
                let lastLine = lines[g.endIdx];
                let endSec = hasNext ? lines[g.nextStartIdx].time : (lastLine.endTime || (lastLine.time + 4.0));
                lineDur = Math.max(1.0, endSec - startSec);
            }

            let rep = LyricsGrouping.getRepeatInfo(groups, lines, g);
            groupKey = rep.groupKey;
            let repeatSuffix = rep.repeatSuffix;
            let baseText = g.text + repeatSuffix;

            if (mode === root.mSing) {
                let colors = {
                    timer: root.colTimerHex,
                    bullet: root.colBulletHex,
                    upcoming: root.colUpcomingHex,
                    bgUpcoming: root.colBgUpcomingHex,
                    lit: root.colLitHex,
                    bgLit: root.colBgLitHex,
                    past: root.colPastHex,
                    bgPast: root.colBgPastHex
                };
                let s = LyricsGrouping.buildSingDisplay(
                    g, currIdx, lines, colors, repeatSuffix,
                    styledMetrics, root._getGroupBounds, started, root.getRepeatSuffixWidth
                );
                line = s.line;
                dim = s.dim;
                lit = s.lit;
                rich = s.rich;
                startFrac = s.startFrac;
                endFrac = s.endFrac;
                if (root.hasWordSync && repeatSuffix.length > 0 && s.totalLyricW > 0) {
                    progScale = s.fullGroupW > 0 ? (s.totalLyricW / s.fullGroupW) : 1.0;
                }
            } else {
                let colors = {
                    timer: root.colTimerHex,
                    waitingSingle: root.colWaitingSingleHex,
                    waitingGroup: root.colWaitingGroupHex
                };
                let trackInfo = { plain: root.trackInfoPlain, rich: root.trackInfoRich };
                let st = LyricsGrouping.buildStatusDisplay(mode, baseText, remaining, g, lines, groups, colors, trackInfo);
                line = st.line;
                rich = st.rich;
                dim = st.dim;
                lit = st.lit;
                lineDur = st.lineDur;
            }
        }

        if (root.currentLyricLine !== line) root.currentLyricLine = line;
        if (root.currentLyricLineDim !== dim) root.currentLyricLineDim = dim;
        if (root.currentLyricLineLit !== lit) root.currentLyricLineLit = lit;
        if (root.currentLyricLineRich !== rich) root.currentLyricLineRich = rich;
        if (root.currentGroupStartIdx !== groupKey) root.currentGroupStartIdx = groupKey;
        if (root.isMultiLineGroup !== isMulti) root.isMultiLineGroup = isMulti;
        if (root.activeLineStartFraction !== startFrac) root.activeLineStartFraction = startFrac;
        if (root.activeLineEndFraction !== endFrac) root.activeLineEndFraction = endFrac;
        if (root.nextLyricLine !== nextText) root.nextLyricLine = nextText;
        if (root.currentLineDuration !== lineDur) root.currentLineDuration = lineDur;
        root._curGroup = curGroup;
        root._progScale = progScale;
    }

    function tick() {
        let lines = root.lyricLines;
        let groups = root.lyricGroupIndex;
        let n = lines.length;
        if (n === 0 || !groups || groups.length !== n) return;

        let now = Date.now();
        let elapsedSec = root.lastKnownTimestamp > 0 ? (now - root.lastKnownTimestamp) / 1000.0 : 0;
        let currentPos = root.lastKnownPosition + elapsedSec + root.lyricsOffsetSec - root.activeDeviceLatencySec;
        let hasWS = root.hasWordSync;

        // For word-by-word karaoke, words and lines synchronize precisely with audio playback (0s lead).
        let lineSyncPos = Math.max(0, currentPos + (hasWS ? 0.0 : root.syncLeadSeconds));

        // Word clock never runs backwards on small jitter
        let wordSyncPos = Math.max(0, currentPos);
        if (wordSyncPos >= root.lastWordSyncPos || Math.abs(wordSyncPos - root.lastWordSyncPos) > 0.4) {
            root.lastWordSyncPos = wordSyncPos;
        } else {
            wordSyncPos = root.lastWordSyncPos;
        }

        let currIdx = root._findLineIdx(lines, lineSyncPos);
        root._rawIdx = currIdx;

        let trackLen = activePlayer?.length || 0;
        let dm = LyricsGrouping.determineMode(currIdx, lines, groups, lineSyncPos, wordSyncPos, root.firstLineLead, trackLen);
        let mode = dm.mode;
        let remaining = dm.remaining;
        let started = dm.started;

        // Anything string-ish only changes when one of these does (at most ~1/s outside of line changes)
        let wasMulti = root.isMultiLineGroup;
        let lineChanged = currIdx !== root._mIdx;
        if (lineChanged) {
            root.currentSweepX = 0.0;
            root.currentLeadProgress = 0.0;
            root.currentBgProgress = 0.0;
            root.currentPastWidth = 0.0;
            root.currentLineProgress = 0.0;
        }
        if (mode !== root._mMode || lineChanged || remaining !== root._mRem || started !== root._mStarted) {
            root._mMode = mode;
            root._mIdx = currIdx;
            root._mRem = remaining;
            root._mStarted = started;
            root._rebuildDisplay(mode, currIdx, remaining, started);
        }

        let curLine = (currIdx >= 0 && currIdx < n) ? lines[currIdx] : null;
        let leadProgress = 0.0, bgProgress = 0.0;
        let leadStart = 0.0, leadWidth = 0.0;
        let bgStart = 0.0, bgWidth = 0.0;
        let pastWidth = 0.0, hasBg = false;
        let sweepX = 0.0;

        if (mode === root.mSing && hasWS && curLine) {
            let tg = VocalSweep.computeTrackGeometry(curLine, currIdx, root._curGroup, lines, wordSyncPos, root._getGroupBounds);
            leadProgress = tg.leadProgress;
            bgProgress = tg.bgProgress;
            leadStart = tg.leadStart;
            leadWidth = tg.leadWidth;
            bgStart = tg.bgStart;
            bgWidth = tg.bgWidth;
            pastWidth = tg.pastWidth;
            hasBg = tg.hasBg;
            sweepX = tg.sweepX;
        } else if (mode === root.mEndHoldLast || mode === root.mEndHoldMuted || mode === root.mWait) {
            sweepX = curLine ? (curLine._totalWidth || 0.0) : 0.0;
        }
        if (root.currentSweepX !== sweepX) root.currentSweepX = sweepX;

        let progress = 0.0;
        if (mode === root.mSing) {
            if (hasWS) {
                progress = root.calculateGroupSweep(root._curGroup, currIdx, wordSyncPos) * root._progScale;
            } else if (currIdx >= 0 && currIdx < n) {
                let g = groups[currIdx];
                let startSec = lines[g.startIdx].time || 0.0;
                let dur = root.currentLineDuration > 0 ? root.currentLineDuration : 3.0;
                progress = Math.max(0.0, Math.min(1.0, (lineSyncPos - startSec) / dur));
            }
        } else if (mode === root.mWait || mode === root.mEndHoldLast || mode === root.mEndHoldMuted) {
            progress = 1.0;
        }

        if (root.currentLineProgress !== progress) root.currentLineProgress = progress;
        if (root.currentLeadProgress !== leadProgress) root.currentLeadProgress = leadProgress;
        if (root.currentBgProgress !== bgProgress) root.currentBgProgress = bgProgress;
        if (root.currentLeadStartX !== leadStart) root.currentLeadStartX = leadStart;
        if (root.currentLeadWidth !== leadWidth) root.currentLeadWidth = leadWidth;
        if (root.currentBgStartX !== bgStart) root.currentBgStartX = bgStart;
        if (root.currentBgWidth !== bgWidth) root.currentBgWidth = bgWidth;
        if (root.currentPastWidth !== pastWidth) root.currentPastWidth = pastWidth;
        if (root.currentLineHasBg !== hasBg) root.currentLineHasBg = hasBg;

        // Enable highlight slide one tick after entering a multi-line group so the entry itself isn't animated
        let shouldSlide = currIdx >= 0 && wasMulti;
        if (root.allowHighlightSlide !== shouldSlide) root.allowHighlightSlide = shouldSlide;

        // Scheduling: frame-rate only while either render track is still visibly moving.
        // Using the group sweep alone could stop the clock while a background tail is
        // still being revealed, so completion is checked per track.
        let nextT = currIdx < 0 ? (lines[0].time - root.firstLineLead) : (currIdx + 1 < n ? lines[currIdx + 1].time : -1);
        let timeToNext = nextT >= 0 ? (nextT - lineSyncPos) : 999;
        let tracksDone = !curLine
            || (leadProgress >= 0.9995 && (!hasBg || bgProgress >= 0.9995));
        let sweeping = hasWS && mode === root.mSing && !(tracksDone && timeToNext > 0.3);
        if (root._sweeping !== sweeping) root._sweeping = sweeping;
        if (!sweeping) {
            let wake = Math.max(16, Math.min(100, Math.floor(timeToNext * 1000) - 4));
            if (Math.abs(wake - root._slowInterval) >= 10) root._slowInterval = wake;
        }
    }

    IpcHandler {
        target: "lyrics"

        function toggleDeviceLatency(): void { root.toggleDeviceLatency(); }
        function setDeviceLatency(ms: int): void { root.setDeviceLatency(ms, true); }
        function resetDeviceLatency(): void { root.resetDeviceLatency(); }
        function status(): string {
            return JSON.stringify({
                deviceLatencyEnabled: root.deviceLatencyEnabled,
                deviceLatencyMs: root.deviceLatencyMs,
                reportedDeviceLatencyMs: root.reportedDeviceLatencyMs,
                activeDeviceLatencyMs: root.activeDeviceLatencyMs,
                audioSinkKey: root.audioSinkKey,
                audioSinkName: root.audioSinkName,
                isBluetoothSink: root.isBluetoothSink,
                lyricsOffsetMs: root.lyricsOffsetMs,
                memoryCache: root._deviceLatencyCache
            });
        }
    }

    Component.onCompleted: {
        root.bulletPixelWidth = root.measurePixelWidth(" • ");
        if (root.audioSinkKey) {
            root._loadDeviceLatencyFromMemory();
        }
        root.syncTrackChange();
    }
}
