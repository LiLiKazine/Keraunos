#!/bin/sh

# Xcode Cloud post-clone step.
#
# Python.xcframework (~115 MB, BeeWare Python-Apple-support) is gitignored and so is
# absent from the clean CI checkout. Without it the build fails to link with
# "no XCFramework found at .../PythonResources/Python.xcframework". Fetch and unpack
# it here, before the build phase that sources its build/utils.sh.
#
# See app/Keraunos/PythonResources/README.md for the framework's role and Xcode wiring.

set -e

PYTHON_SUPPORT_TAG="3.13-b14"
ASSET="Python-3.13-iOS-support.b14.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_SUPPORT_TAG}/${ASSET}"
DEST="${CI_PRIMARY_REPOSITORY_PATH}/app/Keraunos/PythonResources"

if [ -d "${DEST}/Python.xcframework" ]; then
  echo "Python.xcframework already present — skipping download."
  exit 0
fi

echo "Fetching ${ASSET} (Python-Apple-support ${PYTHON_SUPPORT_TAG})…"
WORK="$(mktemp -d)"
curl -fL "${URL}" -o "${WORK}/python-support.tar.gz"
tar -xzf "${WORK}/python-support.tar.gz" -C "${WORK}"
cp -R "${WORK}/Python.xcframework" "${DEST}/"
rm -rf "${WORK}"
echo "Python.xcframework restored to ${DEST}."
