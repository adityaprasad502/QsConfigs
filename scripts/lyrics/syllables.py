#!/usr/bin/env python3
import sys
import json
import base64
import zlib
import re
import urllib.request
import urllib.parse

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

def norm(s):
    return "".join(c.lower() for c in (s or "") if c.isalnum())

# ==============================================================================
# Provider 1: KRC
# ==============================================================================
def fetch_p1(title, artist="", target_duration=0):
    query = f"{title} {artist}".strip()
    if not query:
        return None

    search_url = _U1 % urllib.parse.quote(query)
    req = urllib.request.Request(search_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            s_data = json.loads(resp.read())
    except Exception:
        return None

    info = s_data.get("data", {}).get("info", [])
    if not info:
        return None

    target_artist_norm = norm(artist)
    target_title_norm = norm(title)

    best_song = None
    best_score = -999999

    for s in info:
        h = s.get("hash")
        if not h:
            continue
        s_title = s.get("songname", "")
        s_artist = s.get("singername", "")
        dur = s.get("duration", 0)

        s_artist_norm = norm(s_artist)
        s_title_norm = norm(s_title)

        score = 0
        if target_artist_norm:
            if s_artist_norm == target_artist_norm:
                score += 60
            elif target_artist_norm in s_artist_norm:
                score += 30
            elif s_artist_norm in target_artist_norm:
                score += 20
            else:
                score -= 30

        if target_title_norm:
            if s_title_norm == target_title_norm:
                score += 50
            elif target_title_norm in s_title_norm or s_title_norm in target_title_norm:
                score += 25

        if target_duration > 0 and dur > 0:
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
            best_score = score
            best_song = s

    if not best_song:
        best_song = info[0]

    song_hash = best_song.get("hash")
    if not song_hash:
        return None

    k_url = _U2 % song_hash
    req2 = urllib.request.Request(k_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req2, timeout=4) as resp2:
            k_data = json.loads(resp2.read())
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
        if target_artist_norm and c_singer == target_artist_norm:
            score += 50
        elif target_artist_norm and (target_artist_norm in c_singer or c_singer in target_artist_norm):
            score += 25
        if score > best_cand_score:
            best_cand_score = score
            best_cand = c

    if not best_cand:
        best_cand = candidates[0]

    cand_id = best_cand.get("id")
    accesskey = best_cand.get("accesskey")
    if not cand_id or not accesskey:
        return None

    d_url = _U3 % (cand_id, accesskey)
    req3 = urllib.request.Request(d_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req3, timeout=4) as resp3:
            d_data = json.loads(resp3.read())
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
# Provider 2: QRC (Pure Python 3DES Cipher with S-Box modifications)
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

def _f(state, sub_key):
    lrgstate = [0] * 6
    lrgstate[0] = ((_bit_num_int_r(state, 31, 7) | _bit_num_int_r(state, 0, 6) |
                    _bit_num_int_r(state, 1, 5) | _bit_num_int_r(state, 2, 4) |
                    _bit_num_int_r(state, 3, 3) | _bit_num_int_r(state, 4, 2) |
                    _bit_num_int_r(state, 3, 1) | _bit_num_int_r(state, 4, 0)) ^ sub_key[0])
    lrgstate[1] = ((_bit_num_int_r(state, 5, 7) | _bit_num_int_r(state, 6, 6) |
                    _bit_num_int_r(state, 7, 5) | _bit_num_int_r(state, 8, 4) |
                    _bit_num_int_r(state, 7, 3) | _bit_num_int_r(state, 8, 2) |
                    _bit_num_int_r(state, 9, 1) | _bit_num_int_r(state, 10, 0)) ^ sub_key[1])
    lrgstate[2] = ((_bit_num_int_r(state, 11, 7) | _bit_num_int_r(state, 12, 6) |
                    _bit_num_int_r(state, 11, 5) | _bit_num_int_r(state, 12, 4) |
                    _bit_num_int_r(state, 13, 3) | _bit_num_int_r(state, 14, 2) |
                    _bit_num_int_r(state, 15, 1) | _bit_num_int_r(state, 16, 0)) ^ sub_key[2])
    lrgstate[3] = ((_bit_num_int_r(state, 15, 7) | _bit_num_int_r(state, 16, 6) |
                    _bit_num_int_r(state, 17, 5) | _bit_num_int_r(state, 18, 4) |
                    _bit_num_int_r(state, 19, 3) | _bit_num_int_r(state, 20, 2) |
                    _bit_num_int_r(state, 19, 1) | _bit_num_int_r(state, 20, 0)) ^ sub_key[3])
    lrgstate[4] = ((_bit_num_int_r(state, 21, 7) | _bit_num_int_r(state, 22, 6) |
                    _bit_num_int_r(state, 23, 5) | _bit_num_int_r(state, 24, 4) |
                    _bit_num_int_r(state, 23, 3) | _bit_num_int_r(state, 24, 2) |
                    _bit_num_int_r(state, 25, 1) | _bit_num_int_r(state, 26, 0)) ^ sub_key[4])
    lrgstate[5] = ((_bit_num_int_r(state, 27, 7) | _bit_num_int_r(state, 28, 6) |
                    _bit_num_int_r(state, 27, 5) | _bit_num_int_r(state, 28, 4) |
                    _bit_num_int_r(state, 29, 3) | _bit_num_int_r(state, 30, 2) |
                    _bit_num_int_r(state, 31, 1) | _bit_num_int_r(state, 0, 0)) ^ sub_key[5])

    state = (int(_S_BOX1[_s_box_bit(lrgstate[0] >> 2)]) << 28) | \
            (int(_S_BOX2[_s_box_bit(((lrgstate[0] & 0x03) << 4) | (lrgstate[1] >> 4))]) << 24) | \
            (int(_S_BOX3[_s_box_bit(((lrgstate[1] & 0x0f) << 2) | (lrgstate[2] >> 6))]) << 20) | \
            (int(_S_BOX4[_s_box_bit(lrgstate[2] & 0x3f)]) << 16) | \
            (int(_S_BOX5[_s_box_bit(lrgstate[3] >> 2)]) << 12) | \
            (int(_S_BOX6[_s_box_bit(((lrgstate[3] & 0x03) << 4) | (lrgstate[4] >> 4))]) << 8) | \
            (int(_S_BOX7[_s_box_bit(((lrgstate[4] & 0x0f) << 2) | (lrgstate[5] >> 6))]) << 4) | \
            int(_S_BOX8[_s_box_bit(lrgstate[5] & 0x3f)])

    state = (_bit_num_int_l(state, 15, 0) | _bit_num_int_l(state, 6, 1) | _bit_num_int_l(state, 19, 2) |
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
    return state

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

def _des_crypt(input_bytes, key_schedule):
    state = [0, 0]
    _ip(state, input_bytes)
    for idx in range(15):
        t = state[1]
        i = _f(state[1], key_schedule[idx])
        state[1] = i ^ state[0]
        state[0] = t
    state[0] = _f(state[1], key_schedule[15]) ^ state[0]
    _inv_ip(state, input_bytes)
    return input_bytes

def _func_des(buff, key, length):
    sched = [[0] * 6 for _ in range(16)]
    _des_key_setup(bytearray(key), sched, decrypt=False)
    out = bytearray()
    for i in range(0, length, 8):
        chunk = buff[i:i + 8]
        if len(chunk) < 8:
            break
        out += _des_crypt(chunk, sched)
    return out

def _func_ddes(buff, key, length):
    sched = [[0] * 6 for _ in range(16)]
    _des_key_setup(bytearray(key), sched, decrypt=True)
    out = bytearray()
    for i in range(0, length, 8):
        chunk = buff[i:i + 8]
        if len(chunk) < 8:
            break
        out += _des_crypt(chunk, sched)
    return out

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

        tokens = re.findall(r"([^()]+)\((\d+),(\d+)\)", rest)
        if not tokens:
            out.append(f"[{line_start},{line_dur}]{rest}")
            continue

        res = f"[{line_start},{line_dur}]"
        for w_text, w_start, w_dur in tokens:
            off = max(0, int(w_start) - line_start)
            res += f"<{off},{w_dur},0>{w_text}"
        out.append(res)
    return "\n".join(out)

def fetch_p2(title, artist="", target_duration=0):
    query = f"{title} {artist}".strip()
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
    req = urllib.request.Request(_U4, data=json.dumps(body).encode("utf-8"), headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            s_data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None

    songs = s_data.get("req_1", {}).get("data", {}).get("body", {}).get("song", {}).get("list", [])
    if not songs:
        return None

    target_artist_norm = norm(artist)
    target_title_norm = norm(title)

    best_song = None
    best_score = -999999

    for s in songs:
        s_mid = s.get("mid")
        s_id = s.get("id")
        if not s_mid and not s_id:
            continue

        s_name = s.get("name", "")
        singers = " ".join([sg.get("name", "") for sg in s.get("singer", [])])
        s_dur = s.get("interval", 0)

        s_title_norm = norm(s_name)
        s_artist_norm = norm(singers)

        score = 0
        if target_artist_norm:
            if s_artist_norm == target_artist_norm:
                score += 60
            elif target_artist_norm in s_artist_norm:
                score += 30
            elif s_artist_norm in target_artist_norm:
                score += 20
            else:
                score -= 30

        if target_title_norm:
            if s_title_norm == target_title_norm:
                score += 50
            elif target_title_norm in s_title_norm or s_title_norm in target_title_norm:
                score += 25

        if target_duration > 0 and s_dur > 0:
            diff = abs(s_dur - target_duration)
            if diff <= 1:
                score += 40
            elif diff <= 3:
                score += 20
            elif diff <= 6:
                score += 10
            elif diff > 15:
                score -= 40

        if score > best_score:
            best_score = score
            best_song = s

    if not best_song:
        best_song = songs[0]

    song_id = best_song.get("id")
    song_mid = best_song.get("mid")

    # Step 2: Download QRC
    hex_payload = ""
    for d_url in [
        (_U5 % song_id) if song_id else None,
        (_U5_MID % song_mid) if song_mid else None
    ]:
        if not d_url:
            continue
        req2 = urllib.request.Request(d_url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://y.qq.com/"})
        try:
            with urllib.request.urlopen(req2, timeout=4) as resp2:
                txt = resp2.read().decode("utf-8", errors="ignore")
                m = re.findall(r"<content[^>]*><!\[CDATA\[(.*?)\]\]></content>", txt)
                if m and len(m[0]) > 0:
                    hex_payload = m[0]
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
# Provider 3: YRC (No encryption needed)
# ==============================================================================
def _normalize_yrc(raw_yrc):
    lines = raw_yrc.split("\n")
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

        tokens = re.findall(r"\((\d+),(\d+)(?:,\d+)?\)([^(]*)", rest)
        if not tokens:
            out.append(f"[{line_start},{line_dur}]{rest}")
            continue

        res = f"[{line_start},{line_dur}]"
        for w_start, w_dur, w_text in tokens:
            off = max(0, int(w_start) - line_start)
            res += f"<{off},{w_dur},0>{w_text}"
        out.append(res)
    return "\n".join(out)

def fetch_p3(title, artist="", target_duration=0):
    query = f"{title} {artist}".strip()
    if not query:
        return None

    search_url = _U6 % urllib.parse.quote(query)
    headers = {"User-Agent": "Mozilla/5.0", "Referer": _NE_REF, "Cookie": "os=pc"}
    req = urllib.request.Request(search_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            s_data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None

    songs = s_data.get("result", {}).get("songs", [])
    if not songs:
        return None

    target_artist_norm = norm(artist)
    target_title_norm = norm(title)

    best_song = None
    best_score = -999999

    for s in songs:
        s_id = s.get("id")
        if not s_id:
            continue

        s_name = s.get("name", "")
        singers = " ".join([sg.get("name", "") for sg in s.get("ar", [])])
        s_dur = int((s.get("dt", 0)) / 1000)

        s_title_norm = norm(s_name)
        s_artist_norm = norm(singers)

        score = 0
        if target_artist_norm:
            if s_artist_norm == target_artist_norm:
                score += 60
            elif target_artist_norm in s_artist_norm:
                score += 30
            elif s_artist_norm in target_artist_norm:
                score += 20
            else:
                score -= 30

        if target_title_norm:
            if s_title_norm == target_title_norm:
                score += 50
            elif target_title_norm in s_title_norm or s_title_norm in target_title_norm:
                score += 25

        if target_duration > 0 and s_dur > 0:
            diff = abs(s_dur - target_duration)
            if diff <= 1:
                score += 40
            elif diff <= 3:
                score += 20
            elif diff <= 6:
                score += 10
            elif diff > 15:
                score -= 40

        if score > best_score:
            best_score = score
            best_song = s

    if not best_song:
        best_song = songs[0]

    song_id = best_song.get("id")
    if not song_id:
        return None

    lyric_url = _U7 % song_id
    req2 = urllib.request.Request(lyric_url, headers=headers)
    try:
        with urllib.request.urlopen(req2, timeout=4) as resp2:
            l_data = json.loads(resp2.read().decode("utf-8"))
    except Exception:
        return None

    raw_yrc = l_data.get("yrc", {}).get("lyric", "")
    if not raw_yrc or "(" not in raw_yrc:
        return None

    try:
        normalized = _normalize_yrc(raw_yrc)
        return normalized
    except Exception:
        return None

# ==============================================================================
# Main Dispatcher: P1 -> P2 -> P3
# ==============================================================================
def is_metadata_line(text, time_ms, title="", artist="", has_syllables=False):
    t = text.strip()
    if not t or t == "♪":
        return True
    credit_re = re.compile(
        r"^(lyrics?( by)?|lyricist|composed?( by)?|composer|written( by)?|writer|"
        r"produced?( by)?|producer|arranged?( by)?|arranger|music( by)?|vocals?( by)?|"
        r"track\s*[:：\-]|artist\s*[:：\-]|album\s*[:：\-]|synced by|lrc by|source\s*[:：]|"
        r"mixing( by)?|mixed by|mastering( by)?|mastered by|recorded?( by)?|recording( by)?|"
        r"engineered by|publisher|label|qqmusic|kugou|netease|163\.com|lrclib|"
        r"作\s*词|作\s*曲|编\s*曲|制\s*作|演唱|词曲|词\s*[:：]|曲\s*[:：]|"
        r"录音|混音|母带|监制|统筹|企划|出品|发行|后期|和声|合音|吉他|贝斯|鼓|键盘|弦乐|文案|原唱|翻唱|伴奏|配唱|乐器)",
        re.I
    )
    if credit_re.search(t):
        return True
    if not has_syllables and time_ms < 12000:
        nt = norm(t)
        ntitle = norm(title)
        nartist = norm(artist)
        if ntitle and nartist and (ntitle in nt and nartist in nt):
            return True
        if re.match(r"^.+?\s*[-–—]\s*.+?$", t) and ((ntitle and ntitle in nt) or (nartist and nartist in nt)):
            return True
    return False

def clean_syllables(lyrics, title="", artist=""):
    if not lyrics:
        return ""
    lines = lyrics.split("\n")
    cleaned = []
    seen_first_lyric = False

    for line in lines:
        line_str = line.strip()
        if not line_str:
            continue
        m_hdr = re.match(r"^\[(\d+)(?:,(\d+))?\](.*)", line_str)
        if not m_hdr:
            if line_str.startswith("[offset:"):
                cleaned.append(line_str)
            continue

        time_ms = int(m_hdr.group(1))
        rest = m_hdr.group(3)
        has_syl = "<" in rest and ">" in rest
        plain_text = re.sub(r"<[^>]+>", "", rest)
        plain_text = re.sub(r"\([^)]+\)", "", plain_text).strip()

        if is_metadata_line(plain_text, time_ms, title, artist, has_syllables=has_syl):
            if not seen_first_lyric:
                continue
            credit_re = re.compile(
                r"^(lyrics?( by)?|composed?( by)?|written( by)?|produced?( by)?|arranged?( by)?|"
                r"作\s*词|作\s*曲|编\s*曲|制\s*作|演唱|词曲)\s*[:：]",
                re.I
            )
            if credit_re.search(plain_text):
                continue

        seen_first_lyric = True
        cleaned.append(line_str)

    return "\n".join(cleaned)

def report_status(msg):
    try:
        sys.stderr.write(f"STATUS:{msg}\n")
        sys.stderr.flush()
    except Exception:
        pass

def fetch_syllables(title, artist="", target_duration=0):
    # 1. Primary provider (P1)
    report_status("Searching (src1)…")
    res1 = fetch_p1(title, artist, target_duration)
    if res1 and ("<" in res1 and ">" in res1):
        return clean_syllables(res1, title, artist)

    # 2. Secondary fallback (P2)
    report_status("Searching (src2)…")
    res2 = fetch_p2(title, artist, target_duration)
    if res2 and ("<" in res2 and ">" in res2):
        return clean_syllables(res2, title, artist)

    # 3. Tertiary fallback (P3)
    report_status("Searching (src3)…")
    res3 = fetch_p3(title, artist, target_duration)
    if res3 and ("<" in res3 and ">" in res3):
        return clean_syllables(res3, title, artist)

    return None

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)

    title = sys.argv[1]
    artist = sys.argv[2] if len(sys.argv) > 2 else ""
    target_duration = int(float(sys.argv[3])) if len(sys.argv) > 3 else 0

    res = fetch_syllables(title, artist, target_duration)
    if res and ("<" in res and ">" in res):
        sys.stdout.write(res)
        sys.exit(0)
    else:
        sys.exit(1)
