"""On-device PO token provider for yt-dlp, backed by BotGuard run in JavaScriptCore.

Registered with yt-dlp's youtube.pot framework. The token-minting flow (BotGuard VM
-> integrity token -> mint) is implemented in _real_request_pot; on any failure it
raises PoTokenProviderRejectedRequest so extraction degrades to "no PO token" rather
than erroring hard.

Note: PROVIDER_NAME is a classproperty computed from the class name minus the "PTP"
suffix, yielding "KeraunosPoTokenProvider". It is not set explicitly here.
"""
from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenProvider,
    PoTokenProviderRejectedRequest,
    PoTokenResponse,
    register_provider,
)


@register_provider
class KeraunosPoTokenProviderPTP(PoTokenProvider):
    PROVIDER_VERSION = "0.1.0"
    BUG_REPORT_LOCATION = "https://github.com/lilikazine/Keraunos/issues"
    _SUPPORTED_CLIENTS = ("web", "web_safari", "mweb", "tv", "web_embedded")

    def is_available(self) -> bool:
        return True

    def _real_request_pot(self, request) -> PoTokenResponse:
        # Filled in by Task 9. Until then, reject so yt-dlp proceeds without a PO token.
        raise PoTokenProviderRejectedRequest("Keraunos PO token minting not yet implemented")
