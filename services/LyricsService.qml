pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs
import qs.modules.common
import qs.modules.common.functions

Singleton {
    id: root

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    property string currentTrackName: ""
    property string currentArtistName: ""

    property int currentFetchId: 0
    property bool loading: false
    property string loadingStatus: ""
    property string currentLyricLine: ""
    property string currentLyricLineRich: ""
    property int currentGroupStartIdx: -1
    property string nextLyricLine: ""
    property var lyricLines: [] // Array of { time: seconds, text: string }
    property var lyricGroupIndex: [] // Precomputed group for each line index
    property int lastGroupWidth: 0
    property bool hasUnsyncedLyrics: false

    property var activeGetXhr: null
    property var activeSearchXhr: null

    property real lastKnownPosition: 0
    property real lastKnownTimestamp: 0
    property real syncLeadSeconds: 0.25 // Lead time in seconds (switches to next line slightly earlier)

    // Precomputed lyric style colors: reactive to theme/wallpaper changes, evaluated once (0 overhead in 200ms tick)
    readonly property string colPastHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.35).toString()
    readonly property string colUpcomingHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.60).toString()
    readonly property string colActiveHex: (Appearance?.colors?.colSubtext ?? "#948f94").toString()
    readonly property string colBulletHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.40).toString()
    readonly property string colTimerHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.60).toString()
    readonly property string colWaitingGroupHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.60).toString()
    readonly property string colWaitingSingleHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.75).toString()

    function getTrackBaseInfo() {
        let rawTitle = activePlayer?.trackTitle || "";
        let tName = StringUtils.cleanMusicTitle(rawTitle) || rawTitle;
        let tArtist = activePlayer?.trackArtist || "";
        let plain = (tName && tArtist) ? `${tName} • ${tArtist}` : (tName || tArtist);
        let rich = (tName && tArtist)
            ? `<font color="${root.colActiveHex}">${tName}</font><font color="${root.colBulletHex}"> • </font><font color="${root.colActiveHex}">${tArtist}</font>`
            : `<font color="${root.colActiveHex}">${tName || tArtist}</font>`;
        return { plain: plain, rich: rich };
    }

    function normalizeStr(s) {
        if (!s) return "";
        return String(s).toLowerCase().replace(/[\s\-_''"".,:\;!?()\[\]{}\//\\&+=#@~`^|<>*]/g, "");
    }

    function findBestResult(results, targetTrack, targetArtist, targetDuration) {
        if (!results || !Array.isArray(results) || results.length === 0) return null;
        let normTrack = root.normalizeStr(targetTrack);
        let normArtist = root.normalizeStr(targetArtist);

        let bestResult = null;
        let bestScore = -9999;

        for (let i = 0; i < results.length; i++) {
            let r = results[i];
            if (!r || (!r.syncedLyrics && !r.plainLyrics)) continue;
            let rTrack = root.normalizeStr(r.trackName);
            let rArtist = root.normalizeStr(r.artistName);

            let score = 0;
            if (rTrack === normTrack) score += 50;
            else if (normTrack.length > 2 && (rTrack.includes(normTrack) || normTrack.includes(rTrack))) score += 25;

            if (rArtist === normArtist) score += 40;
            else if (!normArtist || rArtist.includes(normArtist) || normArtist.includes(rArtist)) score += 20;

            if (targetDuration > 0 && r.duration) {
                let diff = Math.abs(r.duration - targetDuration);
                if (diff <= 2) score += 35;
                else if (diff <= 5) score += 20;
                else if (diff > 15) score -= 30;
            }

            if (r.syncedLyrics) score += 10;

            if (score > bestScore) {
                bestScore = score;
                bestResult = r;
            }
        }

        if (bestResult) return bestResult;

        for (let i = 0; i < results.length; i++) {
            if (results[i] && results[i].syncedLyrics) return results[i];
        }
        return results[0];
    }

    function _xh(h) {
        let s = "";
        for (let i = 0; i < h.length; i += 2) {
            s += String.fromCharCode(parseInt(h.substr(i, 2), 16));
        }
        return s;
    }

    readonly property string _lcName: _xh("4c72636c69622d436c69656e74")
    readonly property string _xuaName: _xh("582d557365722d4167656e74")
    readonly property string _uaVal: _xh("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229")

    property var lyricCache: ({})

    function fetchLyrics(track, artist) {
        if (root.activeGetXhr) { root.activeGetXhr.abort(); root.activeGetXhr = null; }
        if (root.activeSearchXhr) { root.activeSearchXhr.abort(); root.activeSearchXhr = null; }

        root.currentFetchId++;
        let myFetchId = root.currentFetchId;

        if (!track || track === "") {
            root.lyricLines = [];
            root.lyricGroupIndex = [];
            root.hasUnsyncedLyrics = false;
            root.currentLyricLine = "";
            root.currentLyricLineRich = "";
            root.currentGroupStartIdx = -1;
            root.nextLyricLine = "";
            root.loading = false;
            root.loadingStatus = "";
            return;
        }
        root.loading = true;
        root.loadingStatus = "Fetching Lyrics…";
        root.lyricLines = [];
        root.lyricGroupIndex = [];
        root.currentLyricLine = "";
        root.currentLyricLineRich = "";
        root.currentGroupStartIdx = -1;
        root.nextLyricLine = "";
        root.hasUnsyncedLyrics = false;

        let cleanTrack = StringUtils.cleanMusicTitle(track);
        let cleanArtist = artist || "";
        let cacheKey = (cleanTrack + "___" + cleanArtist).toLowerCase();

        // Simple cache size limit
        if (Object.keys(root.lyricCache).length > 50) {
            root.lyricCache = ({});
        }

        if (root.lyricCache[cacheKey]) {
            root.loading = false;
            root.loadingStatus = "";
            root.parseLyricsResponse(root.lyricCache[cacheKey]);
            return;
        }

        let targetDuration = Math.round(activePlayer?.length || 0);

        if (targetDuration > 0 && cleanArtist !== "") {
            let getUrl = `https://lrclib.net/api/get?track_name=${encodeURIComponent(cleanTrack)}&artist_name=${encodeURIComponent(cleanArtist)}&duration=${targetDuration}`;
            var getXhr = new XMLHttpRequest();
            root.activeGetXhr = getXhr;
            getXhr.onreadystatechange = function() {
                if (getXhr.readyState === XMLHttpRequest.DONE) {
                    if (myFetchId !== root.currentFetchId) return;
                    if (getXhr.status === 200) {
                        try {
                            var data = JSON.parse(getXhr.responseText);
                            if (data && (data.syncedLyrics || data.plainLyrics)) {
                                root.loading = false;
                                root.loadingStatus = "";
                                root.lyricCache[cacheKey] = data;
                                root.parseLyricsResponse(data);
                                root.activeGetXhr = null;
                                return;
                            }
                        } catch(e) {}
                    }
                    root.activeGetXhr = null;
                    root.loadingStatus = "Fetching Lyrics, Trying Harder…";
                    root.searchLyricsFallback(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey);
                }
            };
            getXhr.open("GET", getUrl, true);
            getXhr.setRequestHeader("User-Agent", root._uaVal);
            getXhr.setRequestHeader(root._lcName, root._uaVal);
            getXhr.setRequestHeader(root._xuaName, root._uaVal);
            getXhr.send();
        } else {
            root.loadingStatus = "Searching…";
            root.searchLyricsFallback(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey);
        }
    }

    function searchLyricsFallback(fetchId, cleanTrack, cleanArtist, targetDuration, cacheKey) {
        let query = `${cleanTrack} ${cleanArtist}`.trim();
        let url = `https://lrclib.net/api/search?q=${encodeURIComponent(query)}`;
        var xhr = new XMLHttpRequest();
        root.activeSearchXhr = xhr;
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (fetchId !== root.currentFetchId) return;
                root.activeSearchXhr = null;
                root.loading = false;
                root.loadingStatus = "";
                if (xhr.status === 200) {
                    try {
                        var results = JSON.parse(xhr.responseText);
                        let best = root.findBestResult(results, cleanTrack, cleanArtist, targetDuration);
                        if (best) {
                            root.lyricCache[cacheKey] = best;
                            root.parseLyricsResponse(best);
                        }
                    } catch(e) {}
                }
            }
        };
        xhr.open("GET", url, true);
        xhr.setRequestHeader("User-Agent", root._uaVal);
        xhr.setRequestHeader(root._lcName, root._uaVal);
        xhr.setRequestHeader(root._xuaName, root._uaVal);
        xhr.send();
    }

    function parseLyricsResponse(data) {
        if (!data) return;
        let synced = data.syncedLyrics;
        root.hasUnsyncedLyrics = (!synced || synced.length === 0) && data.plainLyrics && data.plainLyrics.length > 0;
        if (synced && synced.length > 0) {
            let lines = synced.split("\n");
            let parsed = [];
            let regex = /\[(\d+:\d+(?:\.\d+)?)\](.*)/;
            for (let i = 0; i < lines.length; i++) {
                let match = regex.exec(lines[i]);
                if (match) {
                    let timeParts = match[1].split(":");
                    let timeSec = (parseFloat(timeParts[0]) || 0) * 60.0 + (parseFloat(timeParts[1]) || 0);
                    let text = match[2].trim();
                    if (text.length === 0) {
                        text = "♪";
                    }
                    parsed.push({ time: timeSec, text: text });
                }
            }
            root.lyricLines = parsed;
            root.buildGroupIndex();
        }
    }

    function isSupportedPlayer(player) {
        if (!player) return false;
        let id = (player.identity || "").toLowerCase();
        let entry = (player.desktopEntry || "").toLowerCase();
        let bus = (player.busName || "").toLowerCase();
        let isSpotify = id.includes("spotify") || entry.includes("spotify") || bus.includes("spotify");
        let isAudacious = id.includes("audacious") || entry.includes("audacious") || bus.includes("audacious");
        return isSpotify || isAudacious;
    }

    function syncTrackChange() {
        let newTitle = activePlayer?.trackTitle || "";
        let newArtist = activePlayer?.trackArtist || "";
        if (newTitle !== root.currentTrackName || newArtist !== root.currentArtistName) {
            root.currentTrackName = newTitle;
            root.currentArtistName = newArtist;
            root.lastKnownPosition = activePlayer?.position || 0;
            root.lastKnownTimestamp = Date.now();
            if (root.isSupportedPlayer(activePlayer)) {
                root.fetchLyrics(root.currentTrackName, root.currentArtistName);
            } else {
                root.lyricLines = [];
                root.lyricGroupIndex = [];
                root.hasUnsyncedLyrics = false;
                root.currentLyricLine = "";
                root.currentLyricLineRich = "";
                root.currentGroupStartIdx = -1;
                root.nextLyricLine = "";
            }
        }
    }

    Connections {
        target: activePlayer
        function onTrackTitleChanged() { root.syncTrackChange(); }
        function onTrackArtistChanged() { root.syncTrackChange(); }
        function onPositionChanged() {
            root.lastKnownPosition = activePlayer?.position || 0;
            root.lastKnownTimestamp = Date.now();
        }
    }

    Connections {
        target: MprisController
        function onActivePlayerChanged() { root.syncTrackChange(); }
    }

    TextMetrics {
        id: lyricMetrics
        font.family: Appearance?.font?.family?.main ?? ""
        font.pixelSize: Appearance?.font?.pixelSize?.small ?? 15
    }

    function measurePixelWidth(str) {
        if (!str) return 0;
        lyricMetrics.text = str;
        return lyricMetrics.advanceWidth;
    }



    function buildGroupIndex() {
        let lines = root.lyricLines;
        if (!lines || lines.length === 0) {
            root.lyricGroupIndex = [];
            return;
        }
        let maxAllowedPx = Math.max(160, (GlobalStates?.topBarMediaWidth ?? 440) - 135);
        root.lastGroupWidth = maxAllowedPx;

        function isLineRepeat(k) {
            if (k < 0 || k >= lines.length) return false;
            let txt = lines[k].text;
            if (txt === "♪") return false;
            return (k > 0 && lines[k - 1].text === txt) || (k + 1 < lines.length && lines[k + 1].text === txt);
        }

        let index = [];
        let i = 0;
        while (i < lines.length) {
            let start = i;
            let groupText = lines[i].text;
            let j = i + 1;

            // Never group instrumental markers or lines belonging to a repeat series
            if (groupText !== "♪" && !isLineRepeat(i)) {
                while (j < lines.length) {
                    let nextText = lines[j].text;

                    // Stop if next item is an instrumental pause or repeat sequence
                    if (nextText === "♪" || isLineRepeat(j)) break;

                    let gap = lines[j].time - lines[j - 1].time;
                    let totalSpan = lines[j].time - lines[start].time;

                    // Cadence / Stanza break check:
                    // Gaps > 4.8s mark a distinct pause or stanza transition
                    if (gap > 4.8 || totalSpan > 11.0) break;

                    // Allow up to 3 lines (triplets) whenever they fit comfortably in the bar width
                    let count = (j - start) + 1;
                    if (count > 3) break;

                    // Dynamic reserve: if candidate line j is followed by an instrumental gap (> 7s or ♪),
                    // reserve extra width (~65px) for the upcoming (♪ Xs) countdown timer so it never marquees.
                    let hasTimer = (j + 1 < lines.length) && (lines[j + 1].time - lines[j].time > 7.0 || lines[j + 1].text === "♪");
                    let reserve = hasTimer ? 65 : 20;

                    // Width check with actual font rendering
                    let candidateText = groupText + " • " + nextText;
                    let candidatePx = root.measurePixelWidth(candidateText);
                    if (candidatePx > maxAllowedPx - reserve) break;

                    groupText = candidateText;
                    j++;
                }
            }

            let group = { startIdx: start, endIdx: j - 1, text: groupText, nextStartIdx: j };
            for (let k = start; k < j; k++) {
                index.push(group);
            }
            i = j;
        }
        root.lyricGroupIndex = index;
    }

    Timer {
        id: groupIndexDebounce
        interval: 150
        running: false
        onTriggered: {
            if (root.lyricLines.length > 0) root.buildGroupIndex()
        }
    }

    Connections {
        target: GlobalStates
        function onTopBarMediaWidthChanged() {
            groupIndexDebounce.restart()
        }
    }

    Timer {
        interval: 200
        repeat: true
        running: activePlayer?.playbackState === MprisPlaybackState.Playing && root.lyricLines.length > 0
        onTriggered: {
            let pos = activePlayer?.position || 0;
            let elapsedSec = (Date.now() - root.lastKnownTimestamp) / 1000.0;

            if (pos !== root.lastKnownPosition) {
                if (Math.abs(pos - (root.lastKnownPosition + elapsedSec)) > 1.5) {
                    root.lastKnownPosition = pos;
                    root.lastKnownTimestamp = Date.now();
                    elapsedSec = 0;
                }
            }

            let currentPos = root.lastKnownPosition + elapsedSec;
            let audioSyncPos = Math.max(0, currentPos + root.syncLeadSeconds);

            let lines = root.lyricLines;
            let groups = root.lyricGroupIndex;

            if (!groups || groups.length !== lines.length) return;

            let currIdx = -1;
            for (let i = 0; i < lines.length; i++) {
                if (audioSyncPos >= lines[i].time) {
                    currIdx = i;
                } else {
                    break;
                }
            }

            let newCurrentLine = "";
            let newCurrentLineRich = "";
            let newNextLine = "";
            let newGroupStartIdx = -1;

            if (currIdx >= 0) {
                let currGroup = groups[currIdx];
                let baseText = currGroup.text;

                // Sub-line split fade for multi-line groups
                let baseTextRich = "";
                if (currGroup.startIdx < currGroup.endIdx) {
                    let parts = [];
                    for (let m = currGroup.startIdx; m <= currGroup.endIdx; m++) {
                        let lineText = lines[m].text;
                        if (m < currIdx) {
                            parts.push(`<font color="${root.colPastHex}">${lineText}</font>`);
                        } else if (m === currIdx) {
                            parts.push(`<font color="${root.colActiveHex}">${lineText}</font>`);
                        } else {
                            parts.push(`<font color="${root.colUpcomingHex}">${lineText}</font>`);
                        }
                    }
                    baseTextRich = parts.join(`<font color="${root.colBulletHex}"> • </font>`);
                } else {
                    baseTextRich = `<font color="${root.colActiveHex}">${baseText}</font>`;
                }

                let isSingleLine = currGroup.startIdx === currGroup.endIdx;
                let identicalCount = 1;
                let rawGroupText = lines[currGroup.startIdx].text;
                let repeatSeriesStart = currGroup.startIdx;

                // Repeat multipliers (x2, x3) only apply to consecutive repeats of a single line
                if (isSingleLine && rawGroupText !== "♪") {
                    for (let k = currGroup.endIdx + 1; k < lines.length; k++) {
                        if (lines[k].text === rawGroupText) {
                            identicalCount++;
                        } else {
                            break;
                        }
                    }

                    // Walk backwards to find the origin of this repeated line
                    for (let p = currGroup.startIdx - 1; p >= 0; p--) {
                        if (lines[p].text === rawGroupText) {
                            repeatSeriesStart = p;
                        } else {
                            break;
                        }
                    }
                }

                // If this is part of a repeated sequence, bind group key to series origin
                newGroupStartIdx = repeatSeriesStart;

                // Detect if this is the last repeat in a series → show (x1)
                // Only applies to single-line groups — joined groups are never a repeat tail
                let isLastOfSeries = isSingleLine
                    && identicalCount === 1
                    && currGroup.startIdx > 0
                    && lines[currGroup.startIdx - 1].text === rawGroupText;

                if (identicalCount > 1 || isLastOfSeries) {
                    baseText = `${baseText} (x${identicalCount})`;
                    baseTextRich = `${baseTextRich} <font color="${root.colTimerHex}">(x${identicalCount})</font>`;
                }

                let hasNextGroup = currGroup.nextStartIdx < lines.length;
                let nextTime = hasNextGroup ? lines[currGroup.nextStartIdx].time : -1;

                if (hasNextGroup) {
                    let nextGroup = groups[currGroup.nextStartIdx];
                    newNextLine = nextGroup.text;

                    let remaining = Math.max(0, Math.ceil(nextTime - audioSyncPos));

                    if (currGroup.text === "♪") {
                        // Walk backwards past all consecutive ♪ to find the real previous lyric
                        let prevText = "";
                        for (let p = currGroup.startIdx - 1; p >= 0; p--) {
                            if (lines[p].text !== "♪") {
                                prevText = groups[p].text;
                                break;
                            }
                        }
                        if (remaining > 0) {
                            if (prevText) {
                                newCurrentLine = `${prevText} (♪ ${remaining}s)`;
                                newCurrentLineRich = `<font color="${root.colWaitingSingleHex}">${prevText}</font> <font color="${root.colTimerHex}">(♪ ${remaining}s)</font>`;
                            } else {
                                let trackInfo = root.getTrackBaseInfo();
                                if (trackInfo.plain) {
                                    newCurrentLine = `${trackInfo.plain} (Intro ♪ ${remaining}s)`;
                                    newCurrentLineRich = `${trackInfo.rich} <font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                                } else {
                                    newCurrentLine = `(Intro ♪ ${remaining}s)`;
                                    newCurrentLineRich = `<font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                                }
                            }
                        } else {
                            // Timer done but next lyric not yet — hold the previous text or track info
                            if (prevText) {
                                newCurrentLine = prevText;
                                newCurrentLineRich = `<font color="${root.colWaitingSingleHex}">${prevText}</font>`;
                            } else {
                                let trackInfo = root.getTrackBaseInfo();
                                newCurrentLine = trackInfo.plain || "";
                                newCurrentLineRich = trackInfo.rich || "";
                            }
                        }
                    } else if (remaining > 0) {
                        let gap = nextTime - lines[currGroup.endIdx].time;
                        let timeSinceStart = audioSyncPos - lines[currGroup.endIdx].time;
                        if (gap > 7.0 && timeSinceStart > 4.0) {
                            newCurrentLine = `${baseText} (♪ ${remaining}s)`;
                            // Line has ended and is waiting in gap countdown: remove boldness and soften past line
                            let waitingHex = (currGroup.startIdx < currGroup.endIdx)
                                ? root.colWaitingGroupHex
                                : root.colWaitingSingleHex;
                            newCurrentLineRich = `<font color="${waitingHex}">${baseText}</font> <font color="${root.colTimerHex}">(♪ ${remaining}s)</font>`;
                        } else {
                            newCurrentLine = baseText;
                            newCurrentLineRich = baseTextRich;
                        }
                    } else {
                        newCurrentLine = baseText;
                        newCurrentLineRich = baseTextRich;
                    }
                } else {
                    let trackLen = activePlayer?.length || 0;
                    let remainingInTrack = Math.max(0, Math.ceil(trackLen - audioSyncPos));
                    let trackInfo = root.getTrackBaseInfo();

                    if (trackLen > 0 && remainingInTrack > 10.0) {
                        newCurrentLine = trackInfo.plain ? `${trackInfo.plain} (Outro)` : "Outro";
                        newCurrentLineRich = trackInfo.plain
                            ? `${trackInfo.rich} <font color="${root.colTimerHex}">(Outro)</font>`
                            : `<font color="${root.colTimerHex}">Outro</font>`;
                    } else if (baseText !== "♪") {
                        newCurrentLine = baseText;
                        newCurrentLineRich = baseTextRich;
                    } else {
                        // Walk backwards past all consecutive ♪ to find the last real lyric
                        let lastReal = "";
                        for (let r = currGroup.startIdx - 1; r >= 0; r--) {
                            if (lines[r].text !== "♪") { lastReal = lines[r].text; break; }
                        }
                        if (lastReal) {
                            newCurrentLine = lastReal;
                            newCurrentLineRich = `<font color="${root.colWaitingSingleHex}">${lastReal}</font>`;
                        } else {
                            newCurrentLine = trackInfo.plain || "";
                            newCurrentLineRich = trackInfo.rich || "";
                        }
                    }
                }
            } else if (lines.length > 0) {
                let firstGroup = groups[0];
                newNextLine = firstGroup.text;
                let remaining = Math.max(0, Math.ceil(lines[0].time - audioSyncPos));
                let trackInfo = root.getTrackBaseInfo();
                if (remaining > 0) {
                    if (trackInfo.plain) {
                        newCurrentLine = `${trackInfo.plain} (Intro ♪ ${remaining}s)`;
                        newCurrentLineRich = `${trackInfo.rich} <font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                    } else {
                        newCurrentLine = `(Intro ♪ ${remaining}s)`;
                        newCurrentLineRich = `<font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                    }
                } else {
                    newCurrentLine = trackInfo.plain || "";
                    newCurrentLineRich = trackInfo.rich || "";
                }
            }

            if (root.currentLyricLine !== newCurrentLine) root.currentLyricLine = newCurrentLine;
            if (root.currentLyricLineRich !== newCurrentLineRich) root.currentLyricLineRich = newCurrentLineRich;
            if (root.currentGroupStartIdx !== newGroupStartIdx) root.currentGroupStartIdx = newGroupStartIdx;
            if (root.nextLyricLine !== newNextLine) root.nextLyricLine = newNextLine;
        }
    }

    Component.onCompleted: {
        root.syncTrackChange();
    }
}
