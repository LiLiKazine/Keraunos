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


def test_cold_start_is_used_when_full_flow_fails():
    """Ladder fallback: when the full BotGuard rung fails (here: the WAA HTTP call
    raises), the provider degrades to the synchronous cold-start token. Bypasses
    __init__ via object.__new__ and fakes both seams to stay offline and deterministic."""
    import types
    import keraunos_youtube_pot as m
    import keraunos_extract
    from yt_dlp.extractor.youtube.pot.provider import PoTokenResponse

    # Bypass __init__: no logger/ie needed for this path.
    prov = object.__new__(m.KeraunosPoTokenProviderPTP)

    # Minimal fake request object with the two content-binding fields.
    req = types.SimpleNamespace(visitor_data="VISITOR_123", data_sync_id=None)

    def _boom(endpoint, payload):
        raise RuntimeError("no network in test")

    original_eval = keraunos_extract._JS_EVALUATOR
    original_post = m._waa_post
    try:
        m._waa_post = _boom   # force the full BotGuard rung to fail fast
        keraunos_extract.set_js_evaluator(
            lambda script, t: "COLDTOKEN" if "generateColdStartToken" in script else "")
        resp = prov._real_request_pot(req)
    finally:
        keraunos_extract.set_js_evaluator(original_eval)
        m._waa_post = original_post

    assert isinstance(resp, PoTokenResponse)
    assert resp.po_token == "COLDTOKEN"


def test_full_flow_posts_correct_payloads_and_returns_minted_token():
    """Approach A: Python does the two WAA HTTP calls between two JS evals. Fakes both
    seams (_waa_post and _eval_js) and asserts the wire payloads and that the minted
    token is returned — without a device, network, or the native bridge."""
    import types
    import keraunos_youtube_pot as m
    import keraunos_extract
    from yt_dlp.extractor.youtube.pot.provider import PoTokenResponse

    prov = object.__new__(m.KeraunosPoTokenProviderPTP)
    req = types.SimpleNamespace(visitor_data="VISITOR_123", data_sync_id=None)

    posts = []

    def fake_waa_post(endpoint, payload):
        posts.append((endpoint, payload))
        if endpoint == "Create":
            return ["RAW_CHALLENGE"]
        return ["INTEGRITY_TOKEN", 3600, 0, "fallback"]   # GenerateIT response array

    def fake_eval(script, _timeout):
        # Discriminate by the per-call data each eval carries (the bundle source itself
        # mentions both method names, so method-name substrings can't tell J1 from J2).
        if "RAW_CHALLENGE" in script:
            return "BOTGUARD_RESPONSE"      # J1 snapshot received the challenge
        if "INTEGRITY_TOKEN" in script:
            return "PO_TOKEN_123"           # J2 mint received the integrity token
        return ""

    original_eval = keraunos_extract._JS_EVALUATOR
    original_post = m._waa_post
    try:
        m._waa_post = fake_waa_post
        keraunos_extract.set_js_evaluator(fake_eval)
        resp = prov._real_request_pot(req)
    finally:
        keraunos_extract.set_js_evaluator(original_eval)
        m._waa_post = original_post

    assert isinstance(resp, PoTokenResponse)
    assert resp.po_token == "PO_TOKEN_123"
    assert posts[0] == ("Create", ["O43z0dpjhgX20SCx4KAo"])
    assert posts[1] == ("GenerateIT", ["O43z0dpjhgX20SCx4KAo", "BOTGUARD_RESPONSE"])
