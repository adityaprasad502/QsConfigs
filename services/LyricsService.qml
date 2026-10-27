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
    property bool hasWordSync: false

    property var activeGetXhr: null
    property var activeSearchXhr: null
    property var syllableCallback: null
    property int syllableFetchId: 0

    property real lastKnownPosition: 0
    property real lastKnownTimestamp: 0
    property real lastWordSyncPos: 0
    property real syncLeadSeconds: 0.25 // Lead time in seconds (switches to next line slightly earlier)

    // Precomputed lyric style colors: reactive to theme/wallpaper changes, evaluated once (0 overhead in tick)
    readonly property string colPastHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.35).toString()
    readonly property string colUpcomingHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.40).toString()
    readonly property string colLitHex: ColorUtils.applyAlpha(Appearance?.colors?.colOnLayer1 ?? Appearance?.colors?.colOnLayer0 ?? "#e6e1e1", 0.85).toString()
    readonly property string colActiveHex: colLitHex
    readonly property string colWordHighlightHex: (Appearance?.colors?.colPrimary ?? "#38bdf8").toString()
    readonly property string colBulletHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.40).toString()
    readonly property string colTimerHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.60).toString()
    readonly property string colWaitingGroupHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.60).toString()
    readonly property string colWaitingSingleHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.75).toString()

    // Background vocal styling: softer harmony glow and dimmer upcoming tone (Apple Music style)
    readonly property string colBgLitHex: ColorUtils.applyAlpha(root.colLitHex, 0.60).toString()
    readonly property string colBgUpcomingHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.25).toString()
    readonly property string colBgPastHex: ColorUtils.applyAlpha(Appearance?.colors?.colSubtext ?? "#948f94", 0.25).toString()

    readonly property var charFadeShades: {
        let arr = [];
        for (let s = 0; s <= 20; s++) {
            let frac = s / 20.0;
            arr.push(ColorUtils.mix(root.colLitHex, root.colUpcomingHex, frac).toString());
        }
        return arr;
    }

    readonly property var charFadeShadesBg: {
        let arr = [];
        for (let s = 0; s <= 20; s++) {
            let frac = s / 20.0;
            arr.push(ColorUtils.mix(root.colBgLitHex, root.colBgUpcomingHex, frac).toString());
        }
        return arr;
    }

    function vocalEase(t, dur) {
        if (t <= 0) return 0;
        if (t >= 1) return 1;
        if (dur < 0.18) return t;
        // Smoothstep Hermite S-curve for natural vocal resonance
        return t * t * (3.0 - 2.0 * t);
    }

    function escapeXml(s) {
        if (!s) return "";
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function formatLineRich(rawText, mainCol, bgCol) {
        if (!rawText) return "";
        let parenRegex = /(\([^\)]*\))/g;
        let parts = rawText.split(parenRegex);
        let res = "";
        for (let i = 0; i < parts.length; i++) {
            let part = parts[i];
            if (!part) continue;
            let esc = root.escapeXml(part);
            if (part.startsWith("(") && part.endsWith(")")) {
                let col = bgCol || root.colBgLitHex;
                res += `<i><font color="${col}">${esc}</font></i>`;
            } else {
                let col = mainCol || root.colLitHex;
                res += `<font color="${col}">${esc}</font>`;
            }
        }
        return res;
    }

    function generateWordRichText(line, currentSec) {
        if (!line || !line.isWordSynced || !line.words || line.words.length === 0) {
            return `<font color="${root.colLitHex}">${root.escapeXml(line ? line.text : "")}</font>`;
        }

        let words = line.words;
        let chunks = [];

        for (let i = 0; i < words.length; i++) {
            let w = words[i];
            let isBg = w.isBg || false;

            if (currentSec >= w.end) {
                chunks.push({ type: "sung", text: w.text, isBg: isBg });
            } else if (currentSec >= w.start) {
                let rawText = w.text || "";
                let leadMatch = rawText.match(/^\s*/);
                let trailMatch = rawText.match(/\s*$/);
                let leadSpace = leadMatch ? leadMatch[0] : "";
                let trailSpace = trailMatch ? trailMatch[0] : "";
                let coreText = rawText.substring(leadSpace.length, rawText.length - trailSpace.length);

                if (coreText.length === 0) {
                    chunks.push({ type: "sung", text: rawText, isBg: isBg });
                    continue;
                }

                let dur = Math.max(0.001, (w.end - w.start));
                let rawT = Math.max(0.0, Math.min(1.0, (currentSec - w.start) / dur));
                let t = root.vocalEase(rawT, dur);

                let chars = Array.from(coreText);
                let len = chars.length;

                if (len <= 1) {
                    let shadeIdx = Math.round(t * 20);
                    chunks.push({
                        type: "active",
                        sung: leadSpace,
                        active: coreText,
                        upcoming: trailSpace,
                        shade: shadeIdx,
                        isBg: isBg
                    });
                } else {
                    let charPos = t * len;
                    let activeIdx = Math.min(len - 1, Math.floor(charPos));
                    let charFrac = charPos - activeIdx;
                    let shadeIdx = Math.round(charFrac * 20);

                    chunks.push({
                        type: "active",
                        sung: leadSpace + chars.slice(0, activeIdx).join(""),
                        active: chars[activeIdx],
                        upcoming: chars.slice(activeIdx + 1).join("") + trailSpace,
                        shade: shadeIdx,
                        isBg: isBg
                    });
                }
            } else {
                chunks.push({ type: "upcoming", text: w.text, isBg: isBg });
            }
        }

        // Collapse adjacent identical chunks to minimize DOM tag nodes
        let consolidated = [];
        for (let c = 0; c < chunks.length; c++) {
            let ch = chunks[c];
            if (consolidated.length > 0 &&
                consolidated[consolidated.length - 1].type === ch.type &&
                consolidated[consolidated.length - 1].isBg === ch.isBg &&
                ch.type !== "active") {
                consolidated[consolidated.length - 1].text += ch.text;
            } else {
                consolidated.push(ch);
            }
        }

        let res = "";
        for (let k = 0; k < consolidated.length; k++) {
            let item = consolidated[k];
            let isBg = item.isBg;
            let litCol = isBg ? root.colBgLitHex : root.colLitHex;
            let dimCol = isBg ? root.colBgUpcomingHex : root.colUpcomingHex;

            if (item.type === "sung") {
                let part = `<font color="${litCol}">${root.escapeXml(item.text)}</font>`;
                res += isBg ? `<i>${part}</i>` : part;
            } else if (item.type === "active") {
                let fadeCol = isBg
                    ? (root.charFadeShadesBg[item.shade] || root.colBgLitHex)
                    : (root.charFadeShades[item.shade] || root.colLitHex);
                let part = "";
                if (item.sung && item.sung.length > 0) {
                    part += `<font color="${litCol}">${root.escapeXml(item.sung)}</font>`;
                }
                part += `<font color="${fadeCol}">${root.escapeXml(item.active)}</font>`;
                if (item.upcoming && item.upcoming.length > 0) {
                    part += `<font color="${dimCol}">${root.escapeXml(item.upcoming)}</font>`;
                }
                res += isBg ? `<i>${part}</i>` : part;
            } else if (item.type === "upcoming") {
                let part = `<font color="${dimCol}">${root.escapeXml(item.text)}</font>`;
                res += isBg ? `<i>${part}</i>` : part;
            }
        }

        return res;
    }

    // Precomputed track title + artist strings: reactive to track/theme changes, zero overhead in 200ms tick
    readonly property string trackInfoPlain: {
        let rawTitle = activePlayer?.trackTitle || "";
        let tName = StringUtils.cleanMusicTitle(rawTitle) || rawTitle;
        let tArtist = activePlayer?.trackArtist || "";
        return (tName && tArtist) ? `${tName} • ${tArtist}` : (tName || tArtist);
    }
    readonly property string trackInfoRich: {
        let rawTitle = activePlayer?.trackTitle || "";
        let tName = StringUtils.cleanMusicTitle(rawTitle) || rawTitle;
        let tArtist = activePlayer?.trackArtist || "";
        return (tName && tArtist)
            ? `<font color="${root.colActiveHex}">${tName}</font><font color="${root.colBulletHex}"> • </font><font color="${root.colActiveHex}">${tArtist}</font>`
            : `<font color="${root.colActiveHex}">${tName || tArtist}</font>`;
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

    Process {
        id: syllableProc
        stdout: StdioCollector {}
        stderr: SplitParser {
            onRead: data => {
                let msg = data.trim();
                if (msg.startsWith("STATUS:")) {
                    root.loadingStatus = msg.substring(7).trim();
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            let out = syllableProc.stdout.text || "";
            let cb = root.syllableCallback;
            let fid = root.syllableFetchId;
            root.syllableCallback = null;
            if (cb) {
                cb(exitCode === 0 ? out : "", fid);
            }
        }
    }

    function abortAllXhrs() {
        if (root.activeGetXhr) { root.activeGetXhr.abort(); root.activeGetXhr = null; }
        if (root.activeSearchXhr) { root.activeSearchXhr.abort(); root.activeSearchXhr = null; }
        if (syllableProc.running) { syllableProc.running = false; }
        root.syllableCallback = null;
    }

    function fetchSyllableLyrics(fetchId, cleanTrack, cleanArtist, targetDuration, cacheKey, onFallback) {
        if (syllableProc.running) {
            syllableProc.running = false;
        }
        root.syllableFetchId = fetchId;
        root.syllableCallback = function(output, fid) {
            if (fid !== root.currentFetchId) return;
            if (output && output.includes("<") && output.includes(">")) {
                let parsed = root.parseLyricsString(output);
                if (parsed && parsed.length > 0 && parsed.some(function(l) { return l.isWordSynced; })) {
                    root.lyricCache[cacheKey] = { syncedLyrics: output, lines: parsed, hasWordSync: true };
                    root.lyricLines = parsed;
                    root.hasWordSync = true;
                    root.hasUnsyncedLyrics = false;
                    root.buildGroupIndex();
                    root.loading = false;
                    root.loadingStatus = "";
                    return;
                }
            }
            if (onFallback) onFallback();
        };

        root.loadingStatus = "Searching (src1)…";
        syllableProc.command = [
            "python3",
            Quickshell.shellPath("scripts/lyrics/syllables.py"),
            cleanTrack,
            cleanArtist,
            String(targetDuration || 0)
        ];
        syllableProc.running = true;
    }

    function fetchLrclib(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey) {
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
                    root.loadingStatus = "Searching (src4 deep)…";
                    root.searchLyricsFallback(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey);
                }
            };
            getXhr.open("GET", getUrl, true);
            getXhr.setRequestHeader("User-Agent", root._uaVal);
            getXhr.setRequestHeader(root._lcName, root._uaVal);
            getXhr.setRequestHeader(root._xuaName, root._uaVal);
            getXhr.send();
        } else {
            root.loadingStatus = "Searching (src4)…";
            root.searchLyricsFallback(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey);
        }
    }

    function fetchLyrics(track, artist) {
        root.abortAllXhrs();

        root.currentFetchId++;
        let myFetchId = root.currentFetchId;

        if (!track || track === "") {
            root.lyricLines = [];
            root.lyricGroupIndex = [];
            root.hasUnsyncedLyrics = false;
            root.hasWordSync = false;
            root.currentLyricLine = "";
            root.currentLyricLineRich = "";
            root.currentGroupStartIdx = -1;
            root.nextLyricLine = "";
            root.loading = false;
            root.loadingStatus = "";
            return;
        }
        root.loading = true;
        root.loadingStatus = "Searching (src1)…";
        root.lyricLines = [];
        root.lyricGroupIndex = [];
        root.currentLyricLine = "";
        root.currentLyricLineRich = "";
        root.currentGroupStartIdx = -1;
        root.nextLyricLine = "";
        root.hasUnsyncedLyrics = false;
        root.hasWordSync = false;

        let cleanTrack = StringUtils.cleanMusicTitle(track);
        let cleanArtist = artist || "";
        let cacheKey = (cleanTrack + "___" + cleanArtist).toLowerCase();

        // Simple cache size limit
        if (Object.keys(root.lyricCache).length > 50) {
            root.lyricCache = ({});
        }

        let targetDuration = Math.round(activePlayer?.length || 0);

        if (root.lyricCache[cacheKey]) {
            root.loading = false;
            root.loadingStatus = "";
            root.parseLyricsResponse(root.lyricCache[cacheKey]);
            return;
        }

        // Word-level priority: try syllable-synced lyrics first
        root.fetchSyllableLyrics(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey, function() {
            // Fallback to LRCLIB
            root.fetchLrclib(myFetchId, cleanTrack, cleanArtist, targetDuration, cacheKey);
        });
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

    function parseTimeHeader(h) {
        if (!h) return 0;
        if (h.includes(":")) {
            let p = h.split(":");
            return (parseFloat(p[0]) || 0) * 60.0 + (parseFloat(p[1]) || 0);
        } else if (h.includes(",")) {
            let p = h.split(",");
            return (parseFloat(p[0]) || 0) / 1000.0;
        }
        let v = parseFloat(h) || 0;
        return v > 1000 ? v / 1000.0 : v;
    }


    function isCreditOrMetadataLine(text, duration, timeSec, isWordSynced) {
        if (!text) return true;
        let t = text.trim();
        if (t === "" || t === "♪") return false;

        let creditPattern = /^(lyrics?( by)?|lyricist|composed?( by)?|composer|written( by)?|writer|produced?( by)?|producer|arranged?( by)?|arranger|music( by)?|vocals?( by)?|track\s*[:：\-]|artist\s*[:：\-]|album\s*[:：\-]|synced by|lrc by|source\s*[:：]|mixing( by)?|mixed by|mastering( by)?|mastered by|recorded?( by)?|recording( by)?|engineered by|publisher|label|qqmusic|kugou|netease|163\.com|lrclib|作\s*词|作\s*曲|编\s*曲|制\s*作|演唱|词曲|词\s*[:：]|曲\s*[:：]|录音|混音|母带|监制|统筹|企划|出品|发行|后期|和声|合音|吉他|贝斯|鼓|键盘|弦乐|文案|原唱|翻唱|伴奏|配唱|乐器)/i;
        if (creditPattern.test(t)) return true;

        if (!isWordSynced && timeSec < 12.0) {
            let nt = root.normalizeStr(t);
            let nTitle = root.normalizeStr(root.currentTrackName || activePlayer?.trackTitle || "");
            let nArtist = root.normalizeStr(root.currentArtistName || activePlayer?.trackArtist || "");
            if (nTitle && nArtist && nt.includes(nTitle) && nt.includes(nArtist)) return true;
            if (/^.+?\s*[-–—]\s*.+?$/.test(t) && ((nTitle && nt.includes(nTitle)) || (nArtist && nt.includes(nArtist)))) return true;
        }

        return false;
    }

    function parseLyricsString(synced) {
        if (!synced) return [];

        let globalOffsetSec = 0;
        let offsetMatch = synced.match(/\[offset:\s*([+-]?\d+)\]/i);
        if (offsetMatch) {
            let offsetMs = parseFloat(offsetMatch[1]) || 0;
            globalOffsetSec = offsetMs / 1000.0;
        }

        let parsed = [];
        let lines = synced.split("\n");

        for (let i = 0; i < lines.length; i++) {
            let rawLine = lines[i].trim();
            if (!rawLine) continue;

            let headers = [];
            let headerRegex = /\[(\d+:\d+(?:\.\d+)?|\d+,\d+)\]/g;
            let lastIdx = 0;
            let match;
            while ((match = headerRegex.exec(rawLine)) !== null) {
                if (match.index === lastIdx) {
                    headers.push(match[1]);
                    lastIdx = headerRegex.lastIndex;
                } else {
                    break;
                }
            }
            if (headers.length === 0) continue;

            let content = rawLine.substring(lastIdx);

            for (let h = 0; h < headers.length; h++) {
                let timeSec = Math.max(0, root.parseTimeHeader(headers[h]) - globalOffsetSec);
                let lineDuration = 0;
                if (headers[h].includes(",")) {
                    lineDuration = (parseFloat(headers[h].split(",")[1]) || 0) / 1000.0;
                }

                let words = [];
                let isWordSynced = false;

                if (content.includes("<") && content.includes(">")) {
                    let tagRegex = /<([^>]+)>([^<]*)/g;
                    let tm;
                    let tokens = [];
                    while ((tm = tagRegex.exec(content)) !== null) {
                        tokens.push({ tag: tm[1].trim(), text: tm[2] });
                    }

                    if (tokens.length > 0) {
                        for (let t = 0; t < tokens.length; t++) {
                            let tok = tokens[t];
                            let startSec = 0;
                            let endSec = 0;

                            if (tok.tag.includes(":")) {
                                let p = tok.tag.split(":");
                                startSec = (parseFloat(p[0]) || 0) * 60.0 + (parseFloat(p[1]) || 0) - globalOffsetSec;
                            } else if (tok.tag.includes(",")) {
                                let p = tok.tag.split(",");
                                let off = parseFloat(p[0]) || 0;
                                let dur = parseFloat(p[1]) || 0;
                                startSec = timeSec + (off / 1000.0);
                                endSec = startSec + (dur / 1000.0);
                            } else {
                                let v = parseFloat(tok.tag) || 0;
                                startSec = ((v > 1000) ? v / 1000.0 : v) - globalOffsetSec;
                            }

                            if (endSec <= startSec && t + 1 < tokens.length) {
                                let nextTag = tokens[t + 1].tag;
                                if (nextTag.includes(":")) {
                                    let np = nextTag.split(":");
                                    endSec = (parseFloat(np[0]) || 0) * 60.0 + (parseFloat(np[1]) || 0) - globalOffsetSec;
                                } else if (nextTag.includes(",")) {
                                    let np = nextTag.split(",");
                                    let noff = parseFloat(np[0]) || 0;
                                    endSec = timeSec + (noff / 1000.0);
                                }
                            }

                            if (tok.text.length > 0) {
                                words.push({ text: tok.text, start: Math.max(0, startSec), end: Math.max(0, endSec) });
                            } else if (words.length > 0 && (!words[words.length - 1].end || words[words.length - 1].end <= words[words.length - 1].start)) {
                                words[words.length - 1].end = Math.max(0, startSec);
                            }
                        }
                        if (words.length > 0) isWordSynced = true;
                    }
                } else if (/\(\d+,\d+\)/.test(content)) {
                    let parenRegex = /\((\d+),(\d+)\)([^(]*)/g;
                    let pm;
                    while ((pm = parenRegex.exec(content)) !== null) {
                        let off = parseFloat(pm[1]) || 0;
                        let dur = parseFloat(pm[2]) || 0;
                        let startSec = timeSec + (off / 1000.0);
                        let endSec = startSec + (dur / 1000.0);
                        let wText = pm[3];
                        if (wText.length > 0) {
                            words.push({ text: wText, start: startSec, end: endSec });
                        }
                    }
                    if (words.length > 0) isWordSynced = true;
                }

                let lineWords = (words.length > 0) ? words : null;
                if (lineWords && lineWords.length > 0) {
                    let inParen = false;
                    for (let wIdx = 0; wIdx < lineWords.length; wIdx++) {
                        let wObj = lineWords[wIdx];
                        if (wObj.text.includes("(")) inParen = true;
                        wObj.isBg = inParen || wObj.isBg || false;
                        if (wObj.text.includes(")")) inParen = false;
                    }
                }
                let cleanText = "";
                if (lineWords && lineWords.length > 0) {
                    cleanText = lineWords.map(w => w.text).join("").trim();
                } else {
                    cleanText = content.replace(/<[^>]+>/g, "").replace(/\(\d+,\d+\)/g, "").trim();
                }
                if (cleanText.length === 0) cleanText = "♪";

                if (root.isCreditOrMetadataLine(cleanText, lineDuration, timeSec, isWordSynced && lineWords && lineWords.length > 0)) {
                    continue;
                }

                let lineEnd = (lineWords && lineWords.length > 0 && lineWords[lineWords.length - 1].end > 0)
                    ? lineWords[lineWords.length - 1].end
                    : (lineDuration > 0 ? timeSec + lineDuration : 0);

                parsed.push({
                    time: timeSec,
                    endTime: lineEnd,
                    text: cleanText,
                    isWordSynced: isWordSynced && lineWords && lineWords.length > 0,
                    words: isWordSynced ? lineWords : null
                });
            }
        }

        if (parsed.length > 1) {
            parsed.sort((a, b) => a.time - b.time);
        }

        // Strip leading blank / placeholder / "♪" lines before the first genuine singing lyric
        while (parsed.length > 0 && (!parsed[0].text || parsed[0].text.trim() === "" || parsed[0].text === "♪")) {
            parsed.shift();
        }

        // Strip trailing blank lines
        while (parsed.length > 0 && (!parsed[parsed.length - 1].text || parsed[parsed.length - 1].text.trim() === "")) {
            parsed.pop();
        }

        for (let i = 0; i < parsed.length; i++) {
            let p = parsed[i];
            if (!p.endTime || p.endTime <= p.time) {
                p.endTime = (i + 1 < parsed.length) ? parsed[i + 1].time : (p.time + 4.5);
            }
            if (p.isWordSynced && p.words && p.words.length > 0) {
                let lastW = p.words[p.words.length - 1];
                if (!lastW.end || lastW.end <= lastW.start) {
                    lastW.end = p.endTime;
                }
            }
        }

        return parsed;
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
            } catch(e) {}
        }

        root.hasUnsyncedLyrics = (!parsed || parsed.length === 0) && data.plainLyrics && data.plainLyrics.length > 0;
        if (parsed && parsed.length > 0) {
            root.lyricLines = parsed;
            root.hasWordSync = parsed.some(function(l) { return l.isWordSynced; });
            root.buildGroupIndex();
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
        let bus = (player.busName || "").toLowerCase();
        let isSpotify = id.includes("spotify") || entry.includes("spotify") || bus.includes("spotify");
        let isAudacious = id.includes("audacious") || entry.includes("audacious") || bus.includes("audacious");
        let isKdeConnect = id.includes("kdeconnect") || entry.includes("kdeconnect") || bus.includes("kdeconnect");
        return isSpotify || isAudacious || isKdeConnect || true;
    }

    function syncTrackChange() {
        let newTitle = activePlayer?.trackTitle || "";
        let newArtist = activePlayer?.trackArtist || "";
        if (newTitle !== root.currentTrackName || newArtist !== root.currentArtistName) {
            root.currentTrackName = newTitle;
            root.currentArtistName = newArtist;
            root.lastKnownPosition = (activePlayer?.position && activePlayer.position < 3.0) ? activePlayer.position : 0;
            root.lastKnownTimestamp = Date.now();
            root.lastWordSyncPos = root.lastKnownPosition;
            if (root.isSupportedPlayer(activePlayer)) {
                root.fetchLyrics(root.currentTrackName, root.currentArtistName);
            } else {
                root.lyricLines = [];
                root.lyricGroupIndex = [];
                root.hasUnsyncedLyrics = false;
                root.hasWordSync = false;
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
            let p = activePlayer?.position || 0;
            let now = Date.now();
            let est = root.lastKnownPosition + (now - root.lastKnownTimestamp) / 1000.0;
            if (Math.abs(p - est) > 1.2) {
                root.lastKnownPosition = p;
                root.lastKnownTimestamp = now;
                root.lastWordSyncPos = p;
            } else if (Math.abs(p - est) > 0.05) {
                root.lastKnownPosition += (p - est) * 0.15;
            }
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
        interval: root.hasWordSync ? 25 : 200
        repeat: true
        running: activePlayer?.playbackState === MprisPlaybackState.Playing && root.lyricLines.length > 0
        onTriggered: {
            let pos = activePlayer?.position || 0;
            let now = Date.now();
            let elapsedSec = (now - root.lastKnownTimestamp) / 1000.0;

            if (pos !== root.lastKnownPosition) {
                let drift = pos - (root.lastKnownPosition + elapsedSec);
                if (Math.abs(drift) > 1.2) {
                    root.lastKnownPosition = pos;
                    root.lastKnownTimestamp = now;
                    elapsedSec = 0;
                    root.lastWordSyncPos = pos;
                } else if (Math.abs(drift) > 0.05) {
                    root.lastKnownPosition += drift * 0.15;
                }
            }

            let currentPos = root.lastKnownPosition + elapsedSec;
            // For word-by-word karaoke, words and lines synchronize precisely with audio playback (0s lead).
            let lineSyncPos = Math.max(0, currentPos + (root.hasWordSync ? 0.0 : root.syncLeadSeconds));
            let audioSyncPos = lineSyncPos;

            let wordSyncPos = Math.max(0, currentPos);
            if (activePlayer?.playbackState === MprisPlaybackState.Playing) {
                if (wordSyncPos >= root.lastWordSyncPos && (wordSyncPos - root.lastWordSyncPos) < 2.0) {
                    root.lastWordSyncPos = wordSyncPos;
                } else if (Math.abs(wordSyncPos - root.lastWordSyncPos) >= 2.0) {
                    root.lastWordSyncPos = wordSyncPos;
                } else {
                    wordSyncPos = root.lastWordSyncPos;
                }
            }

            let lines = root.lyricLines;
            let groups = root.lyricGroupIndex;

            if (!groups || groups.length !== lines.length) return;

            let currIdx = -1;
            for (let i = 0; i < lines.length; i++) {
                if (lineSyncPos >= lines[i].time) {
                    currIdx = i;
                } else {
                    break;
                }
            }

            // Anti-cut-off protection: Never jump to the next line before the current line's syllable animation finishes
            while (currIdx > 0 && lines[currIdx - 1].isWordSynced) {
                let prevEnd = lines[currIdx - 1].endTime || (lines[currIdx - 1].words && lines[currIdx - 1].words.length > 0 ? lines[currIdx - 1].words[lines[currIdx - 1].words.length - 1].end : 0);
                if (prevEnd > 0 && currentPos < prevEnd) {
                    currIdx--;
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

                // Sub-line split fade for multi-line groups (with progressive word-by-word highlight)
                let baseTextRich = "";
                if (currGroup.startIdx < currGroup.endIdx) {
                    let parts = [];
                    for (let m = currGroup.startIdx; m <= currGroup.endIdx; m++) {
                        let lObj = lines[m];
                        let lineText = root.escapeXml(lObj.text);
                        if (m < currIdx) {
                            // In karaoke (word-sync), keep previously sung lines glowing rather than turning them off
                            let pastCol = (root.hasWordSync || lObj.isWordSynced) ? root.colLitHex : root.colPastHex;
                            let pastBgCol = (root.hasWordSync || lObj.isWordSynced) ? root.colBgLitHex : root.colBgPastHex;
                            parts.push(root.formatLineRich(lObj.text, pastCol, pastBgCol));
                        } else if (m === currIdx) {
                            if (lObj.isWordSynced && lObj.words && lObj.words.length > 0) {
                                parts.push(root.generateWordRichText(lObj, wordSyncPos));
                            } else {
                                parts.push(root.formatLineRich(lObj.text, root.colActiveHex, root.colBgLitHex));
                            }
                        } else {
                            parts.push(root.formatLineRich(lObj.text, root.colUpcomingHex, root.colBgUpcomingHex));
                        }
                    }
                    baseTextRich = parts.join(`<font color="${root.colBulletHex}"> • </font>`);
                } else {
                    let lObj = lines[currGroup.startIdx];
                    if (lObj && lObj.isWordSynced && lObj.words && lObj.words.length > 0) {
                        baseTextRich = root.generateWordRichText(lObj, wordSyncPos);
                    } else {
                        baseTextRich = root.formatLineRich(baseText, root.colActiveHex, root.colBgLitHex);
                    }
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
                        let prevGroupIdx = -1;
                        for (let p = currGroup.startIdx - 1; p >= 0; p--) {
                            if (lines[p].text !== "♪") {
                                prevText = groups[p].text;
                                prevGroupIdx = p;
                                break;
                            }
                        }
                        // Use the correct waiting color: muted-group for couplets/triplets, muted-single for solo lines
                        let prevWaitingHex = (prevGroupIdx >= 0 && groups[prevGroupIdx].startIdx < groups[prevGroupIdx].endIdx)
                            ? root.colWaitingGroupHex
                            : root.colWaitingSingleHex;
                        if (remaining > 0) {
                            if (prevText) {
                                newCurrentLine = `${prevText} (♪ ${remaining}s)`;
                                newCurrentLineRich = `<font color="${prevWaitingHex}">${prevText}</font> <font color="${root.colTimerHex}">(♪ ${remaining}s)</font>`;
                            } else {
                                if (root.trackInfoPlain) {
                                    newCurrentLine = `${root.trackInfoPlain} (Intro ♪ ${remaining}s)`;
                                    newCurrentLineRich = `${root.trackInfoRich} <font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                                } else {
                                    newCurrentLine = `(Intro ♪ ${remaining}s)`;
                                    newCurrentLineRich = `<font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                                }
                            }
                        } else {
                            // Timer done but next lyric not yet — hold the previous text or track info
                            if (prevText) {
                                newCurrentLine = prevText;
                                newCurrentLineRich = `<font color="${prevWaitingHex}">${prevText}</font>`;
                            } else {
                                newCurrentLine = root.trackInfoPlain || "";
                                newCurrentLineRich = root.trackInfoRich || "";
                            }
                        }
                    } else {
                        let groupEndTime = lines[currGroup.endIdx].endTime || (lines[currGroup.endIdx].time + 3.0);
                        let isGroupFinished = wordSyncPos >= groupEndTime;
                        let gap = nextTime - groupEndTime;
                        let timeSinceEnd = wordSyncPos - groupEndTime;
                        let waitingHex = (currGroup.startIdx < currGroup.endIdx)
                            ? root.colWaitingGroupHex
                            : root.colWaitingSingleHex;

                        // Only show countdown timer if the current line has ACTUALLY finished vocalizing
                        // AND there is a substantial instrumental gap (> 5s) AND 2.5s have passed since singing finished!
                        if (remaining > 0 && isGroupFinished && gap > 5.0 && timeSinceEnd > 2.5) {
                            newCurrentLine = `${baseText} (♪ ${remaining}s)`;
                            newCurrentLineRich = `<font color="${waitingHex}">${root.escapeXml(baseText)}</font> <font color="${root.colTimerHex}">(♪ ${remaining}s)</font>`;
                        } else if (remaining === 0 && isGroupFinished && gap > 5.0 && timeSinceEnd > 2.5) {
                            newCurrentLine = baseText;
                            newCurrentLineRich = `<font color="${waitingHex}">${root.escapeXml(baseText)}</font>`;
                        } else {
                            // Actively singing OR brief gap before next line: NEVER interrupt the lyric animation!
                            newCurrentLine = baseText;
                            newCurrentLineRich = baseTextRich;
                        }
                    }
                } else {
                    let trackLen = activePlayer?.length || 0;
                    let groupEndTime = lines[currGroup.endIdx].endTime || (lines[currGroup.endIdx].time + 3.0);
                    let isGroupFinished = wordSyncPos >= groupEndTime;
                    let timeSinceLastLyric = wordSyncPos - groupEndTime;

                    if (currGroup.text === "♪") {
                        // Trailing instrumental marker at end of track: show Outro until song finishes
                        if (trackLen > 0) {
                            newCurrentLine = root.trackInfoPlain ? `${root.trackInfoPlain} (Outro)` : "Outro";
                            newCurrentLineRich = root.trackInfoPlain
                                ? `${root.trackInfoRich} <font color="${root.colTimerHex}">(Outro)</font>`
                                : `<font color="${root.colTimerHex}">Outro</font>`;
                        } else {
                            let lastReal = "";
                            for (let r = currGroup.startIdx - 1; r >= 0; r--) {
                                if (lines[r].text !== "♪") { lastReal = lines[r].text; break; }
                            }
                            if (lastReal) {
                                newCurrentLine = lastReal;
                                newCurrentLineRich = `<font color="${root.colWaitingSingleHex}">${lastReal}</font>`;
                            } else {
                                newCurrentLine = root.trackInfoPlain || "";
                                newCurrentLineRich = root.trackInfoRich || "";
                            }
                        }
                    } else {
                        // Real lyric at end of track:
                        let hasSignificantOutro = trackLen > 0 && (trackLen - groupEndTime) > 6.0;

                        if (isGroupFinished && hasSignificantOutro && timeSinceLastLyric >= 3.5) {
                            // Singer is done and substantial instrumental outro remains: show Outro and keep it
                            newCurrentLine = root.trackInfoPlain ? `${root.trackInfoPlain} (Outro)` : "Outro";
                            newCurrentLineRich = root.trackInfoPlain
                                ? `${root.trackInfoRich} <font color="${root.colTimerHex}">(Outro)</font>`
                                : `<font color="${root.colTimerHex}">Outro</font>`;
                        } else if (isGroupFinished && timeSinceLastLyric >= 3.5) {
                            // Song ends shortly after: keep holding the completed lyric muted
                            let waitingHex = (currGroup.startIdx < currGroup.endIdx)
                                ? root.colWaitingGroupHex
                                : root.colWaitingSingleHex;
                            newCurrentLine = baseText;
                            newCurrentLineRich = `<font color="${waitingHex}">${root.escapeXml(baseText)}</font>`;
                        } else {
                            // Actively being sung or just finished: keep full animated text!
                            newCurrentLine = baseText;
                            newCurrentLineRich = baseTextRich;
                        }
                    }
                }
            } else if (lines.length > 0) {
                let firstGroup = groups[0];
                newNextLine = firstGroup.text;
                let remaining = Math.max(0, Math.ceil(lines[0].time - audioSyncPos));
                if (remaining > 0) {
                    if (root.trackInfoPlain) {
                        newCurrentLine = `${root.trackInfoPlain} (Intro ♪ ${remaining}s)`;
                        newCurrentLineRich = `${root.trackInfoRich} <font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                    } else {
                        newCurrentLine = `(Intro ♪ ${remaining}s)`;
                        newCurrentLineRich = `<font color="${root.colTimerHex}">(Intro ♪ ${remaining}s)</font>`;
                    }
                } else {
                    newCurrentLine = root.trackInfoPlain || "";
                    newCurrentLineRich = root.trackInfoRich || "";
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
