#!/usr/bin/env python3
import base64
import gzip
import json
import re
import time
import urllib.parse
import urllib.request
import zlib


def _d(h):
    return bytes.fromhex(h).decode()

# Endpoints and keys (obfuscated)
_U1 = _d("687474703a2f2f6d6f62696c6563646e2e6b75676f752e636f6d2f6170692f76332f7365617263682f736f6e673f666f726d61743d6a736f6e266b6579776f72643d257326706167653d31267061676573697a653d35")
_U2 = _d("687474703a2f2f6b7263732e6b75676f752e636f6d2f7365617263683f7665723d31266d616e3d79657326636c69656e743d6d6f6269266b6579776f72643d266475726174696f6e3d26686173683d2573")
_U3 = _d("687474703a2f2f6c79726963732e6b75676f752e636f6d2f646f776e6c6f61643f7665723d3126636c69656e743d70632669643d2573266163636573736b65793d257326666d743d6b726326636861727365743d75746638")
_XK = bytes.fromhex("404761775e3274475136312dced26e69")

_U4 = _d("68747470733a2f2f75362e792e71712e636f6d2f6367692d62696e2f6d75736963752e666367")
_M_SEARCH = _d("446f536561726368466f7251514d757369634465736b746f70")
_U5 = _d("68747470733a2f2f632e792e71712e636f6d2f71716d757369632f666367692d62696e2f6c797269635f646f776e6c6f61642e6663673f6d7573696369643d25732676657273696f6e3d3135266d696e6976657273696f6e3d3832266c7263747970653d34")
_U5_MID = _d("68747470733a2f2f632e792e71712e636f6d2f71716d757369632f666367692d62696e2f6c797269635f646f776e6c6f61642e6663673f736f6e676d69643d25732676657273696f6e3d3135266d696e6976657273696f6e3d3832266c7263747970653d34")
_Q1 = bytes.fromhex("21402329284e484c6975792a24255e26")
_Q2 = bytes.fromhex("3132335a584321402329282a24255e26")
_Q3 = bytes.fromhex("21402329282a24255e26616263444546")

_U6 = _d("68747470733a2f2f6d757369632e3136332e636f6d2f6170692f636c6f75647365617263682f70633f733d257326747970653d31266f66667365743d30266c696d69743d33")
_U7 = _d("68747470733a2f2f6d757369632e3136332e636f6d2f6170692f736f6e672f6c797269633f69643d2573266c763d2d31266b763d2d312674763d2d312679763d31")
_NE_REF = _d("68747470733a2f2f6d757369632e3136332e636f6d2f")
_P2_REF = _d("68747470733a2f2f792e71712e636f6d2f")

_CONTENT_RE = re.compile(r"<content[^>]*><!\[CDATA\[(.*?)\]\]></content>", re.DOTALL)

# Shared monotonic deadline (set by the orchestrator) so no request outlives the overall budget.
_deadline = 0.0

def set_deadline(t):
    global _deadline
    _deadline = t

def _http(url, headers=None, data=None, timeout=6.0):
    """GET/POST returning the (gunzipped) body. Honors the shared deadline."""
    if _deadline:
        remaining = _deadline - time.monotonic()
        if remaining < 0.3:
            raise TimeoutError("deadline")
        timeout = min(timeout, remaining)
    h = {"User-Agent": "Mozilla/5.0", "Accept-Encoding": "gzip"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        if resp.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
    return raw

def norm(s):
    return "".join(c.lower() for c in (s or "") if c.isalnum())

_BRACKETS_RE = re.compile(r"\s*[\(（\[［【〖《〈「『\{][^\)）\]］】〗》〉」』\}]*[\)）\]］】〗》〉」』\}]")
_CJK_RE = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]")
_ARTIST_SPLIT = re.compile(r"[,;&/、]+")

def norm_variants(s):
    """Normalized forms of a name: raw, without bracketed notes, and without CJK translations."""
    if not s:
        return set()
    unbracketed = _BRACKETS_RE.sub("", s)
    out = {norm(s), norm(unbracketed), norm(_CJK_RE.sub("", unbracketed))}
    out.discard("")
    return out

def _relation(a_set, b_set, min_sub):
    """2 = exact match, 1 = containment (shorter side >= min_sub chars), 0 = unrelated."""
    rel = 0
    for a in a_set:
        for b in b_set:
            if a == b:
                return 2
            short, long_ = (a, b) if len(a) <= len(b) else (b, a)
            if len(short) >= min_sub and short in long_:
                rel = 1
    return rel

def _pick_best(items, extract, title, artist, target_duration):
    """Score search results and return the best match (or None).

    `extract(item)` returns (name, singers, duration_seconds) or None to skip the item.
    Names are compared ignoring bracketed notes and CJK translations on either side.
    """
    title_vars = norm_variants(title)
    if not items or not title_vars:
        return None
    artist_vars = [v for v in (norm_variants(a) for a in _ARTIST_SPLIT.split(artist or "")) if v]

    best, best_score = None, -999999
    for item in items:
        fields = extract(item)
        if not fields:
            continue
        name, singers, dur = fields

        rel = _relation(title_vars, norm_variants(name), 3)
        if rel == 0:
            continue
        score = 50 if rel == 2 else 25

        if artist_vars:
            s_artist_vars = norm_variants(singers)
            best_rel = max((_relation(av, s_artist_vars, 2) for av in artist_vars), default=0)
            score += {2: 60, 1: 30, 0: -20}[best_rel]

        if target_duration > 0 and dur and dur > 0:
            diff = abs(dur - target_duration)
            if diff <= 1:
                score += 40
            elif diff <= 3:
                score += 20
            elif diff <= 6:
                score += 10
            elif diff > 15:
                score -= 40

        if score > best_score:
            best, best_score = item, score

    return best if best is not None and best_score >= 25 else None

# ==============================================================================
# Provider 1
# ==============================================================================
def fetch_p1(title, artist="", target_duration=0):
    primary_artist = re.split(r"[,;&/]+", artist)[0].strip() if artist else ""
    query = f"{title} {primary_artist}".strip()
    if not query:
        return None

    search_url = _U1 % urllib.parse.quote(query)
    try:
        s_data = json.loads(_http(search_url))
    except Exception:
        return None

    info = s_data.get("data", {}).get("info", [])
    if not info:
        return None

    target_artists = [norm(a) for a in re.split(r"[,;&/]+", artist) if len(norm(a)) > 1] if artist else []
    best_song = _pick_best(
        info,
        lambda s: (s.get("songname", ""), s.get("singername", ""), s.get("duration", 0)) if s.get("hash") else None,
        title, artist, target_duration)
    if not best_song:
        return None

    song_hash = best_song.get("hash")
    if not song_hash:
        return None

    k_url = _U2 % song_hash
    try:
        k_data = json.loads(_http(k_url))
    except Exception:
        return None

    candidates = k_data.get("candidates", [])
    if not candidates:
        return None

    best_cand = None
    best_cand_score = -9999
    for c in candidates:
        score = 0
        if c.get("krctype") == 1:
            score += 100
        c_singer = norm(c.get("singer", ""))
        if target_artists:
            for ta in target_artists:
                if c_singer == ta:
                    score += 50
                    break
                elif ta in c_singer or c_singer in ta:
                    score += 25
                    break
        if score > best_cand_score:
            best_cand_score = score
            best_cand = c

    if not best_cand or best_cand_score < 50:
        return None

    cand_id = best_cand.get("id")
    accesskey = best_cand.get("accesskey")
    if not cand_id or not accesskey:
        return None

    d_url = _U3 % (cand_id, accesskey)
    try:
        d_data = json.loads(_http(d_url))
    except Exception:
        return None

    b64_content = d_data.get("content")
    if not b64_content:
        return None

    try:
        raw = base64.b64decode(b64_content)
        enc = raw[4:]
        decrypted = bytearray(len(enc))
        for i in range(len(enc)):
            decrypted[i] = enc[i] ^ _XK[i % 16]

        decompressed = zlib.decompress(decrypted).decode("utf-8", errors="ignore")
        return decompressed
    except Exception:
        return None

# ==============================================================================
# Provider 2 (Pure Python 3DES Cipher with S-Box modifications)
# ==============================================================================
def _bit_num(a, b, c):
    byte_index = (b // 32) * 4 + 3 - (b % 32) // 8
    bit_position = 7 - (b % 8)
    extracted_bit = (a[byte_index] >> bit_position) & 0x01
    return extracted_bit << c

def _bit_num_int_r(a, b, c):
    extracted_bit = (a >> (31 - b)) & 0x00000001
    return extracted_bit << c

def _bit_num_int_l(a, b, c):
    extracted_bit = (a << b) & 0x80000000
    return extracted_bit >> c

def _s_box_bit(a):
    return (a & 0x20) | ((a & 0x1f) >> 1) | ((a & 0x01) << 4)

_S_BOX1 = [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13]
_S_BOX2 = [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9]
_S_BOX3 = [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12]
_S_BOX4 = [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14]
_S_BOX5 = [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3]
_S_BOX6 = [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13]
_S_BOX7 = [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12]
_S_BOX8 = [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]

def _ip(state, in_bytes):
    state[0] = (
        _bit_num(in_bytes, 57, 31) | _bit_num(in_bytes, 49, 30) | _bit_num(in_bytes, 41, 29) |
        _bit_num(in_bytes, 33, 28) | _bit_num(in_bytes, 25, 27) | _bit_num(in_bytes, 17, 26) |
        _bit_num(in_bytes, 9, 25) | _bit_num(in_bytes, 1, 24) | _bit_num(in_bytes, 59, 23) |
        _bit_num(in_bytes, 51, 22) | _bit_num(in_bytes, 43, 21) | _bit_num(in_bytes, 35, 20) |
        _bit_num(in_bytes, 27, 19) | _bit_num(in_bytes, 19, 18) | _bit_num(in_bytes, 11, 17) |
        _bit_num(in_bytes, 3, 16) | _bit_num(in_bytes, 61, 15) | _bit_num(in_bytes, 53, 14) |
        _bit_num(in_bytes, 45, 13) | _bit_num(in_bytes, 37, 12) | _bit_num(in_bytes, 29, 11) |
        _bit_num(in_bytes, 21, 10) | _bit_num(in_bytes, 13, 9) | _bit_num(in_bytes, 5, 8) |
        _bit_num(in_bytes, 63, 7) | _bit_num(in_bytes, 55, 6) | _bit_num(in_bytes, 47, 5) |
        _bit_num(in_bytes, 39, 4) | _bit_num(in_bytes, 31, 3) | _bit_num(in_bytes, 23, 2) |
        _bit_num(in_bytes, 15, 1) | _bit_num(in_bytes, 7, 0)
    )
    state[1] = (
        _bit_num(in_bytes, 56, 31) | _bit_num(in_bytes, 48, 30) | _bit_num(in_bytes, 40, 29) |
        _bit_num(in_bytes, 32, 28) | _bit_num(in_bytes, 24, 27) | _bit_num(in_bytes, 16, 26) |
        _bit_num(in_bytes, 8, 25) | _bit_num(in_bytes, 0, 24) | _bit_num(in_bytes, 58, 23) |
        _bit_num(in_bytes, 50, 22) | _bit_num(in_bytes, 42, 21) | _bit_num(in_bytes, 34, 20) |
        _bit_num(in_bytes, 26, 19) | _bit_num(in_bytes, 18, 18) | _bit_num(in_bytes, 10, 17) |
        _bit_num(in_bytes, 2, 16) | _bit_num(in_bytes, 60, 15) | _bit_num(in_bytes, 52, 14) |
        _bit_num(in_bytes, 44, 13) | _bit_num(in_bytes, 36, 12) | _bit_num(in_bytes, 28, 11) |
        _bit_num(in_bytes, 20, 10) | _bit_num(in_bytes, 12, 9) | _bit_num(in_bytes, 4, 8) |
        _bit_num(in_bytes, 62, 7) | _bit_num(in_bytes, 54, 6) | _bit_num(in_bytes, 46, 5) |
        _bit_num(in_bytes, 38, 4) | _bit_num(in_bytes, 30, 3) | _bit_num(in_bytes, 22, 2) |
        _bit_num(in_bytes, 14, 1) | _bit_num(in_bytes, 6, 0)
    )

def _inv_ip(state, in_bytes):
    in_bytes[3] = (
        _bit_num_int_r(state[1], 7, 7) | _bit_num_int_r(state[0], 7, 6) |
        _bit_num_int_r(state[1], 15, 5) | _bit_num_int_r(state[0], 15, 4) |
        _bit_num_int_r(state[1], 23, 3) | _bit_num_int_r(state[0], 23, 2) |
        _bit_num_int_r(state[1], 31, 1) | _bit_num_int_r(state[0], 31, 0)
    )
    in_bytes[2] = (
        _bit_num_int_r(state[1], 6, 7) | _bit_num_int_r(state[0], 6, 6) |
        _bit_num_int_r(state[1], 14, 5) | _bit_num_int_r(state[0], 14, 4) |
        _bit_num_int_r(state[1], 22, 3) | _bit_num_int_r(state[0], 22, 2) |
        _bit_num_int_r(state[1], 30, 1) | _bit_num_int_r(state[0], 30, 0)
    )
    in_bytes[1] = (
        _bit_num_int_r(state[1], 5, 7) | _bit_num_int_r(state[0], 5, 6) |
        _bit_num_int_r(state[1], 13, 5) | _bit_num_int_r(state[0], 13, 4) |
        _bit_num_int_r(state[1], 21, 3) | _bit_num_int_r(state[0], 21, 2) |
        _bit_num_int_r(state[1], 29, 1) | _bit_num_int_r(state[0], 29, 0)
    )
    in_bytes[0] = (
        _bit_num_int_r(state[1], 4, 7) | _bit_num_int_r(state[0], 4, 6) |
        _bit_num_int_r(state[1], 12, 5) | _bit_num_int_r(state[0], 12, 4) |
        _bit_num_int_r(state[1], 20, 3) | _bit_num_int_r(state[0], 20, 2) |
        _bit_num_int_r(state[1], 28, 1) | _bit_num_int_r(state[0], 28, 0)
    )
    in_bytes[7] = (
        _bit_num_int_r(state[1], 3, 7) | _bit_num_int_r(state[0], 3, 6) |
        _bit_num_int_r(state[1], 11, 5) | _bit_num_int_r(state[0], 11, 4) |
        _bit_num_int_r(state[1], 19, 3) | _bit_num_int_r(state[0], 19, 2) |
        _bit_num_int_r(state[1], 27, 1) | _bit_num_int_r(state[0], 27, 0)
    )
    in_bytes[6] = (
        _bit_num_int_r(state[1], 2, 7) | _bit_num_int_r(state[0], 2, 6) |
        _bit_num_int_r(state[1], 10, 5) | _bit_num_int_r(state[0], 10, 4) |
        _bit_num_int_r(state[1], 18, 3) | _bit_num_int_r(state[0], 18, 2) |
        _bit_num_int_r(state[1], 26, 1) | _bit_num_int_r(state[0], 26, 0)
    )
    in_bytes[5] = (
        _bit_num_int_r(state[1], 1, 7) | _bit_num_int_r(state[0], 1, 6) |
        _bit_num_int_r(state[1], 9, 5) | _bit_num_int_r(state[0], 9, 4) |
        _bit_num_int_r(state[1], 17, 3) | _bit_num_int_r(state[0], 17, 2) |
        _bit_num_int_r(state[1], 25, 1) | _bit_num_int_r(state[0], 25, 0)
    )
    in_bytes[4] = (
        _bit_num_int_r(state[1], 0, 7) | _bit_num_int_r(state[0], 0, 6) |
        _bit_num_int_r(state[1], 8, 5) | _bit_num_int_r(state[0], 8, 4) |
        _bit_num_int_r(state[1], 16, 3) | _bit_num_int_r(state[0], 16, 2) |
        _bit_num_int_r(state[1], 24, 1) | _bit_num_int_r(state[0], 24, 0)
    )
    return in_bytes

def _expand_raw(state):
    lrgstate = [0] * 6
    lrgstate[0] = (_bit_num_int_r(state, 31, 7) | _bit_num_int_r(state, 0, 6) |
                   _bit_num_int_r(state, 1, 5) | _bit_num_int_r(state, 2, 4) |
                   _bit_num_int_r(state, 3, 3) | _bit_num_int_r(state, 4, 2) |
                   _bit_num_int_r(state, 3, 1) | _bit_num_int_r(state, 4, 0))
    lrgstate[1] = (_bit_num_int_r(state, 5, 7) | _bit_num_int_r(state, 6, 6) |
                   _bit_num_int_r(state, 7, 5) | _bit_num_int_r(state, 8, 4) |
                   _bit_num_int_r(state, 7, 3) | _bit_num_int_r(state, 8, 2) |
                   _bit_num_int_r(state, 9, 1) | _bit_num_int_r(state, 10, 0))
    lrgstate[2] = (_bit_num_int_r(state, 11, 7) | _bit_num_int_r(state, 12, 6) |
                   _bit_num_int_r(state, 11, 5) | _bit_num_int_r(state, 12, 4) |
                   _bit_num_int_r(state, 13, 3) | _bit_num_int_r(state, 14, 2) |
                   _bit_num_int_r(state, 15, 1) | _bit_num_int_r(state, 16, 0))
    lrgstate[3] = (_bit_num_int_r(state, 15, 7) | _bit_num_int_r(state, 16, 6) |
                   _bit_num_int_r(state, 17, 5) | _bit_num_int_r(state, 18, 4) |
                   _bit_num_int_r(state, 19, 3) | _bit_num_int_r(state, 20, 2) |
                   _bit_num_int_r(state, 19, 1) | _bit_num_int_r(state, 20, 0))
    lrgstate[4] = (_bit_num_int_r(state, 21, 7) | _bit_num_int_r(state, 22, 6) |
                   _bit_num_int_r(state, 23, 5) | _bit_num_int_r(state, 24, 4) |
                   _bit_num_int_r(state, 23, 3) | _bit_num_int_r(state, 24, 2) |
                   _bit_num_int_r(state, 25, 1) | _bit_num_int_r(state, 26, 0))
    lrgstate[5] = (_bit_num_int_r(state, 27, 7) | _bit_num_int_r(state, 28, 6) |
                   _bit_num_int_r(state, 27, 5) | _bit_num_int_r(state, 28, 4) |
                   _bit_num_int_r(state, 29, 3) | _bit_num_int_r(state, 30, 2) |
                   _bit_num_int_r(state, 31, 1) | _bit_num_int_r(state, 0, 0))
    return lrgstate

def _perm_raw(state):
    return (_bit_num_int_l(state, 15, 0) | _bit_num_int_l(state, 6, 1) | _bit_num_int_l(state, 19, 2) |
            _bit_num_int_l(state, 20, 3) | _bit_num_int_l(state, 28, 4) | _bit_num_int_l(state, 11, 5) |
            _bit_num_int_l(state, 27, 6) | _bit_num_int_l(state, 16, 7) | _bit_num_int_l(state, 0, 8) |
            _bit_num_int_l(state, 14, 9) | _bit_num_int_l(state, 22, 10) | _bit_num_int_l(state, 25, 11) |
            _bit_num_int_l(state, 4, 12) | _bit_num_int_l(state, 17, 13) | _bit_num_int_l(state, 30, 14) |
            _bit_num_int_l(state, 9, 15) | _bit_num_int_l(state, 1, 16) | _bit_num_int_l(state, 7, 17) |
            _bit_num_int_l(state, 23, 18) | _bit_num_int_l(state, 13, 19) | _bit_num_int_l(state, 31, 20) |
            _bit_num_int_l(state, 26, 21) | _bit_num_int_l(state, 2, 22) | _bit_num_int_l(state, 8, 23) |
            _bit_num_int_l(state, 18, 24) | _bit_num_int_l(state, 12, 25) | _bit_num_int_l(state, 29, 26) |
            _bit_num_int_l(state, 5, 27) | _bit_num_int_l(state, 21, 28) | _bit_num_int_l(state, 10, 29) |
            _bit_num_int_l(state, 3, 30) | _bit_num_int_l(state, 24, 31))

# All DES stages above are pure bit permutations / expansions, so they can be folded into
# byte-indexed lookup tables generated from the reference bit-twiddling code. Built lazily
# (only provider 2 needs them) and reused for every block.
_TABLES = None

def _tables():
    global _TABLES
    if _TABLES is not None:
        return _TABLES

    exp = [[0] * 256 for _ in range(4)]
    for b in range(4):
        for v in range(256):
            exp[b][v] = int.from_bytes(bytes(_expand_raw(v << (24 - 8 * b))), "big")

    boxes = (_S_BOX1, _S_BOX2, _S_BOX3, _S_BOX4, _S_BOX5, _S_BOX6, _S_BOX7, _S_BOX8)
    sp = []
    for g in range(8):
        sp.append([_perm_raw(int(boxes[g][_s_box_bit(x)]) << (28 - 4 * g)) for x in range(64)])

    ip = [[0] * 256 for _ in range(8)]
    iip = [[0] * 256 for _ in range(8)]
    for b in range(8):
        for v in range(256):
            buf = bytearray(8)
            buf[b] = v
            st = [0, 0]
            _ip(st, buf)
            ip[b][v] = (st[0] << 32) | st[1]

            w = v << (56 - 8 * b)
            out = bytearray(8)
            _inv_ip([w >> 32, w & 0xffffffff], out)
            iip[b][v] = int.from_bytes(out, "big")

    _TABLES = (exp, sp, ip, iip)
    return _TABLES

def _des_key_setup(key, schedule, decrypt=False):
    key_rnd_shift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    key_perm_c = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    key_perm_d = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    key_compression = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]

    c = 0
    d = 0
    for i in range(28):
        c |= _bit_num(key, key_perm_c[i], 31 - i)
        d |= _bit_num(key, key_perm_d[i], 31 - i)

    for i in range(16):
        shift = key_rnd_shift[i]
        c = ((c << shift) | (c >> (28 - shift))) & 0xfffffff0
        d = ((d << shift) | (d >> (28 - shift))) & 0xfffffff0

        to_gen = 15 - i if decrypt else i
        schedule[to_gen] = [0] * 6
        for j in range(24):
            schedule[to_gen][j // 8] |= _bit_num_int_r(c, key_compression[j], 7 - (j % 8))
        for j in range(24, 48):
            schedule[to_gen][j // 8] |= _bit_num_int_r(d, key_compression[j] - 27, 7 - (j % 8))

def _crypt_all(buff, key, length, decrypt):
    sched = [[0] * 6 for _ in range(16)]
    _des_key_setup(bytearray(key), sched, decrypt=decrypt)
    ks = [int.from_bytes(bytes(k), "big") for k in sched]
    exp, sp, ip, iip = _tables()
    e0, e1, e2, e3 = exp
    sp0, sp1, sp2, sp3, sp4, sp5, sp6, sp7 = sp
    ip0, ip1, ip2, ip3, ip4, ip5, ip6, ip7 = ip
    ii0, ii1, ii2, ii3, ii4, ii5, ii6, ii7 = iip

    out = bytearray()
    for i in range(0, length - 7, 8):
        b = buff[i:i + 8]
        w = (ip0[b[0]] | ip1[b[1]] | ip2[b[2]] | ip3[b[3]] |
             ip4[b[4]] | ip5[b[5]] | ip6[b[6]] | ip7[b[7]])
        s0 = w >> 32
        s1 = w & 0xffffffff
        for r in range(16):
            x = (e0[s1 >> 24] | e1[(s1 >> 16) & 255] | e2[(s1 >> 8) & 255] | e3[s1 & 255]) ^ ks[r]
            f = (sp0[x >> 42] | sp1[(x >> 36) & 63] | sp2[(x >> 30) & 63] | sp3[(x >> 24) & 63] |
                 sp4[(x >> 18) & 63] | sp5[(x >> 12) & 63] | sp6[(x >> 6) & 63] | sp7[x & 63])
            if r < 15:
                s0, s1 = s1, f ^ s0
            else:
                s0 = f ^ s0
        o = (s0 << 32) | s1
        res = (ii0[(o >> 56) & 255] | ii1[(o >> 48) & 255] | ii2[(o >> 40) & 255] | ii3[(o >> 32) & 255] |
               ii4[(o >> 24) & 255] | ii5[(o >> 16) & 255] | ii6[(o >> 8) & 255] | ii7[o & 255])
        out += res.to_bytes(8, "big")
    return out

def _func_des(buff, key, length):
    return _crypt_all(buff, key, length, False)

def _func_ddes(buff, key, length):
    return _crypt_all(buff, key, length, True)

def _qrc_decode(content):
    length = len(content)
    content = _func_ddes(content, _Q1, length)
    content = _func_des(content, _Q2, length)
    content = _func_ddes(content, _Q3, length)
    return content

def _normalize_qrc(raw_qrc):
    lines = raw_qrc.split("\n")
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        m_hdr = re.match(r"^\[(\d+),(\d+)\](.*)", line)
        if not m_hdr:
            out.append(line)
            continue
        line_start = int(m_hdr.group(1))
        line_dur = int(m_hdr.group(2))
        rest = m_hdr.group(3)

        parts = re.split(r"\((\d+),(\d+)\)", rest)
        if len(parts) < 3:
            out.append(f"[{line_start},{line_dur}]{rest}")
            continue

        res = f"[{line_start},{line_dur}]"
        trailing = parts[-1] if (len(parts) - 1) % 3 == 0 else ""
        num_words = (len(parts) - 1) // 3
        for idx in range(num_words):
            w_text = parts[idx * 3]
            w_start = int(parts[idx * 3 + 1])
            w_dur = int(parts[idx * 3 + 2])
            if idx == num_words - 1 and trailing:
                w_text += trailing
            off = max(0, w_start - line_start)
            res += f"<{off},{w_dur},0>{w_text}"
        out.append(res)
    return "\n".join(out)

def fetch_p2(title, artist="", target_duration=0):
    primary_artist = re.split(r"[,;&/]+", artist)[0].strip() if artist else ""
    query = f"{title} {primary_artist}".strip()
    if not query:
        return None

    # Step 1: Search song
    body = {
        "req_1": {
            "module": "music.search.SearchCgiService",
            "method": _M_SEARCH,
            "param": {
                "query": query,
                "num_per_page": 5,
                "page_num": 1,
                "search_type": 0
            }
        }
    }
    try:
        s_data = json.loads(_http(_U4, data=json.dumps(body).encode("utf-8")))
    except Exception:
        return None

    songs = s_data.get("req_1", {}).get("data", {}).get("body", {}).get("song", {}).get("list", [])
    if not songs:
        return None

    best_song = _pick_best(
        songs,
        lambda s: (s.get("name", ""), " ".join(sg.get("name", "") for sg in s.get("singer", [])), s.get("interval", 0)) if (s.get("mid") or s.get("id")) else None,
        title, artist, target_duration)
    if not best_song:
        return None

    song_id = best_song.get("id")
    song_mid = best_song.get("mid")

    # Step 2: Download
    hex_payload = ""
    for d_url in [
        (_U5 % song_id) if song_id else None,
        (_U5_MID % song_mid) if song_mid else None
    ]:
        if not d_url:
            continue
        try:
            txt = _http(d_url, headers={"Referer": _P2_REF}).decode("utf-8", errors="ignore")
            m = _CONTENT_RE.search(txt)
            if m and m.group(1):
                hex_payload = m.group(1)
                break
        except Exception:
            continue

    if not hex_payload:
        return None

    # Step 3: Decrypt and normalize
    try:
        content_bytes = bytearray.fromhex(hex_payload)
        decrypted = _qrc_decode(content_bytes)
        decomp = zlib.decompress(decrypted).decode("utf-8", errors="ignore")
        m_lyric = re.search(r"LyricContent=\"(.*?)\"", decomp, re.DOTALL)
        raw_lyric = m_lyric.group(1) if m_lyric else decomp
        if "<" in raw_lyric and ">" in raw_lyric and "[" in raw_lyric:
            return raw_lyric
        normalized = _normalize_qrc(raw_lyric)
        return normalized
    except Exception:
        return None

# ==============================================================================
# Provider 3
# ==============================================================================
def _normalize_p3(raw_lyrics):
    lines = raw_lyrics.split("\n")
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        m_hdr = re.match(r"^\[(\d+),(\d+)\](.*)", line)
        if not m_hdr:
            out.append(line)
            continue
        line_start = int(m_hdr.group(1))
        line_dur = int(m_hdr.group(2))
        rest = m_hdr.group(3)

        parts = re.split(r"\((\d+),(\d+)(?:,\d+)?\)", rest)
        if len(parts) < 3:
            out.append(f"[{line_start},{line_dur}]{rest}")
            continue

        res = f"[{line_start},{line_dur}]"
        leading = parts[0]
        if leading:
            res += f"<0,50,0>{leading}"
        for i in range(1, len(parts), 3):
            w_start = int(parts[i])
            w_dur = int(parts[i + 1])
            w_text = parts[i + 2] if i + 2 < len(parts) else ""
            off = max(0, w_start - line_start)
            res += f"<{off},{w_dur},0>{w_text}"
        out.append(res)
    return "\n".join(out)

def fetch_p3(title, artist="", target_duration=0):
    primary_artist = re.split(r"[,;&/]+", artist)[0].strip() if artist else ""
    query = f"{title} {primary_artist}".strip()
    if not query:
        return None

    search_url = _U6 % urllib.parse.quote(query)
    headers = {"Referer": _NE_REF, "Cookie": "os=pc"}
    try:
        s_data = json.loads(_http(search_url, headers=headers))
    except Exception:
        return None

    songs = s_data.get("result", {}).get("songs", [])
    if not songs:
        return None

    best_song = _pick_best(
        songs,
        lambda s: (s.get("name", ""), " ".join(sg.get("name", "") for sg in s.get("ar", [])), int(s.get("dt", 0) / 1000)) if s.get("id") else None,
        title, artist, target_duration)
    if not best_song:
        return None

    song_id = best_song.get("id")
    if not song_id:
        return None

    lyric_url = _U7 % song_id
    try:
        l_data = json.loads(_http(lyric_url, headers=headers))
    except Exception:
        return None

    raw_lyrics = l_data.get(_d("797263"), {}).get("lyric", "")
    if not raw_lyrics or "(" not in raw_lyrics:
        return None

    try:
        normalized = _normalize_p3(raw_lyrics)
        return normalized
    except Exception:
        return None

# ==============================================================================
# Helpers for the orchestrator (fetch_lyrics.py)
# ==============================================================================
def slim_lyrics(raw):
    """Keep only timed lines and [offset:] — drops metadata tags and base64 blobs."""
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if len(line) > 2 and line[0] == "[" and (line[1].isdigit() or line.startswith("[offset:")):
            out.append(line)
    return "\n".join(out)

def is_word_synced(text):
    return bool(text) and "<" in text and ">" in text

# Word-synced providers, best first: p1, p2, p3
PROVIDERS = (("src1", fetch_p1), ("src2", fetch_p2), ("src3", fetch_p3))
