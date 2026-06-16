"""Keraunos extraction bridge.

Resolves a page URL to either a single progressive (already-muxed) file or a
separate video+audio pair for native merging, using yt-dlp WITHOUT downloading
and WITHOUT ffmpeg. Restricts adaptive selection to AVFoundation-muxable codecs
(HEVC/H.264 video + AAC audio). Always returns a JSON string; never raises.
"""
import json
import os

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
               "age-restricted", "age restricted", "confirm your age", "sensitive",
               "po token", "po_token", "missing a gvs po token")

# --- JavaScript runtime (JavaScriptCore) -----------------------------------------
# yt-dlp solves YouTube's nsig challenge with a JS runtime. The embedded interpreter
# has no subprocess, so we route nsig through the app's in-process JavaScriptCore via
# keraunos_native.eval_js. The pure-Python JSInterpreter path is skipped entirely —
# on-device it is pathologically slow (the original "stuck on Resolving…" hang).

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


class JavaScriptCoreWrapper:
    """Drop-in for yt-dlp's PhantomJSwrapper: runs a self-contained JS snippet that
    prints its result via console.log and returns that output."""

    def __init__(self, extractor, required_version=None, timeout=5000):
        self.extractor = extractor
        self.timeout = timeout

    def execute(self, jscode, video_id=None, *, note='Executing JS'):
        out = _eval_js(jscode, self.timeout)
        if out.startswith("__KERAUNOS_JS_ERROR__"):
            raise ExtractorError(f"JavaScriptCore eval failed: {out[len('__KERAUNOS_JS_ERROR__'):]}")
        return out.strip()


def install_youtube_js_runtime():
    """Patch YoutubeIE so nsig is computed via JavaScriptCore, never pure-Python."""
    from yt_dlp.extractor.youtube import _video
    from yt_dlp.utils import urljoin

    def _decrypt_nsig_via_jsc(self, s, video_id, player_url):
        if player_url is None:
            raise ExtractorError('Cannot decrypt nsig without player_url')
        player_url = urljoin('https://www.youtube.com', player_url)
        _jsi, _name, func_code = self._extract_n_function_code(video_id, player_url)
        args, func_body = func_code
        snippet = 'console.log(function(%s) { %s }(%r));' % (", ".join(args), func_body, s)
        ret = JavaScriptCoreWrapper(self).execute(snippet, video_id=video_id)
        self._store_player_data_to_cache('nsig', player_url, func_code)
        return ret

    _video.YoutubeIE._decrypt_nsig = _decrypt_nsig_via_jsc


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


def extract(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None):
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT,
        "socket_timeout": socket_timeout, "extractor_retries": 2,
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


try:
    install_youtube_js_runtime()
except Exception:
    pass   # fail open: fall back to yt-dlp's default nsig path

try:
    import keraunos_youtube_pot  # noqa: F401  (registers the PO token provider on import)
except Exception:
    pass   # fail open: extraction proceeds without an on-device PO token provider
