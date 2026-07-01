# Resolution Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick which resolution to download, per download, via a picker shown after resolving a link.

**Architecture:** Two-phase flow. Phase 1 (`listFormats`) runs one yt-dlp extraction and returns either the default `ResolvedMedia` (0–1 muxable heights → download now, no picker) or a menu of `FormatOption`s (2+ heights → show picker). Phase 2 (`resolve(_:option:)`) re-runs extraction constrained to the chosen format id, reusing the existing selector. The second extraction is the warm path (cached YouTube player/nsig/PoT).

**Tech Stack:** Swift 6 (SwiftUI, Observation, structured concurrency), Swift Testing, embedded CPython + yt-dlp, ObjC/C Python bridge.

## Global Constraints

- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **Swift Concurrency over GCD**; **actors/`@MainActor` over locks** for shared state.
- **AVFoundation-muxable codecs only** for adaptive selection: H.264/HEVC video + AAC audio. VP9/AV1/Opus are out of scope (not muxable on-device).
- **1080p is the practical ceiling** (YouTube >1080p is SABR-gated). Do not add >1080p handling.
- **Integration/extraction tests run against localhost fixtures only** — never real sites.
- **Pure-Swift units are written first (TDD).**
- Commit messages end with the repo's `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- KeraunosCore is an SPM package (`app/KeraunosCore`) tested with `swift test`; the app target (`Keraunos`) is tested with `xcodebuild … test`.

---

### Task 1: `FormatOption` value type

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/FormatOption.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/FormatOptionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct FormatOption: Equatable, Sendable` with stored `height: Int`, `codecLabel: String`, `approxBytes: Int64?`, `formatID: String`, `isAdaptive: Bool`, memberwise `public init(...)`, and computed `public var displayLabel: String`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/KeraunosCore/Tests/KeraunosCoreTests/FormatOptionTests.swift
import Testing
import Foundation
import KeraunosCore

struct FormatOptionTests {
    private func option(height: Int = 1080, codec: String = "H.264",
                        bytes: Int64? = nil, id: String = "137",
                        adaptive: Bool = true) -> FormatOption {
        FormatOption(height: height, codecLabel: codec, approxBytes: bytes,
                     formatID: id, isAdaptive: adaptive)
    }

    @Test func labelWithAllFields() {
        let bytes: Int64 = 47_185_920   // 45.0 MB (file-style)
        #expect(option(height: 1080, codec: "H.264", bytes: bytes).displayLabel
                == "1080p · H.264 · 45 MB")
    }

    @Test func labelDropsSizeWhenUnknown() {
        #expect(option(height: 720, codec: "HEVC", bytes: nil).displayLabel
                == "720p · HEVC")
    }

    @Test func labelDropsCodecWhenEmpty() {
        #expect(option(height: 360, codec: "", bytes: nil).displayLabel == "360p")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path app/KeraunosCore --filter FormatOptionTests`
Expected: FAIL — `cannot find 'FormatOption' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// app/KeraunosCore/Sources/KeraunosCore/FormatOption.swift
import Foundation

/// One user-selectable resolution from the picker. `formatID` is yt-dlp's format id,
/// replayed in phase 2 to re-select exactly this stream; `isAdaptive` marks a video-only
/// stream that must be paired with a separate audio track (vs. an already-muxed file).
public struct FormatOption: Equatable, Sendable {
    public let height: Int
    public let codecLabel: String
    public let approxBytes: Int64?
    public let formatID: String
    public let isAdaptive: Bool

    public init(height: Int, codecLabel: String, approxBytes: Int64?,
                formatID: String, isAdaptive: Bool) {
        self.height = height
        self.codecLabel = codecLabel
        self.approxBytes = approxBytes
        self.formatID = formatID
        self.isAdaptive = isAdaptive
    }

    /// Picker row text, e.g. "1080p · H.264 · 45 MB". Codec and size segments are
    /// dropped when unavailable so a bare "720p" is still shown.
    public var displayLabel: String {
        var parts = ["\(height)p"]
        if !codecLabel.isEmpty { parts.append(codecLabel) }
        if let approxBytes {
            parts.append(approxBytes.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path app/KeraunosCore --filter FormatOptionTests`
Expected: PASS (3 tests).

> Note: `.byteCount(style: .file)` renders `47_185_920` as `45 MB`. If your platform renders `45.0 MB`, update the Step 1 expectation to match the formatter output — the formatter is the source of truth, not the literal.

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/FormatOption.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/FormatOptionTests.swift
git commit -m "$(cat <<'EOF'
feat(core): FormatOption value type with displayLabel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `FormatListing` + decoder

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/FormatListing.swift`
- Modify: `app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift` (add `decodeListing` to `ExtractionDecoder`)
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/FormatListingDecodingTests.swift`

**Interfaces:**
- Consumes: `FormatOption` (Task 1); existing `ExtractionDecoder.decode(_:)`, `ResolvedMedia`, `KeraunosError`.
- Produces: `public enum FormatListing: Sendable { case ready(ResolvedMedia); case choices([FormatOption]) }` and `public static func decodeListing(_ data: Data) throws -> FormatListing` on `ExtractionDecoder`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/KeraunosCore/Tests/KeraunosCoreTests/FormatListingDecodingTests.swift
import Testing
import Foundation
import KeraunosCore

struct FormatListingDecodingTests {
    @Test func decodesChoices() throws {
        let json = #"""
        {"ok":true,"kind":"choices","options":[
          {"height":1080,"codec":"H.264","approx_bytes":47185920,"format_id":"137","adaptive":true},
          {"height":360,"codec":"H.264","approx_bytes":null,"format_id":"18","adaptive":false}
        ]}
        """#
        guard case let .choices(options) = try ExtractionDecoder.decodeListing(Data(json.utf8)) else {
            Issue.record("expected choices"); return
        }
        #expect(options.count == 2)
        #expect(options[0] == FormatOption(height: 1080, codecLabel: "H.264",
                approxBytes: 47_185_920, formatID: "137", isAdaptive: true))
        #expect(options[1] == FormatOption(height: 360, codecLabel: "H.264",
                approxBytes: nil, formatID: "18", isAdaptive: false))
    }

    @Test func decodesReadyProgressiveAsReady() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"T","filename":"clip.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        guard case let .ready(media) = try ExtractionDecoder.decodeListing(Data(json.utf8)) else {
            Issue.record("expected ready"); return
        }
        #expect(media.suggestedFilename == "clip.mp4")
    }

    @Test func mapsErrorPayloadToKeraunosError() {
        let json = #"{"ok":false,"error_kind":"requires_auth","detail":"sign in"}"#
        #expect(throws: KeraunosError.requiresAuth) {
            try ExtractionDecoder.decodeListing(Data(json.utf8))
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path app/KeraunosCore --filter FormatListingDecodingTests`
Expected: FAIL — `type 'ExtractionDecoder' has no member 'decodeListing'`.

- [ ] **Step 3: Add the `FormatListing` enum**

```swift
// app/KeraunosCore/Sources/KeraunosCore/FormatListing.swift
import Foundation

/// Result of phase 1. `.ready` when there is nothing to choose (0–1 muxable heights):
/// download it immediately, no picker. `.choices` when 2+ heights are available: show the
/// picker, then call `resolve(_:option:)` with the user's pick.
public enum FormatListing: Sendable {
    case ready(ResolvedMedia)
    case choices([FormatOption])
}
```

- [ ] **Step 4: Add `decodeListing` to `ExtractionDecoder`**

In `app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift`, add this method inside the `public enum ExtractionDecoder { … }` body (below the existing `decode(_:)`):

```swift
    /// Decodes the phase-1 (`list_formats`) payload. A `"choices"` kind yields
    /// `.choices`; any other success kind is delegated to `decode(_:)` and wrapped in
    /// `.ready`; failure payloads throw the mapped `KeraunosError`.
    public static func decodeListing(_ data: Data) throws -> FormatListing {
        struct Envelope: Decodable {
            let ok: Bool
            let kind: String?
            let options: [OptionPayload]?
            let errorKind: String?
            let detail: String?
            enum CodingKeys: String, CodingKey {
                case ok, kind, options, detail
                case errorKind = "error_kind"
            }
        }
        struct OptionPayload: Decodable {
            let height: Int
            let codec: String?
            let approx_bytes: Int64?
            let format_id: String
            let adaptive: Bool
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw KeraunosError.runtime(detail: "malformed extraction result")
        }
        guard envelope.ok else {
            throw KeraunosError(errorKind: envelope.errorKind ?? "runtime", detail: envelope.detail ?? "")
        }
        if envelope.kind == "choices" {
            let options = (envelope.options ?? []).map {
                FormatOption(height: $0.height, codecLabel: $0.codec ?? "",
                             approxBytes: $0.approx_bytes, formatID: $0.format_id,
                             isAdaptive: $0.adaptive)
            }
            return .choices(options)
        }
        return .ready(try decode(data))
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path app/KeraunosCore --filter FormatListingDecodingTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/FormatListing.swift \
        app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/FormatListingDecodingTests.swift
git commit -m "$(cat <<'EOF'
feat(core): FormatListing + ExtractionDecoder.decodeListing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Python `list_formats` + format-id selection

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py`
- Modify: `app/Keraunos/python-dev/test_extract.py` (add fixture-based tests for the new pure helper)

**Interfaces:**
- Consumes: existing `_FORMAT`, `_ACODEC_AAC`, `_payload_for_info`, `_extract_impl`, `extract`.
- Produces: pure `_muxable_height_options(formats) -> list[dict]` (keys: `height`, `codec`, `approx_bytes`, `format_id`, `adaptive`); `list_formats(url, socket_timeout, cookiefile, overall_timeout) -> str`; `extract(...)` gains `format_id=None, adaptive=False` kwargs. Wire kinds: `choices` (options JSON) or delegates to `_payload_for_info` (`progressive`/`adaptive`).

- [ ] **Step 1: Write the failing tests** (append to `app/Keraunos/python-dev/test_extract.py`)

```python
# --- list_formats height options (Phase: resolution picker) ----------------------
from keraunos_extract import _muxable_height_options  # noqa: E402


def test_options_group_by_height_prefer_highest_tbr():
    # Two muxable video-only H.264 rows at 1080p (pick the higher-tbr one) + one 720p,
    # plus an AAC audio-only stream. Expect 2 options, sorted 1080 then 720, adaptive.
    opts = _muxable_height_options([
        {"format_id": "v1080a", "protocol": "https", "vcodec": "avc1", "acodec": "none",
         "height": 1080, "tbr": 4000, "filesize": 40_000_000},
        {"format_id": "v1080b", "protocol": "https", "vcodec": "avc1", "acodec": "none",
         "height": 1080, "tbr": 5000, "filesize": 50_000_000},
        {"format_id": "v720", "protocol": "https", "vcodec": "avc1", "acodec": "none",
         "height": 720, "tbr": 2000, "filesize": 20_000_000},
        {"format_id": "a", "protocol": "https", "vcodec": "none", "acodec": "mp4a",
         "tbr": 128, "filesize": 2_000_000},
    ])
    assert [o["height"] for o in opts] == [1080, 720]
    assert opts[0]["format_id"] == "v1080b"          # higher tbr wins
    assert opts[0]["codec"] == "H.264"
    assert opts[0]["adaptive"] is True
    assert opts[0]["approx_bytes"] == 52_000_000     # 50M video + 2M audio


def test_options_progressive_row_uses_own_size_and_marks_non_adaptive():
    opts = _muxable_height_options([
        {"format_id": "prog", "protocol": "https", "vcodec": "h264", "acodec": "aac",
         "height": 480, "tbr": 1000, "filesize_approx": 10_000_000},
    ])
    assert len(opts) == 1
    assert opts[0]["adaptive"] is False
    assert opts[0]["approx_bytes"] == 10_000_000     # progressive: its own size, no audio add


def test_options_skip_non_http_and_non_muxable_and_unknown_height():
    opts = _muxable_height_options([
        {"format_id": "hls", "protocol": "m3u8_native", "vcodec": "avc1", "acodec": "none",
         "height": 1080},                                    # non-http → skip
        {"format_id": "av1", "protocol": "https", "vcodec": "av01", "acodec": "none",
         "height": 1080},                                    # non-muxable vcodec → skip
        {"format_id": "noh", "protocol": "https", "vcodec": "avc1", "acodec": "none"},  # no height → skip
    ])
    assert opts == []


def test_options_hevc_labeled_and_codec_family_detected():
    opts = _muxable_height_options([
        {"format_id": "h", "protocol": "https", "vcodec": "hvc1.1.6", "acodec": "none",
         "height": 1080, "tbr": 3000},
        {"format_id": "a", "protocol": "https", "vcodec": "none", "acodec": "mp4a", "tbr": 128},
    ])
    assert opts[0]["codec"] == "HEVC"
    assert opts[0]["approx_bytes"] is None               # no sizes reported anywhere
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Keraunos/python-dev && python3 -m pytest test_extract.py -k options -q`
Expected: FAIL — `ImportError: cannot import name '_muxable_height_options'`.

(If pytest is unavailable, run `python3 test_extract.py` — mirror how the file is currently executed; the new `test_*` functions run under the same runner the file already uses.)

- [ ] **Step 3: Add the pure helpers** to `app/Keraunos/PythonResources/app/keraunos_extract.py`

Add near the top, after the existing codec-regex string constants (around line 24) — note these are compiled `re` patterns for the Python-side scan, distinct from the yt-dlp selector strings above:

```python
import re

_RE_MUX_HEVC = re.compile(r"^(hvc1|hev1|hevc|h265)")
_RE_MUX_H264 = re.compile(r"^(avc1|avc3|avc|h264)")
_RE_AAC = re.compile(r"^(mp4a|aac)")


def _is_http(fmt):
    return (fmt.get("protocol") or "").startswith("http")


def _codec_label(vcodec):
    v = vcodec or ""
    if _RE_MUX_HEVC.match(v):
        return "HEVC"
    if _RE_MUX_H264.match(v):
        return "H.264"
    return v


def _muxable_vcodec(vcodec):
    v = vcodec or ""
    return bool(_RE_MUX_HEVC.match(v) or _RE_MUX_H264.match(v))


def _best_aac_audio(formats):
    """Highest-tbr http AAC audio-only format, or None if there is no muxable audio."""
    best = None
    for f in formats:
        if not _is_http(f) or (f.get("vcodec") or "none") != "none":
            continue
        if not _RE_AAC.match(f.get("acodec") or ""):
            continue
        if best is None or (f.get("tbr") or 0) > (best.get("tbr") or 0):
            best = f
    return best


def _fmt_size(fmt):
    return fmt.get("filesize") or fmt.get("filesize_approx")


def _muxable_height_options(formats):
    """One AVFoundation-muxable option per distinct height (best tbr wins), sorted high→low.
    Progressive rows (muxable vcodec + AAC) carry their own size; adaptive rows (video-only
    muxable vcodec) are sized as video + best AAC audio, and are emitted only when a muxable
    audio track exists. Pure: no network. Mirrors the selector's muxability rules."""
    audio = _best_aac_audio(formats)
    audio_size = _fmt_size(audio) if audio else None
    by_height = {}
    for f in formats:
        h = f.get("height")
        if not _is_http(f) or not h or not _muxable_vcodec(f.get("vcodec")):
            continue
        acodec = f.get("acodec") or "none"
        progressive = acodec != "none" and bool(_RE_AAC.match(acodec))
        adaptive = acodec == "none"
        if adaptive and audio is None:
            continue                      # no muxable audio to pair with → not muxable
        if not (progressive or adaptive):
            continue                      # video with non-AAC muxed audio → skip
        cur = by_height.get(h)
        if cur is None or (f.get("tbr") or 0) > (cur[0].get("tbr") or 0):
            by_height[h] = (f, adaptive)
    options = []
    for h in sorted(by_height, reverse=True):
        f, adaptive = by_height[h]
        vsize = _fmt_size(f)
        if adaptive:
            size = (vsize + audio_size) if (vsize is not None and audio_size is not None) else None
        else:
            size = vsize
        options.append({
            "height": h,
            "codec": _codec_label(f.get("vcodec")),
            "approx_bytes": size,
            "format_id": f.get("format_id"),
            "adaptive": adaptive,
        })
    return options
```

- [ ] **Step 4: Run the pure-helper tests to verify they pass**

Run: `cd app/Keraunos/python-dev && python3 -m pytest test_extract.py -k options -q`
Expected: PASS (4 new tests) and the existing selector tests still pass.

- [ ] **Step 5: Thread `format_id` through `extract` and add `list_formats`**

In `keraunos_extract.py`, change `_extract_impl` to take a format string, and `extract` to build it from `format_id`/`adaptive`.

Change the `_extract_impl` signature and the `opts["format"]` line:

```python
def _extract_impl(url, socket_timeout, cookiefile, fmt=_FORMAT):
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": fmt,
        # …rest of opts unchanged…
```

Change `extract` to accept and apply the new kwargs (the `_work` closure must forward `fmt`):

```python
def extract(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None,
            overall_timeout=_OVERALL_TIMEOUT, format_id=None, adaptive=False):
    """Runs _extract_impl under an overall wall-clock bound. A non-empty format_id
    re-selects exactly that stream (adaptive → pair with best AAC audio), falling back
    to the default _FORMAT if the id is stale."""
    if format_id:
        if adaptive:
            fmt = (f"{format_id}+bestaudio[protocol^=http][{_ACODEC_AAC}]/"
                   f"{format_id}+bestaudio/{_FORMAT}")
        else:
            fmt = f"{format_id}/{_FORMAT}"
    else:
        fmt = _FORMAT
    box = {}

    def _work():
        try:
            box["result"] = _extract_impl(url, socket_timeout, cookiefile, fmt)
        except Exception as e:
            box["result"] = _err("runtime", str(e))

    worker = threading.Thread(target=_work, daemon=True)
    worker.start()
    worker.join(overall_timeout)
    if worker.is_alive():
        return _err("timeout", f"extraction exceeded {overall_timeout}s")
    return box.get("result", _err("runtime", "extraction produced no result"))
```

Add `list_formats`, plus an impl that reuses the extraction body but branches on the options count. Add a private `_list_impl` next to `_extract_impl`:

```python
def _list_impl(url, socket_timeout, cookiefile):
    """Phase 1: one extraction. Returns a choices payload when 2+ muxable heights exist,
    else the default .ready payload (identical to extract()'s success JSON)."""
    opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT,
        "socket_timeout": socket_timeout, "extractor_retries": 2,
        "cachedir": os.path.join(__import__("tempfile").gettempdir(), "yt-dlp-cache"),
        "extractor_args": {"youtube": {"player_client": ["tv", "tv_embedded", "android_vr"]}},
    }
    if cookiefile and os.path.exists(cookiefile):
        opts["cookiefile"] = cookiefile
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if info.get("_type") == "playlist":
                entries = info.get("entries") or []
                if not entries:
                    return _err("unsupported", "no media in playlist")
                info = entries[0]
            options = _muxable_height_options(info.get("formats") or [])
            if len(options) >= 2:
                return json.dumps({"ok": True, "kind": "choices", "options": options})
            return _payload_for_info(info, ydl.prepare_filename)
    except UnsupportedError as e:
        return _err("unsupported", str(e))
    except (DownloadError, ExtractorError) as e:
        return _map_download_error(e)
    except Exception as e:
        return _err("runtime", str(e))


def list_formats(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None,
                 overall_timeout=_OVERALL_TIMEOUT):
    box = {}

    def _work():
        try:
            box["result"] = _list_impl(url, socket_timeout, cookiefile)
        except Exception as e:
            box["result"] = _err("runtime", str(e))

    worker = threading.Thread(target=_work, daemon=True)
    worker.start()
    worker.join(overall_timeout)
    if worker.is_alive():
        return _err("timeout", f"extraction exceeded {overall_timeout}s")
    return box.get("result", _err("runtime", "extraction produced no result"))
```

To avoid duplicating the long `except (DownloadError, ExtractorError)` mapping, extract the existing mapping block from `_extract_impl` into a module-level `_map_download_error(e)` that returns the same `_err(...)` payloads, and call it from **both** `_extract_impl` and `_list_impl`. (Move the body verbatim — the `msg = str(e).lower()` chain through the final `return _err("unsupported", str(e))`.)

- [ ] **Step 6: Smoke-test `list_formats` against a localhost fixture (optional, if a fixture server is available)**

Run: `cd app/Keraunos/python-dev && python3 -m pytest test_extract.py -q`
Expected: PASS — all selector + options tests. (Full `list_formats` network behavior is verified on-device in Task 6/7.)

- [ ] **Step 7: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_extract.py \
        app/Keraunos/python-dev/test_extract.py
git commit -m "$(cat <<'EOF'
feat(extract): list_formats options + format_id re-selection

Why: back the per-download resolution picker with a phase-1 format list and a
phase-2 selector that re-resolves the chosen stream.

What changed:
- _muxable_height_options: pure, one AVFoundation-muxable option per height.
- list_formats: choices payload at 2+ heights, else the default .ready payload.
- extract(format_id, adaptive): re-select a specific stream with _FORMAT fallback.
- _map_download_error: shared error mapping for extract + list impls.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: C bridge — `list_formats` entry point + `format_id` on `extract`

**Files:**
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`

**Interfaces:**
- Consumes: Python `keraunos_extract.extract(..., format_id=, adaptive=)` and `keraunos_extract.list_formats(...)` (Task 3).
- Produces: `char *keraunos_python_list_formats(const char *url, const char *cookieFilePath);` and an extended `char *keraunos_python_extract(const char *url, const char *cookieFilePath, const char *formatID, int adaptive);`.

> No unit test — this is the embedded-CPython seam, exercised on-device. Steps are implement → build → commit. Per CLAUDE.md, **clean-build** if on-device behavior later contradicts source.

- [ ] **Step 1: Update the header**

In `PythonBridge.h`, replace the `keraunos_python_extract` declaration and add the list entry point:

```c
/// Calls keraunos_extract.extract(url, cookiefile=..., format_id=..., adaptive=...).
/// formatID NULL/empty selects the default best-muxable stream (unchanged behavior).
/// Returns a malloc'd UTF-8 JSON string the caller must free().
char *keraunos_python_extract(const char *url, const char *cookieFilePath,
                              const char *formatID, int adaptive);

/// Calls keraunos_extract.list_formats(url, cookiefile=...). Returns a malloc'd UTF-8
/// JSON string (a choices payload, a .ready payload, or an error payload) to free().
char *keraunos_python_list_formats(const char *url, const char *cookieFilePath);
```

- [ ] **Step 2: Extend `keraunos_python_extract` in `PythonBridge.m`**

Change the signature and add the `format_id`/`adaptive` kwargs (mirroring the existing cookiefile kwarg pattern). Inside the `if (args && kwargs)` setup, after the cookiefile block:

```c
char *keraunos_python_extract(const char *url, const char *cookieFilePath,
                              const char *formatID, int adaptive) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;

    PyObject *module = PyImport_ImportModule("keraunos_extract");
    if (module) {
        PyObject *func = PyObject_GetAttrString(module, "extract");
        if (func && PyCallable_Check(func)) {
            PyObject *args = Py_BuildValue("(s)", url);
            PyObject *kwargs = PyDict_New();
            if (cookieFilePath && cookieFilePath[0] != '\0') {
                PyObject *cf = PyUnicode_FromString(cookieFilePath);
                if (cf) { PyDict_SetItemString(kwargs, "cookiefile", cf); Py_DECREF(cf); }
            }
            if (formatID && formatID[0] != '\0') {
                PyObject *fid = PyUnicode_FromString(formatID);
                if (fid) { PyDict_SetItemString(kwargs, "format_id", fid); Py_DECREF(fid); }
                PyObject *adap = PyBool_FromLong(adaptive);
                if (adap) { PyDict_SetItemString(kwargs, "adaptive", adap); Py_DECREF(adap); }
            }
            if (args && kwargs) {
                PyObject *result = PyObject_Call(func, args, kwargs);
                if (result) {
                    const char *utf8 = PyUnicode_AsUTF8(result);
                    if (utf8) out = strdup(utf8);
                    Py_DECREF(result);
                }
            }
            Py_XDECREF(args);
            Py_XDECREF(kwargs);
        }
        Py_XDECREF(func);
        Py_DECREF(module);
    }
    if (!out && PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);

    if (!out) out = strdup("{\"ok\":false,\"error_kind\":\"runtime\",\"detail\":\"python bridge failure\"}");
    return out;
}
```

- [ ] **Step 3: Add `keraunos_python_list_formats` in `PythonBridge.m`**

Add below `keraunos_python_extract` (same structure; calls `list_formats`, only the cookiefile kwarg):

```c
char *keraunos_python_list_formats(const char *url, const char *cookieFilePath) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;

    PyObject *module = PyImport_ImportModule("keraunos_extract");
    if (module) {
        PyObject *func = PyObject_GetAttrString(module, "list_formats");
        if (func && PyCallable_Check(func)) {
            PyObject *args = Py_BuildValue("(s)", url);
            PyObject *kwargs = PyDict_New();
            if (cookieFilePath && cookieFilePath[0] != '\0') {
                PyObject *cf = PyUnicode_FromString(cookieFilePath);
                if (cf) { PyDict_SetItemString(kwargs, "cookiefile", cf); Py_DECREF(cf); }
            }
            if (args && kwargs) {
                PyObject *result = PyObject_Call(func, args, kwargs);
                if (result) {
                    const char *utf8 = PyUnicode_AsUTF8(result);
                    if (utf8) out = strdup(utf8);
                    Py_DECREF(result);
                }
            }
            Py_XDECREF(args);
            Py_XDECREF(kwargs);
        }
        Py_XDECREF(func);
        Py_DECREF(module);
    }
    if (!out && PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);

    if (!out) out = strdup("{\"ok\":false,\"error_kind\":\"runtime\",\"detail\":\"python bridge failure\"}");
    return out;
}
```

- [ ] **Step 4: Build the app to verify the bridge compiles**

Run:
```bash
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```
Expected: BUILD FAILED at `PythonExtractor.swift` — the actor still calls the **old** two-argument `keraunos_python_extract`. That call site is fixed in Task 5; the C sources themselves must compile. Confirm the failure is only the Swift call-site arity, not a C error.

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h \
        app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m
git commit -m "$(cat <<'EOF'
feat(bridge): list_formats entry point + format_id on extract

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `MediaExtracting` protocol + conformers

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift` (protocol + `MockExtractor`)
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`
- Modify: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift` (interim call-site fix only)
- Modify: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift` (migrate `SequenceExtractor`, `HangingExtractor`)
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/MockExtractorTests.swift`

**Interfaces:**
- Consumes: `FormatListing`, `FormatOption` (Tasks 1–2); bridge funcs (Task 4).
- Produces: protocol
  ```swift
  func listFormats(_ url: URL) async throws -> FormatListing
  func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia
  ```
  `MockExtractor` gains `var listing: Result<FormatListing, KeraunosError>?` (nil → derived from `result`).

- [ ] **Step 1: Write the failing MockExtractor tests**

```swift
// app/KeraunosCore/Tests/KeraunosCoreTests/MockExtractorTests.swift
import Testing
import Foundation
import KeraunosCore

struct MockExtractorTests {
    private let media = ResolvedMedia(
        kind: .progressive(MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                                      httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
        title: "t", suggestedFilename: "v.mp4")

    @Test func listFormatsDefaultsToReadyFromResult() async throws {
        let mock = MockExtractor(result: .success(media))
        guard case let .ready(m) = try await mock.listFormats(URL(string: "https://x.test")!) else {
            Issue.record("expected ready"); return
        }
        #expect(m == media)
    }

    @Test func listFormatsUsesExplicitListingOverride() async throws {
        let option = FormatOption(height: 720, codecLabel: "H.264", approxBytes: nil,
                                  formatID: "22", isAdaptive: false)
        var mock = MockExtractor(result: .success(media))
        mock.listing = .success(.choices([option]))
        guard case let .choices(opts) = try await mock.listFormats(URL(string: "https://x.test")!) else {
            Issue.record("expected choices"); return
        }
        #expect(opts == [option])
    }

    @Test func resolveWithOptionReturnsResult() async throws {
        let mock = MockExtractor(result: .success(media))
        let m = try await mock.resolve(URL(string: "https://x.test")!, option: nil)
        #expect(m == media)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path app/KeraunosCore --filter MockExtractorTests`
Expected: FAIL — `value of type 'MockExtractor' has no member 'listing'` / `listFormats`.

- [ ] **Step 3: Update the protocol and `MockExtractor`**

Replace `app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift` with:

```swift
import Foundation

/// Resolves a page URL to downloadable media. Two phases: `listFormats` lists the
/// resolutions available (or returns a ready-to-download result when there is no choice);
/// `resolve(_:option:)` re-resolves a specific chosen format.
public protocol MediaExtracting: Sendable {
    func listFormats(_ url: URL) async throws -> FormatListing
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia
}

/// Deterministic test/preview double. `listing` overrides the phase-1 result; when nil it
/// is derived from `result` (`.success` → `.ready`, `.failure` → thrown), so existing
/// single-result setups keep working.
public struct MockExtractor: MediaExtracting {
    public var result: Result<ResolvedMedia, KeraunosError>
    public var listing: Result<FormatListing, KeraunosError>?

    public init(result: Result<ResolvedMedia, KeraunosError> = .success(
        ResolvedMedia(
            kind: .progressive(MediaTrack(url: URL(string: "https://example.com/sample.mp4")!,
                                          httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
            title: "Sample",
            suggestedFilename: "sample.mp4")),
                listing: Result<FormatListing, KeraunosError>? = nil) {
        self.result = result
        self.listing = listing
    }

    public func listFormats(_ url: URL) async throws -> FormatListing {
        if let listing { return try listing.get() }
        return .ready(try result.get())
    }

    public func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia {
        try result.get()
    }
}
```

- [ ] **Step 4: Run the MockExtractor tests to verify they pass**

Run: `swift test --package-path app/KeraunosCore --filter MockExtractorTests`
Expected: PASS (3 tests). Run the full core suite too: `swift test --package-path app/KeraunosCore` → PASS.

- [ ] **Step 5: Update `PythonExtractor` to implement both methods**

In `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`, replace `resolve(_:)` and `blockingExtract(_:cookiePath:)` with the two-phase implementation. The new `resolve` takes an `option`; add a `listFormats` that mirrors it via `keraunos_python_list_formats` + `decodeListing`:

```swift
    func listFormats(_ url: URL) async throws -> FormatListing {
        try ensureInitialized()
        let cookieURL = await cookieProvider?.cookieFile()
        defer { if let cookieURL { try? FileManager.default.removeItem(at: cookieURL) } }
        let cookiePath = cookieURL?.path
        return try await withTimeout(timeout) { [self] in
            try await blockingList(url, cookiePath: cookiePath)
        }
    }

    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia {
        try ensureInitialized()
        let cookieURL = await cookieProvider?.cookieFile()
        defer { if let cookieURL { try? FileManager.default.removeItem(at: cookieURL) } }
        let cookiePath = cookieURL?.path
        return try await withTimeout(timeout) { [self] in
            try await blockingExtract(url, cookiePath: cookiePath, option: option)
        }
    }

    private func blockingList(_ url: URL, cookiePath: String?) throws -> FormatListing {
        guard let cString = keraunos_python_list_formats(url.absoluteString, cookiePath) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decodeListing(Data(String(cString: cString).utf8))
    }

    private func blockingExtract(_ url: URL, cookiePath: String?, option: FormatOption?) throws -> ResolvedMedia {
        guard let cString = keraunos_python_extract(url.absoluteString, cookiePath,
                                                    option?.formatID, (option?.isAdaptive ?? false) ? 1 : 0) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decode(Data(String(cString: cString).utf8))
    }
```

- [ ] **Step 6: Fix the interim `DownloadViewModel` call site**

In `DownloadViewModel.swift`, line 66, change:
```swift
            let media = try await extractor.resolve(url)
```
to:
```swift
            let media = try await extractor.resolve(url, option: nil)
```
(This keeps behavior identical — resolve-best — until Task 6 introduces the picker flow.)

- [ ] **Step 7: Migrate the test doubles**

In `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`, replace `SequenceExtractor` and `HangingExtractor` with:

```swift
/// Returns a queued sequence of results across successive phase-1 calls.
final class SequenceExtractor: MediaExtracting, @unchecked Sendable {
    private var results: [Result<ResolvedMedia, KeraunosError>]
    init(results: [Result<ResolvedMedia, KeraunosError>]) { self.results = results }
    private func next() throws -> ResolvedMedia {
        try (results.isEmpty ? .failure(.runtime(detail: "no more results")) : results.removeFirst()).get()
    }
    func listFormats(_ url: URL) async throws -> FormatListing { .ready(try next()) }
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia { try next() }
}

/// Suspends inside phase 1 until cancelled, signalling when it has actually entered so a
/// test can cancel a genuinely in-flight download.
final class HangingExtractor: MediaExtracting, @unchecked Sendable {
    let resolving: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation
    init() {
        var continuation: AsyncStream<Void>.Continuation!
        resolving = AsyncStream { continuation = $0 }
        entered = continuation
    }
    func listFormats(_ url: URL) async throws -> FormatListing {
        entered.yield(())
        try await Task.sleep(for: .seconds(60))
        throw KeraunosError.runtime(detail: "should have been cancelled")
    }
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia {
        try await Task.sleep(for: .seconds(60))
        throw KeraunosError.runtime(detail: "should have been cancelled")
    }
}
```

- [ ] **Step 8: Build and run the full app test suite**

Run:
```bash
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: BUILD SUCCEEDED; all existing `DownloadViewModelTests` PASS (they now flow through `listFormats` → `.ready`).

- [ ] **Step 9: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/MockExtractorTests.swift \
        app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift \
        app/Keraunos/Keraunos/UI/DownloadViewModel.swift \
        app/Keraunos/KeraunosTests/DownloadViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(extractor): two-phase MediaExtracting (listFormats + resolve:option)

Why: back the resolution picker with a list phase and a chosen-format resolve
phase, keeping the existing single-result flow green in the interim.

What changed:
- Protocol gains listFormats + resolve(_:option:); MockExtractor derives .ready
  from its result unless a listing override is set.
- PythonExtractor implements both via the extended bridge.
- Interim: DownloadViewModel calls resolve(url, option: nil) (Task 6 adds the flow).
- Migrated Sequence/HangingExtractor test doubles to the new protocol.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `DownloadViewModel` two-phase flow + picker state

**Files:**
- Modify: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Test: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`

**Interfaces:**
- Consumes: `FormatListing`, `FormatOption`, `MediaExtracting` (Tasks 1–2, 5).
- Produces: `private(set) var pendingOptions: [FormatOption]?`; `func selectFormat(_ option: FormatOption)`; `func cancelSelection()`. Behavior: `startDownload` calls `listFormats`; `.ready` downloads; `.choices` sets `pendingOptions`/`pendingURL` and stops; `selectFormat` resolves the pick and downloads; error handling shared between both phases.

- [ ] **Step 1: Write the failing tests** (add to `DownloadViewModelTests`)

```swift
    private func choices(_ options: [FormatOption]) -> MockExtractor {
        var m = MockExtractor(result: .success(progressive("picked.mp4")))
        m.listing = .success(.choices(options))
        return m
    }
    private var sampleOption: FormatOption {
        FormatOption(height: 720, codecLabel: "H.264", approxBytes: nil,
                     formatID: "22", isAdaptive: false)
    }

    @Test func multipleFormatsShowPickerAndDoNotDownloadYet() async {
        let dir = tempDir()
        let model = vm(extractor: choices([sampleOption,
            FormatOption(height: 360, codecLabel: "H.264", approxBytes: nil,
                         formatID: "18", isAdaptive: false)]),
                       merger: MockMerger(), dir: dir)
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.pendingOptions?.count == 2)
        #expect(model.lastSavedName == nil)                 // nothing downloaded yet
        #expect(model.savedFiles.isEmpty)
    }

    @Test func selectFormatResolvesAndSaves() async {
        let dir = tempDir()
        let model = vm(extractor: choices([sampleOption]), merger: MockMerger(), dir: dir)
        model.urlText = "https://x.test/v"
        await model.startDownload()
        model.selectFormat(sampleOption)
        await model.currentTask?.value
        #expect(model.pendingOptions == nil)
        #expect(model.lastSavedName == "picked.mp4")
    }

    @Test func cancelSelectionClearsPickerWithoutDownloading() async {
        let model = vm(extractor: choices([sampleOption]), merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/v"
        await model.startDownload()
        model.cancelSelection()
        #expect(model.pendingOptions == nil)
        #expect(model.lastSavedName == nil)
    }

    @Test func listFormatsErrorMapsLikeResolveError() async {
        var mock = MockExtractor()
        mock.listing = .failure(.requiresAuth)
        let model = vm(extractor: mock, merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.requiresSignIn)                        // same routing as a resolve failure
        #expect(model.pendingOptions == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:KeraunosTests/DownloadViewModelTests
```
Expected: FAIL — `value of type 'DownloadViewModel' has no member 'pendingOptions'` / `selectFormat` / `cancelSelection`.

- [ ] **Step 3: Refactor `DownloadViewModel`**

Add the new state near the other `private(set)` vars (after `saveMessage`):

```swift
    /// Non-nil when the picker is showing: the resolutions available for the pasted link.
    private(set) var pendingOptions: [FormatOption]?
    /// The URL the pending options were listed for; resolved in `selectFormat`.
    private var pendingURL: URL?
```

Replace `startDownload(isAutoRetry:)` (lines 52–113) with the two-phase version plus shared helpers:

```swift
    func startDownload(isAutoRetry: Bool = false) async {
        guard let url = URLNormalizer.normalize(urlText) else {
            errorMessage = "Enter a valid http(s) link."
            return
        }
        beginWork()
        defer { endWork() }
        do {
            switch try await extractor.listFormats(url) {
            case .ready(let media):
                try await assembleAndRecord(media)
            case .choices(let options):
                pendingOptions = options
                pendingURL = url
            }
        } catch {
            await handleFailure(error, url: url, isAutoRetry: isAutoRetry) {
                await self.startDownload(isAutoRetry: true)
            }
        }
    }

    /// Downloads the user's chosen resolution. Cancels any prior task first.
    func selectFormat(_ option: FormatOption) {
        guard let url = pendingURL else { return }
        pendingOptions = nil
        pendingURL = nil
        currentTask?.cancel()
        currentTask = Task { await self.resolveSelected(url: url, option: option) }
    }

    /// Dismisses the picker without downloading.
    func cancelSelection() {
        pendingOptions = nil
        pendingURL = nil
    }

    private func resolveSelected(url: URL, option: FormatOption, isAutoRetry: Bool = false) async {
        beginWork()
        defer { endWork() }
        do {
            let media = try await extractor.resolve(url, option: option)
            try await assembleAndRecord(media)
        } catch {
            await handleFailure(error, url: url, isAutoRetry: isAutoRetry) {
                await self.resolveSelected(url: url, option: option, isAutoRetry: true)
            }
        }
    }

    private func beginWork() {
        isWorking = true
        errorMessage = nil
        requiresSignIn = false
        signInURL = nil
        canRetry = false
        downloadProgress = nil
        statusText = "Resolving…"
    }

    private func endWork() {
        isWorking = false
        statusText = nil
        downloadProgress = nil
    }

    private func assembleAndRecord(_ media: ResolvedMedia) async throws {
        let saved = try await assembler.assemble(media, into: store, onPhase: { phase in
            self.statusText = Self.label(for: phase)
        }, onProgress: { fraction in
            Task { @MainActor in self.downloadProgress = fraction }
        })
        lastSavedName = saved.lastPathComponent
        savedFiles = store.savedFiles()
    }

    /// Shared failure handling for both phases: transparent one-shot auto-retry for
    /// transient faults (via `retry`), else surface/log the error and route auth walls
    /// to the Sign-In flow.
    private func handleFailure(_ error: Error, url: URL, isAutoRetry: Bool,
                               retry: () async -> Void) async {
        switch error {
        case is CancellationError:
            return
        case let error as KeraunosError:
            guard error != .cancelled else { return }
            if error.isAutoRetryable, !isAutoRetry {
                statusText = "Retrying…"
                await retry()
                return
            }
            errorMessage = error.errorDescription
            canRetry = error.isRetryable
            let detail = { if case .runtime(let d) = error { return d } else { return "" } }()
            failureLog.record(url: url.absoluteString, errorKind: error.kind, detail: detail, date: Date())
            failureLogURL = failureLog.fileURL
            if error == .requiresAuth || error == .restrictedOrEmpty {
                requiresSignIn = true
                signInURL = URLNormalizer.origin(of: url) ?? url
            }
        default:
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
            canRetry = true
            failureLog.record(url: url.absoluteString, errorKind: "runtime",
                              detail: error.localizedDescription, date: Date())
            failureLogURL = failureLog.fileURL
        }
    }
```

(The `start()`, `cancel()`, `retry()`, `openIncoming(_:)`, and the rest below remain unchanged.)

- [ ] **Step 4: Run the full app test suite to verify pass**

Run:
```bash
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: BUILD SUCCEEDED; all `DownloadViewModelTests` PASS — the 4 new picker tests plus the existing `.ready`/error/auto-retry/cancel tests (which now flow through `listFormats`).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/UI/DownloadViewModel.swift \
        app/Keraunos/KeraunosTests/DownloadViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): two-phase download flow with resolution picker state

Why: show a picker when a link offers multiple resolutions; download directly
when there is no choice.

What changed:
- startDownload calls listFormats: .ready downloads, .choices sets pendingOptions.
- selectFormat resolves the chosen option and saves; cancelSelection dismisses.
- Extracted beginWork/endWork/assembleAndRecord/handleFailure so both phases
  share identical error mapping, auto-retry, logging, and Sign-In routing.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Picker UI in `DownloadScreen`

**Files:**
- Modify: `app/Keraunos/Keraunos/UI/DownloadScreen.swift`

**Interfaces:**
- Consumes: `model.pendingOptions`, `model.selectFormat(_:)`, `model.cancelSelection()`, `FormatOption.displayLabel` (Tasks 1, 6).
- Produces: no new API — a `.confirmationDialog` presenting one button per option.

> UI wiring — verified by build + on-device/simulator interaction, not a unit test.

- [ ] **Step 1: Add the confirmation dialog**

In `DownloadScreen.swift`, add this modifier on the `Form` (e.g. directly after `.quickLookPreview($previewURL)` on line 124):

```swift
            .confirmationDialog(
                "Choose quality",
                isPresented: Binding(
                    get: { model.pendingOptions != nil },
                    set: { if !$0 { model.cancelSelection() } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(model.pendingOptions ?? [], id: \.formatID) { option in
                    Button(option.displayLabel) { model.selectFormat(option) }
                }
                Button("Cancel", role: .cancel) { model.cancelSelection() }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (simulator or device)**

Paste a multi-resolution link (e.g. a YouTube URL). Expected: after "Resolving…", an action sheet titled "Choose quality" lists rows like `1080p · H.264 · 45 MB`, `720p · H.264 · 25 MB`, `360p · H.264`. Tapping a row downloads that resolution; Cancel dismisses without downloading. Paste a single-stream link (e.g. a direct Twitter/X video) → no picker, downloads directly (no regression).

> Per CLAUDE.md: if on-device behavior contradicts the source, suspect a stale binary — ⇧⌘K (Clean Build Folder) before debugging.

- [ ] **Step 4: Commit**

```bash
git add app/Keraunos/Keraunos/UI/DownloadScreen.swift
git commit -m "$(cat <<'EOF'
feat(ui): resolution picker confirmation dialog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- **Codec-regex duplication is intentional.** `keraunos_extract.py` has two representations of muxability: the yt-dlp **selector strings** (`_VCODEC_MUXABLE` etc., used to *pick* formats during extraction) and the new compiled **`re` patterns** (`_RE_MUX_*`, used to *scan* `info["formats"]` in `_muxable_height_options`). They must stay in sync — if you add a codec family to one, add it to the other.
- **`option: FormatOption?` is optional** only to keep Task 5's interim call site (`resolve(url, option: nil)`) compiling. After Task 6, the VM only ever passes a real option; the mock/doubles ignore it.
- **The `_FORMAT` fallback in phase 2 is deliberate.** A stale `format_id` degrades to the best muxable stream rather than failing the download — a resolution mismatch is acceptable, a failed download is not.
```
