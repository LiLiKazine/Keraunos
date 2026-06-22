"""On-device YouTube JS-challenge (n/sig) provider for yt-dlp, backed by JavaScriptCore.

yt-dlp (2025.11+) solves YouTube's n/sig challenges with its EJS framework: a vendored
solver bundle (yt-dlp-ejs) is run in a JS runtime. The built-in runtimes (deno/node/bun)
shell out to a binary, which the embedded interpreter can't do. This provider runs the
SAME self-contained solver script in the app's in-process JavaScriptCore
(keraunos_native.eval_js) — so n/sig resolves on-device with no subprocess.

Replaces the pre-2025.11 monkeypatch of YoutubeIE._decrypt_nsig: those hooks were
removed when yt-dlp moved challenge solving into the EJS / JsChallengeProvider framework.
EJSBaseJCP does all the work (load player + solver scripts, build a self-contained
`console.log(JSON.stringify(jsc(...)))` script, parse the JSON result); a subclass only
supplies a JS runtime and an availability check.
"""
import keraunos_extract

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError,
    register_preference,
    register_provider,
)

# Solving the EJS bundle over several challenges in JSC is heavier than a bare nsig
# call; keep this under the Swift-side and extraction watchdogs so a wedged eval still
# surfaces as an error rather than hanging.
_TIMEOUT_MS = 10_000


@register_provider
class KeraunosJavaScriptCoreJCP(EJSBaseJCP):
    PROVIDER_NAME = "javascriptcore"
    PROVIDER_VERSION = "0.1.0"
    BUG_REPORT_LOCATION = "https://github.com/lilikazine/Keraunos/issues"
    JS_RUNTIME_NAME = "JavaScriptCore"

    def is_available(self) -> bool:
        # In-process JSC is NOT a registered external-binary runtime, so the base's
        # runtime_info gate would always fail us — bypass it. Available = JSC reachable
        # AND the solver scripts loaded (self._available flips False on a script-load miss).
        return self._jsc_reachable() and self._available

    @staticmethod
    def _jsc_reachable() -> bool:
        if keraunos_extract._JS_EVALUATOR is not None:   # test seam
            return True
        try:
            import keraunos_native  # noqa: F401  (present only in the running app)
            return True
        except Exception:
            return False

    def _run_js_runtime(self, stdin: str, /) -> str:
        # `stdin` is a complete script (solver lib + core + a single
        # `console.log(JSON.stringify(jsc(...)))`); JSC evals it and returns that log.
        out = keraunos_extract._eval_js(stdin, _TIMEOUT_MS)
        sentinel = "__KERAUNOS_JS_ERROR__"
        if out.startswith(sentinel):
            raise JsChallengeProviderError(f"JavaScriptCore eval failed: {out[len(sentinel):]}")
        return out.strip()


@register_preference(KeraunosJavaScriptCoreJCP)
def _prefer_javascriptcore(provider, requests) -> int:
    # Prefer our in-process runtime; the binary-backed builtins (deno/node/bun) aren't
    # available on-device anyway.
    return 1000
