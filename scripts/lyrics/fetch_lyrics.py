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
import gzip
import hashlib
import http.client
import json
import os
import queue
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import syllables as sy  # noqa: E402

TOTAL_BUDGET = 9.0       # hard cap for any request
WORD_BUDGET = 6.0        # how long we wait for word-synced providers
LRC_BUDGET = 8.0

TTL_WORD = 90 * 86400        # word-synced lyrics practically never change
TTL_LRC = 30 * 86400
TTL_RETRY_WORD = 3 * 86400   # after a line-synced only result, retry word providers this often
TTL_NONE = 30 * 60
CACHE_MAX_FILES = 400
CACHE_KEEP_FILES = 300

_LRC_HOST = sy._d("6c72636c69622e6e6574")
# Client identification (decoded at runtime like the other endpoints)
_LRC_HEADERS = {
    "User-Agent": sy._d("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229"),
    sy._d("4c72636c69622d436c69656e74"): sy._d("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229"),
    sy._d("582d557365722d4167656e74"): sy._d("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229"),
    "Accept-Encoding": "gzip",
}


# ------------------------------------------------------------------------------------------------
# Disk cache
# ------------------------------------------------------------------------------------------------
def _cache_path(cache_dir, key):
    return os.path.join(cache_dir, hashlib.sha1(key.encode("utf-8")).hexdigest()[:24] + ".json")

def cache_load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            entry = json.load(f)
        return entry if isinstance(entry, dict) and entry.get("v") == 1 else None
    except Exception:
        return None

def cache_save(path, entry):
    try:
        d = os.path.dirname(path)
        os.makedirs(d, exist_ok=True)
        entry["v"] = 1
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(entry, f, ensure_ascii=False)
        os.replace(tmp, path)
        _cache_prune(d)
    except Exception:
        pass

def _cache_prune(d):
    try:
        files = [e for e in os.scandir(d) if e.name.endswith(".json")]
        if len(files) <= CACHE_MAX_FILES:
            return
        files.sort(key=lambda e: e.stat().st_mtime)
        for e in files[:len(files) - CACHE_KEEP_FILES]:
            try:
                os.remove(e.path)
            except OSError:
                pass
    except Exception:
        pass


# ------------------------------------------------------------------------------------------------
# Line-synced provider
# ------------------------------------------------------------------------------------------------
def _lrc_json(path):
    """-> (status, parsed_json_or_None); status 0 means transport failure."""
    remaining = sy._deadline - time.monotonic() if sy._deadline else 6.0
    if remaining < 0.3:
        return 0, None
    conn = http.client.HTTPSConnection(_LRC_HOST, timeout=min(6.0, remaining))
    try:
        conn.request("GET", path, headers=_LRC_HEADERS)
        resp = conn.getresponse()
        body = resp.read()
        if resp.getheader("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        if resp.status != 200:
            return resp.status, None
        return 200, json.loads(body)
    except Exception:
        return 0, None
    finally:
        try:
            conn.close()
        except Exception:
            pass

def pick_lrc(results, title, artist, duration):
    if not isinstance(results, list):
        return None
    title_vars = sy.norm_variants(title)
    if not title_vars:
        return None
    artist_vars = sy.norm_variants(artist)
    part_vars = [v for v in (sy.norm_variants(a) for a in sy._ARTIST_SPLIT.split(artist or "")) if v]

    best, best_score = None, -9999
    for r in results:
        if not isinstance(r, dict) or not (r.get("syncedLyrics") or r.get("plainLyrics")):
            continue
        rel = sy._relation(title_vars, sy.norm_variants(r.get("trackName")), 3)
        if rel == 0:
            continue
        score = 50 if rel == 2 else 25

        if artist_vars:
            cand = sy.norm_variants(r.get("artistName"))
            a_rel = max([sy._relation(artist_vars, cand, 2)] + [sy._relation(p, cand, 2) for p in part_vars])
            score += {2: 40, 1: 20, 0: 0}[a_rel]

        d = r.get("duration")
        if duration > 0 and isinstance(d, (int, float)) and d > 0:
            diff = abs(d - duration)
            if diff <= 2:
                score += 35
            elif diff <= 5:
                score += 20
            elif diff > 15:
                score -= 30

        if r.get("syncedLyrics"):
            score += 10
        if score > best_score:
            best, best_score = r, score
    return best if best is not None and best_score >= 25 else None

def lrc_lookup(title, artist, duration):
    """-> (result_dict_or_None, definitive). `get` (exact) and `search` run concurrently."""
    primary = sy._ARTIST_SPLIT.split(artist or "")[0].strip()
    search_path = "/api/search?q=" + urllib.parse.quote(f"{title} {primary}".strip())
    search_out = {}

    def do_search():
        search_out["r"] = _lrc_json(search_path)

    st = threading.Thread(target=do_search, daemon=True)
    st.start()

    if duration > 0 and primary:
        get_path = "/api/get?" + urllib.parse.urlencode(
            {"track_name": title, "artist_name": primary, "duration": duration})
        status, data = _lrc_json(get_path)
        if status == 200 and isinstance(data, dict) and (data.get("syncedLyrics") or data.get("plainLyrics")):
            return data, True

    st.join(max(0.1, (sy._deadline - time.monotonic()) if sy._deadline else 6.0))
    status, results = search_out.get("r", (0, None))
    if status != 200:
        return None, False
    return pick_lrc(results, title, artist, duration), True


# ------------------------------------------------------------------------------------------------
# Orchestration
# ------------------------------------------------------------------------------------------------
def run(title, artist, duration, cache_dir, emit):
    start = time.monotonic()
    sy.set_deadline(start + TOTAL_BUDGET)
    now = time.time()
    key = f"{title}___{artist}".lower()
    path = _cache_path(cache_dir, key) if cache_dir else None
    entry = (cache_load(path) if path else None) or {}

    need_lrc = True
    need_word = True
    lrc = None

    ts = entry.get("ts", 0)
    if entry.get("word") and now - ts < TTL_WORD:
        emit({"k": "word", "text": entry["word"]})
        return
    if entry.get("none") and now - entry["none"] < TTL_NONE:
        emit({"k": "none"})
        return
    if entry.get("lrc") and now - ts < TTL_LRC:
        lrc = entry["lrc"]
        emit({"k": "lrc", "synced": lrc.get("synced", ""), "plain": lrc.get("plain", "")})
        need_lrc = False
        if now - entry.get("word_tried", 0) < TTL_RETRY_WORD:
            return
    else:
        entry = {}

    events = queue.Queue()
    words_pending = 0

    if need_lrc:
        def lrc_worker():
            try:
                events.put(("lrc",) + lrc_lookup(title, artist, duration))
            except Exception:
                events.put(("lrc", None, False))
        threading.Thread(target=lrc_worker, daemon=True).start()

    def word_worker(fn):
        try:
            raw = fn(title, artist, duration)
            text = sy.slim_lyrics(raw) if raw else ""
        except Exception:
            text = ""
        events.put(("word", text if sy.is_word_synced(text) else None))

    for _src, fn in sy.PROVIDERS:
        threading.Thread(target=word_worker, args=(fn,), daemon=True).start()
        words_pending += 1

    lrc_pending = need_lrc
    lrc_definitive = False

    while lrc_pending or words_pending:
        t = time.monotonic() - start
        limits = []
        if lrc_pending:
            limits.append(LRC_BUDGET - t)
        if words_pending:
            limits.append(WORD_BUDGET - t)
        wait = min(limits)
        if wait <= 0:
            if words_pending and t >= WORD_BUDGET:
                words_pending = 0
            if lrc_pending and t >= LRC_BUDGET:
                lrc_pending = False
            continue
        try:
            ev = events.get(timeout=wait)
        except queue.Empty:
            continue

        if ev[0] == "lrc":
            lrc_pending = False
            _, result, lrc_definitive = ev
            if result:
                lrc = {"synced": result.get("syncedLyrics") or "", "plain": result.get("plainLyrics") or ""}
                emit({"k": "lrc", "synced": lrc["synced"], "plain": lrc["plain"]})
                if path:
                    cache_save(path, {"ts": time.time(), "lrc": lrc, "word_tried": 0})
        else:
            words_pending -= 1
            if ev[1]:
                emit({"k": "word", "text": ev[1]})
                if path:
                    cache_save(path, {"ts": time.time(), "word": ev[1], "lrc": lrc})
                return

    # No word-synced result
    if path:
        if lrc:
            cache_save(path, {"ts": entry.get("ts") or time.time(), "lrc": lrc, "word_tried": time.time()})
        elif lrc_definitive:
            cache_save(path, {"ts": time.time(), "none": time.time()})
    if not lrc:
        emit({"k": "none"} if lrc_definitive else {"k": "fail"})


def main(argv):
    if len(argv) < 2:
        return 1
    title = argv[1]
    artist = argv[2] if len(argv) > 2 else ""
    try:
        duration = int(float(argv[3])) if len(argv) > 3 else 0
    except ValueError:
        duration = 0
    cache_dir = argv[4] if len(argv) > 4 else ""

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    def emit(obj):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    try:
        run(title, artist, duration, cache_dir, emit)
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
