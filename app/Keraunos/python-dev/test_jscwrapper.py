import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))
import keraunos_extract  # noqa: E402


def test_wrapper_calls_eval_backend_and_returns_output():
    calls = []
    keraunos_extract.set_js_evaluator(lambda script, timeout_ms: calls.append(script) or "  4321  ")
    w = keraunos_extract.JavaScriptCoreWrapper(extractor=None)
    out = w.execute("console.log(1234);", video_id="vid")
    assert out == "4321"          # stripped
    assert calls and "console.log" in calls[0]


def test_nsig_monkeypatch_targets_still_exist():
    # Drift guard: the symbols our monkeypatch reaches into must exist in the pinned
    # yt-dlp. If this fails after a yt-dlp bump, the nsig patch needs revisiting.
    from yt_dlp.extractor.youtube._video import YoutubeIE
    assert hasattr(YoutubeIE, "_decrypt_nsig")
    assert hasattr(YoutubeIE, "_extract_n_function_code")


def test_install_youtube_js_runtime_patches_decrypt_nsig():
    from yt_dlp.extractor.youtube._video import YoutubeIE
    original = YoutubeIE._decrypt_nsig
    keraunos_extract.install_youtube_js_runtime()
    assert YoutubeIE._decrypt_nsig is not original  # patched
