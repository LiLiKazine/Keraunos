import json
import sys
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
