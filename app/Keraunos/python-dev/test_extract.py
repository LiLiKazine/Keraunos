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


def test_resolves_direct_progressive_file(tmp_path):
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]

    out = json.loads(keraunos_extract.extract(f"http://127.0.0.1:{port}/sample.mp4"))
    ready[0].shutdown()

    assert out["ok"] is True
    assert out["direct_url"].endswith("/sample.mp4")


def test_unsupported_url_returns_error_kind():
    out = json.loads(keraunos_extract.extract("https://invalid.invalid/nothing-here"))
    assert out["ok"] is False
    assert out["error_kind"] in {"unsupported", "network"}
