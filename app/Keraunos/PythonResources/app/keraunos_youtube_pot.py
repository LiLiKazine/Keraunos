"""On-device PO token provider for yt-dlp, backed by BotGuard run in JavaScriptCore.

Registered with yt-dlp's youtube.pot framework. The token-minting flow (BotGuard VM
-> integrity token -> mint) is implemented in _real_request_pot; on any failure it
raises PoTokenProviderRejectedRequest so extraction degrades to "no PO token" rather
than erroring hard.

Note: PROVIDER_NAME is a classproperty computed from the class name minus the "PTP"
suffix, yielding "KeraunosPoTokenProvider". It is not set explicitly here.
"""
import json
from pathlib import Path

from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenProvider,
    PoTokenProviderRejectedRequest,
    PoTokenResponse,
    register_provider,
)

_BUNDLE_CACHE = None


def _bundle_js():
    global _BUNDLE_CACHE
    if _BUNDLE_CACHE is None:
        _BUNDLE_CACHE = (Path(__file__).resolve().parent / "bgutils" / "bgutils.bundle.js").read_text()
    return _BUNDLE_CACHE


def _cold_start_snippet(identifier):
    # Loading the bundle defines globalThis.BG; generateColdStartToken is synchronous.
    return _bundle_js() + (
        "\nconsole.log(globalThis.BG.PoToken.generateColdStartToken(%s));" % json.dumps(identifier)
    )


@register_provider
class KeraunosPoTokenProviderPTP(PoTokenProvider):
    PROVIDER_VERSION = "0.1.0"
    BUG_REPORT_LOCATION = "https://github.com/lilikazine/Keraunos/issues"
    _SUPPORTED_CLIENTS = ("web", "web_safari", "mweb", "tv", "web_embedded")

    def is_available(self) -> bool:
        return True

    def _real_request_pot(self, request) -> PoTokenResponse:
        # Tier 1: synchronous cold-start token (no BotGuard, no network). Works while
        # YouTube's StreamProtectionStatus is 2; full BotGuard attestation is a later tier.
        identifier = request.visitor_data or request.data_sync_id
        if not identifier:
            raise PoTokenProviderRejectedRequest(
                "no visitor_data/data_sync_id to bind a cold-start PO token")
        import keraunos_extract  # lazy: avoid circular import
        token = keraunos_extract._eval_js(_cold_start_snippet(identifier), 5000)
        if not token or token.startswith("__KERAUNOS_JS_ERROR__"):
            raise PoTokenProviderRejectedRequest(
                f"cold-start PO token generation failed: {token!r}")
        return PoTokenResponse(po_token=token)
