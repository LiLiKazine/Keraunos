# PythonResources

Keraunos embeds CPython 3.13 (BeeWare [Python-Apple-support], release **3.13-b14**)
to run yt-dlp for extraction only. Layout follows the b14 reference `testbed`.

This folder sits **outside** the file-system-synchronized `Keraunos/` source root
on purpose: its contents are bundle **resources** (added as folder references), not
compiled sources. The C/Swift bridge that drives the interpreter lives under
`Keraunos/PythonRuntime/` (auto-compiled by the synchronized group).

## What is committed

- `app/keraunos_extract.py` — the extraction bridge (a sys.path source dir).
- `app/cacert.pem` — certifi CA bundle (embedded Python has no system trust store;
  the C bridge points `SSL_CERT_FILE` at this).
- `app_packages/yt_dlp/…` — vendored pure-Python yt-dlp (no compiled extensions).

## What is NOT committed

`Python.xcframework/` is a large prebuilt binary and is gitignored. To restore it:

1. `gh release download 3.13-b14 --repo beeware/Python-Apple-support --pattern 'Python-3.13-iOS-support.b14.tar.gz'`
2. `tar -xzf Python-3.13-iOS-support.b14.tar.gz -C <tmp>`
3. `cp -R <tmp>/Python.xcframework app/Keraunos/PythonResources/`

On **Xcode Cloud** this restore happens automatically: `app/Keraunos/ci_scripts/ci_post_clone.sh`
fetches the same release after the clean checkout, before the build links the framework.

## How it is wired (Xcode)

- `Python.xcframework` → Keraunos target **General → Frameworks, Libraries, and
  Embedded Content**, set **Embed & Sign**.
- `app/` and `app_packages/` → **Copy Bundle Resources** as **folder references**
  (blue), so they land at `<bundle>/app` and `<bundle>/app_packages`.
- A run-script phase **after "Embed Frameworks"** (paths relative to `$PROJECT_DIR`
  = `app/Keraunos`), with **User Script Sandboxing = No**:

```sh
set -e
source "$PROJECT_DIR/PythonResources/Python.xcframework/build/utils.sh"
install_python "PythonResources/Python.xcframework" "PythonResources/app" "PythonResources/app_packages"
```

This copies the stdlib out of the xcframework into `<bundle>/python/lib/python3.13`
and processes binary modules. At runtime the C bridge sets `PYTHONHOME =
<bundle>/python`, reads site config, and appends `app_packages` + `app` to `sys.path`.

[Python-Apple-support]: https://github.com/beeware/Python-Apple-support
