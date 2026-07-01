"""Keraunos extraction bridge.

Resolves a page URL to either a single progressive (already-muxed) file or a
separate video+audio pair for native merging, using yt-dlp WITHOUT downloading
and WITHOUT ffmpeg. Restricts adaptive selection to AVFoundation-muxable codecs
(HEVC/H.264 video + AAC audio). Always returns a JSON string; never raises.
"""
import json
import os
import re
import threading

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

# Codec families AVFoundation can mux into an mp4 that Photos plays: H.264 / HEVC
# video + AAC audio. Match BOTH the fourcc forms (avc1/avc3/hvc1/hev1/mp4a) and the
# bare names some extractors emit — RedNote (xiaohongshu.py) labels its progressive
# stream h264/aac, and Reddit's complete fallback video is bare h264. The fourcc-only
# regex silently dropped both to needs_ffmpeg. VP9/AV1/Opus are deliberately NOT here:
# they aren't AVFoundation-muxable, so they stay on the Phase 4 (libav) path.
_VCODEC_MUXABLE = "vcodec~='^(avc1|avc3|avc|h264|hvc1|hev1|hevc|h265)'"
_VCODEC_HEVC = "vcodec~='^(hvc1|hev1|hevc|h265)'"
_VCODEC_H264 = "vcodec~='^(avc1|avc3|avc|h264)'"
_ACODEC_AAC = "acodec~='^(mp4a|aac)'"

# Compiled re equivalents of the codec families above, for the Python-side format scan
# in _muxable_height_options (yt-dlp's selector strings above can't be reused outside
# build_format_selector). Intentionally kept separate from _VCODEC_*/_ACODEC_AAC.
_RE_MUX_HEVC = re.compile(r"^(hvc1|hev1|hevc|h265)")
_RE_MUX_H264 = re.compile(r"^(avc1|avc3|avc|h264)")
_RE_AAC = re.compile(r"^(mp4a|aac)")

# Prefer a progressive muxed http file with muxable codecs; else best HEVC then H.264
# video-only + best AAC audio-only (all AVFoundation-muxable, no VP9/AV1/Opus); else
# any progressive http mp4. The trailing branch keeps M1's behavior for already-muxed
# direct-file URLs, whose codecs yt-dlp can't probe under skip_download (vcodec/acodec
# come back None) — a single playable file we just download, never merge. HLS stays
# excluded via protocol^=http.
_FORMAT = (
    f"best[protocol^=http][{_VCODEC_MUXABLE}][{_ACODEC_AAC}]/"
    f"bestvideo[protocol^=http][{_VCODEC_HEVC}]+bestaudio[protocol^=http][{_ACODEC_AAC}]/"
    f"bestvideo[protocol^=http][{_VCODEC_H264}]+bestaudio[protocol^=http][{_ACODEC_AAC}]/"
    "best[protocol^=http][ext=mp4]"
)

# Bound every network read so a stalled or bot-gated host (e.g. Reddit gating its
# post JSON / DASH manifest) surfaces a .network error in seconds instead of
# hanging the "Resolving…" spinner forever. There is otherwise no timeout: yt-dlp
# defaults socket_timeout to None and so does Python's global socket timeout.
_SOCKET_TIMEOUT = 15

# Overall wall-clock bound on a single extraction. socket_timeout bounds individual
# socket reads, but some hangs (DNS/SSL stalls, retry loops, a wedged JS eval) are not
# a single socket read — this watchdog bounds the whole extraction so the bridge always
# returns. Set below the Swift-side backstop (45s) so this fires first with a clear error.
_OVERALL_TIMEOUT = 30

_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw",
               "age-restricted", "age restricted", "confirm your age", "sensitive",
               "po token", "po_token", "missing a gvs po token")

# Content-state hints: the video is gone (removed/terminated), private without a
# sign-in path, or geo-blocked. A distinct kind from "unsupported" (tool bug) so the
# owner can tell a *gone* video from a broken extractor. Checked AFTER _AUTH_HINTS so
# a private video that says "sign in" still routes to requires_auth.
_UNAVAILABLE_HINTS = ("video unavailable", "this video is unavailable",
                      "no longer available", "has been removed", "removed by",
                      "has been terminated", "this video is private", "private video",
                      "content isn't available", "content is not available",
                      "available in your country", "not available from your location",
                      "geo restrict", "geo-restrict", "blocked it in your country")

# --- JavaScript runtime (JavaScriptCore) -----------------------------------------
# yt-dlp solves YouTube's n/sig challenges with a JS runtime. The embedded interpreter
# has no subprocess, so we route them through the app's in-process JavaScriptCore via
# keraunos_native.eval_js. The actual integration lives in keraunos_youtube_jsc as a
# JsChallengeProvider (yt-dlp 2025.11+ framework); this module only exposes the eval
# bridge + a test seam that the provider calls.

_JS_EVALUATOR = None   # test seam; when None, the real keraunos_native is used.


def set_js_evaluator(fn):
    """Inject a fake eval backend `fn(script, timeout_ms) -> str` for tests."""
    global _JS_EVALUATOR
    _JS_EVALUATOR = fn


def _eval_js(script, timeout_ms=5000):
    if _JS_EVALUATOR is not None:
        return _JS_EVALUATOR(script, timeout_ms)
    import keraunos_native
    return keraunos_native.eval_js(script, timeout_ms)


def _err(kind, detail=""):
    return json.dumps({"ok": False, "error_kind": kind, "detail": detail})


def _track(fmt):
    return {
        "url": fmt.get("url"),
        "headers": fmt.get("http_headers") or {},
        "vcodec": fmt.get("vcodec"),
        "acodec": fmt.get("acodec"),
        "ext": fmt.get("ext"),
    }


def _payload_for_info(info, prepare_filename):
    """Builds the success JSON for a resolved info dict. Pure (no network)."""
    filename = prepare_filename(info)
    title = info.get("title") or ""
    requested = info.get("requested_formats")
    if requested and len(requested) == 2:
        video = next((f for f in requested if (f.get("vcodec") or "none") != "none"), None)
        audio = next((f for f in requested if (f.get("acodec") or "none") != "none"), None)
        if video and audio:
            return json.dumps({
                "ok": True, "kind": "adaptive", "title": title, "filename": filename,
                "video": _track(video), "audio": _track(audio),
            })
    if info.get("url"):
        # Reject a single format that explicitly lacks a track, else we'd save a silent
        # (or video-less) file and report success. Only the literal string "none" means
        # the track is genuinely absent; None/missing is the already-muxed direct-file
        # path (M1) whose codecs yt-dlp can't probe under skip_download — that stays valid.
        if info.get("vcodec") == "none" or info.get("acodec") == "none":
            return _err("needs_ffmpeg", "progressive stream is missing audio or video")
        return json.dumps({
            "ok": True, "kind": "progressive", "title": title, "filename": filename,
            "media": _track(info),
        })
    return _err("needs_ffmpeg", "no AVFoundation-muxable formats available")


def _is_http(fmt):
    return (fmt.get("protocol") or "").startswith("http")


def _codec_label(vcodec):
    v = vcodec or ""
    if _RE_MUX_HEVC.match(v):
        return "HEVC"
    if _RE_MUX_H264.match(v):
        return "H.264"
    return v


def _muxable_vcodec(vcodec):
    v = vcodec or ""
    return bool(_RE_MUX_HEVC.match(v) or _RE_MUX_H264.match(v))


def _best_aac_audio(formats):
    """Highest-tbr http AAC audio-only format, or None if there is no muxable audio."""
    best = None
    for f in formats:
        if not _is_http(f) or (f.get("vcodec") or "none") != "none":
            continue
        if not _RE_AAC.match(f.get("acodec") or ""):
            continue
        if best is None or (f.get("tbr") or 0) > (best.get("tbr") or 0):
            best = f
    return best


def _fmt_size(fmt):
    return fmt.get("filesize") or fmt.get("filesize_approx")


def _muxable_height_options(formats):
    """One AVFoundation-muxable option per distinct height (best tbr wins), sorted high→low.
    Progressive rows (muxable vcodec + AAC) carry their own size; adaptive rows (video-only
    muxable vcodec) are sized as video + best AAC audio, and are emitted only when a muxable
    audio track exists. Pure: no network. Mirrors the selector's muxability rules."""
    audio = _best_aac_audio(formats)
    audio_size = _fmt_size(audio) if audio else None
    by_height = {}
    for f in formats:
        h = f.get("height")
        if not _is_http(f) or not h or not _muxable_vcodec(f.get("vcodec")):
            continue
        acodec = f.get("acodec") or "none"
        progressive = acodec != "none" and bool(_RE_AAC.match(acodec))
        adaptive = acodec == "none"
        if adaptive and audio is None:
            continue                      # no muxable audio to pair with → not muxable
        if not (progressive or adaptive):
            continue                      # video with non-AAC muxed audio → skip
        cur = by_height.get(h)
        if cur is None or (f.get("tbr") or 0) > (cur[0].get("tbr") or 0):
            by_height[h] = (f, adaptive)
    options = []
    for h in sorted(by_height, reverse=True):
        f, adaptive = by_height[h]
        vsize = _fmt_size(f)
        if adaptive:
            size = (vsize + audio_size) if (vsize is not None and audio_size is not None) else None
        else:
            size = vsize
        options.append({
            "height": h,
            "codec": _codec_label(f.get("vcodec")),
            "approx_bytes": size,
            "format_id": f.get("format_id"),
            "adaptive": adaptive,
        })
    return options


def _map_download_error(e):
    """Maps a DownloadError/ExtractorError to an _err(...) payload. Shared by
    _extract_impl and _list_impl so both extraction paths classify failures
    identically."""
    msg = str(e).lower()
    if "requested format is not available" in msg:
        return _err("needs_ffmpeg", str(e))
    if any(hint in msg for hint in _AUTH_HINTS):
        return _err("requires_auth", str(e))
    # Bot-gate / forbidden / precondition statuses (Bilibili 412, Reddit 403, 401):
    # the actionable fix is sign-in/cookies, so route to requires_auth (surfaces the
    # "Sign in to {host}" button) instead of the generic network bucket — even though
    # the message also says "unable to download". 429 (rate-limit) stays network.
    if any(s in msg for s in ("http error 401", "http error 403", "http error 412")):
        return _err("requires_auth", str(e))
    # Rate-limit (HTTP 429 / "too many requests"): checked before the network bucket
    # (its message also says "unable to download") so it gets the correct "wait and
    # retry" remedy instead of being auto-hammered as a connection blip.
    if "http error 429" in msg or "too many requests" in msg:
        return _err("rate_limited", str(e))
    # Content gone/private/geo-blocked — a distinct state from "unsupported".
    if any(hint in msg for hint in _UNAVAILABLE_HINTS):
        return _err("unavailable", str(e))
    # "No video could be found in this tweet": X serves a bare TweetTombstone to
    # logged-out (guest-token) clients for age-restricted/sensitive tweets, and
    # yt-dlp — which only reads a populated tombstone — falls through to this generic
    # no-formats message. The content was REACHED but withheld from guests, so this is
    # neither a tool bug ("unsupported") nor a gone video ("unavailable"): the remedy
    # is sign-in (or the tweet genuinely has no video). restricted_or_empty surfaces
    # the Sign In button while staying honest about the ambiguity. Auth-explicit
    # tombstones ("NSFW tweet requires authentication") still hit _AUTH_HINTS above.
    if "no video could be found" in msg:
        return _err("restricted_or_empty", str(e))
    if "unable to download" in msg or "timed out" in msg or "connection" in msg:
        # Extraction-side network failure. The download half (native URLSession,
        # Swift Downloader) emits download_network — keeping them distinct lets a
        # local failure log attribute which side broke without telemetry.
        return _err("extract_network", str(e))
    return _err("unsupported", str(e))


def _extract_impl(url, socket_timeout, cookiefile, fmt=_FORMAT):
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": fmt,
        "socket_timeout": socket_timeout, "extractor_retries": 2,
        # iOS sandbox: only Documents/Library/tmp are writable, not ~/.cache. Point
        # yt-dlp's cache (nsig functions etc.) at tmp so it stops failing and can reuse.
        "cachedir": os.path.join(__import__("tempfile").gettempdir(), "yt-dlp-cache"),
        # YouTube: use non-web clients that need NO GVS PO token and aren't SABR/HLS-only,
        # so extraction yields direct, AVFoundation-muxable (H.264+AAC) URLs. A *set* (not
        # tv-only) lets yt-dlp skip a client that throws "page needs to be reloaded" and
        # merge formats from the rest. Excludes web/web_safari/mweb (SABR / HLS / PO-gated).
        "extractor_args": {"youtube": {"player_client": ["tv", "tv_embedded", "android_vr"]}},
    }
    if cookiefile and os.path.exists(cookiefile):
        opts["cookiefile"] = cookiefile
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if info.get("_type") == "playlist":
                entries = info.get("entries") or []
                if not entries:
                    return _err("unsupported", "no media in playlist")
                info = entries[0]
            return _payload_for_info(info, ydl.prepare_filename)
    except UnsupportedError as e:
        return _err("unsupported", str(e))
    except (DownloadError, ExtractorError) as e:
        return _map_download_error(e)
    except Exception as e:  # never raise into the bridge
        return _err("runtime", str(e))


def _list_impl(url, socket_timeout, cookiefile):
    """Phase 1: one extraction. Returns a choices payload when 2+ muxable heights exist,
    else the default .ready payload (identical to extract()'s success JSON)."""
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT,
        "socket_timeout": socket_timeout, "extractor_retries": 2,
        "cachedir": os.path.join(__import__("tempfile").gettempdir(), "yt-dlp-cache"),
        "extractor_args": {"youtube": {"player_client": ["tv", "tv_embedded", "android_vr"]}},
    }
    if cookiefile and os.path.exists(cookiefile):
        opts["cookiefile"] = cookiefile
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if info.get("_type") == "playlist":
                entries = info.get("entries") or []
                if not entries:
                    return _err("unsupported", "no media in playlist")
                info = entries[0]
            options = _muxable_height_options(info.get("formats") or [])
            if len(options) >= 2:
                return json.dumps({"ok": True, "kind": "choices", "options": options})
            return _payload_for_info(info, ydl.prepare_filename)
    except UnsupportedError as e:
        return _err("unsupported", str(e))
    except (DownloadError, ExtractorError) as e:
        return _map_download_error(e)
    except Exception as e:
        return _err("runtime", str(e))


def extract(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None,
            overall_timeout=_OVERALL_TIMEOUT, format_id=None, adaptive=False):
    """Runs _extract_impl under an overall wall-clock bound. A non-empty format_id
    re-selects exactly that stream (adaptive → pair with best AAC audio), falling back
    to the default _FORMAT if the id is stale. If it exceeds overall_timeout, returns a
    timeout error and abandons the worker thread (it keeps running until it finishes;
    the next extraction is serialized by the caller)."""
    if format_id:
        if adaptive:
            # First branch (AAC-constrained) is what actually resolves: list_formats only
            # emits an adaptive option when muxable AAC audio exists, so that branch always
            # pairs. The middle `{id}+bestaudio` (no codec filter) is a defensive fallback,
            # NOT a license to pair with Opus — if you ever loosen the list_formats audio
            # gate, keep an AAC constraint here or you'll silently mux a non-AVFoundation pair.
            fmt = (f"{format_id}+bestaudio[protocol^=http][{_ACODEC_AAC}]/"
                   f"{format_id}+bestaudio/{_FORMAT}")
        else:
            fmt = f"{format_id}/{_FORMAT}"
    else:
        fmt = _FORMAT
    box = {}

    def _work():
        try:
            box["result"] = _extract_impl(url, socket_timeout, cookiefile, fmt)
        except Exception as e:  # _extract_impl shouldn't raise, but never let the thread die silently
            box["result"] = _err("runtime", str(e))

    worker = threading.Thread(target=_work, daemon=True)
    worker.start()
    worker.join(overall_timeout)
    if worker.is_alive():
        return _err("timeout", f"extraction exceeded {overall_timeout}s")
    return box.get("result", _err("runtime", "extraction produced no result"))


def list_formats(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None,
                 overall_timeout=_OVERALL_TIMEOUT):
    box = {}

    def _work():
        try:
            box["result"] = _list_impl(url, socket_timeout, cookiefile)
        except Exception as e:
            box["result"] = _err("runtime", str(e))

    worker = threading.Thread(target=_work, daemon=True)
    worker.start()
    worker.join(overall_timeout)
    if worker.is_alive():
        return _err("timeout", f"extraction exceeded {overall_timeout}s")
    return box.get("result", _err("runtime", "extraction produced no result"))


try:
    import keraunos_youtube_jsc  # noqa: F401  (registers the JS-challenge provider on import)
except Exception:
    pass   # fail open: extraction proceeds (YouTube n/sig unavailable without it)

try:
    import keraunos_youtube_pot  # noqa: F401  (registers the PO token provider on import)
except Exception:
    pass   # fail open: extraction proceeds without an on-device PO token provider
