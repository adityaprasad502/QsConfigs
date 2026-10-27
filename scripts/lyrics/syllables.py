#!/usr/bin/env python3
import sys
import json
import base64
import zlib
import urllib.request
import urllib.parse

def _d(h):
    return bytes.fromhex(h).decode()

_U1 = _d("687474703a2f2f6d6f62696c6563646e2e6b75676f752e636f6d2f6170692f76332f7365617263682f736f6e673f666f726d61743d6a736f6e266b6579776f72643d257326706167653d31267061676573697a653d35")
_U2 = _d("687474703a2f2f6b7263732e6b75676f752e636f6d2f7365617263683f7665723d31266d616e3d79657326636c69656e743d6d6f6269266b6579776f72643d266475726174696f6e3d26686173683d2573")
_U3 = _d("687474703a2f2f6c79726963732e6b75676f752e636f6d2f646f776e6c6f61643f7665723d3126636c69656e743d70632669643d2573266163636573736b65793d257326666d743d6b726326636861727365743d75746638")
_XK = bytes.fromhex("404761775e3274475136312dced26e69")

def fetch_syllables(title, artist="", target_duration=0):
    query = f"{title} {artist}".strip()
    if not query:
        return None

    # Step 1: Search track
    search_url = _U1 % urllib.parse.quote(query)
    req = urllib.request.Request(search_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            s_data = json.loads(resp.read())
    except Exception:
        return None

    info = s_data.get("data", {}).get("info", [])
    if not info:
        return None

    def norm(s):
        return "".join(c.lower() for c in (s or "") if c.isalnum())

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

    # Step 2: Fetch candidate metadata
    k_url = _U2 % song_hash
    req2 = urllib.request.Request(k_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req2, timeout=5) as resp2:
            k_data = json.loads(resp2.read())
    except Exception:
        return None

    candidates = k_data.get("candidates", [])
    if not candidates:
        return None

    # Prefer word-synced candidates (krctype == 1) and matching performer
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

    # Step 3: Fetch payload
    d_url = _U3 % (cand_id, accesskey)
    req3 = urllib.request.Request(d_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req3, timeout=5) as resp3:
            d_data = json.loads(resp3.read())
    except Exception:
        return None

    b64_content = d_data.get("content")
    if not b64_content:
        return None

    # Step 4: Decode and decompress payload
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
