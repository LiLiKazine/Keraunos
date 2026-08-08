#!/bin/sh

# Seed per-module privacy manifests into the Python XCframework.
#
# Two CPython stdlib extension modules — _ssl and _hashlib — statically link
# OpenSSL. Apple's App Store scanner fingerprints that as BoringSSL /
# openssl_grpc, a "commonly used third-party SDK" which must carry a privacy
# manifest; without one the upload is rejected with ITMS-91061 and the version
# goes to INVALID_BINARY. (Keraunos build 46 was rejected exactly this way on
# 2026-08-07.) Python-Apple-support ships no manifests of its own.
#
# Python.xcframework/build/utils.sh already has the hook: install_dylib() looks
# for "<module>.xcprivacy" next to each .so and, if present, installs it into
# the generated framework as PrivacyInfo.xcprivacy — before it codesigns, so the
# signature stays valid. This script's job is to put those files there.
#
# It cannot be done by committing them into the XCframework: Python.xcframework/
# is gitignored (~115 MB) and ci_post_clone.sh re-downloads a pristine copy on
# Xcode Cloud, which would silently drop them and reintroduce the rejection. So
# the manifests live in tracked source under privacy-manifests/ and are copied
# in at build time, ahead of install_python.
#
# After bumping the Python-Apple-support version, re-check which modules embed
# OpenSSL — if the set changed, the manifests below must change with it:
#
#   cd Python.xcframework/ios-arm64/lib-arm64/python3.*/lib-dynload
#   for f in *.so; do
#     strings -a "$f" | grep -qiE "OpenSSL [0-9]|BoringSSL" && echo "$f"
#   done

set -e

XCFRAMEWORK_PATH=$1
if [ -z "$XCFRAMEWORK_PATH" ]; then
    echo "usage: seed-privacy-manifests.sh <path-to-Python.xcframework>" >&2
    exit 1
fi

MANIFEST_DIR="$(dirname "$0")/privacy-manifests"

for MANIFEST in "$MANIFEST_DIR"/*.xcprivacy; do
    MODULE=$(basename "$MANIFEST" .xcprivacy)
    SEEDED=0

    # Extension modules live per-slice, per-arch: <slice>/lib-<arch>/python3.N/lib-dynload.
    for DYNLOAD in "$XCFRAMEWORK_PATH"/*/lib-*/python3.*/lib-dynload; do
        [ -d "$DYNLOAD" ] || continue
        # Only seed next to a module that is actually present in this slice;
        # an orphaned manifest would never be picked up by install_dylib.
        ls "$DYNLOAD/$MODULE."*.so >/dev/null 2>&1 || continue
        cp "$MANIFEST" "$DYNLOAD/$MODULE.xcprivacy"
        SEEDED=$((SEEDED + 1))
    done

    if [ "$SEEDED" -eq 0 ]; then
        echo "error: no $MODULE extension module found in $XCFRAMEWORK_PATH;" >&2
        echo "       $MODULE.xcprivacy would not ship and the build would be" >&2
        echo "       rejected with ITMS-91061. Did the Python version change?" >&2
        exit 1
    fi

    echo "Seeded $MODULE.xcprivacy into $SEEDED slice(s)"
done
