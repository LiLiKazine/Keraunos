"""Keraunos extraction bridge.

Resolves a page URL to a single progressive (already-muxed) media file using
yt-dlp, WITHOUT downloading and WITHOUT ffmpeg. Always returns a JSON string;
never raises, so the Swift C bridge has a single, total contract.
"""
import json

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

# Single progressive file: served over http(s), BOTH audio and video in one
# stream. Excludes HLS and split audio/video that would need ffmpeg.
_FORMAT = "best[protocol^=http][acodec!=none][vcodec!=none]/best[ext=mp4]"

# Substring hints, matched against the lowercased error message. Keep these
# specific: a bare "age" would false-match "webpage"/"message", misclassifying
# generic network errors as auth failures.
_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw",
               "age-restricted", "age restricted", "confirm your age", "sensitive")


def _err(kind, detail=""):
    return json.dumps({"ok": False, "error_kind": kind, "detail": detail})


def extract(url):
    opts = {"quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT}
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if info.get("_type") == "playlist":
                entries = info.get("entries") or []
                if not entries:
                    return _err("unsupported", "no media in playlist")
                info = entries[0]
            if info.get("requested_formats"):
                return _err("needs_ffmpeg", "requires merging separate streams")
            direct = info.get("url")
            if not direct:
                return _err("needs_ffmpeg", "no single progressive url available")
            return json.dumps({
                "ok": True,
                "direct_url": direct,
                "filename": ydl.prepare_filename(info),
                "title": info.get("title") or "",
            })
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
