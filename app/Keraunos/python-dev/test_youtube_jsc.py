import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1] / "PythonResources"
# Resolve against the VENDORED packages (what actually ships), not the venv copy.
sys.path.insert(0, str(ROOT / "app_packages"))
sys.path.insert(0, str(ROOT / "app"))
import keraunos_extract  # noqa: E402
import keraunos_youtube_jsc as jsc  # noqa: E402  (importing also self-registers the provider)
from yt_dlp.extractor.youtube.jsc.provider import JsChallengeProviderError  # noqa: E402
from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers  # noqa: E402


def _provider_instance():
    # Bypass EJSBaseJCP.__init__ (it needs a real extractor); we only exercise the two
    # methods this provider adds on top of the framework.
    return object.__new__(jsc.KeraunosJavaScriptCoreJCP)


def test_provider_is_registered_in_the_jsc_framework():
    # The director discovers providers from this registry, so registration is the wiring.
    assert jsc.KeraunosJavaScriptCoreJCP in _jsc_providers.value.values()


def test_jsc_reachable_via_injected_evaluator():
    keraunos_extract.set_js_evaluator(lambda script, timeout_ms: "x")
    try:
        assert jsc.KeraunosJavaScriptCoreJCP._jsc_reachable() is True
    finally:
        keraunos_extract.set_js_evaluator(None)


def test_run_js_runtime_returns_stripped_output():
    calls = []
    keraunos_extract.set_js_evaluator(lambda script, timeout_ms: calls.append(script) or '  {"ok":1}  ')
    try:
        out = _provider_instance()._run_js_runtime("console.log(JSON.stringify(jsc({})));")
        assert out == '{"ok":1}'                      # stripped, ready for json.loads
        assert calls and "jsc(" in calls[0]           # the self-contained solver script ran
    finally:
        keraunos_extract.set_js_evaluator(None)


def test_run_js_runtime_raises_on_error_sentinel():
    keraunos_extract.set_js_evaluator(lambda script, timeout_ms: "__KERAUNOS_JS_ERROR__boom")
    try:
        with pytest.raises(JsChallengeProviderError):
            _provider_instance()._run_js_runtime("whatever")
    finally:
        keraunos_extract.set_js_evaluator(None)
