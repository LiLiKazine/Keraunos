import json
import sys
import time
import socket
import threading
import http.server
import functools
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))
import keraunos_extract  # noqa: E402


def _serve(directory, ready):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    ready.append(httpd)
    httpd.serve_forever()


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
    assert out["error_kind"] == "network"


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
