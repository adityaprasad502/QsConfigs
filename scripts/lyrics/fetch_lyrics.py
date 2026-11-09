#!/usr/bin/env python3
"""Lyrics lookup that streams its results as JSON lines on stdout.

usage: fetch_lyrics.py <title> <artist> <duration_seconds> <cache_dir>

Events (one JSON object per line):
  {"k": "lrc",  "synced": "<LRC text or ''>", "plain": "<plain text or ''>"}   line-synced / plain
  {"k": "word", "text": "<enhanced lyrics with per-word timing>"}              word-synced
  {"k": "none"}                                                                 definitively nothing found
  {"k": "fail"}                                                                 inconclusive (network trouble)

Line-synced and word-synced providers run in parallel; the first line-synced answer is emitted immediately and
a word-synced result (if any) follows. Results are cached on disk so repeat plays never hit the network.
"""
import difflib
import gzip
import hashlib
import http.client
import json
import os
import queue
import random
import re
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import syllables as sy

TOTAL_BUDGET = 18.0         # hard cap for any request
PROVIDER_BUDGET = 15.0      # timeout for individual providers (word or line)

TTL_WORD = 30 * 86400        # word-synced lyrics cached 30 days (refreshed on replay)
TTL_LRC = 7 * 86400          # non-karaoke line-synced lyrics expire after 7 days
TTL_RETRY_WORD = 48 * 3600   # retry word providers after 48 hours if only line-synced found
TTL_NONE = 90 * 60           # no lyrics found: re-query after 90 minutes
CACHE_MAX_BYTES = 7 * 1024 * 1024            # 7 MiB hard limit
CACHE_TARGET_BYTES = 6 * 1024 * 1024          # prune down to 6 MiB
CACHE_VERSION = 2                             # bump when normalized output changes

_LRC_HOST = sy._d("6c72636c69622e6e6574")
# Client identification (decoded at runtime like the other endpoints)
_LRC_HEADERS = {
    "User-Agent": sy._d("446576584f2d4c79726963732f312e30202868747470733a2f2f6769746875622e636f6d2f70753934782f646f74732d687970726c616e6429"),
    sy._d("4c72636c69622d436c69656e74"): sy._d("446576584f2d4c79726963732f312e30202868747470733a2f2f6769746875622e636f6d2f70753934782f646f74732d687970726c616e6429"),
    sy._d("582d557365722d4167656e74"): sy._d("446576584f2d4c79726963732f312e30202868747470733a2f2f6769746875622e636f6d2f70753934782f646f74732d687970726c616e6429"),
    "Accept-Encoding": "gzip",
}


def _log(msg):
    sys.stderr.write(f"{msg}\n")
    sys.stderr.flush()


# ------------------------------------------------------------------------------------------------
# Disk cache & LRU management
# ------------------------------------------------------------------------------------------------
def _cache_path(cache_dir, key):
    return os.path.join(cache_dir, hashlib.sha1(key.encode("utf-8")).hexdigest()[:24] + ".json")

def _file_sz(p):
    try:
        if not p or not os.path.isfile(p):
            return ""
        sz = os.path.getsize(p)
        return f"{sz / 1024:.1f} KB" if sz >= 1024 else f"{sz} B"
    except Exception:
        return ""

def _format_time_interval(secs):
    secs = int(round(secs))
    if secs <= 0:
        return "0m"
    h = secs // 3600
    m = (secs % 3600) // 60
    parts = []
    if h > 0:
        parts.append(f"{h}h")
    if m > 0 or not parts:
        parts.append(f"{m}m")
    return " ".join(parts)

def _touch(path):
    if not path:
        return
    try:
        os.utime(path, None)
    except OSError:
        pass

def cache_load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            entry = json.load(f)
        return entry if isinstance(entry, dict) and entry.get("v") == CACHE_VERSION else None
    except Exception:
        return None

def cache_save(path, entry):
    try:
        d = os.path.dirname(path)
        os.makedirs(d, exist_ok=True)
        entry["v"] = CACHE_VERSION
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(entry, f, ensure_ascii=False)
        os.replace(tmp, path)
        _cache_prune(d)
    except Exception:
        pass

def _cache_prune(d):
    try:
        entries = []
        total_size = 0
        now = time.time()
        for e in os.scandir(d):
            if not e.name.endswith(".json"):
                continue
            try:
                st = e.stat()
                entries.append({
                    "path": e.path,
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                })
                total_size += st.st_size
            except OSError:
                pass

        if total_size <= CACHE_MAX_BYTES:
            return

        for item in entries:
            try:
                with open(item["path"], "r", encoding="utf-8") as f:
                    data = json.load(f)
                ts = data.get("ts", item["mtime"])
                is_word = bool(data.get("word"))
                is_none = bool(data.get("none"))
                ttl = TTL_WORD if is_word else (TTL_NONE if is_none else TTL_LRC)

                # Tier 0: Expired TTL or negative results -> evict first
                if is_none or (now - ts >= ttl):
                    tier = 0
                    effective_age = now - ts
                else:
                    tier = 1
                    # LRU age in hours based on last play/access (mtime)
                    age_hours = max(0.0, (now - item["mtime"]) / 3600.0)
                    # Karaoke has 3x longevity shield over line-synced,
                    # but old dead recommended songs from weeks ago age out before active songs!
                    effective_age = (age_hours / 3.0) if is_word else age_hours
            except Exception:
                tier = 0
                effective_age = float("inf")

            item["tier"] = tier
            item["effective_age"] = effective_age

        # Evict: Tier 0 first (expired/none), then Tier 1 sorted by effective_age descending (oldest unlistened first)
        entries.sort(key=lambda x: (x["tier"], -x["effective_age"]))

        # Delete entries until total size falls under target
        evicted_count = 0
        evicted_bytes = 0
        for item in entries:
            if total_size <= CACHE_TARGET_BYTES:
                break
            try:
                os.remove(item["path"])
                total_size -= item["size"]
                evicted_bytes += item["size"]
                evicted_count += 1
            except OSError:
                pass

        if evicted_count > 0:
            freed_str = f"{evicted_bytes / 1024:.0f} KB"
            curr_str = f"{total_size / 1024:.0f} KB"
            _log(f"[PRUNE] Cache: Evicted {evicted_count} tracks (-{freed_str}, down to {curr_str})")
    except Exception:
        pass


# ------------------------------------------------------------------------------------------------
# Line-synced provider
# ------------------------------------------------------------------------------------------------
def _lrc_json(path):
    """-> (status, parsed_json_or_None); status 0 means transport failure."""
    for attempt in range(3):
        remaining = sy._deadline - time.monotonic() if sy._deadline else 8.0
        if remaining < 0.4:
            return 0, None
        conn = http.client.HTTPSConnection(_LRC_HOST, timeout=min(6.0, remaining))
        try:
            conn.request("GET", path, headers=_LRC_HEADERS)
            resp = conn.getresponse()
            status = resp.status
            headers_dict = {k.lower(): v for k, v in resp.getheaders()}
            body = resp.read()
            conn.close()

            if status == 404:
                return 404, None
            if status in (429, 503) and attempt < 2 and remaining > 1.8:
                retry_after = headers_dict.get("retry-after")
                base_wait = float(retry_after) if retry_after and retry_after.isdigit() else 1.5
                wait = max(1.5, base_wait) + (attempt * 0.8) + random.uniform(0.2, 0.5)
                if remaining > wait + 0.3:
                    time.sleep(wait)
                    continue
            if headers_dict.get("content-encoding") == "gzip":
                body = gzip.decompress(body)
            if status != 200:
                return status, None
            content_type = headers_dict.get("content-type", "")
            # Protect against non-JSON edge/firewall responses
            if content_type and "application/json" not in content_type and not body.strip().startswith((b"{", b"[")):
                return 0, None
            try:
                return 200, json.loads(body)
            except (json.JSONDecodeError, UnicodeDecodeError):
                return 0, None
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            if attempt < 2 and remaining > 1.5:
                time.sleep(0.8)
                continue
            return 0, None
    return 0, None


# ------------------------------------------------------------------------------------------------
# Explicit / Uncensored Lyrics Restoration (Anchor & Patch using LRCLIB text)
# ------------------------------------------------------------------------------------------------
def _parse_lrc_lines(lrc_dict_or_text):
    text = ""
    if isinstance(lrc_dict_or_text, dict):
        text = lrc_dict_or_text.get("synced") or lrc_dict_or_text.get("syncedLyrics") or ""
    elif isinstance(lrc_dict_or_text, str):
        text = lrc_dict_or_text
    lines = []
    for l in text.splitlines():
        m = re.match(r"^\s*\[(\d+):(\d+(?:\.\d+)?)\](.*)", l)
        if m:
            t = int(m.group(1)) * 60.0 + float(m.group(2))
            clean_txt = re.sub(r"\s*[\(\[（【][^\)\]）】]*[\)\]）】]", " ", m.group(3)).strip()
            if clean_txt:
                lines.append((t, clean_txt))
    return lines

def _clean_token(w):
    return re.sub(r"[^\w*]", "", w.lower())

def _compute_lrc_offset(word_text, lrc_lines):
    if not word_text or not lrc_lines:
        return 0.0
    w_lines = []
    for line in word_text.splitlines():
        m = re.match(r"^\s*\[(\d+)(?:,\s*(\d+))?\](.*)", line)
        if m:
            v = float(m.group(1))
            t = v / 1000.0 if v > 1000 else v
            txt = re.sub(r"<[^>]+>", "", m.group(3)).strip()
            if txt and "*" not in txt:
                tokens = [_clean_token(w) for w in txt.split() if _clean_token(w)]
                if len(tokens) >= 3:
                    w_lines.append((t, tokens))
        else:
            m2 = re.match(r"^\s*\[(\d+):(\d+(?:\.\d+)?)\](.*)", line)
            if m2:
                t = int(m2.group(1)) * 60.0 + float(m2.group(2))
                txt = re.sub(r"<[^>]+>", "", m2.group(3)).strip()
                if txt and "*" not in txt:
                    tokens = [_clean_token(w) for w in txt.split() if _clean_token(w)]
                    if len(tokens) >= 3:
                        w_lines.append((t, tokens))
    if not w_lines:
        return 0.0

    l_tokens = [(t, [_clean_token(w) for w in txt.split() if _clean_token(w)]) for t, txt in lrc_lines]
    deltas = []
    for t_w, w_words in w_lines[:25]:
        for t_l, l_words in l_tokens:
            if abs(len(w_words) - len(l_words)) <= 2:
                sm = difflib.SequenceMatcher(None, w_words, l_words)
                if sm.ratio() > 0.8:
                    deltas.append(t_l - t_w)
                    break
    if len(deltas) >= 3:
        deltas.sort()
        mid = len(deltas) // 2
        median_delta = deltas[mid] if len(deltas) % 2 != 0 else (deltas[mid - 1] + deltas[mid]) / 2.0
        if abs(median_delta) >= 1.0:
            return median_delta
    return 0.0

PUNCT_BEFORE = r"[\s>\"'“‘(（\[]"
PUNCT_AFTER = r"[\s<,\.!\?，。\"'“”()（）\]]|$"

def _align_and_replace(res_line, w_words, cand_text):
    l_words = re.findall(r"[\w]+(?:'[\w]+)*", cand_text)
    if not l_words:
        return res_line, 0
    sm = difflib.SequenceMatcher(None, [_clean_token(w) for w in w_words], [_clean_token(w) for w in l_words])
    replacements = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "replace" and (i2 - i1) == (j2 - j1):
            for w_w, l_w in zip(w_words[i1:i2], l_words[j1:j2]):
                if "*" in w_w and "*" not in l_w:
                    pat = "^" + re.escape(_clean_token(w_w)).replace(r"\*", r"\w*") + "$"
                    if re.match(pat, _clean_token(l_w), re.I) or (set(_clean_token(w_w)) == {"*"} and len(_clean_token(l_w)) >= 2):
                        replacements.append((w_w, l_w))
    if not replacements:
        return res_line, 0

    res = res_line
    words_count = 0
    for w_orig, l_clean in replacements:
        escaped_w = re.escape(w_orig)
        direct_pat = r"(?<=" + PUNCT_BEFORE + r")" + escaped_w + r"(?=" + PUNCT_AFTER + r")"
        if re.search(direct_pat, res):
            res = re.sub(direct_pat, l_clean, res, count=1)
            words_count += 1
            continue

        tag_pat = "".join(re.escape(ch) if i == 0 else r"(?:<[^>]+>)?" + re.escape(ch) for i, ch in enumerate(w_orig))
        m_tag = re.search(r"(<[^>]+>[^\w*]*)" + tag_pat + r"(?=" + PUNCT_AFTER + r")", res)
        if m_tag:
            first_tag = m_tag.group(1)
            matched_span = m_tag.group(0)[len(first_tag):]
            inner_tags = re.findall(r"<[^>]+>", matched_span)
            all_tags = [first_tag] + inner_tags
            if len(l_clean) == len(all_tags):
                new_chunk = "".join(tag + ch for tag, ch in zip(all_tags, l_clean))
            else:
                new_chunk = all_tags[0] + l_clean + "".join(all_tags[1:])
            res = res[:m_tag.start()] + new_chunk + res[m_tag.end():]
            words_count += 1
    return res, words_count

def _restore_explicit_line(w_line, lrc_lines):
    if "*" not in w_line or not lrc_lines:
        return w_line, 0

    m = re.match(r"^\s*\[(\d+)(?:,\s*(\d+))?\]", w_line)
    if m:
        v = float(m.group(1))
        t_w = v / 1000.0 if v > 1000 else v
    else:
        m2 = re.match(r"^\s*\[(\d+):(\d+(?:\.\d+)?)\]", w_line)
        if not m2:
            return w_line, 0
        t_w = int(m2.group(1)) * 60.0 + float(m2.group(2))

    clean_w_line = re.sub(r"(\*+)\s*<[^>]+>\s*", r"\1 ", w_line)
    clean_w_line = re.sub(r"\s*<[^>]+>\s*(\*+)", r" \1", clean_w_line)
    clean_w_line = re.sub(r"<[^>]+>", "", clean_w_line)
    clean_w_line = re.sub(r"^\s*\[[^\]]+\]", "", clean_w_line).strip()
    w_words = re.findall(r"[\w*]+(?:'[\w*]+)*", clean_w_line)
    if not w_words:
        return w_line, 0

    w_clean_tokens = [_clean_token(w) for w in w_words if "*" not in w]

    # Gather nearby candidates within +/- 4.0s (single lines and adjacent concatenated pairs for merged lines)
    candidates = []
    for idx, (t_l, l_txt) in enumerate(lrc_lines):
        diff = abs(t_l - t_w)
        if diff <= 4.0:
            candidates.append((diff, l_txt))
            if idx + 1 < len(lrc_lines) and abs(lrc_lines[idx + 1][0] - t_w) <= 5.0:
                candidates.append((diff + 0.15, l_txt + " " + lrc_lines[idx + 1][1]))
            if idx > 0 and abs(lrc_lines[idx - 1][0] - t_w) <= 5.0:
                candidates.append((diff + 0.15, lrc_lines[idx - 1][1] + " " + l_txt))

    if not candidates:
        return w_line, 0

    def score_cand(item):
        diff, txt = item
        c_tokens = set(_clean_token(w) for w in re.findall(r"[\w]+(?:'[\w]+)*", txt))
        overlap = sum(1 for w in w_clean_tokens if w in c_tokens)
        return (-overlap, diff)

    candidates.sort(key=score_cand)
    cand_lrc = candidates[0][1]
    return _align_and_replace(w_line, w_words, cand_lrc)

def _restore_from_plain_lines(w_line, plain_lines):
    if "*" not in w_line or not plain_lines:
        return w_line, 0
    clean_w_line = re.sub(r"(\*+)\s*<[^>]+>\s*", r"\1 ", w_line)
    clean_w_line = re.sub(r"\s*<[^>]+>\s*(\*+)", r" \1", clean_w_line)
    clean_w_line = re.sub(r"<[^>]+>", "", clean_w_line)
    clean_w_line = re.sub(r"^\s*\[[^\]]+\]", "", clean_w_line).strip()
    segments = [s.strip() for s in re.split(r"\s*•\s*", clean_w_line) if "*" in s]
    res = w_line
    total_cnt = 0
    for seg in segments:
        w_words = re.findall(r"[\w*]+(?:'[\w*]+)*", seg)
        w_clean_tokens = [_clean_token(w) for w in w_words if "*" not in w]
        if not w_clean_tokens:
            continue
        def score_p(p_line):
            p_words = re.findall(r"[\w]+(?:'[\w]+)*", p_line)
            p_tokens = set(_clean_token(w) for w in p_words)
            overlap = sum(1 for w in w_clean_tokens if w in p_tokens)
            diff = abs(len(w_words) - len(p_words))
            return (-overlap, diff)
        candidates = sorted(plain_lines, key=score_p)
        best_cand = candidates[0]
        best_p_tokens = set(_clean_token(w) for w in re.findall(r"[\w]+(?:'[\w]+)*", best_cand))
        overlap = sum(1 for w in w_clean_tokens if w in best_p_tokens)
        if overlap >= max(1, len(w_clean_tokens) * 0.4):
            res, cnt = _align_and_replace(res, w_words, best_cand)
            total_cnt += cnt
    return res, total_cnt

COMMON_MASKS = [
    (re.compile(pat, re.I), sy._d(h)) for pat, h in [
        (r'\b(mother)?f\*+k?(in\'|ing|ed|er|s)?\b', '6675636b'),
        (r'\b(mother)\*+(ing|er)?\b', '6675636b'),
        (r'\b(?:sh\*+t|s\*+t)(s)?\b', '73686974'),
        (r'\bb\*+c?h(es)?\b', '6269746368'),
        (r'\b(?:ni\*+a|n\*+a)(s)?\b', '6e69676761'),
        (r'\bd\*+k(s)?\b', '6469636b'),
        (r'\bp\*+y\b', '7075737379'),
        (r'\ba\*+s\b|((?:^|[\s>\"\'“‘(（\[]))a\*{2}(?=[\s<,\.!\?，。\"\'“”()（）\]]|$)', '617373'),
        (r'\bs\*x\b', '736578'),
        (r'\bh\*e(\'s|s)?\b', '686f65'),
        (r'\bc\*+t(s)?\b', '63756e74'),
        (r'\bc\*+k(s)?\b', '636f636b'),
        (r'\bsl\*+t(s)?\b', '736c7574'),
        (r'\b(god)?d\*+m?n(ed)?\b', '64616d6e'),
        (r'\bb\*{4,6}d(s)?\b', '62617374617264'),
        (r'\bw\*+d\b', '77656564'),
        (r'\bd\*+e\b', '646f7065'),
        (r'\bc\*{4,6}e\b', '636f6465696e65'),
        (r'((?:what|who) the\s*(?:<[^>]+>\s*)?)\*{3,4}(?=[\s\?<\.,\"\'“”()（）\]]|$)', '6675636b'),
        (r'((?:^|[\s>\"\'“‘(（\[]))\*{3,4}( a )', '6675636b'),
        (r'((?:^|[\s>\"\'“‘(（\[]))\*{4}(ed|ing|in\')\b', '6675636b'),
        (r'((?:some\s*(?:<[^>]+>\s*)?more,?\s*(?:<[^>]+>\s*)?))\*{3,5}(?=[\s<,\.!\?，。\"\'“”()（）\]]|$)', '6e69676761'),
        (r'((?:type\s*(?:<[^>]+>\s*)?of\s*(?:<[^>]+>\s*)?))\*{3,5}(?=[\s<,\.!\?，。\"\'“”()（）\]]|$)', '6e69676761'),
    ]
]

def _unmask_common_patterns(line):
    words_count = 0
    for pat, word in COMMON_MASKS:
        def repl(m, w=word):
            nonlocal words_count
            words_count += 1
            g = [x for x in m.groups() if x is not None]
            if not g:
                return w
            if len(g) == 1:
                return (g[0] + w) if (g[0].lower() in ('mother', 'what the ', 'who the ', 'god') or g[0].endswith(' ') or g[0].endswith('>')) else (w + g[0])
            return g[0] + w + g[1]
        line = pat.sub(repl, line)
    return line, words_count

def restore_explicit_lyrics(word_text, lrc_source):
    if not word_text or "*" not in word_text:
        return word_text, 0, 0
    lrc_lines = _parse_lrc_lines(lrc_source) if lrc_source else []
    plain_lines = []
    if isinstance(lrc_source, dict):
        p_txt = lrc_source.get("plain") or lrc_source.get("plainLyrics") or ""
        plain_lines = [l.strip() for l in p_txt.splitlines() if l.strip() and "*" not in l]
    if lrc_lines:
        offset = _compute_lrc_offset(word_text, lrc_lines)
        if offset != 0.0:
            lrc_lines = [(t - offset, txt) for t, txt in lrc_lines]
    out = []
    total_words = 0
    total_lines = 0
    for line in word_text.splitlines():
        if "*" in line:
            new_line = line
            w_cnt = 0
            if lrc_lines:
                new_line, cnt = _restore_explicit_line(new_line, lrc_lines)
                w_cnt += cnt
            if "*" in new_line and plain_lines:
                new_line, cnt = _restore_from_plain_lines(new_line, plain_lines)
                w_cnt += cnt
            if "*" in new_line:
                new_line, cnt = _unmask_common_patterns(new_line)
                w_cnt += cnt
            if w_cnt > 0:
                total_words += w_cnt
                total_lines += 1
            out.append(new_line)
        else:
            out.append(line)
    return "\n".join(out), total_words, total_lines

def pick_lrc(results, title, artist, duration, album=""):
    if not isinstance(results, list):
        return None
    title_vars = sy.norm_variants(title)
    if not title_vars:
        return None
    artist_vars = sy.norm_variants(artist)
    part_vars = [v for v in (sy.norm_variants(a) for a in sy._ARTIST_SPLIT.split(artist or "")) if v]
    title_lower = title.lower()

    best, best_score = None, -9999
    for r in results:
        if not isinstance(r, dict):
            continue
        has_lyrics = bool(r.get("syncedLyrics") or r.get("plainLyrics"))
        is_inst = bool(r.get("instrumental"))
        if not has_lyrics and not is_inst:
            continue
        rel = sy._relation(title_vars, sy.norm_variants(r.get("trackName")), 3)
        if rel == 0:
            continue
        score = 80 if rel == 2 else 35

        # Penalize version mismatches (e.g. live, remix, acoustic, cover when not requested)
        cand_name_lower = (r.get("trackName") or "").lower()
        for tag in ("live", "remix", "acoustic", "instrumental", "karaoke", "cover"):
            if tag in cand_name_lower and tag not in title_lower:
                score -= 45

        if artist_vars:
            cand = sy.norm_variants(r.get("artistName"))
            a_rel = max([sy._relation(artist_vars, cand, 2)] + [sy._relation(p, cand, 2) for p in part_vars])
            score += {2: 70, 1: 35, 0: -60}[a_rel]

        d = r.get("duration")
        if duration > 0 and isinstance(d, (int, float)) and d > 0:
            diff = abs(d - duration)
            if diff <= 1.5:
                score += 50
            elif diff <= 3.5:
                score += 35
            elif diff <= 6.0:
                score += 18
            elif diff <= 10.0:
                score += 5
            elif diff > 15.0:
                score -= 40 + min(60, int((diff - 15) * 3))

        if r.get("syncedLyrics"):
            score += 20
        if album and r.get("albumName"):
            cand_alb = r.get("albumName", "").lower()
            if album.lower() in cand_alb or cand_alb in album.lower():
                score += 15
        if score > best_score:
            best, best_score = r, score

    min_thresh = 45 if artist_vars else 30
    return best if best is not None and best_score >= min_thresh else None

def lrc_lookup(title, artist, duration, album=""):
    """-> (result_dict_or_None, definitive, reason). Paces requests to prevent 503 ServerOverloaded."""
    primary = sy._ARTIST_SPLIT.split(artist or "")[0].strip()

    # 1. If primary artist is available, try direct exact lookup first
    if primary:
        params = {"track_name": title, "artist_name": primary}
        # LRCLIB strictly enforces 1 <= duration <= 3600 (returns 400 ValidationError otherwise)
        dur_int = int(round(duration)) if duration > 0 else 0
        if 1 <= dur_int <= 3600:
            params["duration"] = dur_int
        if album:
            params["album_name"] = album
        get_path = "/api/get?" + urllib.parse.urlencode(params)
        status, data = _lrc_json(get_path)
        if status == 200 and isinstance(data, dict):
            if data.get("syncedLyrics") or data.get("plainLyrics"):
                return data, True, ""
            if data.get("instrumental") is True:
                return {"instrumental": True}, True, ""
        # Generous pacing delay between sequential requests to avoid tripping LRCLIB rate limits
        time.sleep(1.5)

    # 2. Fallback to structured search query
    search_params = {"track_name": title}
    if primary:
        search_params["artist_name"] = primary
    search_path = "/api/search?" + urllib.parse.urlencode(search_params)
    status, results = _lrc_json(search_path)
    if status == 200 and isinstance(results, list):
        return pick_lrc(results, title, artist, duration, album), True, ""
    if status in (429, 503):
        return None, False, f"Server busy ({status})"
    if status != 200:
        return None, False, "Connection failure" if status == 0 else f"HTTP {status}"
    return None, True, ""


# ------------------------------------------------------------------------------------------------
# Orchestration
# ------------------------------------------------------------------------------------------------
def run(title, artist, duration, cache_dir, emit, album="", spotify_id=""):
    start = time.monotonic()
    sy.set_deadline(start + TOTAL_BUDGET)
    now = time.time()
    key = f"{title}___{artist}".lower()
    path = _cache_path(cache_dir, key) if cache_dir else None
    entry = (cache_load(path) if path else None) or {}
    cached_offset = int(entry.get("offset_ms", 0))

    need_lrc = True
    lrc = None
    is_instrumental = False

    ts = entry.get("ts", 0)
    if entry.get("word") and now - ts < TTL_WORD:
        _touch(path)
        age_str = f"{_format_time_interval(now - ts)} ago"
        sz_str = f", {_file_sz(path)}" if _file_sz(path) else ""
        cached_src = entry.get("src") or "src4"
        _log(f"[HIT] Karaoke ({cached_src}, {age_str}{sz_str}): \"{title}\" - \"{artist}\"")
        emit({"k": "word", "text": sy.normalize_all_caps(entry["word"]), "offset_ms": cached_offset, "src": cached_src})
        return
    if entry.get("instrumental") and now - ts < TTL_WORD:
        _touch(path)
        age_str = f"{_format_time_interval(now - ts)} ago"
        sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
        _log(f"[HIT] Instrumental ({age_str}{sz_str}): \"{title}\" - \"{artist}\"")
        emit({"k": "none"})
        return
    if entry.get("none"):
        if now - entry["none"] < TTL_NONE:
            sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
            _log(f"[HIT] Negative cache{sz_str}: \"{title}\" - \"{artist}\"")
            emit({"k": "none"})
            return
        else:
            if path and os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass
            entry = {}
    if entry.get("lrc") and now - ts < TTL_LRC:
        _touch(path)
        age_str = f"{_format_time_interval(now - ts)} ago"
        sz_str = f", {_file_sz(path)}" if _file_sz(path) else ""
        cached_lrc_src = entry.get("src") or "lrc"
        _log(f"[HIT] Line-synced (lrc, {age_str}{sz_str}): \"{title}\" - \"{artist}\"")
        lrc = entry["lrc"]
        emit({"k": "lrc", "synced": sy.normalize_all_caps(lrc.get("synced", "")), "plain": sy.normalize_all_caps(lrc.get("plain", "")), "offset_ms": cached_offset, "src": cached_lrc_src})
        need_lrc = False
        time_since_tried = now - entry.get("word_tried", 0)
        if time_since_tried < TTL_RETRY_WORD:
            rem = max(0, TTL_RETRY_WORD - time_since_tried)
            rem_str = _format_time_interval(rem)
            passed_str = _format_time_interval(time_since_tried)
            _log(f"[COOLDOWN] Song retry cooldown active for \"{title}\" (passed: {passed_str}, {rem_str} left)")
            return
    else:
        entry = {}

    active_sources = ["lrc"] if need_lrc else []
    active_sources += [name for name, _ in sy.PROVIDERS]
    id_note = f" [id: {spotify_id}]" if spotify_id else ""
    _log(f"[FETCH] Querying [{', '.join(active_sources)}] for \"{title}\" - \"{artist}\" ({duration}s){id_note}")

    events = queue.Queue()
    words_pending = 0

    if need_lrc:
        def lrc_worker():
            t0 = time.monotonic()
            try:
                _log("[QUERY] lrc: Searching line-synced lyrics...")
                res, definitive, reason = lrc_lookup(title, artist, duration, album)
                elapsed = time.monotonic() - t0
                if res and (res.get("syncedLyrics") or res.get("plainLyrics")):
                    mode = "synced" if res.get("syncedLyrics") else "plain"
                    _log(f"[RESULT] lrc: Found {mode} lyrics ({elapsed:.2f}s)")
                elif res and res.get("instrumental"):
                    _log(f"[RESULT] lrc: Confirmed instrumental ({elapsed:.2f}s)")
                elif reason:
                    _log(f"[RESULT] lrc: {reason} ({elapsed:.2f}s)")
                else:
                    _log(f"[RESULT] lrc: No lyrics found ({elapsed:.2f}s)")
                events.put(("lrc", res, definitive))
            except Exception as ex:
                elapsed = time.monotonic() - t0
                _log(f"[ERROR] lrc ({elapsed:.2f}s): {ex}")
                events.put(("lrc", None, False))
        threading.Thread(target=lrc_worker, daemon=True).start()

    def _lyric_quality(text, target_dur=0, provider=""):
        """Multi-factor lyric quality scoring:
        Evaluates:
          1. Word & syllable count with healthy density weighting (diminishing returns).
          2. Line structure & words-per-line distribution.
          3. Timeline coverage (first to last lyric vs target duration).
          4. Duration precision (continuous falloff penalty for drift).
          5. Monotonicity & timing integrity (no reversed line timestamps).
          6. Penalties for placeholders ('纯音乐'), snippets, or truncated texts.
          7. Provider quality tier (Studio Apple Music > Commercial Karaoke).
        """
        if not text:
            return 0

        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        if not lines:
            return 0

        # Reject instrumental / pure music placeholders
        for bad_phrase in ("纯音乐", "Instrumental", "没有填词", "暂无歌词"):
            if any(bad_phrase in ln for ln in lines[:3]):
                return -9999

        word_count = text.count("<")
        line_count = len(lines)

        # 1. Base Word Score (sweet spot: 120-600 words)
        # Using diminishing returns so bloated/spam lyrics do not beat a clean studio track
        if word_count < 15:
            return -500  # Snippet / intro teaser
        elif word_count < 50:
            base_words = word_count * 2.0
        elif word_count <= 400:
            base_words = 100.0 + (word_count - 50) * 0.8
        else:
            base_words = 380.0 + min(120.0, (word_count - 400) * 0.3)

        # 2. Line Structure & Formatting (clean stanza density)
        words_per_line = word_count / max(1, line_count)
        if 3.0 <= words_per_line <= 16.0:
            structure_bonus = 60.0
        elif words_per_line < 2.0:
            structure_bonus = -40.0
        else:
            structure_bonus = 20.0

        score = base_words + structure_bonus

        # Parse timestamps: [start_ms, dur_ms]
        first_time_sec = None
        last_time_sec = None
        is_monotonic = True
        prev_time = -1

        for ln in lines:
            m = re.match(r"^\[(\d+),\s*(\d+)\]", ln)
            if m:
                start_ms, dur_ms = int(m.group(1)), int(m.group(2))
                st_sec = start_ms / 1000.0
                end_sec = (start_ms + dur_ms) / 1000.0

                if first_time_sec is None:
                    first_time_sec = st_sec

                if st_sec < prev_time - 0.5:
                    is_monotonic = False
                prev_time = st_sec
                last_time_sec = end_sec

        # 3. Timing Monotonicity
        if not is_monotonic:
            score -= 100.0
        else:
            score += 30.0

        # 4. Target Duration Alignment & Coverage
        if target_dur > 0 and last_time_sec is not None:
            diff = abs(last_time_sec - target_dur)

            # Smooth, continuous duration match (max +180, steep falloff for >25s)
            if diff <= 1.5:
                score += 180.0
            elif diff <= 4.0:
                score += 140.0 - (diff - 1.5) * 16.0
            elif diff <= 10.0:
                score += 100.0 - (diff - 4.0) * 8.0
            elif diff <= 25.0:
                score += 52.0 - (diff - 10.0) * 4.0
            else:
                score -= min(300.0, 50.0 + (diff - 25.0) * 8.0)

            # Timeline coverage (span of vocals vs song duration)
            if first_time_sec is not None and first_time_sec < last_time_sec:
                span = last_time_sec - first_time_sec
                coverage = span / target_dur
                if coverage >= 0.70:
                    score += 100.0  # Full song coverage
                elif coverage >= 0.50:
                    score += 50.0
                elif coverage < 0.30:
                    score -= 180.0  # Heavy penalty for short snippet/intro

        # 5. Provider Quality Tier (p4 studio word-sync > p5 community TTML > p1/p2/p3 commercial karaoke)
        PROVIDER_TIERS = {
            "src4": 95,
            "src5": 75,
            "src1": 40,
            "src2": 40,
            "src3": 30,
        }
        score += PROVIDER_TIERS.get(provider, 0)

        return int(round(score))

    best_word = None  # (name, text, score)

    def word_worker(name, fn):
        t0 = time.monotonic()
        try:
            _log(f"[QUERY] {name}: Searching karaoke (word-synced)...")
            raw = fn(title, artist, duration, spotify_id=spotify_id)
            elapsed = time.monotonic() - t0
            text = sy.normalize_all_caps(sy.slim_lyrics(raw)) if raw else ""
            if text and sy.is_word_synced(text):
                wc = text.count("<")
                score = _lyric_quality(text, duration, provider=name)
                _log(f"[RESULT] {name}: Karaoke found ({wc} timed words, score: {score}, {elapsed:.2f}s)")
                events.put(("word", name, text, score))
            else:
                _log(f"[RESULT] {name}: No word-synced lyrics ({elapsed:.2f}s)")
                events.put(("word", name, None, 0))
        except Exception as ex:
            elapsed = time.monotonic() - t0
            _log(f"[ERROR] {name} ({elapsed:.2f}s): {ex}")
            events.put(("word", name, None, 0))

    pending_providers = {name for name, _ in sy.PROVIDERS}
    for name, fn in sy.PROVIDERS:
        threading.Thread(target=word_worker, args=(name, fn), daemon=True).start()
        words_pending += 1

    lrc_pending = need_lrc
    lrc_definitive = False

    def _try_restore_and_save(lrc_source, label):
        nonlocal best_word
        if not (best_word and "*" in best_word[1]):
            return
        old_name, old_text, old_score = best_word
        restored, words_cnt, lines_cnt = restore_explicit_lyrics(old_text, lrc_source)
        if words_cnt > 0:
            restored = sy.normalize_all_caps(restored)
            _log(f"[RESTORE] {old_name}: Restored {words_cnt} explicit words ({lines_cnt} lines) using {label}")
            best_word = (old_name, restored, old_score)
            emit({"k": "word", "text": restored, "offset_ms": cached_offset, "src": old_name})
            if path:
                payload = {"ts": time.time(), "title": title, "artist": artist, "word": restored, "src": old_name}
                if cached_offset:
                    payload["offset_ms"] = cached_offset
                cache_save(path, payload)

    def _log_complete():
        elapsed = time.monotonic() - start
        sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
        _log(f"[COMPLETE] Done in {elapsed:.2f}s: using {best_word[0]} karaoke (score: {best_word[2]}){sz_str}")

    while lrc_pending or words_pending:
        t = time.monotonic() - start
        wait = PROVIDER_BUDGET - t
        if wait <= 0:
            if words_pending:
                for timed_out in sorted(pending_providers):
                    _log(f"[TIMEOUT] {timed_out} ({t:.2f}s): Exceeded {PROVIDER_BUDGET:.0f}s budget")
                pending_providers.clear()
                words_pending = 0
            if lrc_pending:
                _log(f"[TIMEOUT] lrc ({t:.2f}s): Exceeded {PROVIDER_BUDGET:.0f}s budget")
                lrc_pending = False
                _try_restore_and_save(None, "fallback")
            continue
        try:
            ev = events.get(timeout=wait)
        except queue.Empty:
            continue

        if ev[0] == "lrc":
            lrc_pending = False
            _, result, lrc_definitive = ev
            if result:
                if result.get("instrumental"):
                    is_instrumental = True
                else:
                    lrc = {"synced": sy.normalize_all_caps(result.get("syncedLyrics") or ""), "plain": sy.normalize_all_caps(result.get("plainLyrics") or "")}
                    if best_word:
                        _try_restore_and_save(lrc, "lrc")
                        if path and not ("*" in best_word[1]):
                            payload = {"ts": time.time(), "title": title, "artist": artist, "word": best_word[1], "src": best_word[0]}
                            if cached_offset:
                                payload["offset_ms"] = cached_offset
                            cache_save(path, payload)
                        if words_pending == 0:
                            _log_complete()
                            return
                    else:
                        emit({"k": "lrc", "synced": lrc["synced"], "plain": lrc["plain"], "offset_ms": cached_offset, "src": "lrc"})
                        if words_pending > 0:
                            _log("[EMIT] Using lrc line-synced lyrics (awaiting karaoke...)")
                            if path:
                                payload = {"ts": time.time(), "title": title, "artist": artist, "lrc": lrc, "word_tried": 0}
                                if cached_offset:
                                    payload["offset_ms"] = cached_offset
                                cache_save(path, payload)
            else:
                _try_restore_and_save(None, "fallback")
                if words_pending == 0 and best_word is not None:
                    _log_complete()
                    return
        else:
            words_pending -= 1
            _, name, text, score = ev
            pending_providers.discard(name)
            if text:
                is_initial = best_word is None
                is_upgrade = not is_initial and score > best_word[2]

                if not (is_initial or is_upgrade):
                    _log(f"[DISCARD] {name} match ignored (score: {score} <= {best_word[0]} score: {best_word[2]})")
                    continue

                if lrc and "*" in text:
                    restored, words_cnt, lines_cnt = restore_explicit_lyrics(text, lrc)
                    if words_cnt > 0:
                        _log(f"[RESTORE] {name}: Restored {words_cnt} explicit words ({lines_cnt} lines) using lrc")
                        text = restored

                if is_initial:
                    _log(f"[EMIT] Initial karaoke source: {name} (score: {score})")
                elif is_upgrade:
                    old_name, _, old_score = best_word
                    diff = score - old_score
                    _log(f"[UPGRADE] Replaced {old_name} (score: {old_score}) -> BETTER match from {name} (score: {score}, +{diff} pts)")

                best_word = (name, text, score)
                emit({"k": "word", "text": text, "offset_ms": cached_offset, "src": name})
                if path:
                    payload = {"ts": time.time(), "title": title, "artist": artist, "word": text, "src": name}
                    if cached_offset:
                        payload["offset_ms"] = cached_offset
                    cache_save(path, payload)
            if words_pending == 0 and best_word is not None:
                if lrc_pending:
                    continue  # Wait for line-synced lyrics to un-censor asterisks
                _log_complete()
                return

    if best_word is not None:
        if lrc_pending and not ("*" in best_word[1]):
            _log("[DISCARD] lrc: Karaoke found, line search canceled")
        _log_complete()
        return

    # No word-synced result
    elapsed = time.monotonic() - start
    if is_instrumental and not lrc:
        if path:
            cache_save(path, {"ts": time.time(), "title": title, "artist": artist, "none": time.time(), "instrumental": True})
            sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
            _log(f"[NOT FOUND] Done in {elapsed:.2f}s: confirmed instrumental track{sz_str}")
        emit({"k": "none"})
        return
    if path:
        if lrc:
            payload = {"ts": entry.get("ts") or time.time(), "title": title, "artist": artist, "lrc": lrc, "word_tried": time.time()}
            if cached_offset:
                payload["offset_ms"] = cached_offset
            cache_save(path, payload)
            sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
            _log(f"[FALLBACK] Done in {elapsed:.2f}s: no karaoke found, keeping lrc line-synced lyrics{sz_str}")
        elif lrc_definitive:
            cache_save(path, {"ts": time.time(), "title": title, "artist": artist, "none": time.time()})
            sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
            _log(f"[NOT FOUND] Done in {elapsed:.2f}s: no lyrics found across any provider{sz_str}")
    if not lrc:
        if not lrc_definitive:
            if elapsed >= PROVIDER_BUDGET:
                _log(f"[TIMEOUT] Done in {elapsed:.2f}s: search budget exceeded")
            else:
                _log(f"[FAILED] Done in {elapsed:.2f}s: network or provider error")
        emit({"k": "none"} if lrc_definitive else {"k": "fail"})


def main(argv):
    if len(argv) < 2:
        return 1

    if argv[1] == "--set-offset":
        # usage: fetch_lyrics.py --set-offset <title> <artist> <offset_ms> <cache_dir>
        if len(argv) >= 6:
            title = argv[2]
            artist = argv[3]
            try:
                offset_ms = int(argv[4])
            except ValueError:
                offset_ms = 0
            cache_dir = argv[5]
            if cache_dir:
                key = f"{title}___{artist}".lower()
                path = _cache_path(cache_dir, key)
                entry = cache_load(path)
                if not entry and offset_ms == 0:
                    return 0
                if not entry:
                    entry = {"ts": time.time(), "title": title, "artist": artist}
                if offset_ms != 0:
                    entry["offset_ms"] = offset_ms
                else:
                    entry.pop("offset_ms", None)
                cache_save(path, entry)
        return 0

    title = argv[1]
    artist = argv[2] if len(argv) > 2 else ""
    try:
        duration = int(float(argv[3])) if len(argv) > 3 else 0
    except ValueError:
        duration = 0
    cache_dir = argv[4] if len(argv) > 4 else ""
    album = argv[5] if len(argv) > 5 else ""
    spotify_id = argv[6] if len(argv) > 6 else ""

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    def emit(obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    try:
        run(title, artist, duration, cache_dir, emit, album, spotify_id)
    except Exception:
        emit({"k": "fail"})
    return 0


if __name__ == "__main__":
    code = main(sys.argv)
    try:
        sys.stdout.flush()
    except Exception:
        pass
    os._exit(code)  # don't wait for straggling provider threads
