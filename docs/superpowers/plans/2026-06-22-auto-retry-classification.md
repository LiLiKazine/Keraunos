# Plan: tested auto-retry classification (+ retry download-side blips)

Date: 2026-06-22 (cycle 5) · Roadmap item: BACKLOG #7 (retry/backoff), bounded slice.

## Problem

`DownloadViewModel.startDownload` does one transparent auto-retry on `error == .extractNetwork || .timedOut` (an inline, hand-coded set). Two issues:
1. `.downloadNetwork` — a mid-transfer URLSession blip / transient 5xx / 0-byte body — is
   NOT auto-retried, even though it's the most natural transparent-retry candidate on a
   flaky mobile network. It surfaces an error the user must manually re-tap.
2. The inline set silently disagrees with `KeraunosError.isRetryable`
   (`KeraunosError.swift`), which also marks `.downloadNetwork`, `.runtime`, `.rateLimited`
   retryable. Two notions of "transient" drift apart with no single source of truth.

Note: this is NOT full exponential backoff (over-engineering for a single-user tool).
It's a single transparent retry, gated by a tested classification.

## Design

Introduce a SECOND, narrower classification distinct from `isRetryable`:
- `isRetryable` = "could a *manual* retry plausibly succeed?" (drives the "Try again"
  button). Unchanged.
- `isAutoRetryable` (NEW) = "should we *transparently* retry once, without surfacing?"

`isAutoRetryable` is a strict subset of `isRetryable`:
- **true**: `.extractNetwork`, `.timedOut`, `.downloadNetwork` — transient transport/cold-
  start faults a warm retry clears.
- **false**: `.rateLimited` (re-hammering immediately is exactly wrong — message says
  "wait"), `.runtime` (don't auto-loop on unknown faults; manual retry only), and all
  terminal kinds (`.unsupported`, `.needsFfmpeg`, `.requiresAuth`, `.cancelled`,
  `.mergeFailed`, `.unavailable`).

## Changes

### `app/KeraunosCore/Sources/KeraunosCore/KeraunosError.swift`
Add a computed `var isAutoRetryable: Bool` (exhaustive switch) with the sets above and a
comment explaining how it differs from `isRetryable` (rateLimited/runtime are manually
retryable but NOT auto-retryable).

### `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
Replace the inline `if (error == .extractNetwork || error == .timedOut), !isAutoRetry`
with `if error.isAutoRetryable, !isAutoRetry`. Update the adjacent comment so it no longer
reads as YouTube-cold-start-only (now also covers a transient download-side blip). No
other logic change; `.rateLimited` continues to surface immediately with `canRetry == true`.

## Tests (TDD, write FIRST)

### `app/KeraunosCore/Tests/KeraunosCoreTests/KeraunosErrorTests.swift`
- `autoRetryableSetIsTheTransientTransportKinds`: `.extractNetwork`, `.timedOut`,
  `.downloadNetwork` are `isAutoRetryable == true`; `.rateLimited`, `.runtime`,
  `.unsupported`, `.needsFfmpeg`, `.requiresAuth`, `.cancelled`, `.mergeFailed`,
  `.unavailable` are `false`.
- `autoRetryableIsSubsetOfRetryable`: for every auto-retryable kind, `isRetryable` is also
  true (the invariant). And explicitly: `.rateLimited`/`.runtime` are retryable but NOT
  auto-retryable.

### `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`
- Extend `autoRetriesOnceOnTransientColdStart(_:)` arguments to include `.downloadNetwork`
  (now also transparently retried → succeeds on the warm second attempt).
- `doesNotAutoRetryRateLimited`: `SequenceExtractor([.failure(.rateLimited), .success(...)])`
  → after `startDownload`, `errorMessage == .rateLimited.errorDescription`,
  `lastSavedName == nil` (the success is NOT consumed — proving no auto-retry), and
  `canRetry == true` (manual retry still offered).

## Verify gate

Full build + Swift Testing suite on iPhone 17 simulator (this spans both the Core package
and the app target). KeraunosCore alone: `cd app/KeraunosCore && swift test`. Recurring
UI-runner flake: `xcrun simctl shutdown all; killall Simulator; sleep 6` then re-run.
