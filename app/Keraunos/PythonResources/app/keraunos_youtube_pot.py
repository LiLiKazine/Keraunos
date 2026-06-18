"""On-device PO token provider for yt-dlp, backed by BotGuard run in JavaScriptCore.

Registered with yt-dlp's youtube.pot framework. The token-minting flow (BotGuard VM
-> integrity token -> mint) is implemented in _real_request_pot; on any failure it
raises PoTokenProviderRejectedRequest so extraction degrades to "no PO token" rather
than erroring hard.

Note: PROVIDER_NAME is a classproperty computed from the class name minus the "PTP"
suffix, yielding "KeraunosPoTokenProvider". It is not set explicitly here.
"""
import json
import sys
import urllib.request
from pathlib import Path

from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenProvider,
    PoTokenProviderRejectedRequest,
    PoTokenResponse,
    register_provider,
)

# BotGuard / WAA attestation. These endpoints authenticate via x-goog-api-key only
# (no YouTube cookies), mirroring bgutils-js getHeaders(). requestKey is the standard
# YouTube-web key. See the 2026-06-18 spec addendum for the full-flow rationale.
_REQUESTKEY = "O43z0dpjhgX20SCx4KAo"
_GOOG = "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa"
_GOOG_API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
_USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
              "AppleWebKit/537.36(KHTML, like Gecko)")

def _spike_log(msg):
    # Spike instrumentation: stderr reaches the Xcode debug console.
    print(f"[keraunos-pot] {msg}", file=sys.stderr)


_BUNDLE_CACHE = None


def _bundle_js():
    global _BUNDLE_CACHE
    if _BUNDLE_CACHE is None:
        _BUNDLE_CACHE = (Path(__file__).resolve().parent / "bgutils" / "bgutils.bundle.js").read_text()
    return _BUNDLE_CACHE


def _waa_post(endpoint, payload):
    """POST a protobuf-JSON array to a WAA endpoint ("Create"/"GenerateIT") and return
    the parsed JSON array. Tight timeout so two round-trips stay under the 30s watchdog."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{_GOOG}/{endpoint}", data=data, headers={
        "content-type": "application/json+protobuf",
        "x-goog-api-key": _GOOG_API_KEY,
        "x-user-agent": "grpc-web-javascript/0.1",
        "user-agent": _USER_AGENT,
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode())


def _snapshot_snippet(raw_challenge):
    # J1: parse challenge -> install the VM -> create the client -> SYNCHRONOUS snapshot.
    # Stash webPoSignalOutput (holds the VM minter-factory closure) in a global so J2 can
    # reuse it; the shared JSContext is long-lived so it survives to the next eval. Errors
    # are caught and printed as the sentinel — async-IIFE rejections don't set
    # context.exception, so the Swift-side exception check would otherwise miss them.
    return _bundle_js() + ("""
(async () => {
  const ch = globalThis.BG.Challenge.parseChallengeData(%s);
  (0, eval)(ch.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue);
  const bg = await globalThis.BG.BotGuardClient.create(
      { program: ch.program, globalName: ch.globalName, globalObj: globalThis });
  const sig = [];
  const botguardResponse = await bg.snapshotSynchronous({ webPoSignalOutput: sig });
  globalThis.__keraunos_sig = sig;
  console.log(botguardResponse);
})().catch(e => console.log("__KERAUNOS_JS_ERROR__" + (e && e.stack || e)));
""" % json.dumps(raw_challenge))


def _mint_snippet(integrity_response, identifier):
    # J2: rebuild integrityTokenData from the GenerateIT array (positional, per
    # bgutils-js webPoClient.generate) and mint against the stashed webPoSignalOutput.
    integrity_data = {
        "integrityToken": integrity_response[0],
        "estimatedTtlSecs": integrity_response[1] if len(integrity_response) > 1 else None,
        "mintRefreshThreshold": integrity_response[2] if len(integrity_response) > 2 else None,
        "websafeFallbackToken": integrity_response[3] if len(integrity_response) > 3 else None,
    }
    return _bundle_js() + ("""
(async () => {
  const minter = await globalThis.BG.WebPoMinter.create(%s, globalThis.__keraunos_sig);
  console.log(await minter.mintAsWebsafeString(%s));
})().catch(e => console.log("__KERAUNOS_JS_ERROR__" + (e && e.stack || e)));
""" % (json.dumps(integrity_data), json.dumps(identifier)))


def _full_botguard_token(identifier):
    """Full BotGuard flow (approach A): Create -> J1 snapshot -> GenerateIT -> J2 mint.
    Raises on any failure so the caller can fall back to a cold-start token."""
    import keraunos_extract  # lazy: reuse the JS eval seam
    _spike_log("full: POST Create")
    raw = _waa_post("Create", [_REQUESTKEY])
    _spike_log("full: J1 snapshot")
    botguard_response = keraunos_extract._eval_js(_snapshot_snippet(raw), 10000)
    if not botguard_response or botguard_response.startswith("__KERAUNOS_JS_ERROR__"):
        raise RuntimeError(f"snapshot failed: {botguard_response!r}")
    _spike_log("full: POST GenerateIT")
    integrity = _waa_post("GenerateIT", [_REQUESTKEY, botguard_response])
    _spike_log("full: J2 mint")
    token = keraunos_extract._eval_js(_mint_snippet(integrity, identifier), 10000)
    if not token or token.startswith("__KERAUNOS_JS_ERROR__"):
        raise RuntimeError(f"mint failed: {token!r}")
    _spike_log("full: done")
    return token


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
        # PO tokens bind to a visitor id or data-sync id (per bgutils-js); video_id is not
        # a valid identifier for either rung. Without one we cannot mint, so reject.
        identifier = request.visitor_data or request.data_sync_id
        if not identifier:
            _spike_log("rejected: no visitor_data/data_sync_id to bind a PO token")
            raise PoTokenProviderRejectedRequest(
                "no visitor_data/data_sync_id to bind a PO token")

        # Tier 2: full BotGuard attestation (Create -> snapshot -> GenerateIT -> mint).
        # Valid regardless of StreamProtectionStatus.
        try:
            token = _full_botguard_token(identifier)
            _spike_log(f"minted full BotGuard PO token (len={len(token)})")
            return PoTokenResponse(po_token=token)
        except Exception as e:
            _spike_log(f"full BotGuard flow failed, falling back to cold-start: {e}")

        # Tier 1: synchronous cold-start token (no BotGuard, no network). Only accepted by
        # YouTube while StreamProtectionStatus == 2; otherwise the video still fails, but
        # cleanly (no hang).
        import keraunos_extract  # lazy: avoid circular import
        token = keraunos_extract._eval_js(_cold_start_snippet(identifier), 5000)
        if token and not token.startswith("__KERAUNOS_JS_ERROR__"):
            _spike_log(f"minted cold-start PO token (len={len(token)})")
            return PoTokenResponse(po_token=token)

        _spike_log(f"rejected: full flow failed and cold-start produced {token!r}")
        raise PoTokenProviderRejectedRequest(f"PO token minting failed: {token!r}")
