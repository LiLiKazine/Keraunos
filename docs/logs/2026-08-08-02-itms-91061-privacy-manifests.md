# 2026-08-08-02: Privacy manifests for OpenSSL-linked Python extension modules

**Status:** Implemented

## Context

App Store review rejected Keraunos 1.0 build 46 on 2026-08-07. The submission
(`feba6a9e-0082-47af-8856-23054b6506db`) went to `UNRESOLVED_ISSUES` and the iOS
version dropped to `INVALID_BINARY`, with no message in Resolution Center — Apple
sent the reason by email instead:

> ITMS-91061: Missing privacy manifest — Your app includes
> "Frameworks/_hashlib.framework/_hashlib" … which includes BoringSSL /
> openssl_grpc, an SDK that was identified in the documentation as a commonly
> used third-party SDK.

The same error was reported for `_ssl.framework`. Both are CPython stdlib
extension modules from BeeWare Python-Apple-support `3.13-b14`, which statically
link OpenSSL; Apple's scanner fingerprints that as BoringSSL / openssl_grpc, and
commonly-used third-party SDKs must ship a `PrivacyInfo.xcprivacy`.

Two facts shaped the fix:

- Upstream ships no manifests. `3.13-b14` is the newest 3.13 release, so there
  was no version to upgrade into. `Python.xcframework/build/utils.sh` *does*
  already have the hook — `install_dylib()` installs a `<module>.xcprivacy`
  found next to a `.so` into the generated framework as `PrivacyInfo.xcprivacy`,
  before it codesigns — but nothing was feeding it.
- `Python.xcframework/` is gitignored (~115 MB) and `ci_scripts/ci_post_clone.sh`
  re-downloads a pristine copy on Xcode Cloud.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Commit manifests into `Python.xcframework/.../lib-dynload/` | No new build machinery; uses the upstream hook directly | **Broken on CI** — the directory is gitignored and post-clone replaces it wholesale, silently reintroducing the rejection. Rejected. |
| Write `PrivacyInfo.xcprivacy` into the built `.app`'s framework bundles after `install_python`, then re-sign | Never touches the vendored XCframework | Duplicates `install_dylib`'s codesign invocation, and re-signing after the fact risks drifting from the flags upstream uses. Rejected. |
| Keep manifests in tracked source, seed them into the XCframework at build time (chosen) | Survives the CI re-download; drives the upstream hook, so signing stays upstream's business | One more script in the build phase; depends on `utils.sh` internals (the `<module>.xcprivacy` convention) |
| Upgrade Python-Apple-support | Would inherit official manifests | No newer 3.13 release exists, and none of the shipped releases contain any `.xcprivacy`. Not available. |

## Decision

Keep the two manifests in tracked source under
`app/Keraunos/PythonResources/privacy-manifests/` and copy them into every
XCframework slice's `lib-dynload/` from a build-phase script that runs ahead of
`install_python`.

## Rationale

The seeding approach is the only one that survives Xcode Cloud's clean checkout
while still letting upstream own framework creation and signing. Writing into
the built app instead would mean re-implementing `install_dylib`'s codesign call
with `--preserve-metadata` and the right flags — a copy that would silently rot
against future Python-Apple-support releases.

Placing the files next to the `.so` also means a Python upgrade that reorganizes
`lib-dynload` fails loudly (the seeder exits non-zero when a declared module is
missing) rather than quietly shipping an unmanifested binary — the failure mode
that cost us a review cycle in the first place.

## What Changed

- **Added** `app/Keraunos/PythonResources/privacy-manifests/_ssl.xcprivacy` —
  no tracking, no collected data, `FileTimestamp / C617.1` for OpenSSL's
  `stat()` on the bundled certifi CA files.
- **Added** `app/Keraunos/PythonResources/privacy-manifests/_hashlib.xcprivacy` —
  no tracking, no collected data, no required-reason API (in-memory digests only).
- **Added** `app/Keraunos/PythonResources/seed-privacy-manifests.sh` — copies each
  manifest next to its matching `.so` in every `<slice>/lib-*/python3.*/lib-dynload`,
  and exits non-zero if a declared module isn't found.
- **Modified** `app/Keraunos/Keraunos.xcodeproj/project.pbxproj` — the "Process
  Python libraries" phase runs the seeder before `install_python`.
- **Modified** `CLAUDE.md` — gotcha entry, including the re-scan step for Python bumps.

## What Was Discovered

- **Apple can reject with no Resolution Center message.** `asc web review show`
  reported `threads: 0, messages: 0, rejections: 0` while the submission was
  plainly rejected. ITMS-level binary rejections arrive by email only; don't read
  an empty Resolution Center as "no reason recorded".
- **`asc review history` mislabels the rejected item type.** It reported
  `type: inAppPurchaseVersion` for an app that has zero IAPs and zero
  subscription groups; the web session correctly showed the item as the
  `appStoreVersion`. The type appears to be decoded from the composite item ID.
  Don't chase it.
- **Exactly two modules embed OpenSSL**, confirmed by scanning all extension
  modules rather than trusting the email's list:
  `strings -a *.so | grep -iE "OpenSSL [0-9]|BoringSSL"` hits only `_hashlib`
  and `_ssl`. The scan is recorded in the seeder's header for future upgrades.
- **The manifests land inside the code signature, not beside it.** Verified via
  `codesign --verify --strict` plus a grep of `_CodeSignature/CodeResources` —
  `install_dylib` installs the xcprivacy *before* signing, so ordering within the
  build phase matters. Seeding after `install_python` would have produced an
  unsealed file.
- **Builds 47, 48 and 49 carry the same defect.** They predate this fix, so
  attaching any of them would have burned another review cycle. The fix is only
  provable at Apple's processing step — the scanner runs server-side on upload,
  so a local build can confirm the manifest is present and sealed, but not that
  Apple accepts it.
