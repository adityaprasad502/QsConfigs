.pragma library

/**
 * Vocal sweep and easing calculations for synchronized lyrics.
 *
 * Handles organic vocal timing curves (vocalEase), per-word glyph & duration
 * interpolation (bounds), lead/background track geometry separation, and
 * multi-line progress calculation.
 */

/**
 * Applies an organic vocal easing curve to linear time progress t in [0, 1].
 * Long sustained notes get an expressive musical S-curve swell.
 * Chained syllables preserve forward momentum across word boundaries.
 */
function vocalEase(t, dur, chainedPrev, chainedNext) {
    if (t <= 0) return 0.0;
    if (t >= 1) return 1.0;
    if (dur < 0.10) return t;

    // Long held notes (sustained vowel) always get an organic musical S-curve swell
    if (dur >= 0.75) {
        let mix = Math.min(0.55, 0.25 + 0.20 * Math.min(2.0, dur));
        return t + (t * t * (3.0 - 2.0 * t) - t) * mix;
    }

    // Chained syllables in a continuous singing phrase: preserve forward momentum
    if (chainedPrev && chainedNext) {
        return t;
    } else if (!chainedPrev && chainedNext) {
        // Phrase attack: start gently from silence, flow with momentum into next syllable
        let mix = Math.min(0.35, 0.15 + 0.25 * dur);
        return t + (t * t - t) * mix;
    } else if (chainedPrev && !chainedNext) {
        // Phrase release: enter with momentum, then gently settle into the pause
        let mix = Math.min(0.35, 0.15 + 0.25 * dur);
        return t + (t - t * t) * mix;
    }

    // Isolated word with pauses before and after: balanced gentle S-curve
    let mix = Math.min(0.40, 0.15 + 0.25 * dur);
    return t + (t * t * (3.0 - 2.0 * t) - t) * mix;
}

/**
 * Computes per-word character pixel bounds (cx) and balanced duration shares (ct).
 * Balances glyph count with visual width proportion so narrow characters do not crawl
 * and wide characters do not sprint.
 */
function computeBounds(line, measureFn) {
    let bounds = [];
    let prefix = "";
    let prevW = 0;
    let words = line.words || [];
    for (let i = 0; i < words.length; i++) {
        let text = words[i].text;
        let chars = Array.from(text);
        let n = chars.length;
        let cx = [];
        let ct = [];
        let acc = "";
        for (let j = 0; j < n; j++) {
            acc += chars[j];
            cx.push(j === n - 1 ? measureFn(prefix + text) : measureFn(prefix + acc));
        }
        let endX = n > 0 ? cx[n - 1] : prevW;
        let trimmed = text.replace(/\s+$/, "");
        let visEndX = trimmed.length < text.length ? measureFn(prefix + trimmed) : endX;
        let wordW = endX - prevW;

        // Balance character timing between glyph index and visual width proportion
        for (let j = 0; j < n; j++) {
            let indexFrac = (j + 1) / n;
            let visualFrac = wordW > 0 ? Math.max(0.0, Math.min(1.0, (cx[j] - prevW) / wordW)) : indexFrac;
            ct.push(0.15 * indexFrac + 0.85 * visualFrac);
        }

        prefix += text;
        bounds.push({ startX: prevW, endX: endX, visEndX: visEndX, cx: cx, ct: ct });
        prevW = endX;
    }
    line._wordBounds = bounds;
    return bounds;
}

/**
 * Splits a line's word bounds into foreground (track 0) and background (track 1) regions.
 * Precomputes track subset arrays and bounding geometry once per line.
 */
function assignTrackRegions(line) {
    let words = line.words || [];
    let bounds = line._wordBounds || [];
    let lead = line._leadIdx || [];
    let bg = line._bgIdx || [];

    function _makeTrackData(idx) {
        if (!idx || idx.length === 0) return null;
        let tw = [];
        let tb = [];
        for (let i = 0; i < idx.length; i++) {
            tw.push(words[idx[i]]);
            tb.push(bounds[idx[i]]);
        }
        let sx = tb[0].startX;
        let firstWordIdx = idx[0];
        if (firstWordIdx > 0 && /\s$/.test(words[firstWordIdx - 1].text)) {
            let prevVisEnd = bounds[firstWordIdx - 1].visEndX !== undefined ? bounds[firstWordIdx - 1].visEndX : bounds[firstWordIdx - 1].endX;
            let gap = sx - prevVisEnd;
            if (gap > 0.5) {
                sx = Math.max(prevVisEnd + gap * 0.35, sx - Math.min(1.6, gap * 0.45));
            }
        }
        let lastBound = tb[tb.length - 1];
        let ex = lastBound.endX;
        if (lastBound.visEndX !== undefined && lastBound.visEndX < ex) {
            let trailGap = ex - lastBound.visEndX;
            ex = lastBound.visEndX + Math.min(0.8, trailGap * 0.25);
        }
        return {
            words: tw,
            bounds: tb,
            startX: sx,
            endX: ex,
            width: Math.max(0.0, ex - sx)
        };
    }
    line._trackData0 = _makeTrackData(lead);
    line._trackData1 = _makeTrackData(bg);
}

/**
 * Precompiles text metrics and repairs squashed word durations for a lyric line.
 */
function precompileLineMetrics(line, metricsRev, measureFn) {
    if (!line || line._rev === metricsRev) return;
    line._rev = metricsRev;
    line._wi = 0;
    line._wiLead = 0;
    line._wiBg = 0;
    if (!line.words || line.words.length === 0) {
        line._wordBounds = null;
        line._leadIdx = [];
        line._bgIdx = [];
        line._trackData0 = null;
        line._trackData1 = null;
        line._totalWidth = measureFn(line.text);
        return;
    }
    let joined = "";
    for (let i = 0; i < line.words.length; i++) joined += line.words[i].text;
    let w = measureFn(joined);
    line._totalWidth = w > 0 ? w : measureFn(line.text);
    computeBounds(line, measureFn);

    // Separate tracks by track id (0 = foreground, 1 = background)
    let lead = [], bg = [];
    for (let i = 0; i < line.words.length; i++) {
        if ((line.words[i].track || 0) === 1) bg.push(i);
        else lead.push(i);
    }
    line._leadIdx = lead;
    line._bgIdx = bg;

    // Repair squashed tail words or words whose durations were artificially squashed
    for (let track = 0; track <= 1; track++) {
        let idx = track === 1 ? bg : lead;
        if (idx.length === 0) continue;
        let tw = [];
        for (let i = 0; i < idx.length; i++) tw.push(line.words[idx[i]]);

        let hasSquashed = false;
        if (tw.length === 1) {
            let dur = tw[0].end - tw[0].start;
            if (dur < 0.120) hasSquashed = true;
        } else {
            for (let i = 0; i < tw.length; i++) {
                let dur = tw[i].end - tw[i].start;
                if (dur <= 0.025 || (i > 0 && tw[i].start <= tw[i - 1].start)) {
                    hasSquashed = true;
                    break;
                }
            }
        }

        if (hasSquashed) {
            if (tw.length === 1) {
                tw[0].start = Math.max(line.time, tw[0].end - 0.200);
            } else {
                let trackStart = tw[0].start;
                let trackEnd = tw[tw.length - 1].end;
                let totalSpan = Math.max(0.100, trackEnd - trackStart);
                let weights = [];
                let totalWeight = 0;
                for (let i = 0; i < tw.length; i++) {
                    let wt = Math.max(1, (tw[i].text || "").trim().length);
                    weights.push(wt);
                    totalWeight += wt;
                }
                let cur = trackStart;
                for (let i = 0; i < tw.length; i++) {
                    let wDur = (weights[i] / totalWeight) * totalSpan;
                    tw[i].start = cur;
                    tw[i].end = (i === tw.length - 1) ? trackEnd : cur + wDur;
                    cur = tw[i].end;
                }
            }
        }
    }
    assignTrackRegions(line);
}

/**
 * Calculates sweep fraction across a subset of words (e.g. lead vocals or bg vocals).
 */
function sweepWordSubset(words, bounds, totalW, baseStartX, currentSec, lineRefKey, line) {
    if (!words || words.length === 0 || totalW <= 0) return 1.0;
    if (currentSec <= words[0].start) return 0.0;
    if (currentSec >= words[words.length - 1].end) return 1.0;

    let i = line[lineRefKey] || 0;
    if (i >= words.length || currentSec < words[i].start) i = 0;
    while (i < words.length && currentSec >= words[i].end) i++;
    line[lineRefKey] = i;
    if (i >= words.length) return 1.0;

    let w = words[i];
    let b = bounds[i];
    let relStartX = Math.max(0, b.startX - baseStartX);
    let relEndX = Math.max(relStartX, b.endX - baseStartX);
    if (currentSec <= w.start) {
        let pauseX = b.startX;
        if (i > 0 && (w.start - words[i - 1].end) > 0.08 && bounds[i - 1].visEndX !== undefined && bounds[i - 1].visEndX < pauseX) {
            let prevEnd = bounds[i - 1].visEndX;
            pauseX = prevEnd + Math.min(0.8, (pauseX - prevEnd) * 0.25);
        }
        return Math.max(0.0, Math.min(1.0, (pauseX - baseStartX) / totalW));
    }

    let dur = Math.max(0.001, w.end - w.start);
    let rawT = Math.max(0.0, Math.min(1.0, (currentSec - w.start) / dur));
    let chainedPrev = i > 0 && (w.start - words[i - 1].end) <= 0.08;
    let chainedNext = (i + 1 < words.length) && (words[i + 1].start - w.end) <= 0.08;
    let e = vocalEase(rawT, dur, chainedPrev, chainedNext);

    let wordSpan = relEndX - relStartX;
    if (wordSpan <= 0) return Math.max(0.0, Math.min(1.0, relStartX / totalW));

    let smoothX = relStartX + e * wordSpan;
    let smoothBlend = Math.min(1.0, Math.max(0.35, (dur - 0.15) / 0.50));

    let pixelX;
    if (smoothBlend >= 1.0 || !b.cx || b.cx.length <= 1) {
        pixelX = smoothX;
    } else {
        let ct = b.ct;
        let cx = b.cx;
        let k = 0;
        while (k < ct.length - 1 && e >= ct[k]) k++;
        let t0 = k === 0 ? 0 : ct[k - 1];
        let span = ct[k] - t0;
        let local = span > 0 ? (e - t0) / span : 1.0;
        let sLocal = local * local * (3.0 - 2.0 * local);
        let cLocal = 0.6 * local + 0.4 * sLocal;
        let x0 = Math.max(0, (k === 0 ? b.startX : cx[k - 1]) - baseStartX);
        let x1 = Math.max(x0, cx[k] - baseStartX);
        let charX = x0 + cLocal * (x1 - x0);

        pixelX = charX + smoothBlend * (smoothX - charX);
    }

    return Math.max(0.0, Math.min(1.0, pixelX / totalW));
}

/**
 * Calculates the progress of a line as a fraction in [0.0, 1.0].
 */
function getLineSweepFraction(line, currentSec, measureFn) {
    if (!line) return 0.0;
    let totalW = line._totalWidth || 0;
    if (totalW <= 0) return 0.0;
    let words = line.words;
    if (!words || words.length === 0) return 1.0;
    let bounds = line._wordBounds || computeBounds(line, measureFn);
    return sweepWordSubset(words, bounds, totalW, 0, currentSec, "_wi", line);
}

/**
 * Returns track metadata ({ words, bounds, startX, endX, width }) for a line.
 */
function lineTrackData(line, track) {
    if (!line) return null;
    return track === 1 ? (line._trackData1 || null) : (line._trackData0 || null);
}

/**
 * Returns progress within one track's region (0 = untouched, 1 = fully swept).
 */
function getLineTrackProgress(line, track, currentSec, measureFn) {
    let d = lineTrackData(line, track);
    if (!d) return 0.0;
    if (d.width <= 0) return 1.0;
    let key = track === 1 ? "_wiBg" : "_wiLead";
    return sweepWordSubset(d.words, d.bounds, d.width, d.startX, currentSec, key, line);
}

/**
 * Absolute X position of a line inside its (possibly multi-line) display group.
 */
function getGroupLineStartX(g, lineIdx, lines, getGroupBoundsFn) {
    if (!g) return 0.0;
    if (lineIdx < g.startIdx || lineIdx > g.endIdx) return 0.0;
    let b = getGroupBoundsFn(g, lines);
    if (!b || b.length <= 0) return 0.0;
    let off = lineIdx - g.startIdx;
    if (off < 0 || off >= b.length) return 0.0;
    return b[off].startX || 0.0;
}

/**
 * Computes the total swept fraction across a group of lyrics (single or multi-line).
 */
function calculateGroupSweep(currGroup, currIdx, currentSec, lines, bulletW, measureFn) {
    if (!currGroup || !lines || lines.length === 0) return 0.0;

    if (currGroup.startIdx === currGroup.endIdx) {
        let lObj = lines[currGroup.startIdx];
        if (!lObj || !lObj.isWordSynced) return 1.0;
        return getLineSweepFraction(lObj, currentSec, measureFn);
    }

    let bulletPixelW = bulletW > 0 ? bulletW : measureFn(" • ");
    let totalGroupW = 0;
    let sweptPixels = 0;

    for (let m = currGroup.startIdx; m <= currGroup.endIdx; m++) {
        let lObj = lines[m];
        let lineW = lObj._totalWidth || 0;

        if (m > currGroup.startIdx) {
            totalGroupW += bulletPixelW;
            if (m <= currIdx) {
                sweptPixels += bulletPixelW;
            }
        }

        totalGroupW += lineW;

        if (m < currIdx) {
            sweptPixels += lineW;
        } else if (m === currIdx) {
            if (lObj.isWordSynced) {
                sweptPixels += getLineSweepFraction(lObj, currentSec, measureFn) * lineW;
            } else {
                sweptPixels += lineW;
            }
        }
    }

    if (totalGroupW <= 0) return 0.0;
    return Math.max(0.0, Math.min(1.0, sweptPixels / totalGroupW));
}


/**
 * Computes geometric bounds, progress, and reveal extents for lead and background vocal tracks.
 */
function computeTrackGeometry(curLine, currIdx, curGroup, lines, wordSyncPos, getGroupBoundsFn) {
    let base = getGroupLineStartX(curGroup, currIdx, lines, getGroupBoundsFn);
    let pastWidth = base;
    let leadProgress = 0.0, bgProgress = 0.0;
    let leadStart = 0.0, leadWidth = 0.0;
    let bgStart = 0.0, bgWidth = 0.0;
    let hasBg = false;

    if (!curLine.isWordSynced) {
        leadStart = base;
        leadWidth = curLine._totalWidth || 0;
        leadProgress = 1.0;
    } else {
        let d0 = lineTrackData(curLine, 0);
        if (d0) {
            leadStart = base + d0.startX;
            leadWidth = d0.width;
            leadProgress = d0.width > 0
                ? sweepWordSubset(d0.words, d0.bounds, d0.width, d0.startX, wordSyncPos, "_wiLead", curLine)
                : 1.0;
        } else {
            leadProgress = 1.0;
        }
        let d1 = lineTrackData(curLine, 1);
        if (d1) {
            hasBg = true;
            bgStart = base + d1.startX;
            bgWidth = d1.width;
            bgProgress = d1.width > 0
                ? sweepWordSubset(d1.words, d1.bounds, d1.width, d1.startX, wordSyncPos, "_wiBg", curLine)
                : 1.0;
        }
    }

    let leadEdge = (leadWidth > 0 && leadProgress > 0) ? (leadStart + leadWidth * leadProgress) : 0.0;
    let bgEdge = (hasBg && bgWidth > 0 && bgProgress > 0) ? (bgStart + bgWidth * bgProgress) : 0.0;
    let sweepX = Math.max(pastWidth, Math.max(leadEdge, bgEdge));

    return {
        pastWidth: pastWidth,
        leadStart: leadStart,
        leadWidth: leadWidth,
        leadProgress: leadProgress,
        bgStart: bgStart,
        bgWidth: bgWidth,
        bgProgress: bgProgress,
        hasBg: hasBg,
        sweepX: sweepX
    };
}
