import json
import sys
import time
import socket
import threading
import http.server
import functools
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
APP_PACKAGES = Path(__file__).resolve().parents[1] / "PythonResources" / "app_packages"
sys.path.insert(0, str(APP))
sys.path.insert(0, str(APP_PACKAGES))
import keraunos_extract  # noqa: E402
from yt_dlp import YoutubeDL  # noqa: E402


def _select(formats):
    """Run the production _FORMAT selector over raw format dicts (no network) and
    return the list of selected top-level formats. Mirrors how yt-dlp picks formats
    inside extract(); lets us unit-test the selector against site-shaped fixtures."""
    ydl = YoutubeDL({"quiet": True, "simulate": True, "no_warnings": True})
    selector = ydl.build_format_selector(keraunos_extract._FORMAT)
    return list(selector({"formats": formats, "incomplete_formats": {}}))


# --- Format-selector: bare-codec admission (Phase 1) -----------------------------
# RedNote (xiaohongshu.py) and Reddit (reddit.py) label their clean, AVFoundation-
# muxable H.264/AAC streams with BARE codec names (h264 / aac) rather than the
# fourcc forms (avc1 / mp4a). The original selector matched only the fourcc forms,
# so these progressive/pairable streams were silently dropped to needs_ffmpeg.

def test_selector_admits_bare_codec_progressive_without_ext():
    # RedNote: progressive muxed file, bare h264/aac, URL carries no extension so
    # the trailing best[ext=mp4] fallback can't rescue it — only codec admission can.
    picked = _select([{
        "format_id": "xhs", "url": "https://sns-video.xhscdn.com/abc", "protocol": "https",
        "vcodec": "h264", "acodec": "aac", "width": 1280, "height": 720, "tbr": 1500,
    }])
    assert [f.get("format_id") for f in picked] == ["xhs"]
    # Single progressive file: no separate video+audio request.
    assert "requested_formats" not in picked[0]


def test_selector_pairs_reddit_videoonly_h264_with_aac_audio():
    # Reddit fallback_url is a complete video-only H.264 mp4 (acodec none); audio is
    # a separate complete AAC stream. The selector must pair them as bestvideo+bestaudio.
    picked = _select([
        {"format_id": "fallback", "url": "https://v.redd.it/x/DASH_720.mp4",
         "protocol": "https", "vcodec": "h264", "acodec": "none", "ext": "mp4",
         "width": 1280, "height": 720, "tbr": 1500},
        {"format_id": "dash-audio", "url": "https://v.redd.it/x/DASH_AUDIO_128.mp4",
         "protocol": "https", "vcodec": "none", "acodec": "aac", "ext": "m4a", "tbr": 128},
    ])
    assert len(picked) == 1
    reqs = picked[0].get("requested_formats")
    assert reqs is not None and len(reqs) == 2
    assert {f["format_id"] for f in reqs} == {"fallback", "dash-audio"}


def test_selector_admits_bare_hevc():
    # HEVC labelled bare (hevc / h265) must also pass — same Photos-muxable family.
    picked = _select([{
        "format_id": "hevc-prog", "url": "https://x/v.mp4", "protocol": "https",
        "vcodec": "hevc", "acodec": "aac", "ext": "mp4", "height": 1080, "tbr": 4000,
    }])
    assert [f.get("format_id") for f in picked] == ["hevc-prog"]


def test_selector_still_picks_fourcc_progressive():
    # Regression guard: the fourcc forms that already worked must keep working.
    picked = _select([{
        "format_id": "yt", "url": "https://x/v.mp4", "protocol": "https",
        "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2", "ext": "mp4",
        "height": 1080, "tbr": 3000,
    }])
    assert [f.get("format_id") for f in picked] == ["yt"]


def test_selector_rejects_av1_vp9_opus():
    # Photos-playability guarantee: VP9/AV1 video and Opus audio are NOT AVFoundation-
    # muxable, so the default selector must still reject them (they go to Phase 4/libav,
    # not the AVFoundation path). Video-only/audio-only means best[ext=mp4] can't grab them.
    picked = _select([
        {"format_id": "av1", "url": "https://x/v.mp4", "protocol": "https",
         "vcodec": "av01.0.08M.08", "acodec": "none", "ext": "mp4", "height": 2160, "tbr": 12000},
        {"format_id": "vp9", "url": "https://x/v.webm", "protocol": "https",
         "vcodec": "vp9", "acodec": "none", "ext": "webm", "height": 2160, "tbr": 11000},
        {"format_id": "opus", "url": "https://x/a.webm", "protocol": "https",
         "vcodec": "none", "acodec": "opus", "ext": "webm", "tbr": 160},
    ])
    assert picked == []


def _serve(directory, ready):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    ready.append(httpd)
    httpd.serve_forever()


# --- Progressive guard: reject explicit-"none" codec single files -----------------
# A single resolved format can legitimately carry both tracks (progressive muxed) OR
# carry only one (a video-only/audio-only stream the selector's trailing fallback
# happened to grab). Emitting a progressive payload for the latter saves a silent,
# audio-less (or video-less) file and reports success — the worst failure for a
# hand-run tool. The guard rejects ONLY the explicit string "none"; None/missing is
# the legitimate already-muxed direct-file path (codecs unprobed under skip_download).

def test_videoonly_progressive_with_explicit_none_audio_is_needs_ffmpeg():
    # Video-only mp4 (acodec literally "none") with a direct url — emitting this
    # progressive would save a silent file and report success.
    info = {
        "title": "Clip", "ext": "mp4", "url": "https://x.test/v.mp4",
        "vcodec": "avc1.4d401e", "acodec": "none",
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.mp4"))
    assert out["ok"] is False
    assert out["error_kind"] == "needs_ffmpeg"


def test_audioonly_progressive_with_explicit_none_video_is_needs_ffmpeg():
    # Audio-only stream (vcodec literally "none") with a direct url — a video-less file.
    info = {
        "title": "Clip", "ext": "m4a", "url": "https://x.test/a.m4a",
        "vcodec": "none", "acodec": "mp4a.40.2",
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.m4a"))
    assert out["ok"] is False
    assert out["error_kind"] == "needs_ffmpeg"


def test_directfile_progressive_with_unprobed_codecs_still_succeeds():
    # Invariant guard: the M1 already-muxed direct-file path resolves formats yt-dlp
    # can't probe under skip_download, so vcodec/acodec are MISSING (or None). That
    # progressive payload is correct and must keep working — the guard must trigger
    # ONLY on the explicit string "none", never on None/missing.
    info = {
        "title": "Clip", "ext": "mp4", "url": "https://x.test/v.mp4",
        "http_headers": {"User-Agent": "yt"},
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.mp4"))
    assert out["ok"] is True
    assert out["kind"] == "progressive"


# --- Format-selector regression fixtures (no network) ----------------------------

def test_selector_videoonly_mp4_with_none_audio():
    # A lone video-only mp4 (acodec "none"). yt-dlp's `best` (the trailing
    # best[protocol^=http][ext=mp4] fallback) treats acodec "none" as NOT a complete
    # format, so it does NOT pick it — the selector returns [] here. So at the SELECTOR
    # layer this particular case is already safe. The _payload_for_info "none" guard is
    # still the real safety net: it catches any single format with an explicit-"none"
    # track that reaches _payload_for_info via a different path (e.g. an extractor that
    # set info["url"] directly), where the selector never had a chance to reject it.
    picked = _select([{
        "format_id": "vonly", "url": "https://x/v.mp4", "protocol": "https",
        "vcodec": "avc1.4d401e", "acodec": "none", "ext": "mp4",
        "height": 1080, "tbr": 3000,
    }])
    assert [f.get("format_id") for f in picked] == []


def test_selector_tiebreaks_same_height_by_tbr():
    # Two muxable progressive formats, same height, different tbr → best[] picks the
    # higher-bitrate one.
    picked = _select([
        {"format_id": "lo", "url": "https://x/lo.mp4", "protocol": "https",
         "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2", "ext": "mp4",
         "height": 720, "tbr": 1000},
        {"format_id": "hi", "url": "https://x/hi.mp4", "protocol": "https",
         "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2", "ext": "mp4",
         "height": 720, "tbr": 2500},
    ])
    assert [f.get("format_id") for f in picked] == ["hi"]


def test_selector_tolerates_missing_height_and_tbr():
    # A degenerate format (height None, no tbr) mixed with a valid muxable progressive:
    # the selector must not crash and must pick the valid one.
    picked = _select([
        {"format_id": "junk", "url": "https://x/j.mp4", "protocol": "https",
         "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2", "ext": "mp4",
         "height": None},
        {"format_id": "good", "url": "https://x/g.mp4", "protocol": "https",
         "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2", "ext": "mp4",
         "height": 1080, "tbr": 3000},
    ])
    assert [f.get("format_id") for f in picked] == ["good"]


def test_progressive_payload_shape():
    info = {
        "title": "Clip", "ext": "mp4", "url": "https://x.test/v.mp4",
        "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2",
        "http_headers": {"User-Agent": "yt"},
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.mp4"))
    assert out["ok"] is True
    assert out["kind"] == "progressive"
    assert out["media"]["url"] == "https://x.test/v.mp4"
    assert out["media"]["headers"]["User-Agent"] == "yt"
    assert out["media"]["ext"] == "mp4"


def test_adaptive_payload_shape():
    info = {
        "title": "Clip", "ext": "mp4",
        "requested_formats": [
            {"url": "https://x.test/v.m4v", "vcodec": "hvc1", "acodec": "none",
             "ext": "mp4", "http_headers": {"User-Agent": "yt"}},
            {"url": "https://x.test/a.m4a", "vcodec": "none", "acodec": "mp4a.40.2",
             "ext": "m4a", "http_headers": {"Referer": "r"}},
        ],
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.mp4"))
    assert out["kind"] == "adaptive"
    assert out["video"]["url"] == "https://x.test/v.m4v"
    assert out["video"]["vcodec"] == "hvc1"
    assert out["audio"]["url"] == "https://x.test/a.m4a"
    assert out["audio"]["headers"]["Referer"] == "r"


def test_extraction_times_out_instead_of_hanging():
    # Server accepts the connection but never sends a response, so the read
    # stalls — the real-world "stuck on Resolving…" case (a bot-gated/slow host).
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    port = srv.getsockname()[1]

    def _hold():
        conns = []
        try:
            while True:
                conn, _ = srv.accept()
                conns.append(conn)  # hold open, never reply
        except OSError:
            pass

    threading.Thread(target=_hold, daemon=True).start()

    result = {}

    def _run():
        result["out"] = keraunos_extract.extract(
            f"http://127.0.0.1:{port}/x", socket_timeout=1)

    worker = threading.Thread(target=_run, daemon=True)
    worker.start()
    worker.join(timeout=25)
    srv.close()

    assert not worker.is_alive(), "extraction hung past the socket timeout"
    out = json.loads(result["out"])
    assert out["ok"] is False
    # Extraction-side network failure: distinct kind from a download-side one so a
    # local failure log can tell which half broke (Phase 3).
    assert out["error_kind"] == "extract_network"


def test_resolves_local_progressive_file(tmp_path):
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]
    out = json.loads(keraunos_extract.extract(f"http://127.0.0.1:{port}/sample.mp4"))
    ready[0].shutdown()
    assert out["ok"] is True
    assert out["kind"] == "progressive"
    assert out["media"]["url"].endswith("/sample.mp4")


def test_cookiefile_present_is_accepted(tmp_path):
    # A header-only cookies.txt is valid and must not break extraction.
    cookies = tmp_path / "cookies.txt"
    cookies.write_text("# Netscape HTTP Cookie File\n")
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]
    out = json.loads(keraunos_extract.extract(
        f"http://127.0.0.1:{port}/sample.mp4", cookiefile=str(cookies)))
    ready[0].shutdown()
    assert out["ok"] is True
    assert out["kind"] == "progressive"


def test_missing_cookiefile_path_does_not_crash(tmp_path):
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]
    out = json.loads(keraunos_extract.extract(
        f"http://127.0.0.1:{port}/sample.mp4", cookiefile="/no/such/cookies.txt"))
    ready[0].shutdown()
    assert out["ok"] is True   # extraction still works; bad path is ignored


def test_overall_timeout_bounds_a_nonresponsive_host():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0)); srv.listen(8)
    port = srv.getsockname()[1]

    def _hold():
        conns = []
        try:
            while True:
                conn, _ = srv.accept(); conns.append(conn)
        except OSError:
            pass
    threading.Thread(target=_hold, daemon=True).start()

    t0 = time.time()
    # Long socket_timeout so ONLY the overall watchdog can bound this.
    out = json.loads(keraunos_extract.extract(
        f"http://127.0.0.1:{port}/x", socket_timeout=30, overall_timeout=1))
    elapsed = time.time() - t0
    srv.close()
    assert out["ok"] is False
    assert out["error_kind"] == "timeout"
    assert elapsed < 10, f"watchdog did not bound the call (took {elapsed:.1f}s)"


def test_po_token_error_maps_to_requires_auth(monkeypatch):
    # yt-dlp emits "... missing a GVS PO Token ..." for bot-gated videos.
    # extract() lowercases the message and checks _AUTH_HINTS — verify the
    # mapping fires and the caller gets requires_auth instead of unsupported.
    from yt_dlp.utils import DownloadError
    monkeypatch.setattr(
        keraunos_extract.yt_dlp.YoutubeDL,
        "extract_info",
        lambda *a, **kw: (_ for _ in ()).throw(
            DownloadError("Some web client https formats have been skipped as they are missing a GVS PO Token.")
        ),
    )
    out = json.loads(keraunos_extract.extract("https://www.youtube.com/watch?v=abc123"))
    assert out["ok"] is False
    assert out["error_kind"] == "requires_auth"


def test_bot_gate_http_statuses_map_to_requires_auth(monkeypatch):
    # Bilibili (412 Precondition Failed) and Reddit (403 Blocked) are anti-bot/forbidden
    # gates whose actionable fix is sign-in/cookies — they must surface the "Sign in"
    # path, not the generic "check your connection" network bucket, even though their
    # messages contain "unable to download".
    from yt_dlp.utils import DownloadError
    for status in ("HTTP Error 412: Precondition Failed",
                   "HTTP Error 403: Blocked",
                   "HTTP Error 401: Unauthorized"):
        monkeypatch.setattr(
            keraunos_extract.yt_dlp.YoutubeDL, "extract_info",
            lambda *a, _m=status, **kw: (_ for _ in ()).throw(
                DownloadError(f"ERROR: [generic] Unable to download webpage: {_m}")),
        )
        out = json.loads(keraunos_extract.extract("https://b23.tv/x"))
        assert out["error_kind"] == "requires_auth", status


def test_plain_connection_failure_stays_extract_network(monkeypatch):
    # A genuine transport failure (no HTTP gate status) must remain a retryable network error.
    from yt_dlp.utils import DownloadError
    monkeypatch.setattr(
        keraunos_extract.yt_dlp.YoutubeDL, "extract_info",
        lambda *a, **kw: (_ for _ in ()).throw(
            DownloadError("ERROR: Unable to download webpage: <urlopen error [Errno 61] Connection refused>")),
    )
    out = json.loads(keraunos_extract.extract("https://x.test/v"))
    assert out["error_kind"] == "extract_network"


def test_rate_limit_maps_to_rate_limited(monkeypatch):
    # HTTP 429 / "too many requests" is a rate-limit, NOT a generic transport failure.
    # The message ALSO contains "unable to download", so this also proves rate_limited
    # is checked before the network bucket (which would otherwise swallow it).
    from yt_dlp.utils import DownloadError
    monkeypatch.setattr(
        keraunos_extract.yt_dlp.YoutubeDL, "extract_info",
        lambda *a, **kw: (_ for _ in ()).throw(
            DownloadError("ERROR: Unable to download webpage: HTTP Error 429: Too Many Requests")),
    )
    out = json.loads(keraunos_extract.extract("https://x.test/v"))
    assert out["ok"] is False
    assert out["error_kind"] == "rate_limited"


def test_unavailable_content_maps_to_unavailable(monkeypatch):
    # Removed / no-longer-available / geo-blocked videos are a distinct content state,
    # not the generic "unsupported" tool-bug bucket.
    from yt_dlp.utils import DownloadError
    for message in (
        "ERROR: [youtube] xxx: Video unavailable",
        "ERROR: This video is no longer available",
        "ERROR: [youtube] xxx: The uploader has not made this video available in your country.",
    ):
        monkeypatch.setattr(
            keraunos_extract.yt_dlp.YoutubeDL, "extract_info",
            lambda *a, _m=message, **kw: (_ for _ in ()).throw(DownloadError(_m)),
        )
        out = json.loads(keraunos_extract.extract("https://x.test/v"))
        assert out["error_kind"] == "unavailable", message


def test_private_with_signin_still_requires_auth(monkeypatch):
    # Ordering guard: a private video whose message says "Sign in" must route to
    # requires_auth (auth check wins over the unavailable hints).
    from yt_dlp.utils import DownloadError
    monkeypatch.setattr(
        keraunos_extract.yt_dlp.YoutubeDL, "extract_info",
        lambda *a, **kw: (_ for _ in ()).throw(DownloadError(
            "ERROR: [youtube] xxx: Private video. Sign in if you've been granted access to this video")),
    )
    out = json.loads(keraunos_extract.extract("https://x.test/v"))
    assert out["error_kind"] == "requires_auth"


def test_instagram_login_required_maps_to_requires_auth(monkeypatch):
    # Phase 2: confirm the cookie path's trigger fires for Instagram. The IG extractor
    # signals "log in" via raise_login_required(), which appends yt-dlp's _login_hint
    # ("Use --cookies ... how to manually pass cookies"). extract() must map that to
    # requires_auth so the UI surfaces the "Sign in" button (which drives LoginWebView
    # -> cookie capture -> cookiefile). This is the one fragile link in the otherwise
    # already-wired flow, so it gets a regression guard. The string below is exactly
    # what raise_login_required('Requested content ... login required') produces.
    from yt_dlp.utils import DownloadError
    ig_message = (
        "Requested content is not available, rate-limit reached or login required. "
        "Use --cookies, --cookies-from-browser, --username and --password, --netrc-cmd, "
        "or --netrc (instagram) to provide account credentials. See  "
        "https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  "
        "for how to manually pass cookies"
    )
    monkeypatch.setattr(
        keraunos_extract.yt_dlp.YoutubeDL,
        "extract_info",
        lambda *a, **kw: (_ for _ in ()).throw(DownloadError(ig_message)),
    )
    out = json.loads(keraunos_extract.extract("https://www.instagram.com/reel/ABC123/"))
    assert out["ok"] is False
    assert out["error_kind"] == "requires_auth"
