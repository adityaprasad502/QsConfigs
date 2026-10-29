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
import re
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import syllables as sy

TOTAL_BUDGET = 18.0      # hard cap for any request
WORD_BUDGET = 15.0       # how long we wait for word-synced providers
LRC_BUDGET = 12.0

TTL_WORD = 30 * 86400        # word-synced lyrics cached 30 days (refreshed on replay)
TTL_LRC = 7 * 86400          # non-karaoke line-synced lyrics expire after 7 days
TTL_RETRY_WORD = 48 * 3600   # retry word providers after 48 hours if only line-synced found
TTL_NONE = 90 * 60           # no lyrics found: re-query after 90 minutes
CACHE_MAX_BYTES = 5 * 1024 * 1024        # 5 MB hard limit
CACHE_TARGET_BYTES = int(4.4 * 1024 * 1024)  # prune down to ~4.4 MB

_LRC_HOST = sy._d("6c72636c69622e6e6574")
# Client identification (decoded at runtime like the other endpoints)
_LRC_HEADERS = {
    "User-Agent": sy._d("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229"),
    sy._d("4c72636c69622d436c69656e74"): sy._d("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229"),
    sy._d("582d557365722d4167656e74"): sy._d("4c52434c49422057656220436c69656e74202868747470733a2f2f6769746875622e636f6d2f7472616e7875616e7468616e672f6c72636c696229"),
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
            freed_str = f"{evicted_bytes / (1024 * 1024):.1f} MB" if evicted_bytes >= 1024 * 1024 else f"{evicted_bytes / 1024:.0f} KB"
            curr_str = f"{total_size / (1024 * 1024):.1f} MB" if total_size >= 1024 * 1024 else f"{total_size / 1024:.0f} KB"
            _log(f"[PRUNE] Cache: Evicted {evicted_count} tracks (-{freed_str}, down to {curr_str})")
    except Exception:
        pass


# ------------------------------------------------------------------------------------------------
# Line-synced provider
# ------------------------------------------------------------------------------------------------
def _lrc_json(path):
    """-> (status, parsed_json_or_None); status 0 means transport failure."""
    for attempt in range(2):
        remaining = sy._deadline - time.monotonic() if sy._deadline else 8.0
        if remaining < 0.3:
            return 0, None
        conn = http.client.HTTPSConnection(_LRC_HOST, timeout=min(8.0, remaining))
        try:
            conn.request("GET", path, headers=_LRC_HEADERS)
            resp = conn.getresponse()
            if resp.status == 404:
                return 404, None
            if resp.status in (429, 503) and attempt == 0 and remaining > 1.2:
                time.sleep(0.4)
                continue
            body = resp.read()
            if resp.getheader("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            if resp.status != 200:
                return resp.status, None
            return 200, json.loads(body)
        except Exception:
            if attempt == 0 and remaining > 1.2:
                time.sleep(0.3)
                continue
            return 0, None
        finally:
            try:
                conn.close()
            except Exception:
                pass
    return 0, None

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
    """-> (result_dict_or_None, definitive, reason). `get` (exact) and `search` run concurrently."""
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
            return data, True, ""

    st.join(max(0.1, (sy._deadline - time.monotonic()) if sy._deadline else 6.0))
    status, results = search_out.get("r", (0, None))
    if status in (429, 503):
        return None, False, f"Server error ({status})"
    if status != 200:
        return None, False, "Connection failure" if status == 0 else f"HTTP {status}"
    return pick_lrc(results, title, artist, duration), True, ""


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
    lrc = None

    ts = entry.get("ts", 0)
    if entry.get("word") and now - ts < TTL_WORD:
        _touch(path)
        age_str = f"{(now - ts) / 3600:.1f}h ago"
        sz_str = f", {_file_sz(path)}" if _file_sz(path) else ""
        _log(f"[HIT] Karaoke ({entry.get('src', 'cache')}, {age_str}{sz_str}): \"{title}\" - \"{artist}\"")
        emit({"k": "word", "text": entry["word"]})
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
        age_str = f"{(now - ts) / 3600:.1f}h ago"
        sz_str = f", {_file_sz(path)}" if _file_sz(path) else ""
        _log(f"[HIT] Line-synced (lrc, {age_str}{sz_str}): \"{title}\" - \"{artist}\"")
        lrc = entry["lrc"]
        emit({"k": "lrc", "synced": lrc.get("synced", ""), "plain": lrc.get("plain", "")})
        need_lrc = False
        time_since_tried = now - entry.get("word_tried", 0)
        if time_since_tried < TTL_RETRY_WORD:
            rem = max(0, TTL_RETRY_WORD - time_since_tried)
            rem_str = f"{rem / 3600:.1f}h" if rem >= 3600 else f"{int(rem / 60)}m"
            _log(f"[COOLDOWN] Song retry cooldown active for \"{title}\" ({rem_str} left)")
            return
    else:
        entry = {}

    active_sources = ["lrc"] if need_lrc else []
    active_sources += [name for name, _ in sy.PROVIDERS]
    _log(f"[FETCH] Querying [{', '.join(active_sources)}] for \"{title}\" - \"{artist}\" ({duration}s)")

    events = queue.Queue()
    words_pending = 0

    if need_lrc:
        def lrc_worker():
            t0 = time.monotonic()
            try:
                _log("[QUERY] lrc: Searching line-synced lyrics...")
                res, definitive, reason = lrc_lookup(title, artist, duration)
                elapsed = time.monotonic() - t0
                if res and (res.get("syncedLyrics") or res.get("plainLyrics")):
                    mode = "synced" if res.get("syncedLyrics") else "plain"
                    _log(f"[RESULT] lrc: Found {mode} lyrics ({elapsed:.2f}s)")
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

    def _lyric_quality(text, target_dur=0):
        if not text:
            return 0
        score = text.count("<") + len(text.splitlines()) * 2
        if target_dur > 0:
            times = re.findall(r"\[(\d+),\s*(\d+)\]", text)
            if times:
                try:
                    end_sec = (int(times[-1][0]) + int(times[-1][1])) / 1000.0
                    diff = abs(end_sec - target_dur)
                    if diff <= 8:
                        score += 60   # close duration match to track
                    elif diff <= 20:
                        score += 30
                    elif diff > 45:
                        score -= 80   # heavily penalize partial snippets / cutoffs
                except Exception:
                    pass
        return score

    best_word = None  # (name, text, score)

    def word_worker(name, fn):
        t0 = time.monotonic()
        try:
            _log(f"[QUERY] {name}: Searching karaoke (word-synced)...")
            raw = fn(title, artist, duration)
            elapsed = time.monotonic() - t0
            text = sy.slim_lyrics(raw) if raw else ""
            if text and sy.is_word_synced(text):
                wc = text.count("<")
                score = _lyric_quality(text, duration)
                _log(f"[RESULT] {name}: Karaoke found ({wc} timed words, score: {score}, {elapsed:.2f}s)")
                events.put(("word", name, text, score))
            else:
                _log(f"[RESULT] {name}: No word-synced lyrics ({elapsed:.2f}s)")
                events.put(("word", name, None, 0))
        except Exception as ex:
            elapsed = time.monotonic() - t0
            _log(f"[ERROR] {name} ({elapsed:.2f}s): {ex}")
            events.put(("word", name, None, 0))

    pending_providers = set(name for name, _ in sy.PROVIDERS)
    for name, fn in sy.PROVIDERS:
        threading.Thread(target=word_worker, args=(name, fn), daemon=True).start()
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
                for timed_out in sorted(pending_providers):
                    _log(f"[TIMEOUT] {timed_out}: Exceeded {WORD_BUDGET:.0f}s word budget")
                pending_providers.clear()
                words_pending = 0
            if lrc_pending and t >= LRC_BUDGET:
                _log(f"[TIMEOUT] lrc: Exceeded {LRC_BUDGET:.0f}s line budget")
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
                if not best_word:
                    _log("[EMIT] Using lrc line-synced lyrics (awaiting karaoke...)")
                    emit({"k": "lrc", "synced": lrc["synced"], "plain": lrc["plain"]})
                    if path:
                        cache_save(path, {"ts": time.time(), "title": title, "artist": artist, "lrc": lrc, "word_tried": 0})
        else:
            words_pending -= 1
            _, name, text, score = ev
            pending_providers.discard(name)
            if text:
                if best_word is None:
                    best_word = (name, text, score)
                    _log(f"[EMIT] Initial karaoke source: {name} (score: {score})")
                    emit({"k": "word", "text": text})
                    if path:
                        cache_save(path, {"ts": time.time(), "title": title, "artist": artist, "word": text, "src": name, "lrc": lrc})
                elif score > best_word[2]:
                    # Better karaoke match found; upgrade both display and cache
                    old_name, _, old_score = best_word
                    diff = score - old_score
                    _log(f"[UPGRADE] Replaced {old_name} (score: {old_score}) -> BETTER match from {name} (score: {score}, +{diff} pts)")
                    best_word = (name, text, score)
                    emit({"k": "word", "text": text})
                    if path:
                        cache_save(path, {"ts": time.time(), "title": title, "artist": artist, "word": text, "src": name, "lrc": lrc})
                else:
                    _log(f"[DISCARD] {name} match ignored (score: {score} <= {best_word[0]} score: {best_word[2]})")
            if words_pending == 0 and best_word is not None:
                if lrc_pending:
                    _log("[DISCARD] lrc: Karaoke found, line search canceled")
                elapsed = time.monotonic() - start
                sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
                _log(f"[COMPLETE] Done in {elapsed:.2f}s: using {best_word[0]} karaoke (score: {best_word[2]}){sz_str}")
                return

    if best_word is not None:
        if lrc_pending:
            _log("[DISCARD] lrc: Karaoke found, line search canceled")
        elapsed = time.monotonic() - start
        sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
        _log(f"[COMPLETE] Done in {elapsed:.2f}s: using {best_word[0]} karaoke (score: {best_word[2]}){sz_str}")
        return

    # No word-synced result
    elapsed = time.monotonic() - start
    if path:
        if lrc:
            cache_save(path, {"ts": entry.get("ts") or time.time(), "title": title, "artist": artist, "lrc": lrc, "word_tried": time.time()})
            sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
            _log(f"[FALLBACK] Done in {elapsed:.2f}s: no karaoke found, keeping lrc line-synced lyrics{sz_str}")
        elif lrc_definitive:
            cache_save(path, {"ts": time.time(), "title": title, "artist": artist, "none": time.time()})
            sz_str = f" ({_file_sz(path)})" if _file_sz(path) else ""
            _log(f"[NOT FOUND] Done in {elapsed:.2f}s: no lyrics found across any provider{sz_str}")
    if not lrc:
        if not lrc_definitive:
            if elapsed >= WORD_BUDGET:
                _log(f"[TIMEOUT] Done in {elapsed:.2f}s: search budget exceeded")
            else:
                _log(f"[FAILED] Done in {elapsed:.2f}s: network or provider error")
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
