.pragma library

/**
 * Multi-line lyric grouping, silence heuristics, and repeat detection.
 *
 * Automatically merges consecutive short lyrics into single display units (separated
 * by •), detects phrase repetitions (x2, x3), measures group bounding geometry,
 * and handles binary search for active lines.
 */

/**
 * Escapes XML/HTML special characters for rich-text display.
 */
function escapeXml(s) {
    if (!s) return "";
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/**
 * Formats a lyric line into HTML rich text, styling background vocal parentheticals
 * and bullet separators with designated colors.
 */
function formatLineRich(rawText, mainCol, bgCol, bulletCol) {
    if (!rawText) return "";
    let parts = rawText.split(/(\([^\)]*\))/g);
    let res = "";
    for (let i = 0; i < parts.length; i++) {
        let part = parts[i];
        if (!part) continue;
        let esc = escapeXml(part);
        if (part.startsWith("(") && part.endsWith(")")) {
            res += `<font color="${bgCol}">${esc}</font>`;
        } else if (esc.indexOf(" • ") !== -1) {
            let chunks = esc.split(" • ");
            for (let c = 0; c < chunks.length; c++) {
                if (c > 0) res += `<font color="${bulletCol}"> • </font>`;
                if (chunks[c].length > 0) {
                    res += `<font color="${mainCol}">${chunks[c]}</font>`;
                }
            }
        } else {
            res += `<font color="${mainCol}">${esc}</font>`;
        }
    }
    return res;
}

/**
 * Checks whether line at index k is part of a consecutive duplicate sequence.
 */
function isLineRepeat(lines, k) {
    if (!lines || k < 0 || k >= lines.length) return false;
    let txt = lines[k].text;
    if (txt === "♪") return false;
    return (k > 0 && lines[k - 1].text === txt) || (k + 1 < lines.length && lines[k + 1].text === txt);
}

/**
 * Constructs multi-line groups based on natural song cadence, punctuation,
 * and available top-bar pixel width.
 */
function buildGroupIndex(lines, bulletW, maxAllowedPx, precompileLineMetricsFn) {
    if (!lines || lines.length === 0) return [];

    for (let l = 0; l < lines.length; l++) {
        if (precompileLineMetricsFn) precompileLineMetricsFn(lines[l]);
    }

    let index = [];
    let i = 0;
    while (i < lines.length) {
        let start = i;
        let currentLine = lines[i];
        let groupText = currentLine.text;
        let currentGroupWidth = currentLine._totalWidth || 0;
        let j = i + 1;

        // Never group instrumental markers or repeat sequences
        let isRepeat = isLineRepeat(lines, i);
        let isInstrumental = groupText === "♪";
        let isAlreadyLong = currentGroupWidth > maxAllowedPx * 0.62;

        if (!isInstrumental && !isRepeat && !isAlreadyLong) {
            while (j < lines.length) {
                let nextLine = lines[j];
                let nextText = nextLine.text;

                // Stop if next item is an instrumental pause or repeat sequence
                if (nextText === "♪" || isLineRepeat(lines, j)) break;

                let prevLine = lines[j - 1];
                let prevEnd = prevLine.endTime || (prevLine.time + 3.0);
                let silenceGap = nextLine.time - prevEnd;

                let lineStartInterval = nextLine.time - prevLine.time;
                let totalSpan = nextLine.time - lines[start].time;
                if (silenceGap > 1.6 || lineStartInterval > 5.0 || totalSpan > 9.5) break;

                let prevTrimmed = prevLine.text.trim();
                let hasTerminalPunctuation = /[.?!:]$/.test(prevTrimmed) && !/\.\.\.$/.test(prevTrimmed);
                let bothBrief = (prevTrimmed.length <= 16) && (nextText.trim().length <= 16);
                if (hasTerminalPunctuation && !bothBrief) break;

                // Triplet restraint
                let currentCount = (j - start) + 1;
                if (currentCount > 3) break;
                if (currentCount === 3) {
                    let line1Short = lines[start].text.length <= 18;
                    let line2Short = lines[start + 1].text.length <= 18;
                    let line3Short = nextText.length <= 18;
                    if (!line1Short || !line2Short || !line3Short) break;
                }

                // Countdown timer reserve
                let nextAfter = (j + 1 < lines.length) ? lines[j + 1] : null;
                let nextAfterGap = nextAfter ? (nextAfter.time - (nextLine.endTime || nextLine.time + 3.0)) : 999;
                let hasTimer = (nextAfterGap > 4.5) || (nextAfter && nextAfter.text === "♪");
                let reserve = hasTimer ? 65 : 20;

                // Pixel width check using precompiled line lengths
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
    return index;
}

/**
 * Measures styled sub-bounds for each line within a multi-line group using TextMetrics.
 */
function computeGroupBounds(g, lines, metricsRev, bulletCol, colLitHex, colBgLitHex, styledMetrics, formatLineRichFn) {
    if (!g) return null;
    if (g._bounds && g._rev === metricsRev) return g._bounds;

    let count = g.endIdx - g.startIdx + 1;
    if (count <= 1) {
        g._rev = metricsRev;
        g._bounds = [{
            startFrac: 0.0,
            endFrac: 1.0,
            startX: 0,
            endX: lines[g.startIdx]?._totalWidth || 0
        }];
        g._totalWidth = lines[g.startIdx]?._totalWidth || 0;
        return g._bounds;
    }

    let bulletSep = `<font color="${bulletCol}"> • </font>`;
    let parts = [];
    for (let m = g.startIdx; m <= g.endIdx; m++) {
        parts.push(formatLineRichFn ? formatLineRichFn(lines[m].text, colLitHex, colBgLitHex) : lines[m].text);
    }

    styledMetrics.text = parts.join(bulletSep);
    let totalW = styledMetrics.implicitWidth;
    if (totalW <= 0) {
        g._rev = metricsRev;
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

        // Generous padding into bullet separator whitespace to guarantee zero clipping of edge glyphs
        let clipStart = (i === 0) ? 0.0 : Math.max(0.0, startX - 2.5);
        let clipEnd = (i === count - 1) ? totalW : Math.min(totalW, endX + 2.0);

        bounds.push({
            startX: startX,
            endX: endX,
            clipStart: clipStart,
            clipEnd: clipEnd,
            startFrac: Math.max(0.0, Math.min(1.0, clipStart / totalW)),
            endFrac: Math.max(0.0, Math.min(1.0, clipEnd / totalW))
        });
    }

    g._rev = metricsRev;
    g._bounds = bounds;
    g._totalWidth = totalW;
    return bounds;
}

/**
 * Generalized repeat detection for any unit (single line, pair A•B, triplet A•B•C, etc.)
 */
function getRepeatInfo(groups, lines, g) {
    let identicalCount = 1;
    let repeatSeriesStart = g.startIdx;
    if (g.text && g.text !== "♪") {
        // Forward scan across consecutive groups (with max 6.0s natural musical gap)
        let nextIdx = g.nextStartIdx;
        let prevEnd = lines[g.endIdx].endTime || (lines[g.endIdx].time + 3.0);
        while (nextIdx < lines.length) {
            let nextGroup = groups[nextIdx];
            if (!nextGroup || nextGroup.text !== g.text) break;
            let nextStart = lines[nextGroup.startIdx].time;
            let silenceGap = nextStart - prevEnd;
            if (silenceGap > 6.0) break; // Exclude long interludes / separate song sections
            identicalCount++;
            prevEnd = lines[nextGroup.endIdx].endTime || (lines[nextGroup.endIdx].time + 3.0);
            nextIdx = nextGroup.nextStartIdx;
        }
        // Backward scan across consecutive groups
        let prevIdx = g.startIdx - 1;
        let currStart = lines[g.startIdx].time;
        while (prevIdx >= 0) {
            let prevGroup = groups[prevIdx];
            if (!prevGroup || prevGroup.text !== g.text) break;
            let pEnd = lines[prevGroup.endIdx].endTime || (lines[prevGroup.endIdx].time + 3.0);
            let silenceGap = currStart - pEnd;
            if (silenceGap > 6.0) break;
            repeatSeriesStart = prevGroup.startIdx;
            currStart = lines[prevGroup.startIdx].time;
            prevIdx = prevGroup.startIdx - 1;
        }
    }

    let hasRepeatSeries = identicalCount > 1 || (g.startIdx > 0 && groups[g.startIdx - 1].text === g.text);
    let groupKey = hasRepeatSeries ? repeatSeriesStart : g.startIdx;
    let isLastOfSeries = identicalCount === 1 && g.startIdx > 0 && groups[g.startIdx - 1].text === g.text;
    let repeatSuffix = (identicalCount > 1 || isLastOfSeries) ? ` (x${identicalCount})` : "";

    return {
        identicalCount: identicalCount,
        groupKey: groupKey,
        isLastOfSeries: isLastOfSeries,
        repeatSuffix: repeatSuffix
    };
}

/**
 * Finds the last lyric line whose time <= pos.
 * Fast path O(1) checks current and next lines; fallback O(log N) binary search.
 */
function findLineIdx(lines, pos, firstLineLead, rawIdx) {
    let n = lines.length;
    if (pos < Math.max(0, lines[0].time - firstLineLead)) return -1;

    let i = rawIdx;
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

/**
 * Walks backward to find the last line that is not an instrumental pause (♪).
 */
function lastRealLine(lines, fromIdx) {
    for (let p = fromIdx; p >= 0; p--) {
        if (lines[p].text !== "♪") return p;
    }
    return -1;
}


/**
 * Constructs line, dim, lit, rich, and bounds geometry for sung lyrics (mSing).
 */
function buildSingDisplay(g, currIdx, lines, colors, repeatSuffix, styledMetrics, getGroupBoundsFn, started, measureSuffixFn) {
    let isSingle = g.startIdx === g.endIdx;
    let baseText = g.text + repeatSuffix;
    let timerCol = colors.timer;
    let bulletSep = `<font color="${colors.bullet}"> • </font>`;
    let dim = "", lit = "", rich = "";
    let totalLyricW = 0, fullGroupW = 0;
    let startFrac = 0.0, endFrac = 1.0;

    if (!isSingle) {
        let partsDim = [], partsLit = [], partsRich = [];
        for (let m = g.startIdx; m <= g.endIdx; m++) {
            let lObj = lines[m];
            let dimPart = formatLineRich(lObj.text, colors.upcoming, colors.bgUpcoming, colors.bullet);
            partsDim.push(dimPart);
            partsLit.push(formatLineRich(lObj.text, colors.lit, colors.bgLit, colors.bullet));
            partsRich.push(m < currIdx
                ? formatLineRich(lObj.text, colors.past, colors.bgPast, colors.bullet)
                : dimPart);
        }
        let groupBounds = getGroupBoundsFn ? getGroupBoundsFn(g, lines) : null;
        totalLyricW = g._totalWidth || 0;
        fullGroupW = totalLyricW;
        dim = partsDim.join(bulletSep);
        lit = partsLit.join(bulletSep);
        rich = partsRich.join(bulletSep);
        if (repeatSuffix.length > 0) {
            let suffixRich = ` <font color="${timerCol}">${repeatSuffix}</font>`;
            dim += suffixRich;
            rich += suffixRich;
            if (styledMetrics) {
                styledMetrics.text = rich;
                fullGroupW = styledMetrics.implicitWidth > 0 ? styledMetrics.implicitWidth : (totalLyricW + (measureSuffixFn ? measureSuffixFn(repeatSuffix) : 0));
            } else {
                fullGroupW = totalLyricW + (measureSuffixFn ? measureSuffixFn(repeatSuffix) : 0);
            }
        }
        if (groupBounds && currIdx >= g.startIdx && currIdx <= g.endIdx && started) {
            let b = groupBounds[currIdx - g.startIdx];
            if (fullGroupW > 0) {
                startFrac = Math.max(0.0, Math.min(1.0, b.clipStart / fullGroupW));
                endFrac = Math.max(0.0, Math.min(1.0, b.clipEnd / fullGroupW));
            } else {
                startFrac = b.startFrac;
                endFrac = b.endFrac;
            }
        }
    } else {
        totalLyricW = lines[g.startIdx]._totalWidth || 0;
        fullGroupW = totalLyricW;
        dim = formatLineRich(g.text, colors.upcoming, colors.bgUpcoming, colors.bullet);
        lit = formatLineRich(g.text, colors.lit, colors.bgLit, colors.bullet);
        rich = lit;
        if (repeatSuffix.length > 0) {
            let suffixRich = ` <font color="${timerCol}">${repeatSuffix}</font>`;
            dim += suffixRich;
            rich += suffixRich;
            fullGroupW = totalLyricW + (measureSuffixFn ? measureSuffixFn(repeatSuffix) : 0);
        }
    }

    return {
        line: baseText,
        dim: dim,
        lit: lit,
        rich: rich,
        totalLyricW: totalLyricW,
        fullGroupW: fullGroupW,
        startFrac: startFrac,
        endFrac: endFrac
    };
}

/**
 * Builds display strings and line duration for non-sing modes.
 */
function buildStatusDisplay(mode, baseText, remaining, g, lines, groups, colors, trackInfo) {
    let line = "", rich = "", lineDur = 4.5;
    let timerCol = colors.timer;
    let waitingHex = (!g || g.startIdx === g.endIdx) ? colors.waitingSingle : colors.waitingGroup;

    switch (mode) {
    case 1: { // mMark
        if (remaining > 0) lineDur = remaining;
        let prevIdx = lastRealLine(lines, g ? (g.startIdx - 1) : -1);
        let prevText = prevIdx >= 0 ? groups[prevIdx].text : "";
        let prevHex = (prevIdx >= 0 && groups[prevIdx].startIdx < groups[prevIdx].endIdx)
            ? colors.waitingGroup : colors.waitingSingle;
        if (remaining > 0) {
            if (prevText) {
                line = `${prevText} (♪ ${remaining}s)`;
                rich = `<font color="${prevHex}">${escapeXml(prevText)}</font> <font color="${timerCol}">(♪ ${remaining}s)</font>`;
            } else if (trackInfo && trackInfo.plain) {
                line = `${trackInfo.plain} (Intro ♪ ${remaining}s)`;
                rich = `${trackInfo.rich} <font color="${timerCol}">(Intro ♪ ${remaining}s)</font>`;
            } else {
                line = `(Intro ♪ ${remaining}s)`;
                rich = `<font color="${timerCol}">(Intro ♪ ${remaining}s)</font>`;
            }
        } else if (prevText) {
            line = prevText;
            rich = `<font color="${prevHex}">${escapeXml(prevText)}</font>`;
        } else {
            line = trackInfo?.plain || "";
            rich = trackInfo?.rich || "";
        }
        break;
    }
    case 2: { // mWait
        if (remaining > 0) lineDur = remaining;
        if (remaining > 0) {
            line = `${baseText} (♪ ${remaining}s)`;
            rich = `<font color="${waitingHex}">${escapeXml(baseText)}</font> <font color="${timerCol}">(♪ ${remaining}s)</font>`;
        } else {
            line = baseText;
            rich = `<font color="${waitingHex}">${escapeXml(baseText)}</font>`;
        }
        break;
    }
    case 7: { // mEndHoldMuted
        line = baseText;
        rich = `<font color="${waitingHex}">${escapeXml(baseText)}</font>`;
        break;
    }
    case 5: { // mEndHoldLast
        let li = lastRealLine(lines, g ? (g.startIdx - 1) : -1);
        let lastText = li >= 0 ? lines[li].text : "";
        line = lastText;
        rich = `<font color="${colors.waitingSingle}">${escapeXml(lastText)}</font>`;
        break;
    }
    case 4: { // mOutro
        if (trackInfo && trackInfo.plain) {
            line = `${trackInfo.plain} (Outro ♪)`;
            rich = `${trackInfo.rich} <font color="${timerCol}">(Outro ♪)</font>`;
        } else {
            line = "Outro ♪";
            rich = `<font color="${timerCol}">Outro ♪</font>`;
        }
        break;
    }
    case 6: { // mEndFallback
        let li = lastRealLine(lines, g ? (g.startIdx - 1) : -1);
        if (li >= 0) {
            line = lines[li].text;
            rich = `<font color="${colors.waitingSingle}">${escapeXml(line)}</font>`;
        } else {
            line = trackInfo?.plain || "";
            rich = trackInfo?.rich || "";
        }
        break;
    }
    }

    return { line: line, rich: rich, dim: rich, lit: rich, lineDur: lineDur };
}


/**
 * Evaluates active playback mode (Intro, Sing, Wait, Mark, Outro, Hold) and countdown second.
 */
function determineMode(currIdx, lines, groups, lineSyncPos, wordSyncPos, firstLineLead, trackLen) {
    let mode = 0; // mIntro
    let remaining = 0;
    let started = false;
    let n = lines ? lines.length : 0;

    if (currIdx < 0) {
        remaining = Math.max(0, Math.ceil(lines[0].time - firstLineLead - lineSyncPos));
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
                mode = 1; // mMark
            } else {
                let groupEnd = lastLine.endTime || (lastLine.time + 3.0);
                let waiting = wordSyncPos >= groupEnd && (nextTime - groupEnd) > 4.0 && (wordSyncPos - groupEnd) > 1.5;
                mode = waiting ? 2 : 3; // mWait : mSing
            }
        } else {
            let holdSec = 4.5;
            let groupEnd = lastLine.endTime || (lastLine.time + 4.0);
            if (isMark) {
                let li = lastRealLine(lines, g.startIdx - 1);
                let sinceReal = 999;
                if (li >= 0) {
                    let realEnd = lines[li].endTime || (lines[li].time + 4.0);
                    if (realEnd > 0) sinceReal = wordSyncPos - realEnd;
                }
                if (li >= 0 && sinceReal < holdSec) mode = 5; // mEndHoldLast
                else if (trackLen > 0) mode = 4; // mOutro
                else mode = 6; // mEndFallback
            } else {
                let finished = wordSyncPos >= groupEnd;
                let since = wordSyncPos - groupEnd;
                if (finished && trackLen > 0 && (trackLen - groupEnd) > 6.0 && since >= holdSec) mode = 4; // mOutro
                else if (finished && since >= holdSec) mode = 7; // mEndHoldMuted
                else mode = 3; // mSing
            }
        }
    }
    return { mode: mode, remaining: remaining, started: started };
}
