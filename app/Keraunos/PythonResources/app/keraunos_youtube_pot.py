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
    # The bundle is prepended and re-evaluated each call; that's safe because defining
    # globalThis.BG is idempotent and the library is side-effect-free after definition.
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
        # YouTube's StreamProtectionStatus is 2; when status != 2 the token won't be
        # accepted by YouTube and the video will still fail (degrades to no-token) —
        # full BotGuard attestation is Tier 2 and is not implemented here.
        # Cold-start tokens bind ONLY to a visitor id or data-sync id (per bgutils-js);
        # video_id is NOT a valid cold-start identifier (it's a full-BotGuard content
        # binding, Tier 2). If neither is present we cannot mint and must reject.
        identifier = request.visitor_data or request.data_sync_id
        if not identifier:
            self.logger.warning("Keraunos PO token: no visitor_data/data_sync_id to bind a cold-start token")
            raise PoTokenProviderRejectedRequest(
                "no visitor_data/data_sync_id to bind a cold-start PO token")
        import keraunos_extract  # lazy: avoid circular import
        token = keraunos_extract._eval_js(_cold_start_snippet(identifier), 5000)
        if token.startswith("__KERAUNOS_JS_ERROR__"):
            detail = token[len("__KERAUNOS_JS_ERROR__"):]
            self.logger.warning(f"Keraunos PO token: cold-start JS error: {detail}")
            raise PoTokenProviderRejectedRequest(f"cold-start JS error: {detail}")
        if not token:
            self.logger.warning("Keraunos PO token: cold-start produced an empty token")
            raise PoTokenProviderRejectedRequest("cold-start produced an empty token")
        return PoTokenResponse(po_token=token)
