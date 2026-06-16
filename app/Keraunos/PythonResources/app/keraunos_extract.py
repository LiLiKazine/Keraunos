"""Keraunos extraction bridge.

Resolves a page URL to either a single progressive (already-muxed) file or a
separate video+audio pair for native merging, using yt-dlp WITHOUT downloading
and WITHOUT ffmpeg. Restricts adaptive selection to AVFoundation-muxable codecs
(HEVC/H.264 video + AAC audio). Always returns a JSON string; never raises.
"""
import json

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

# Prefer a progressive muxed http file with known muxable codecs; else best HEVC
# then H.264 video-only + best AAC audio-only (all AVFoundation-muxable, no
# VP9/AV1/Opus); else any progressive http mp4. The trailing branch keeps M1's
# behavior for already-muxed direct-file URLs, whose codecs yt-dlp can't probe
# under skip_download (vcodec/acodec come back None) — they're a single playable
# file we just download, never merge. HLS stays excluded via protocol^=http.
_FORMAT = (
    "best[protocol^=http][vcodec~='^(avc1|hvc1|hev1)'][acodec^=mp4a]/"
    "bestvideo[protocol^=http][vcodec~='^(hvc1|hev1)']+bestaudio[acodec^=mp4a]/"
    "bestvideo[protocol^=http][vcodec^=avc1]+bestaudio[acodec^=mp4a]/"
    "best[protocol^=http][ext=mp4]"
)

# Bound every network read so a stalled or bot-gated host (e.g. Reddit gating its
# post JSON / DASH manifest) surfaces a .network error in seconds instead of
# hanging the "Resolving…" spinner forever. There is otherwise no timeout: yt-dlp
# defaults socket_timeout to None and so does Python's global socket timeout.
_SOCKET_TIMEOUT = 15

_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw",
               "age-restricted", "age restricted", "confirm your age", "sensitive")


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
        return json.dumps({
            "ok": True, "kind": "progressive", "title": title, "filename": filename,
            "media": _track(info),
        })
    return _err("needs_ffmpeg", "no AVFoundation-muxable formats available")


def extract(url, socket_timeout=_SOCKET_TIMEOUT):
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT,
        "socket_timeout": socket_timeout, "extractor_retries": 2,
    }
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
        msg = str(e).lower()
        if "requested format is not available" in msg:
            return _err("needs_ffmpeg", str(e))
        if any(hint in msg for hint in _AUTH_HINTS):
            return _err("requires_auth", str(e))
        if "unable to download" in msg or "timed out" in msg or "connection" in msg:
            return _err("network", str(e))
        return _err("unsupported", str(e))
    except Exception as e:  # never raise into the bridge
        return _err("runtime", str(e))
