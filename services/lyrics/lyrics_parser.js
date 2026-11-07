.pragma library

// ==============================================================================================
// LRC / Enhanced LRC / Word-by-Word Lyric Parser & Sanitizer
// ==============================================================================================

const _cjk = "\\u3040-\\u30ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\uac00-\\ud7af";
const _reCjkG = new RegExp("[" + _cjk + "]", "g");
const _alpha = "a-z0-9\\u00c0-\\u024f\\u1e00-\\u1eff\\u0370-\\u03ff\\u0400-\\u04ff\\u0590-\\u06ff\\u0900-\\u097f\\u0e00-\\u0e7f";
const _reLatinG = /[A-Za-z\u00c0-\u024f\u1e00-\u1eff]/g;
const _reNormStrip = new RegExp("[^" + _alpha + _cjk + "]", "g");
const _reSymbolOnly = /^[\s.,\-_~*+=!?\u2026\u2014\u2013\u2022\u00b7\u266a\u266b\u266c\u3001\u3002\uff0c\uff01\uff1f\u300a\u300b()\[\]{}<>\/\\|:;'"`^#@&%$\u2605\u2606\u25cf\u25cb\u2500-\u257f]+$/;
const _reBrackets = /\s*[\(（\[［【〖《〈「『\{][^\)）\]］】〗》〉」』\}]*[\)）\]］】〗》〉」』\}]/g;
const _reInvisible = /[\ufeff\u200b-\u200d\u2060]/g;

// Translation glued to a line: "English / 中文", "English (中文)", "中文 / English"
const _reTransSlashLatin = new RegExp("^(.*[A-Za-z0-9].*?)\\s*[\\/|\\uff5c]\\s*[" + _cjk + "][^A-Za-z]*$");
const _reTransParenLatin = new RegExp("^(.*[A-Za-z0-9].*?)\\s*[\\(\\uff08][^A-Za-z\\)\\uff09]*[" + _cjk + "][^A-Za-z\\)\\uff09]*[\\)\\uff09]\\s*$");
const _reTransSlashCjk = new RegExp("^(.*[" + _cjk + "].*?)\\s*[\\/|\\uff5c]\\s*[A-Za-z][^" + _cjk + "]*$");

// Credits / metadata. "Hard" patterns are unambiguous and removed anywhere in the song.
const _reHardEn = /^\s*(?:words?|lyrics?|lyricist|composers?|composed|composition|music|written|writers?|songwriters?|author|prod(?:uced|ucer|ucers|uction)|co-?producer|executive producer|vocals?(?: producer| arranger| arrangement| engineer)?|backing vocals?|background vocals?|arranged|arranger|arrangement|orchestra(?:ted|tion)?|conductor|mix(?:ed|ing|er)?|mix engineer|mastered|mastering|recorded|recording|engineer(?:ed)?|engineering|programm(?:ed|ing)|guitars?|bass|drums?|piano|keyboards?|strings|violin|cello|saxophone|trumpet|percussion|synth(?:esizer)?|publish(?:er|ing)|label|copyright|isrc|upc|op|sp|translat(?:or|ed|ion)|subtitles?|sync(?:ed)?|lrc|timeline|source|cover|original(?: (?:publisher|singer|artist|lyrics|title|composer))?|album|artist|singer|title|track|song|studio|credits?|presented|distribut(?:ion|ed)|licen[sc]ed|special thanks|thanks)(?:\s+by)?\s*[:：]/i;
const _reHardBy = /^\s*(?:words?|lyrics?|music|written|composed?|produced?|arranged?|mix(?:ed)?|mastered|recorded|engineered|performed|sung|cover(?:ed)?|translated|edited|programmed|directed|presented|published|vocals?|guitars?|bass|drums?|keyboards?|piano|strings|original|sync(?:ed)?|lrc|subtitles?|timeline)(?:\s*(?:&|and|\+|\/)\s*(?:words?|lyrics?|music|composition|arranged))?\s+by\b/i;

function _d(hex) {
    let s = "";
    for (let i = 0; i < hex.length; i += 2) {
        s += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
    }
    return s;
}

const _reLegal = new RegExp("[©℗]|\\ball rights reserved\\b|\\bisrc\\b|^\\s*copyright\\b|https?:\\/\\/|\\bwww\\.|版权所有|未经(?:著作权人)?许可|享有本翻译作品|网易云音乐|酷狗音乐|QQ音乐|" + _d("71716d757369637c6b75676f757c6e6574656173657c3136335c2e636f6d7c6c72636c6962"), "i");
const _reCjkStrong = /^\s*(?:作\s*[词詞曲]|[编編]\s*曲|词\s*曲|詞\s*曲|[监監]\s*[制製]|[制製]\s*作\s*人|母\s*[带帶]|混\s*音|[录錄]\s*音|原\s*唱|配\s*唱|[统統]\s*[筹籌]|企\s*[划劃]|版\s*[权權]|出\s*品|[发發]\s*行|音\s*乐\s*[总總]\s*[监監])/;
const _reCjkColon = /^\s*(?:(?:作\s*[词詞曲]|[编編]\s*曲|词\s*曲|詞\s*曲|[监監]\s*[制製]|[制製]\s*作(?:人|助理|统筹)?|母\s*[带帶](?:工程?师|处理)?|混\s*音(?:工程?师|师|助理)?|[录錄]\s*音(?:工程?师|师|助理|室|棚)?|原\s*唱|配\s*唱|[统統]\s*[筹籌]|企\s*[划劃]|版\s*[权權]|出\s*品(?:人)?|[发發]\s*行(?:人)?|音\s*乐\s*[总總]\s*[监監]|音\s*频(?:工程?师|师|助理|制作)?|人\s*声(?:编辑|编写|录音)?|附加制作|弦\s*乐(?:编写|监制)?|[鼓键琴笛弦管铜木]\s*编[曲程]|弦乐|管乐|铜管|木管|打击乐|和声(?:编写)?|合音|文案|乐器|后期|策划|演奏|录制|原曲|翻译|译者|字幕|歌词|歌詞|演唱|歌手|歌名|曲名|[专專]\s*辑|(?:原声|木|电)?\s*吉他|(?:低音|电)?\s*贝[斯司]|(?:架子|低音)?\s*鼓|键盘|钢\s*琴|(?:[小中大小]|爱尔兰)?\s*提琴|(?:哈蒙德)?\s*(?:手|管|簧)?\s*风琴|(?:爱尔兰)?\s*(?:长|短|哨)?\s*笛|萨克斯|小号|圆号|长号|单簧管|双簧管|大管|古筝|琵琶|二胡|プロデュース|ミックス|マスタリング|レコーディング|ボーカル|コーラス|歌|작사|작곡|편곡|노래|프로듀서|믹싱|마스터링|녹음))\s*[:：]/;
const _reSoftEn = /^\s*(?:(?:executive |vocal |co-?)?producers?|composers?|lyricists?|arrangers?|songwriters?|publisher|written by)\b/i;
const _reCjkSoft = /^\s*(?:演唱|歌手|歌名|曲名|[专專]\s*辑|和声|合音|吉他|贝斯|键盘|弦乐|乐器|后期|制作|策划|编写|歌词|文案)/;
const _reMusicLabel = /^\s*[\[\(（【]?\s*(?:instrumental(?: track)?|interlude|intro|outro|solo|music|间奏|間奏|前奏|尾奏|纯音乐[^\n]{0,12}|此歌曲为没有填词的纯音乐[^\n]{0,12}|暂无歌词|no lyrics|lyrics not available)\s*[\]\)）】]?\s*[.。!！]*\s*$/i;
const _reSectionLabel = /^\s*[\[\(（【]?\s*(?:verse|chorus|pre-?chorus|bridge|hook|refrain|break|drop|副歌|主歌|桥段|橋段)(?:\s*\d+)?\s*[\]\)）】]?\s*[:：]?\s*$/i;

function _norm(s) {
    return s ? String(s).toLowerCase().replace(_reNormStrip, "") : "";
}

function _normVariants(s) {
    if (!s) return [];
    let str = String(s);
    let unbracketed = str.replace(_reBrackets, "");
    let noCjk = unbracketed.replace(_reCjkG, "");
    let cands = [_norm(str), _norm(unbracketed), _norm(noCjk)];
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

function _scriptOf(s) {
    if (!s) return "";
    let c = _countMatches(s, _reCjkG);
    let l = _countMatches(s, _reLatinG);
    if (c > 0 && l === 0) return "cjk";
    if (l > 0 && c === 0) return "latin";
    return (c > 0 && l > 0) ? "mixed" : "";
}

function capitalizeFirstLetter(str) {
    if (!str) return "";
    return str.replace(/^([^\p{L}\p{N}]*)(\p{L})/u, function(_, leading, letter) {
        return leading + letter.toUpperCase();
    });
}

function normalizeCapsLine(str) {
    if (!str) return "";
    let s = str.toLowerCase();
    s = s.replace(/^([^\p{L}\p{N}]*)(\p{L})/u, function(_, leading, letter) {
        return leading + letter.toUpperCase();
    });
    s = s.replace(/([.!?]\s+)(\p{L})/gu, function(_, punct, letter) {
        return punct + letter.toUpperCase();
    });
    s = s.replace(/\b(i)(['’](?:m|ve|ll|d))?\b/gu, function(_, _, suffix) {
        return "I" + (suffix || "");
    });
    s = s.replace(/\b(ok|dj|tv|vip|sos|usa|uk)\b/gi, function(m) {
        return m.toUpperCase();
    });
    return s;
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

function _parseWords(content, timeSec, offsetSec) {
    let words = [];
    let lt = content.indexOf("<");
    if (lt >= 0 && content.indexOf(">", lt) > lt) {
        let tagRegex = /<([^>]+)>([^<]*)/g;
        let tm;
        let tokens = [];
        while ((tm = tagRegex.exec(content)) !== null) {
            let tag = tm[1].trim();
            if (!/^[\d:.,\s]+$/.test(tag)) continue;
            tokens.push({ tag: tag, text: tm[2] });
        }
        if (tokens.length === 0) return words;

        if (lt > 0 && content.substring(0, lt).length > 0) {
            words.push({ text: content.substring(0, lt), start: timeSec, end: timeSec + 0.05, track: 0 });
        }

        for (let t = 0; t < tokens.length; t++) {
            let tok = tokens[t];
            let startSec = 0;
            let endSec = 0;
            let track = 0;

            if (tok.tag.includes(":")) {
                let p = tok.tag.split(":");
                startSec = (parseFloat(p[0]) || 0) * 60.0 + (parseFloat(p[1]) || 0) - offsetSec;
            } else if (tok.tag.includes(",")) {
                let p = tok.tag.split(",");
                startSec = timeSec + ((parseFloat(p[0]) || 0) / 1000.0);
                endSec = startSec + ((parseFloat(p[1]) || 0) / 1000.0);
                track = p.length >= 3 ? (parseInt(p[2], 10) || 0) : 0;
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
                words.push({ text: tok.text, start: Math.max(0, startSec), end: Math.max(0, endSec), track: track });
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
            let trailing = parenParts[parenParts.length - 1];
            let num = Math.floor((parenParts.length - 1) / 3);
            for (let idx = 0; idx < num; idx++) {
                let wText = parenParts[idx * 3];
                let off = parseFloat(parenParts[idx * 3 + 1]) || 0;
                let dur = parseFloat(parenParts[idx * 3 + 2]) || 0;
                if (idx === num - 1 && trailing) wText += trailing;
                let startSec = timeSec + (off / 1000.0);
                if (wText.length > 0) words.push({ text: wText, start: startSec, end: startSec + (dur / 1000.0), track: 0 });
            }
        } else {
            if (parenParts[0].length > 0) {
                words.push({ text: parenParts[0], start: timeSec, end: timeSec + 0.05, track: 0 });
            }
            for (let idx = 1; idx < parenParts.length; idx += 3) {
                let off = parseFloat(parenParts[idx]) || 0;
                let dur = parseFloat(parenParts[idx + 1]) || 0;
                let wText = parenParts[idx + 2] || "";
                let startSec = timeSec + (off / 1000.0);
                if (wText.length > 0) words.push({ text: wText, start: startSec, end: startSec + (dur / 1000.0), track: 0 });
            }
        }
    }
    return words;
}

function _normalizeWordTimings(words, baseSec, limitSec) {
    if (!words || words.length === 0) return;
    let limit = Math.max(baseSec || 0, limitSec || 0);
    let prevEnd = Math.max(0, baseSec || 0);
    for (let i = 0; i < words.length; i++) {
        let w = words[i];
        let start = Math.max(0, w.start || 0);
        let end = Math.max(0, w.end || 0);
        if (end <= start) end = start + 0.05;

        if (start < prevEnd) {
            if (end > prevEnd) {
                start = prevEnd;
                end = Math.min(end, limit);
                if (end <= start) end = Math.min(limit, start + 0.001);
            } else {
                let start2 = Math.min(prevEnd, limit);
                let remainingWords = Math.max(1, words.length - i);
                let budget = Math.max(0, limit - start2);
                let slice = budget > 0
                    ? Math.min(0.5, budget, Math.max(0.02, (budget / remainingWords) * 0.5))
                    : 0.001;
                start = start2;
                end = start + Math.max(0.001, Math.min(Math.max(end - start, 0.001), slice));
            }
        }
        w.start = start;
        w.end = end;
        prevEnd = Math.max(prevEnd, w.end);
    }
}

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

        let content = rawLine.substring(lastIdx).replace(_reInvisible, "");

        for (let h = 0; h < headers.length; h++) {
            let timeSec = Math.max(0, parseTimeHeader(headers[h]) - offsetSec);
            let lineDuration = 0;
            if (headers[h].includes(",")) {
                lineDuration = (parseFloat(headers[h].split(",")[1]) || 0) / 1000.0;
            }

            let words = _parseWords(content, timeSec, offsetSec);
            let isWordSynced = words.length > 0;

            let headerEnd = lineDuration > 0 ? timeSec + lineDuration : 0;
            let maxWordEnd = 0;
            if (isWordSynced) {
                let track0 = [];
                let track1 = [];
                for (let w = 0; w < words.length; w++) {
                    if ((words[w].track || 0) === 1) track1.push(words[w]);
                    else track0.push(words[w]);
                }
                let limit = headerEnd;
                for (let w = 0; w < words.length; w++) {
                    if ((words[w].end || 0) > limit) limit = words[w].end || 0;
                }
                _normalizeWordTimings(track0, timeSec, limit);
                _normalizeWordTimings(track1, timeSec, limit);
                maxWordEnd = 0;
                for (let w = 0; w < words.length; w++) {
                    if (words[w].end > maxWordEnd) maxWordEnd = words[w].end;
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

            let lineEnd = (isWordSynced && maxWordEnd > 0)
                ? Math.max(maxWordEnd, headerEnd)
                : headerEnd;

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

function _buildContext(title, artist, album) {
    let meta = {};
    let any = false;
    let add = function(s) {
        let v = _normVariants(s);
        for (let i = 0; i < v.length; i++) { meta[v[i]] = true; any = true; }
        return v;
    };
    let tv = add(title || "");
    let av = add(artist || "");
    add(album || "");
    let artistParts = (artist || "").split(/\s*(?:,|;|&|\/|、|\bfeat\.?|\bft\.?|\band\b)\s*/i);
    for (let i = 0; i < artistParts.length; i++) add(artistParts[i]);
    if (tv.length > 0 && av.length > 0) {
        meta[tv[0] + av[0]] = true;
        meta[av[0] + tv[0]] = true;
    }

    let titleScript = _scriptOf(title || "");
    let artistScript = _scriptOf(artist || "");
    let hint = "";
    if ((titleScript === "cjk" || titleScript === "latin")
            && (!artistScript || artistScript === "mixed" || artistScript === titleScript)) {
        hint = titleScript;
    }

    return { meta: meta, hasMeta: any, hint: hint, stats: "", primary: "" };
}

function _pruneTranslations(entries, ctx) {
    let n = entries.length;
    for (let i = 0; i < n; i++) {
        let e = entries[i];
        if (e.text === "♪") { e._k = ""; continue; }
        let c = _countMatches(e.text, _reCjkG);
        let l = _countMatches(e.text, _reLatinG);
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

    let c = 0, l = 0;
    for (let k = 0; k < clusters.length; k++) {
        for (let x = clusters[k][0]; x < clusters[k][1]; x++) {
            let e = entries[x];
            if (e._k === "" || _isNoise(e, ctx)) continue;
            if (e._k === "c") c++; else l++;
            break;
        }
    }
    ctx.stats = c > l ? "cjk" : "latin";
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
        m = text.match(_reTransSlashLatin) || text.match(_reTransParenLatin);
    } else if (primary === "cjk") {
        m = text.match(_reTransSlashCjk);
    }
    if (!m) return text;
    let kept = m[1].trim();
    return kept.length > 0 ? kept : text;
}

function _isHardCredit(t) {
    return _reHardEn.test(t) || _reHardBy.test(t) || _reCjkStrong.test(t)
        || _reCjkColon.test(t) || _reLegal.test(t);
}

function _isPerformerTag(t, ctx) {
    if (!ctx.hasMeta) return false;
    let m = t.match(/^\s*[\[\(（【]?\s*([A-Za-z0-9\s._'\/&+-]+?)\s*[\]\)）】]?\s*[:：]\s*$/);
    if (!m) return false;
    let v = _normVariants(m[1].trim());
    for (let i = 0; i < v.length; i++) {
        if (ctx.meta[v[i]]) return true;
    }
    let parts = m[1].trim().split(/\s*(?:,|;|&|\/|\+|、|\bfeat\.?|\bft\.?|\band\b)\s*/i);
    if (parts.length > 1) {
        let allMatch = true;
        for (let p = 0; p < parts.length; p++) {
            let pv = _normVariants(parts[p]);
            let ok = false;
            for (let i = 0; i < pv.length; i++) {
                if (ctx.meta[pv[i]]) { ok = true; break; }
            }
            if (!ok) { allMatch = false; break; }
        }
        if (allMatch) return true;
    }
    return false;
}

function _isNoise(e, ctx) {
    let t = e.text;
    return _isHardCredit(t) || _reSoftEn.test(t) || _reCjkSoft.test(t)
        || (e.time < 15 && _isMetaEcho(t, ctx))
        || _isPerformerTag(t, ctx);
}

function _isMetaEcho(t, ctx) {
    if (!ctx.hasMeta) return false;
    let whole = _normVariants(t);
    for (let i = 0; i < whole.length; i++) {
        if (ctx.meta[whole[i]]) return true;
    }
    let parts = t.split(/\s+[-–—]\s+|\s*[\/|｜:：]\s*/);
    if (parts.length >= 2) {
        let allMatch = true;
        for (let p = 0; p < parts.length; p++) {
            let pv = _normVariants(parts[p]);
            let ok = false;
            for (let i = 0; i < pv.length; i++) {
                if (ctx.meta[pv[i]]) { ok = true; break; }
            }
            if (!ok) allMatch = false;
        }
        if (allMatch) return true;

        let dashParts = t.split(/\s+[-–—]\s+/);
        if (dashParts.length === 2) {
            let p0v = _normVariants(dashParts[0]);
            let p1v = _normVariants(dashParts[1]);
            let p0Match = p0v.some(function(v) { return !!ctx.meta[v]; });
            let p1Match = p1v.some(function(v) { return !!ctx.meta[v]; });
            if (p0Match || p1Match) {
                if (p0Match && p1Match) return true;
                if (ctx.primary === "latin" && (_reCjkG.test(dashParts[0]) || _reCjkG.test(dashParts[1]))) return true;
                if (_reTransParenLatin.test(dashParts[0]) || _reTransParenLatin.test(dashParts[1])) return true;
            }
        }
    }
    return false;
}

function _stripCredits(entries, ctx) {
    let freq = {};
    for (let i = 0; i < entries.length; i++) {
        let k = _norm(entries[i].text);
        freq[k] = (freq[k] || 0) + 1;
    }

    let firstLatinLyric = -1;
    if (ctx.primary === "latin" && ctx.stats === "latin") {
        for (let i = 0; i < entries.length; i++) {
            let e = entries[i];
            if (e._k === "l" && !_isNoise(e, ctx)) { firstLatinLyric = i; break; }
        }
    }

    let out = [];
    let seenLyric = false;
    let dropNext = false;

    for (let i = 0; i < entries.length; i++) {
        let e = entries[i];
        let t = e.text;

        if (t !== "♪") {
            if (_reMusicLabel.test(t) || _reSymbolOnly.test(t)) {
                e.text = t = "♪";
                e.isWordSynced = false;
                e.words = null;
            } else if (_reSectionLabel.test(t) || _isPerformerTag(t, ctx)) {
                continue;
            } else if (_isHardCredit(t)) {
                dropNext = !seenLyric && /[:：]\s*$/.test(t);
                continue;
            } else if (!seenLyric) {
                if (dropNext && e.time < 25) { dropNext = false; continue; }
                if (_reSoftEn.test(t) || _reCjkSoft.test(t)) continue;
                if (e.time < 15 && freq[_norm(t)] === 1 && _isMetaEcho(t, ctx)) continue;
                if (i < firstLatinLyric && e.time < 25 && e._k === "c"
                    && _countMatches(t, _reLatinG) === 0) continue;
                if (ctx.primary === "latin" && e.time < 15 && _reCjkG.test(t) && _isMetaEcho(t, ctx)) continue;
            }
            dropNext = false;
        }

        if (t === "♪") {
            if (!seenLyric) continue;
            if (out.length > 0 && out[out.length - 1].text === "♪") continue;
        } else {
            seenLyric = true;
        }
        out.push(e);
    }

    while (out.length > 0) {
        let last = out[out.length - 1];
        let lt = last.text;
        if (lt === "♪") {
            out.pop();
            continue;
        }
        let isOutroCredit = _isHardCredit(lt)
            || _reSoftEn.test(lt)
            || _reCjkSoft.test(lt)
            || _reLegal.test(lt)
            || _isMetaEcho(lt, ctx)
            || (ctx.primary === "latin" && _reCjkG.test(lt));
        if (isOutroCredit) {
            out.pop();
        } else {
            break;
        }
    }

    return out;
}

function parseLyricsString(synced, title, artist, album) {
    if (!synced) return [];
    if (synced.indexOf("&") >= 0) synced = unescapeHtml(synced);

    let offsetSec = 0;
    let offsetMatch = synced.match(/\[offset:\s*([+-]?\d+)\]/i);
    if (offsetMatch) offsetSec = (parseFloat(offsetMatch[1]) || 0) / 1000.0;

    let entries = _tokenize(synced, offsetSec);
    if (entries.length === 0) return [];
    if (entries.length > 1) entries.sort((a, b) => a.time - b.time);

    let ctx = _buildContext(title, artist, album);
    entries = _pruneTranslations(entries, ctx);
    for (let i = 0; i < entries.length; i++) {
        let e = entries[i];
        if (e.text !== "♪") {
            if (ctx.primary === "latin" && _reCjkG.test(e.text)) {
                let cleaned = _stripInlineTranslation(e.text, "latin");
                if (cleaned !== e.text) {
                    e.text = cleaned;
                    if (e.isWordSynced && e.words && e.words.length > 0) {
                        while (e.words.length > 0 && _reCjkG.test(e.words[e.words.length - 1].text)) {
                            e.words.pop();
                        }
                        while (e.words.length > 0 && /[\s()（）]/.test(e.words[e.words.length - 1].text.trim())) {
                            e.words.pop();
                        }
                    }
                }
            } else if (!e.isWordSynced && ctx.primary === ctx.stats) {
                e.text = _stripInlineTranslation(e.text, ctx.primary);
            }
        }
    }
    let parsed = _stripCredits(entries, ctx);

    while (parsed.length > 0 && (!parsed[0].text || parsed[0].text.trim() === "")) {
        parsed.shift();
    }
    while (parsed.length > 0 && (!parsed[parsed.length - 1].text || parsed[parsed.length - 1].text.trim() === "")) {
        parsed.pop();
    }

    let totalUpper = 0;
    let totalLower = 0;
    for (let i = 0; i < parsed.length; i++) {
        let t = parsed[i].text;
        if (t && t !== "♪") {
            let u = t.match(/\p{Lu}/gu);
            let l = t.match(/\p{Ll}/gu);
            if (u) totalUpper += u.length;
            if (l) totalLower += l.length;
        }
    }
    let totalAlpha = totalUpper + totalLower;
    let isSongAllWordCaps = (totalAlpha >= 30) && (totalUpper / totalAlpha >= 0.70);

    for (let i = 0; i < parsed.length; i++) {
        let p = parsed[i];
        delete p._k;
        if (p.text && p.text !== "♪") {
            if (isSongAllWordCaps) {
                if (p.isWordSynced && p.words && p.words.length > 0) {
                    let fullText = p.words.map(w => w.text).join("");
                    let normFull = normalizeCapsLine(fullText);
                    let offset = 0;
                    for (let w = 0; w < p.words.length; w++) {
                        let len = p.words[w].text.length;
                        p.words[w].text = normFull.substring(offset, offset + len);
                        offset += len;
                    }
                    p.text = normFull.replace(/\s+/g, " ").trim();
                } else {
                    p.text = normalizeCapsLine(p.text);
                }
            } else {
                p.text = capitalizeFirstLetter(p.text);
                if (p.isWordSynced && p.words && p.words.length > 0) {
                    for (let w = 0; w < p.words.length; w++) {
                        let orig = p.words[w].text;
                        let cap = capitalizeFirstLetter(orig);
                        if (cap !== orig) {
                            p.words[w].text = cap;
                            break;
                        }
                    }
                }
            }
        }
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

    if (!parsed.some(function(p) { return p.text !== "♪"; })) return [];
    return parsed;
}
