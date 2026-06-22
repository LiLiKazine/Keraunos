"""Keraunos extraction bridge.

Resolves a page URL to either a single progressive (already-muxed) file or a
separate video+audio pair for native merging, using yt-dlp WITHOUT downloading
and WITHOUT ffmpeg. Restricts adaptive selection to AVFoundation-muxable codecs
(HEVC/H.264 video + AAC audio). Always returns a JSON string; never raises.
"""
import json
import os
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
            import sys
            print(f"[keraunos-nsig] JavaScriptCore eval failed: {out[len('__KERAUNOS_JS_ERROR__'):]}", file=sys.stderr)
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


def _extract_impl(url, socket_timeout, cookiefile):
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT,
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
        if "unable to download" in msg or "timed out" in msg or "connection" in msg:
            # Extraction-side network failure. The download half (native URLSession,
            # Swift Downloader) emits download_network — keeping them distinct lets a
            # local failure log attribute which side broke without telemetry.
            return _err("extract_network", str(e))
        return _err("unsupported", str(e))
    except Exception as e:  # never raise into the bridge
        return _err("runtime", str(e))


def extract(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None, overall_timeout=_OVERALL_TIMEOUT):
    """Runs _extract_impl under an overall wall-clock bound. If it exceeds
    overall_timeout, returns a timeout error and abandons the worker thread (it keeps
    running until it finishes; the next extraction is serialized by the caller)."""
    box = {}

    def _work():
        try:
            box["result"] = _extract_impl(url, socket_timeout, cookiefile)
        except Exception as e:  # _extract_impl shouldn't raise, but never let the thread die silently
            box["result"] = _err("runtime", str(e))

    worker = threading.Thread(target=_work, daemon=True)
    worker.start()
    worker.join(overall_timeout)
    if worker.is_alive():
        return _err("timeout", f"extraction exceeded {overall_timeout}s")
    return box.get("result", _err("runtime", "extraction produced no result"))


try:
    install_youtube_js_runtime()
except Exception:
    pass   # fail open: fall back to yt-dlp's default nsig path

try:
    import keraunos_youtube_pot  # noqa: F401  (registers the PO token provider on import)
except Exception:
    pass   # fail open: extraction proceeds without an on-device PO token provider
