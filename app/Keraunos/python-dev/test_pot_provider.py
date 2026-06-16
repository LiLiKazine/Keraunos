import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))


def test_provider_class_is_well_formed():
    import keraunos_youtube_pot as m
    from yt_dlp.extractor.youtube.pot.provider import PoTokenProvider
    assert issubclass(m.KeraunosPoTokenProviderPTP, PoTokenProvider)
    assert m.KeraunosPoTokenProviderPTP.__name__.endswith("PTP")


def test_provider_registers_with_pot_framework():
    import keraunos_youtube_pot as m
    from yt_dlp.extractor.youtube.pot._registry import _pot_providers
    assert any(cls is m.KeraunosPoTokenProviderPTP for cls in _pot_providers.value.values())


def test_cold_start_snippet_includes_bundle_and_identifier():
    import keraunos_youtube_pot as m
    snippet = m._cold_start_snippet("VISITOR_123")
    assert "globalThis.BG.PoToken.generateColdStartToken" in snippet
    assert '"VISITOR_123"' in snippet          # JSON-encoded identifier
    assert "globalThis.BG" in snippet          # bundle present (defines BG)


def test_cold_start_returns_po_token_response():
    """Wiring test: uses object.__new__ to bypass __init__ (avoids needing a real
    IEContentProviderLogger implementation), and monkeypatches keraunos_extract._eval_js
    directly instead of going through set_js_evaluator, to avoid polluting global state."""
    import types
    import keraunos_youtube_pot as m
    import keraunos_extract
    from yt_dlp.extractor.youtube.pot.provider import PoTokenResponse

    # Bypass __init__: no logger/ie needed for this path.
    prov = object.__new__(m.KeraunosPoTokenProviderPTP)

    # Minimal fake request object with the two content-binding fields.
    req = types.SimpleNamespace(visitor_data="VISITOR_123", data_sync_id=None)

    # Inject a fake JS evaluator that returns a token when the cold-start call is present.
    original = keraunos_extract._JS_EVALUATOR
    try:
        keraunos_extract.set_js_evaluator(
            lambda script, t: "COLDTOKEN" if "generateColdStartToken" in script else "")
        resp = prov._real_request_pot(req)
    finally:
        keraunos_extract.set_js_evaluator(original)

    assert isinstance(resp, PoTokenResponse)
    assert resp.po_token == "COLDTOKEN"
