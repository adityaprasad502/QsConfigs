pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs
import qs.modules.common
import qs.modules.common.functions

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
    property string currentLyricLine: ""
    property string currentLyricLineRich: ""
    property string currentLyricLineDim: ""
    property string currentLyricLineLit: ""
    property real currentLineProgress: 0.0
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

    // Precomputed lyric style colors: mixed over layer0 background so HTML <font color="..."> parses standard 6-digit RGB
    readonly property color _colLitBase: Appearance?.colors?.colOnLayer1 ?? Appearance?.colors?.colOnLayer0 ?? "#e6e1e1"
    readonly property color _colSubtextBase: Appearance?.colors?.colSubtext ?? "#948f94"
    readonly property color _colLyricBg: Appearance?.colors?.colLayer0 ?? "#161515"

    readonly property string colPastHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.35).toString()
    readonly property string colUpcomingHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.40).toString()
    readonly property string colLitHex: ColorUtils.mix(root._colLitBase, root._colLyricBg, 0.85).toString()
    readonly property string colActiveHex: colLitHex
    readonly property string colBulletHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.40).toString()
    readonly property string colTimerHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.60).toString()
    readonly property string colWaitingGroupHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.60).toString()
    readonly property string colWaitingSingleHex: colWaitingGroupHex

    // Background vocal styling: softer harmony glow and dimmer upcoming tone (Apple Music style)
    readonly property string colBgLitHex: ColorUtils.mix(root.colLitHex, root._colLyricBg, 0.60).toString()
    readonly property string colBgPastHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.20).toString()
    readonly property string colBgUpcomingHex: ColorUtils.mix(root._colSubtextBase, root._colLyricBg, 0.25).toString()

    // Anything baked into the cached rich-text strings; a change forces a rebuild
    readonly property string displaySig: colPastHex + colUpcomingHex + colLitHex + colBulletHex + colTimerHex
        + colWaitingGroupHex + colWaitingSingleHex + colBgLitHex + colBgPastHex + colBgUpcomingHex + trackInfoRich
    onDisplaySigChanged: {
        root._mMode = -1;
        Qt.callLater(root.tick);
    }

    // How much of a gentle S-curve is blended over the whole word (0 = none, 1 = full smoothstep)
    readonly property real wordEaseMix: 0.3

    function vocalEase(t, dur) {
        if (t <= 0) return 0;
        if (t >= 1) return 1;
        if (dur < 0.15) return t;
        return t + (t * t * (3.0 - 2.0 * t) - t) * root.wordEaseMix;
    }

    function escapeXml(s) {
        if (!s) return "";
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function formatLineRich(rawText, mainCol, bgCol) {
        if (!rawText) return "";
        let parts = rawText.split(/(\([^\)]*\))/g);
        let res = "";
        for (let i = 0; i < parts.length; i++) {
            let part = parts[i];
            if (!part) continue;
            let esc = root.escapeXml(part);
            if (part.startsWith("(") && part.endsWith(")")) {
                res += `<i><font color="${bgCol || root.colBgLitHex}">${esc}</font></i>`;
            } else {
                res += `<font color="${mainCol || root.colLitHex}">${esc}</font>`;
            }
        }
        return res;
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
    // Text helpers
    // ------------------------------------------------------------------------------------------
    readonly property string _cjk: "\\u3040-\\u30ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\uac00-\\ud7af"
    readonly property var _reCjkG: new RegExp("[" + _cjk + "]", "g")
    readonly property string _alpha: "a-z0-9\\u00c0-\\u024f\\u1e00-\\u1eff\\u0370-\\u03ff\\u0400-\\u04ff\\u0590-\\u06ff\\u0900-\\u097f\\u0e00-\\u0e7f"
    readonly property var _reLatinG: /[A-Za-z\u00c0-\u024f\u1e00-\u1eff]/g
    readonly property var _reNormStrip: new RegExp("[^" + _alpha + _cjk + "]", "g")
    readonly property var _reSymbolOnly: /^[\s.,\-_~*+=!?\u2026\u2014\u2013\u2022\u00b7\u266a\u266b\u266c\u3001\u3002\uff0c\uff01\uff1f\u300a\u300b()\[\]{}<>\/\\|:;'"`^#@&%$\u2605\u2606\u25cf\u25cb\u2500-\u257f]+$/
    readonly property var _reBrackets: /\s*[\(（\[［【〖《〈「『\{][^\)）\]］】〗》〉」』\}]*[\)）\]］】〗》〉」』\}]/g
    readonly property var _reInvisible: /[\ufeff\u200b-\u200d\u2060]/g

    // Translation glued to a line: "English / 中文", "English (中文)", "中文 / English"
    readonly property var _reTransSlashLatin: new RegExp("^(.*[A-Za-z0-9].*?)\\s*[\\/|\\uff5c]\\s*[" + _cjk + "][^A-Za-z]*$")
    readonly property var _reTransParenLatin: new RegExp("^(.*[A-Za-z0-9].*?)\\s*[\\(\\uff08][^A-Za-z\\)\\uff09]*[" + _cjk + "][^A-Za-z\\)\\uff09]*[\\)\\uff09]\\s*$")
    readonly property var _reTransSlashCjk: new RegExp("^(.*[" + _cjk + "].*?)\\s*[\\/|\\uff5c]\\s*[A-Za-z][^" + _cjk + "]*$")

    // Credits / metadata. "Hard" patterns are unambiguous and removed anywhere in the song.
    readonly property var _reHardEn: /^\s*(?:words?|lyrics?|lyricist|composers?|composed|composition|music|written|writers?|songwriters?|author|prod(?:uced|ucer|ucers|uction)|co-?producer|executive producer|vocals?(?: producer| arranger| arrangement| engineer)?|backing vocals?|background vocals?|arranged|arranger|arrangement|orchestra(?:ted|tion)?|conductor|mix(?:ed|ing|er)?|mix engineer|mastered|mastering|recorded|recording|engineer(?:ed)?|engineering|programm(?:ed|ing)|guitars?|bass|drums?|piano|keyboards?|strings|violin|cello|saxophone|trumpet|percussion|synth(?:esizer)?|publish(?:er|ing)|label|copyright|isrc|upc|op|sp|translat(?:or|ed|ion)|subtitles?|sync(?:ed)?|lrc|timeline|source|cover|original(?: (?:publisher|singer|artist|lyrics|title|composer))?|album|artist|singer|title|track|song|studio|credits?|presented|distribut(?:ion|ed)|licen[sc]ed|special thanks|thanks)(?:\s+by)?\s*[:：]/i
    readonly property var _reHardBy: /^\s*(?:words?|lyrics?|music|written|composed?|produced?|arranged?|mix(?:ed)?|mastered|recorded|engineered|performed|sung|cover(?:ed)?|translated|edited|programmed|directed|presented|published|vocals?|guitars?|bass|drums?|keyboards?|piano|strings|original|sync(?:ed)?|lrc|subtitles?|timeline)(?:\s*(?:&|and|\+|\/)\s*(?:words?|lyrics?|music|composition|arranged))?\s+by\b/i
    function _d(hex) {
        let s = "";
        for (let i = 0; i < hex.length; i += 2) {
            s += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
        }
        return s;
    }
    readonly property var _reLegal: new RegExp("[©℗]|\\ball rights reserved\\b|\\bisrc\\b|^\\s*copyright\\b|https?:\\/\\/|\\bwww\\.|版权所有|未经(?:著作权人)?许可|享有本翻译作品|网易云音乐|酷狗音乐|QQ音乐|" + root._d("71716d757369637c6b75676f757c6e6574656173657c3136335c2e636f6d7c6c72636c6962"), "i")
    readonly property var _reCjkStrong: /^\s*(?:作\s*[词詞曲]|[编編]\s*曲|词\s*曲|詞\s*曲|[监監]\s*[制製]|[制製]\s*作\s*人|母\s*[带帶]|混\s*音|[录錄]\s*音|原\s*唱|配\s*唱|[统統]\s*[筹籌]|企\s*[划劃]|版\s*[权權]|出\s*品|[发發]\s*行|音\s*乐\s*[总總]\s*[监監])/
    readonly property var _reCjkColon: /^\s*(?:(?:作\s*[词詞曲]|[编編]\s*曲|词\s*曲|詞\s*曲|[监監]\s*[制製]|[制製]\s*作(?:人|助理|统筹)?|母\s*[带帶](?:工程?师|处理)?|混\s*音(?:工程?师|师|助理)?|[录錄]\s*音(?:工程?师|师|助理|室|棚)?|原\s*唱|配\s*唱|[统統]\s*[筹籌]|企\s*[划劃]|版\s*[权權]|出\s*品(?:人)?|[发發]\s*行(?:人)?|音\s*乐\s*[总總]\s*[监監]|音\s*频(?:工程?师|师|助理|制作)?|人\s*声(?:编辑|编写|录音)?|附加制作|弦\s*乐(?:编写|监制)?|[鼓键琴笛弦管铜木]\s*编[曲程]|弦乐|管乐|铜管|木管|打击乐|和声(?:编写)?|合音|文案|乐器|后期|策划|演奏|录制|原曲|翻译|译者|字幕|歌词|歌詞|演唱|歌手|歌名|曲名|[专專]\s*辑|(?:原声|木|电)?\s*吉他|(?:低音|电)?\s*贝[斯司]|(?:架子|低音)?\s*鼓|键盘|钢\s*琴|(?:[小中大小]|爱尔兰)?\s*提琴|(?:哈蒙德)?\s*(?:手|管|簧)?\s*风琴|(?:爱尔兰)?\s*(?:长|短|哨)?\s*笛|萨克斯|小号|圆号|长号|单簧管|双簧管|大管|古筝|琵琶|二胡|プロデュース|ミックス|マスタリング|レコーディング|ボーカル|コーラス|歌|작사|작곡|편곡|노래|프로듀서|믹싱|마스터링|녹음))\s*[:：]/
    // Only trusted before the first sung line
    readonly property var _reSoftEn: /^\s*(?:(?:executive |vocal |co-?)?producers?|composers?|lyricists?|arrangers?|songwriters?|publisher|written by)\b/i
    readonly property var _reCjkSoft: /^\s*(?:演唱|歌手|歌名|曲名|[专專]\s*辑|和声|合音|吉他|贝斯|键盘|弦乐|乐器|后期|制作|策划|编写|歌词|文案)/
    readonly property var _reMusicLabel: /^\s*[\[\(（【]?\s*(?:instrumental(?: track)?|interlude|intro|outro|solo|music|间奏|間奏|前奏|尾奏|纯音乐[^\n]{0,12}|此歌曲为没有填词的纯音乐[^\n]{0,12}|暂无歌词|no lyrics|lyrics not available)\s*[\]\)）】]?\s*[.。!！]*\s*$/i
    readonly property var _reSectionLabel: /^\s*[\[\(（【]?\s*(?:verse|chorus|pre-?chorus|bridge|hook|refrain|break|drop|副歌|主歌|桥段|橋段)(?:\s*\d+)?\s*[\]\)）】]?\s*[:：]?\s*$/i

    function _norm(s) {
        return s ? String(s).toLowerCase().replace(root._reNormStrip, "") : "";
    }

    // Normalized forms of a name: raw, without bracketed notes, without CJK (translations)
    function _normVariants(s) {
        if (!s) return [];
        let str = String(s);
        let unbracketed = str.replace(root._reBrackets, "");
        let noCjk = unbracketed.replace(root._reCjkG, "");
        let cands = [root._norm(str), root._norm(unbracketed), root._norm(noCjk)];
        let out = [];
        for (let i = 0; i < cands.length; i++) {
            if (cands[i] && out.indexOf(cands[i]) < 0) out.push(cands[i]);
        }
        return out;
    }

    function _countMatches(text, re) {
        let m = text.match(re);
        return m ? m.length : 0;
    }

    // "cjk" | "latin" | "mixed" | ""
    function _scriptOf(s) {
        if (!s) return "";
        let c = root._countMatches(s, root._reCjkG);
        let l = root._countMatches(s, root._reLatinG);
        if (c > 0 && l === 0) return "cjk";
        if (l > 0 && c === 0) return "latin";
        return (c > 0 && l > 0) ? "mixed" : "";
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
        root._curGroup = null;
        root._progScale = 1.0;
        root._sweeping = false;
        root._slowInterval = 100;
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
        root.currentGroupStartIdx = -1;
        root.isMultiLineGroup = false;
        root.allowHighlightSlide = false;
        root.activeLineStartFraction = 0.0;
        root.activeLineEndFraction = 1.0;
        root.nextLyricLine = "";
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
                root.parseLyricsResponse(cached);
                return;
            }
            if ((Date.now() - cached.ts) / 1000.0 < root.negativeCacheSeconds) {
                root.loading = false;
                root.loadingStatus = "";
                return;
            }
        }

        root._job = { id: myFetchId, key: cacheKey, gotWord: false, shown: false, best: null, definiteNone: false };
        let proc = fetchProcComp.createObject(root, { jobId: myFetchId });
        proc.command = [
            "python3",
            Quickshell.shellPath("scripts/lyrics/fetch_lyrics.py"),
            cleanTrack,
            cleanArtist,
            String(Math.round(activePlayer?.length || 0)),
            root._cacheDir,
            activePlayer?.trackAlbum || ""
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

        if (ev.k === "word") {
            if (!ev.text) return;
            let parsed = root.parseLyricsString(ev.text);
            if (parsed.length > 0 && parsed.some(function(l) { return l.isWordSynced; })) {
                job.gotWord = true;
                job.best = { syncedLyrics: ev.text, lines: parsed, hasWordSync: true };
                root.precompileAndSetLyrics(parsed, true);
            }
        } else if (ev.k === "lrc") {
            if (job.gotWord) return;
            let data = { syncedLyrics: ev.synced || "", plainLyrics: ev.plain || "" };
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

    function unescapeHtml(s) {
        if (!s) return "";
        return String(s)
            .replace(/&apos;/g, "'")
            .replace(/&#39;/g, "'")
            .replace(/&#x27;/g, "'")
            .replace(/&quot;/g, '"')
            .replace(/&#34;/g, '"')
            .replace(/&nbsp;/g, " ")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/&amp;/g, "&");
    }

    function parseTimeHeader(h) {
        if (!h) return 0;
        if (h.includes(":")) {
            let p = h.split(":");
            if (p.length === 3) {
                return (parseFloat(p[0]) || 0) * 3600.0 + (parseFloat(p[1]) || 0) * 60.0 + (parseFloat(p[2]) || 0);
            }
            return (parseFloat(p[0]) || 0) * 60.0 + (parseFloat(p[1]) || 0);
        } else if (h.includes(",")) {
            let p = h.split(",");
            return (parseFloat(p[0]) || 0) / 1000.0;
        }
        let v = parseFloat(h) || 0;
        return v > 1000 ? v / 1000.0 : v;
    }

    // ------------------------------------------------------------------------------------------
    // Parsing: tokenize -> prune translations -> strip credits -> finalize timings
    // ------------------------------------------------------------------------------------------

    // Word timing from one line's content. Supports enhanced LRC <mm:ss.xx>/<off,dur[,x]>, word(start,dur)
    // and (start,dur)word. Returns [] when the line carries no (valid) word timing.
    function _parseWords(content, timeSec, offsetSec) {
        let words = [];
        let lt = content.indexOf("<");
        if (lt >= 0 && content.indexOf(">", lt) > lt) {
            let tagRegex = /<([^>]+)>([^<]*)/g;
            let tm;
            let tokens = [];
            while ((tm = tagRegex.exec(content)) !== null) {
                let tag = tm[1].trim();
                if (!/^[\d:.,\s]+$/.test(tag)) continue; // "<3", "<i>" ... not a timing tag
                tokens.push({ tag: tag, text: tm[2] });
            }
            if (tokens.length === 0) return words;

            if (lt > 0 && content.substring(0, lt).length > 0) {
                words.push({ text: content.substring(0, lt), start: timeSec, end: timeSec + 0.05 });
            }

            for (let t = 0; t < tokens.length; t++) {
                let tok = tokens[t];
                let startSec = 0;
                let endSec = 0;

                if (tok.tag.includes(":")) {
                    let p = tok.tag.split(":");
                    startSec = (parseFloat(p[0]) || 0) * 60.0 + (parseFloat(p[1]) || 0) - offsetSec;
                } else if (tok.tag.includes(",")) {
                    let p = tok.tag.split(",");
                    startSec = timeSec + ((parseFloat(p[0]) || 0) / 1000.0);
                    endSec = startSec + ((parseFloat(p[1]) || 0) / 1000.0);
                } else {
                    let v = parseFloat(tok.tag) || 0;
                    startSec = ((v > 1000) ? v / 1000.0 : v) - offsetSec;
                }

                if (endSec <= startSec && t + 1 < tokens.length) {
                    let nextTag = tokens[t + 1].tag;
                    if (nextTag.includes(":")) {
                        let np = nextTag.split(":");
                        endSec = (parseFloat(np[0]) || 0) * 60.0 + (parseFloat(np[1]) || 0) - offsetSec;
                    } else if (nextTag.includes(",")) {
                        endSec = timeSec + ((parseFloat(nextTag.split(",")[0]) || 0) / 1000.0);
                    }
                }

                if (tok.text.length > 0) {
                    words.push({ text: tok.text, start: Math.max(0, startSec), end: Math.max(0, endSec) });
                } else if (words.length > 0) {
                    let lastW = words[words.length - 1];
                    if (!lastW.end || lastW.end <= lastW.start) lastW.end = Math.max(0, startSec);
                }
            }
        } else if (/\(\d+,\d+(?:,\d+)?\)/.test(content)) {
            let parenParts = content.split(/\((\d+),(\d+)(?:,\d+)?\)/);
            if (parenParts.length < 3) return words;
            let isSuffix = (parenParts[0].trim().length > 0) && (parenParts[parenParts.length - 1].trim().length === 0);
            if (isSuffix) {
                // Format: word(start,dur)
                let trailing = parenParts[parenParts.length - 1];
                let num = Math.floor((parenParts.length - 1) / 3);
                for (let idx = 0; idx < num; idx++) {
                    let wText = parenParts[idx * 3];
                    let off = parseFloat(parenParts[idx * 3 + 1]) || 0;
                    let dur = parseFloat(parenParts[idx * 3 + 2]) || 0;
                    if (idx === num - 1 && trailing) wText += trailing;
                    let startSec = timeSec + (off / 1000.0);
                    if (wText.length > 0) words.push({ text: wText, start: startSec, end: startSec + (dur / 1000.0) });
                }
            } else {
                // Format: (start,dur)word
                if (parenParts[0].length > 0) {
                    words.push({ text: parenParts[0], start: timeSec, end: timeSec + 0.05 });
                }
                for (let idx = 1; idx < parenParts.length; idx += 3) {
                    let off = parseFloat(parenParts[idx]) || 0;
                    let dur = parseFloat(parenParts[idx + 1]) || 0;
                    let wText = parenParts[idx + 2] || "";
                    let startSec = timeSec + (off / 1000.0);
                    if (wText.length > 0) words.push({ text: wText, start: startSec, end: startSec + (dur / 1000.0) });
                }
            }
        }
        return words;
    }

    // Raw text -> unsorted-safe entries { time, endTime, text, words, isWordSynced }
    function _tokenize(synced, offsetSec) {
        let entries = [];
        let lines = synced.split("\n");
        let headerRegex = /\[(\d+(?::\d+)+(?:\.\d+)?|\d+(?:,\d+)?)\]\s*/g;

        for (let i = 0; i < lines.length; i++) {
            let rawLine = lines[i].trim();
            if (rawLine.length < 3 || rawLine.charCodeAt(0) !== 91 /* [ */) continue;

            let headers = [];
            let lastIdx = 0;
            let match;
            headerRegex.lastIndex = 0;
            while ((match = headerRegex.exec(rawLine)) !== null && match.index === lastIdx) {
                headers.push(match[1]);
                lastIdx = headerRegex.lastIndex;
            }
            if (headers.length === 0) continue;

            let content = rawLine.substring(lastIdx).replace(root._reInvisible, "");

            for (let h = 0; h < headers.length; h++) {
                let timeSec = Math.max(0, root.parseTimeHeader(headers[h]) - offsetSec);
                let lineDuration = 0;
                if (headers[h].includes(",")) {
                    lineDuration = (parseFloat(headers[h].split(",")[1]) || 0) / 1000.0;
                }

                let words = root._parseWords(content, timeSec, offsetSec);
                let isWordSynced = words.length > 0;

                if (isWordSynced) {
                    let inParen = false;
                    for (let w = 0; w < words.length; w++) {
                        let wObj = words[w];
                        if (wObj.text.includes("(")) inParen = true;
                        wObj.isBg = inParen;
                        if (wObj.text.includes(")")) inParen = false;
                    }
                }

                let cleanText = isWordSynced
                    ? words.map(w => w.text).join("")
                    : content.replace(/<[^>]+>/g, "").replace(/\(\d+,\d+(?:,\d+)?\)/g, "");
                cleanText = cleanText.replace(/\s+/g, " ").trim();
                if (cleanText.length === 0) {
                    cleanText = "♪";
                    isWordSynced = false;
                }

                let lineEnd = (isWordSynced && words[words.length - 1].end > 0)
                    ? words[words.length - 1].end
                    : (lineDuration > 0 ? timeSec + lineDuration : 0);

                entries.push({
                    time: timeSec,
                    endTime: lineEnd,
                    text: cleanText,
                    isWordSynced: isWordSynced,
                    words: isWordSynced ? words : null
                });
            }
        }
        return entries;
    }

    function _buildContext() {
        let title = StringUtils.cleanMusicTitle(root.currentTrackName) || root.currentTrackName || activePlayer?.trackTitle || "";
        let artist = root.currentArtistName || activePlayer?.trackArtist || "";
        let album = activePlayer?.trackAlbum || "";

        let meta = {};
        let any = false;
        let add = function(s) {
            let v = root._normVariants(s);
            for (let i = 0; i < v.length; i++) { meta[v[i]] = true; any = true; }
            return v;
        };
        let tv = add(title);
        let av = add(artist);
        add(album);
        let artistParts = artist.split(/\s*(?:,|;|&|\/|、|\bfeat\.?|\bft\.?|\band\b)\s*/i);
        for (let i = 0; i < artistParts.length; i++) add(artistParts[i]);
        if (tv.length > 0 && av.length > 0) {
            meta[tv[0] + av[0]] = true;
            meta[av[0] + tv[0]] = true;
        }

        // Which script is the song itself in? (decides which side of a bilingual pair is the translation)
        let titleScript = root._scriptOf(title);
        let artistScript = root._scriptOf(artist);
        let hint = "";
        if ((titleScript === "cjk" || titleScript === "latin")
                && (!artistScript || artistScript === "mixed" || artistScript === titleScript)) {
            hint = titleScript;
        }

        return { meta: meta, hasMeta: any, hint: hint, stats: "", primary: "" };
    }

    // Splits time-adjacent lines into clusters and keeps only the song's own language where a
    // cluster mixes CJK and Latin (bilingual LRC: original + translation sharing a timestamp).
    function _pruneTranslations(entries, ctx) {
        let n = entries.length;
        for (let i = 0; i < n; i++) {
            let e = entries[i];
            if (e.text === "♪") { e._k = ""; continue; }
            let c = root._countMatches(e.text, root._reCjkG);
            let l = root._countMatches(e.text, root._reLatinG);
            e._k = (c > 0 && c >= l) ? "c" : (l > 0 ? "l" : "");
        }

        let clusters = [];
        let i = 0;
        while (i < n) {
            let j = i + 1;
            while (j < n && entries[j].time - entries[i].time <= 0.3) j++;
            clusters.push([i, j]);
            i = j;
        }

        // Language of the lyric body (first sung, non-credit line of every cluster)
        let c = 0, l = 0;
        for (let k = 0; k < clusters.length; k++) {
            for (let x = clusters[k][0]; x < clusters[k][1]; x++) {
                let e = entries[x];
                if (e._k === "" || root._isNoise(e, ctx)) continue;
                if (e._k === "c") c++; else l++;
                break;
            }
        }
        ctx.stats = c > l ? "cjk" : "latin";
        // The title's script wins for deciding which half of a bilingual pair is the translation
        ctx.primary = ctx.hint || ctx.stats;
        let keepKind = ctx.primary === "cjk" ? "c" : "l";

        let out = [];
        for (let k = 0; k < clusters.length; k++) {
            let a = clusters[k][0], b = clusters[k][1];
            if (b - a === 1) { out.push(entries[a]); continue; }

            let hasC = false, hasL = false;
            for (let x = a; x < b; x++) {
                if (entries[x]._k === "c") hasC = true;
                else if (entries[x]._k === "l") hasL = true;
            }
            let mixed = hasC && hasL;
            let seen = {};
            for (let x = a; x < b; x++) {
                let e = entries[x];
                if (mixed && e._k !== "" && e._k !== keepKind) continue;
                let dupKey = e.text + "|" + Math.round(e.time * 100);
                if (seen[dupKey]) continue;
                seen[dupKey] = true;
                out.push(e);
            }
        }
        return out;
    }

    function _stripInlineTranslation(text, primary) {
        let m = null;
        if (primary === "latin") {
            m = text.match(root._reTransSlashLatin) || text.match(root._reTransParenLatin);
        } else if (primary === "cjk") {
            m = text.match(root._reTransSlashCjk);
        }
        if (!m) return text;
        let kept = m[1].trim();
        return kept.length > 0 ? kept : text;
    }

    function _isHardCredit(t) {
        return root._reHardEn.test(t) || root._reHardBy.test(t) || root._reCjkStrong.test(t)
            || root._reCjkColon.test(t) || root._reLegal.test(t);
    }

    function _isPerformerTag(t, ctx) {
        if (!ctx.hasMeta) return false;
        let m = t.match(/^\s*[\[\(（【]?\s*([A-Za-z0-9\s._'-]+?)\s*[\]\)）】]?\s*[:：]\s*$/);
        if (!m) return false;
        let v = root._normVariants(m[1].trim());
        for (let i = 0; i < v.length; i++) {
            if (ctx.meta[v[i]]) return true;
        }
        return false;
    }

    // Credit-ish line that must not count as lyric content
    function _isNoise(e, ctx) {
        let t = e.text;
        return root._isHardCredit(t) || root._reSoftEn.test(t) || root._reCjkSoft.test(t)
            || (e.time < 15 && root._isMetaEcho(t, ctx))
            || root._isPerformerTag(t, ctx);
    }

    // Title / artist / album echoes in the intro ("Song - Artist", "Artist (艾德·希兰)", ...)
    function _isMetaEcho(t, ctx) {
        if (!ctx.hasMeta) return false;
        let whole = root._normVariants(t);
        for (let i = 0; i < whole.length; i++) {
            if (ctx.meta[whole[i]]) return true;
        }
        let parts = t.split(/\s+[-–—]\s+|\s*[\/|｜:：]\s*/);
        if (parts.length >= 2) {
            let allMatch = true;
            for (let p = 0; p < parts.length; p++) {
                let pv = root._normVariants(parts[p]);
                let ok = false;
                for (let i = 0; i < pv.length; i++) {
                    if (ctx.meta[pv[i]]) { ok = true; break; }
                }
                if (!ok) allMatch = false;
            }
            if (allMatch) return true;

            let dashParts = t.split(/\s+[-–—]\s+/);
            if (dashParts.length === 2) {
                let p0v = root._normVariants(dashParts[0]);
                let p1v = root._normVariants(dashParts[1]);
                let p0Match = p0v.some(function(v) { return !!ctx.meta[v]; });
                let p1Match = p1v.some(function(v) { return !!ctx.meta[v]; });
                if (p0Match || p1Match) {
                    if (p0Match && p1Match) return true;
                    if (ctx.primary === "latin" && (root._reCjkG.test(dashParts[0]) || root._reCjkG.test(dashParts[1]))) return true;
                    if (root._reTransParenLatin.test(dashParts[0]) || root._reTransParenLatin.test(dashParts[1])) return true;
                }
            }
        }
        return false;
    }

    function _stripCredits(entries, ctx) {
        let freq = {};
        for (let i = 0; i < entries.length; i++) {
            let k = root._norm(entries[i].text);
            freq[k] = (freq[k] || 0) + 1;
        }

        // First genuine Latin lyric: CJK-only lines before it are translated title/artist/credits.
        // (If the song has no Latin lyric at all, CJK lines are the lyrics and are never touched.)
        let firstLatinLyric = -1;
        if (ctx.primary === "latin" && ctx.stats === "latin") {
            for (let i = 0; i < entries.length; i++) {
                let e = entries[i];
                if (e._k === "l" && !root._isNoise(e, ctx)) { firstLatinLyric = i; break; }
            }
        }

        let out = [];
        let seenLyric = false;
        let dropNext = false;

        for (let i = 0; i < entries.length; i++) {
            let e = entries[i];
            let t = e.text;

            if (t !== "♪") {
                if (root._reMusicLabel.test(t) || root._reSymbolOnly.test(t)) {
                    e.text = t = "♪";
                    e.isWordSynced = false;
                    e.words = null;
                } else if (root._reSectionLabel.test(t) || root._isPerformerTag(t, ctx)) {
                    continue;
                } else if (root._isHardCredit(t)) {
                    dropNext = !seenLyric && /[:：]\s*$/.test(t);
                    continue;
                } else if (!seenLyric) {
                    if (dropNext && e.time < 25) { dropNext = false; continue; }
                    if (root._reSoftEn.test(t) || root._reCjkSoft.test(t)) continue;
                    if (e.time < 15 && freq[root._norm(t)] === 1 && root._isMetaEcho(t, ctx)) continue;
                    if (i < firstLatinLyric && e.time < 25 && e._k === "c"
                        && root._countMatches(t, root._reLatinG) === 0) continue;
                    if (ctx.primary === "latin" && e.time < 15 && root._reCjkG.test(t) && root._isMetaEcho(t, ctx)) continue;
                }
                dropNext = false;
            }

            if (t === "♪") {
                if (!seenLyric) continue; // no leading instrumental markers; the intro countdown covers it
                if (out.length > 0 && out[out.length - 1].text === "♪") continue;
            } else {
                seenLyric = true;
            }
            out.push(e);
        }

        // Strip trailing credits, legal notices, and meta echoes from the outro
        while (out.length > 0) {
            let last = out[out.length - 1];
            let lt = last.text;
            if (lt === "♪") {
                out.pop();
                continue;
            }
            let isOutroCredit = root._isHardCredit(lt)
                || root._reSoftEn.test(lt)
                || root._reCjkSoft.test(lt)
                || root._reLegal.test(lt)
                || root._isMetaEcho(lt, ctx)
                || (ctx.primary === "latin" && root._reCjkG.test(lt));
            if (isOutroCredit) {
                out.pop();
            } else {
                break;
            }
        }

        return out;
    }

    function parseLyricsString(synced) {
        if (!synced) return [];
        if (synced.indexOf("&") >= 0) synced = root.unescapeHtml(synced);

        let offsetSec = 0;
        let offsetMatch = synced.match(/\[offset:\s*([+-]?\d+)\]/i);
        if (offsetMatch) offsetSec = (parseFloat(offsetMatch[1]) || 0) / 1000.0;

        let entries = root._tokenize(synced, offsetSec);
        if (entries.length === 0) return [];
        if (entries.length > 1) entries.sort((a, b) => a.time - b.time);

        let ctx = root._buildContext();
        entries = root._pruneTranslations(entries, ctx);
        for (let i = 0; i < entries.length; i++) {
            let e = entries[i];
            if (e.text !== "♪") {
                if (ctx.primary === "latin" && root._reCjkG.test(e.text)) {
                    let cleaned = root._stripInlineTranslation(e.text, "latin");
                    if (cleaned !== e.text) {
                        e.text = cleaned;
                        if (e.isWordSynced && e.words && e.words.length > 0) {
                            while (e.words.length > 0 && root._reCjkG.test(e.words[e.words.length - 1].text)) {
                                e.words.pop();
                            }
                            while (e.words.length > 0 && /[\s()（）]/.test(e.words[e.words.length - 1].text.trim())) {
                                e.words.pop();
                            }
                        }
                    }
                } else if (!e.isWordSynced && ctx.primary === ctx.stats) {
                    e.text = root._stripInlineTranslation(e.text, ctx.primary);
                }
            }
        }
        let parsed = root._stripCredits(entries, ctx);

        // Drop leading and trailing blank text
        while (parsed.length > 0 && (!parsed[0].text || parsed[0].text.trim() === "")) {
            parsed.shift();
        }
        while (parsed.length > 0 && (!parsed[parsed.length - 1].text || parsed[parsed.length - 1].text.trim() === "")) {
            parsed.pop();
        }

        for (let i = 0; i < parsed.length; i++) {
            let p = parsed[i];
            delete p._k;
            let nextT = (i + 1 < parsed.length) ? parsed[i + 1].time : (p.time + 4.5);
            let rawGap = Math.max(0.1, nextT - p.time);

            if (p.isWordSynced && p.words && p.words.length > 0) {
                let lastW = p.words[p.words.length - 1];
                if (!lastW.end || lastW.end <= lastW.start) {
                    let wStart = lastW.start || p.time;
                    let remainingGap = Math.max(0.2, nextT - wStart);
                    lastW.end = Math.min(nextT, wStart + Math.min(remainingGap, 2.0));
                }
                if (!p.endTime || p.endTime <= p.time) {
                    p.endTime = Math.min(nextT, Math.max(p.time + 0.1, lastW.end));
                }
            } else if (!p.endTime || p.endTime <= p.time) {
                let dur = Math.min(rawGap, Math.max(2.5, Math.min(5.0, p.text.length * 0.28 + 1.2)));
                p.endTime = p.time + dur;
            }
        }

        // Only ♪ markers left (e.g. "pure music") means there is nothing to show
        if (!parsed.some(function(p) { return p.text !== "♪"; })) return [];
        return parsed;
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
        let initPos = activePlayer?.position || 0;
        root.lastMprisPos = initPos;
        root.lastKnownPosition = initPos;
        root.lastKnownTimestamp = Date.now();
        root.lastWordSyncPos = initPos;

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
        if (!line || line._rev === root._metricsRev) return;
        line._rev = root._metricsRev;
        line._wordBounds = null;
        line._wi = 0;
        if (!line.words || line.words.length === 0) {
            if (line.text.indexOf("(") >= 0 && line.text.indexOf(")") >= 0) {
                styledMetrics.text = root.formatLineRich(line.text, root.colLitHex, root.colBgLitHex);
                line._totalWidth = styledMetrics.implicitWidth;
            } else {
                line._totalWidth = root.measurePixelWidth(line.text);
            }
            return;
        }
        let joined = "";
        for (let i = 0; i < line.words.length; i++) joined += line.words[i].text;
        let w = root.measurePixelWidth(joined);
        line._totalWidth = w > 0 ? w : root.measurePixelWidth(line.text);
    }

    // Per word: pixel position after each character (cx) and the cumulative share of the word's
    // duration each character is allotted (ct, ending at 1). Cumulative-prefix measurement keeps
    // kerning exact, but costs one layout per character, so it is only done for lines actually sung.
    function _computeBounds(line) {
        let bounds = [];
        let prefix = "";
        let prevW = 0;
        for (let i = 0; i < line.words.length; i++) {
            let text = line.words[i].text;
            let chars = Array.from(text);
            let n = chars.length;
            let cx = [];
            let ct = [];
            let acc = "";
            for (let j = 0; j < n; j++) {
                acc += chars[j];
                cx.push(j === n - 1 ? root.measurePixelWidth(prefix + text) : root.measurePixelWidth(prefix + acc));
                ct.push((j + 1) / n);
            }
            prefix += text;
            let endX = n > 0 ? cx[n - 1] : prevW;

            // Monotonic PCHIP tangents for smooth C1 velocity across character boundaries
            let tangents = [];
            if (n > 1) {
                let slopes = [];
                for (let j = 0; j < n; j++) {
                    let prevX = j === 0 ? prevW : cx[j - 1];
                    let prevT = j === 0 ? 0 : ct[j - 1];
                    let dt = ct[j] - prevT;
                    let dx = cx[j] - prevX;
                    slopes.push(dt > 0 ? dx / dt : 0);
                }
                for (let j = 0; j <= n; j++) {
                    if (j === 0) {
                        tangents.push(slopes[0]);
                    } else if (j === n) {
                        tangents.push(slopes[n - 1]);
                    } else {
                        let s0 = slopes[j - 1];
                        let s1 = slopes[j];
                        if (s0 * s1 <= 0) {
                            tangents.push(0);
                        } else {
                            tangents.push((2 * s0 * s1) / (s0 + s1));
                        }
                    }
                }
            }

            bounds.push({ startX: prevW, endX: endX, cx: cx, ct: ct, tangents: tangents });
            prevW = endX;
        }
        line._wordBounds = bounds;
        return bounds;
    }

    function recompileAllMetrics() {
        let lines = root.lyricLines;
        if (!lines || lines.length === 0) return;
        for (let i = 0; i < lines.length; i++) {
            root.precompileLineMetrics(lines[i]);
        }
        root.buildGroupIndex();
    }

    function getLineSweepFraction(line, currentSec) {
        if (!line) return 0.0;
        let totalW = line._totalWidth || 0;
        if (totalW <= 0) return 0.0;
        let words = line.words;
        if (!words || words.length === 0) return 1.0;

        if (currentSec <= words[0].start) return 0.0;
        if (currentSec >= words[words.length - 1].end) return 1.0;

        let bounds = line._wordBounds || root._computeBounds(line);
        if (bounds.length !== words.length) return 0.0;

        // Playback moves forward, so resume the search from the last active word
        let i = line._wi || 0;
        if (i >= words.length || currentSec < words[i].start) i = 0;
        while (i < words.length && currentSec >= words[i].end) i++;
        line._wi = i;
        if (i >= words.length) return 1.0;

        let w = words[i];
        let b = bounds[i];
        if (currentSec <= w.start) return b.startX / totalW;

        let dur = Math.max(0.001, w.end - w.start);
        let rawT = Math.max(0.0, Math.min(1.0, (currentSec - w.start) / dur));
        let e = root.vocalEase(rawT, dur);

        // Find the character being sung and interpolate inside its slice of the word
        let ct = b.ct;
        let cx = b.cx;
        let tangents = b.tangents;
        let k = 0;
        while (k < ct.length - 1 && e >= ct[k]) k++;
        let t0 = k === 0 ? 0 : ct[k - 1];
        let span = ct[k] - t0;
        let local = span > 0 ? Math.min(1.0, (e - t0) / span) : 1.0;
        let x0 = k === 0 ? b.startX : cx[k - 1];
        let x1 = cx[k];

        let pixelX;
        if (tangents && tangents.length > k + 1) {
            let m0 = tangents[k];
            let m1 = tangents[k + 1];
            let l2 = local * local;
            let l3 = l2 * local;
            pixelX = (2 * l3 - 3 * l2 + 1) * x0 + (l3 - 2 * l2 + local) * span * m0 + (-2 * l3 + 3 * l2) * x1 + (l3 - l2) * span * m1;
        } else {
            pixelX = x0 + local * (x1 - x0);
        }
        return Math.max(0.0, Math.min(1.0, pixelX / totalW));
    }

    function calculateGroupSweep(currGroup, currIdx, currentSec) {
        let lines = root.lyricLines;
        if (!currGroup || !lines || lines.length === 0) return 0.0;

        if (currGroup.startIdx === currGroup.endIdx) {
            let lObj = lines[currGroup.startIdx];
            if (!lObj || !lObj.isWordSynced) return 1.0;
            return root.getLineSweepFraction(lObj, currentSec);
        }

        let bulletW = root.bulletPixelWidth > 0 ? root.bulletPixelWidth : root.measurePixelWidth(" • ");
        let totalGroupW = 0;
        let sweptPixels = 0;

        for (let m = currGroup.startIdx; m <= currGroup.endIdx; m++) {
            let lObj = lines[m];
            let lineW = lObj._totalWidth || 0;

            if (m > currGroup.startIdx) {
                totalGroupW += bulletW;
                if (m <= currIdx) {
                    sweptPixels += bulletW;
                }
            }

            totalGroupW += lineW;

            if (m < currIdx) {
                sweptPixels += lineW;
            } else if (m === currIdx) {
                if (lObj.isWordSynced) {
                    sweptPixels += root.getLineSweepFraction(lObj, currentSec) * lineW;
                } else {
                    sweptPixels += lineW;
                }
            }
        }

        if (totalGroupW <= 0) return 0.0;
        return Math.max(0.0, Math.min(1.0, sweptPixels / totalGroupW));
    }

    function _getGroupBounds(g, lines) {
        if (!g) return null;
        if (g._bounds && g._rev === root._metricsRev) return g._bounds;

        let count = g.endIdx - g.startIdx + 1;
        if (count <= 1) {
            g._rev = root._metricsRev;
            g._bounds = [{
                startFrac: 0.0,
                endFrac: 1.0,
                startX: 0,
                endX: lines[g.startIdx]?._totalWidth || 0
            }];
            g._totalWidth = lines[g.startIdx]?._totalWidth || 0;
            return g._bounds;
        }

        let bulletSep = `<font color="${root.colBulletHex}"> • </font>`;
        let parts = [];
        for (let m = g.startIdx; m <= g.endIdx; m++) {
            parts.push(root.formatLineRich(lines[m].text, root.colLitHex, root.colBgLitHex));
        }

        styledMetrics.text = parts.join(bulletSep);
        let totalW = styledMetrics.implicitWidth;
        if (totalW <= 0) {
            g._rev = root._metricsRev;
            g._bounds = null;
            return null;
        }

        let prefix = "";
        let bounds = [];
        for (let i = 0; i < count; i++) {
            let startX = 0;
            if (i > 0) {
                styledMetrics.text = prefix + bulletSep;
                startX = styledMetrics.implicitWidth;
                prefix = prefix + bulletSep + parts[i];
            } else {
                prefix = parts[0];
                startX = 0;
            }
            styledMetrics.text = prefix;
            let endX = styledMetrics.implicitWidth;

            // Half-whitespace padding into bullet separator to guarantee zero clipping of edge glyphs
            let clipStart = (i === 0) ? 0.0 : Math.max(0.0, startX - 1.5);
            let clipEnd = (i === count - 1) ? totalW : Math.min(totalW, endX + 1.5);

            bounds.push({
                startX: startX,
                endX: endX,
                clipStart: clipStart,
                clipEnd: clipEnd,
                startFrac: Math.max(0.0, Math.min(1.0, clipStart / totalW)),
                endFrac: Math.max(0.0, Math.min(1.0, clipEnd / totalW))
            });
        }

        g._rev = root._metricsRev;
        g._bounds = bounds;
        g._totalWidth = totalW;
        return bounds;
    }

    function buildGroupIndex() {
        let lines = root.lyricLines;
        if (!lines || lines.length === 0) {
            root.lyricGroupIndex = [];
            return;
        }

        let bulletW = root.bulletPixelWidth > 0 ? root.bulletPixelWidth : root.measurePixelWidth(" • ");
        root.bulletPixelWidth = bulletW;

        for (let l = 0; l < lines.length; l++) {
            root.precompileLineMetrics(lines[l]);
        }

        let maxAllowedPx = Math.max(160, (GlobalStates?.topBarMediaWidth ?? 440) - 135);

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
            let currentLine = lines[i];
            let groupText = currentLine.text;
            let currentGroupWidth = currentLine._totalWidth || 0;
            let j = i + 1;

            // Never group instrumental markers, repeat sequences, or lines that are already wide (>62% of bar)
            let isRepeat = isLineRepeat(i);
            let isInstrumental = groupText === "♪";
            let isAlreadyLong = currentGroupWidth > maxAllowedPx * 0.62;

            if (!isInstrumental && !isRepeat && !isAlreadyLong) {
                while (j < lines.length) {
                    let nextLine = lines[j];
                    let nextText = nextLine.text;

                    // Stop if next item is an instrumental pause or repeat sequence
                    if (nextText === "♪" || isLineRepeat(j)) break;

                    let prevLine = lines[j - 1];
                    let prevEnd = prevLine.endTime || (prevLine.time + 3.0);
                    let silenceGap = nextLine.time - prevEnd;
                    let lineStartInterval = nextLine.time - prevLine.time;
                    let totalSpan = nextLine.time - lines[start].time;

                    // 1. Natural rhythm & vocal rest check
                    if (silenceGap > 1.6 || lineStartInterval > 5.0 || totalSpan > 9.5) break;

                    // 2. Sentence / punctuation boundary check
                    let prevTrimmed = prevLine.text.trim();
                    let hasTerminalPunctuation = /[.?!:]$/.test(prevTrimmed) && !/\.\.\.$/.test(prevTrimmed);
                    let bothBrief = (prevTrimmed.length <= 16) && (nextText.trim().length <= 16);
                    if (hasTerminalPunctuation && !bothBrief) break;

                    // 3. Triplet restraint
                    let currentCount = (j - start) + 1;
                    if (currentCount > 3) break;
                    if (currentCount === 3) {
                        let line1Short = lines[start].text.length <= 18;
                        let line2Short = lines[start + 1].text.length <= 18;
                        let line3Short = nextText.length <= 18;
                        if (!line1Short || !line2Short || !line3Short) break;
                    }

                    // 4. Countdown timer reserve
                    let nextAfter = (j + 1 < lines.length) ? lines[j + 1] : null;
                    let nextAfterGap = nextAfter ? (nextAfter.time - (nextLine.endTime || nextLine.time + 3.0)) : 999;
                    let hasTimer = (nextAfterGap > 4.5) || (nextAfter && nextAfter.text === "♪");
                    let reserve = hasTimer ? 65 : 20;

                    // 5. Pixel width check using precompiled line lengths
                    let candidateWidth = currentGroupWidth + bulletW + (nextLine._totalWidth || 0);
                    let maxTargetWidth = (currentCount === 3) ? (maxAllowedPx * 0.85) : maxAllowedPx;
                    if (candidateWidth > maxTargetWidth - reserve) break;

                    // Merge line into multiline group
                    groupText = groupText + " • " + nextText;
                    currentGroupWidth = candidateWidth;
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
        let n = lines.length;
        if (pos < Math.max(0, lines[0].time - root.firstLineLead)) return -1;

        let i = root._rawIdx;
        if (i >= 0 && i < n && lines[i].time <= pos) {
            if (i + 1 >= n || lines[i + 1].time > pos) return i;
            if (i + 2 >= n || lines[i + 2].time > pos) return i + 1;
        }

        let lo = 0, hi = n - 1;
        while (lo < hi) {
            let mid = (lo + hi + 1) >> 1;
            if (lines[mid].time <= pos) lo = mid;
            else hi = mid - 1;
        }
        return lo;
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
        for (let p = fromIdx; p >= 0; p--) {
            if (lines[p].text !== "♪") return p;
        }
        return -1;
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

        if (currIdx < 0) {
            // Before the first line
            nextText = groups[0].text;
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

            // Repeat multipliers (x2, x3) only apply to consecutive repeats of a single line
            let identicalCount = 1;
            let repeatSeriesStart = g.startIdx;
            if (isSingle && rawText !== "♪") {
                for (let k = g.endIdx + 1; k < lines.length; k++) {
                    if (lines[k].text === rawText) identicalCount++;
                    else break;
                }
                for (let p = g.startIdx - 1; p >= 0; p--) {
                    if (lines[p].text === rawText) repeatSeriesStart = p;
                    else break;
                }
            }
            groupKey = isSingle ? repeatSeriesStart : g.startIdx;

            let isLastOfSeries = isSingle
                && identicalCount === 1
                && g.startIdx > 0
                && lines[g.startIdx - 1].text === rawText;
            let repeatSuffix = (identicalCount > 1 || isLastOfSeries) ? ` (x${identicalCount})` : "";
            let baseText = g.text + repeatSuffix;

            let waitingHex = isSingle ? root.colWaitingSingleHex : root.colWaitingGroupHex;
            let bulletSep = `<font color="${root.colBulletHex}"> • </font>`;
            let totalLyricW = 0;

            if (!isSingle) {
                let partsDim = [], partsLit = [], partsRich = [];
                for (let m = g.startIdx; m <= g.endIdx; m++) {
                    let lObj = lines[m];
                    if (mode === root.mSing) {
                        let dimPart = root.formatLineRich(lObj.text, root.colUpcomingHex, root.colBgUpcomingHex);
                        partsDim.push(dimPart);
                        partsLit.push(root.formatLineRich(lObj.text, root.colLitHex, root.colBgLitHex));
                        partsRich.push(m < currIdx
                            ? root.formatLineRich(lObj.text, root.colPastHex, root.colBgPastHex)
                            : dimPart);
                    }
                }
                let groupBounds = root._getGroupBounds(g, lines);
                if (groupBounds && currIdx >= g.startIdx && currIdx <= g.endIdx && started) {
                    let b = groupBounds[currIdx - g.startIdx];
                    startFrac = b.startFrac;
                    endFrac = b.endFrac;
                    totalLyricW = g._totalWidth || 0;
                }
                if (mode === root.mSing) {
                    dim = partsDim.join(bulletSep);
                    lit = partsLit.join(bulletSep);
                    rich = partsRich.join(bulletSep);
                    line = baseText;
                }
            } else {
                totalLyricW = lines[g.startIdx]._totalWidth || 0;
                if (mode === root.mSing) {
                    dim = root.formatLineRich(g.text, root.colUpcomingHex, root.colBgUpcomingHex);
                    lit = root.formatLineRich(g.text, root.colLitHex, root.colBgLitHex);
                    rich = lit;
                    if (repeatSuffix.length > 0) {
                        // Repeat indicators are UI metadata, not sung lyrics — keep out of the lit overlay
                        let suffixRich = ` <font color="${timerCol}">${repeatSuffix}</font>`;
                        dim += suffixRich;
                        rich += suffixRich;
                    }
                    line = baseText;
                }
            }

            if (mode === root.mSing && root.hasWordSync && repeatSuffix.length > 0 && totalLyricW > 0) {
                progScale = totalLyricW / (totalLyricW + root.getRepeatSuffixWidth(repeatSuffix));
            }

            switch (mode) {
            case root.mMark: {
                // Walk back past all consecutive ♪ to find the real previous lyric
                let prevIdx = root._lastRealLine(lines, g.startIdx - 1);
                let prevText = prevIdx >= 0 ? groups[prevIdx].text : "";
                let prevHex = (prevIdx >= 0 && groups[prevIdx].startIdx < groups[prevIdx].endIdx)
                    ? root.colWaitingGroupHex : root.colWaitingSingleHex;
                if (remaining > 0) {
                    if (prevText) {
                        line = `${prevText} (♪ ${remaining}s)`;
                        rich = `<font color="${prevHex}">${root.escapeXml(prevText)}</font> <font color="${timerCol}">(♪ ${remaining}s)</font>`;
                    } else {
                        let t = root._tagged(`(Intro ♪ ${remaining}s)`);
                        line = t.plain;
                        rich = t.rich;
                    }
                } else if (prevText) {
                    line = prevText;
                    rich = `<font color="${prevHex}">${root.escapeXml(prevText)}</font>`;
                } else {
                    line = root.trackInfoPlain || "";
                    rich = root.trackInfoRich || "";
                }
                dim = rich;
                lit = rich;
                break;
            }
            case root.mWait: {
                if (remaining > 0) {
                    line = `${baseText} (♪ ${remaining}s)`;
                    rich = `<font color="${waitingHex}">${root.escapeXml(baseText)}</font> <font color="${timerCol}">(♪ ${remaining}s)</font>`;
                } else {
                    line = baseText;
                    rich = `<font color="${waitingHex}">${root.escapeXml(baseText)}</font>`;
                }
                dim = rich;
                lit = rich;
                break;
            }
            case root.mEndHoldMuted: {
                line = baseText;
                rich = `<font color="${waitingHex}">${root.escapeXml(baseText)}</font>`;
                dim = rich;
                lit = rich;
                break;
            }
            case root.mEndHoldLast: {
                let lastText = lines[root._lastRealLine(lines, g.startIdx - 1)].text;
                line = lastText;
                rich = `<font color="${root.colWaitingSingleHex}">${root.escapeXml(lastText)}</font>`;
                dim = rich;
                lit = rich;
                break;
            }
            case root.mOutro: {
                if (root.trackInfoPlain) {
                    line = `${root.trackInfoPlain} (Outro ♪)`;
                    rich = `${root.trackInfoRich} <font color="${timerCol}">(Outro ♪)</font>`;
                } else {
                    line = "Outro ♪";
                    rich = `<font color="${timerCol}">Outro ♪</font>`;
                }
                dim = rich;
                lit = rich;
                break;
            }
            case root.mEndFallback: {
                let li = root._lastRealLine(lines, g.startIdx - 1);
                if (li >= 0) {
                    line = lines[li].text;
                    rich = `<font color="${root.colWaitingSingleHex}">${root.escapeXml(line)}</font>`;
                } else {
                    line = root.trackInfoPlain || "";
                    rich = root.trackInfoRich || "";
                }
                dim = rich;
                lit = rich;
                break;
            }
            default:
                break;
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
        let currentPos = root.lastKnownPosition + elapsedSec;
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

        let rawIdx = root._findLineIdx(lines, lineSyncPos);
        root._rawIdx = rawIdx;
        let currIdx = rawIdx;

        // Anti-cut-off protection: if lead-in looked ahead to the next line, do not switch early
        // while the previous line's syllables are still actively being sung.
        // But NEVER hold back if audio position has actually reached the next line's start time!
        while (currIdx > 0 && lines[currIdx - 1].isWordSynced && currentPos < lines[currIdx].time) {
            let prev = lines[currIdx - 1];
            let prevEnd = (prev.words && prev.words.length > 0) ? prev.words[prev.words.length - 1].end : (prev.endTime || 0);
            if (prevEnd > 0 && currentPos < prevEnd) currIdx--;
            else break;
        }

        let mode = root.mIntro;
        let remaining = 0;
        let started = false;

        if (currIdx < 0) {
            remaining = Math.max(0, Math.ceil(lines[0].time - root.firstLineLead - lineSyncPos));
        } else {
            let g = groups[currIdx];
            let lastLine = lines[g.endIdx];
            let isMark = g.text === "♪";
            let hasNext = g.nextStartIdx < n;
            started = lineSyncPos >= lines[g.startIdx].time;

            if (hasNext) {
                let nextTime = lines[g.nextStartIdx].time;
                remaining = Math.max(0, Math.ceil(nextTime - lineSyncPos));
                if (isMark) {
                    mode = root.mMark;
                } else {
                    let groupEnd = lastLine.endTime || (lastLine.time + 3.0);
                    let waiting = wordSyncPos >= groupEnd && (nextTime - groupEnd) > 4.0 && (wordSyncPos - groupEnd) > 1.5;
                    mode = waiting ? root.mWait : root.mSing;
                }
            } else {
                let trackLen = activePlayer?.length || 0;
                let holdSec = 4.5;
                let groupEnd = lastLine.endTime || (lastLine.time + 4.0);
                if (isMark) {
                    let li = root._lastRealLine(lines, g.startIdx - 1);
                    let sinceReal = 999;
                    if (li >= 0) {
                        let realEnd = lines[li].endTime || (lines[li].time + 4.0);
                        if (realEnd > 0) sinceReal = wordSyncPos - realEnd;
                    }
                    if (li >= 0 && sinceReal < holdSec) mode = root.mEndHoldLast;
                    else if (trackLen > 0) mode = root.mOutro;
                    else mode = root.mEndFallback;
                } else {
                    let finished = wordSyncPos >= groupEnd;
                    let since = wordSyncPos - groupEnd;
                    if (finished && trackLen > 0 && (trackLen - groupEnd) > 6.0 && since >= holdSec) mode = root.mOutro;
                    else if (finished && since >= holdSec) mode = root.mEndHoldMuted;
                    else mode = root.mSing;
                }
            }
        }

        // Anything string-ish only changes when one of these does (at most ~1/s outside of line changes)
        let wasMulti = root.isMultiLineGroup;
        if (mode !== root._mMode || currIdx !== root._mIdx || remaining !== root._mRem || started !== root._mStarted) {
            root._mMode = mode;
            root._mIdx = currIdx;
            root._mRem = remaining;
            root._mStarted = started;
            root._rebuildDisplay(mode, currIdx, remaining, started);
        }

        let progress = 0.0;
        if (mode === root.mSing) {
            progress = hasWS ? root.calculateGroupSweep(root._curGroup, currIdx, wordSyncPos) * root._progScale : 1.0;
        } else if (mode === root.mEndHoldLast || mode === root.mEndHoldMuted) {
            progress = 1.0;
        }

        // Enable highlight slide one tick after entering a multi-line group so the entry itself isn't animated
        let shouldSlide = currIdx >= 0 && wasMulti;
        if (root.allowHighlightSlide !== shouldSlide) root.allowHighlightSlide = shouldSlide;
        if (root.currentLineProgress !== progress) root.currentLineProgress = progress;

        // Scheduling: frame-rate only while the sweep is visibly moving
        let nextT = currIdx < 0 ? (lines[0].time - root.firstLineLead) : (currIdx + 1 < n ? lines[currIdx + 1].time : -1);
        let timeToNext = nextT >= 0 ? (nextT - lineSyncPos) : 999;
        let sweeping = hasWS && mode === root.mSing && !(progress >= 0.9995 && timeToNext > 0.3);
        if (root._sweeping !== sweeping) root._sweeping = sweeping;
        if (!sweeping) {
            let wake = Math.max(16, Math.min(100, Math.floor(timeToNext * 1000) - 4));
            if (Math.abs(wake - root._slowInterval) >= 10) root._slowInterval = wake;
        }
    }

    Component.onCompleted: {
        root.bulletPixelWidth = root.measurePixelWidth(" • ");
        root.syncTrackChange();
    }
}
