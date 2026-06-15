# PythonRuntime resources

Keraunos embeds CPython 3.13 (BeeWare [Python-Apple-support], release **3.13-b14**)
to run yt-dlp for extraction only. Layout follows the b14 reference `testbed`.

## What is committed

- `app/keraunos_extract.py` — the extraction bridge (sys.path source dir).
- `app/cacert.pem` — certifi CA bundle (embedded Python has no system trust store;
  the C bridge points `SSL_CERT_FILE` at this).
- `app_packages/yt_dlp/…` — vendored pure-Python yt-dlp (no compiled extensions).

## What is NOT committed

`Python.xcframework/` is a large prebuilt binary and is gitignored. To restore it:

1. `gh release download 3.13-b14 --repo beeware/Python-Apple-support --pattern 'Python-3.13-iOS-support.b14.tar.gz'`
2. `tar -xzf Python-3.13-iOS-support.b14.tar.gz -C <tmp>`
3. `cp -R <tmp>/Python.xcframework app/Keraunos/Keraunos/PythonRuntime/`

## How it is wired (Xcode)

`Python.xcframework` is embedded (**Embed & Sign**). `app/` and `app_packages/` are
added as **folder references** (blue) so they land at `<bundle>/app` and
`<bundle>/app_packages`. A run-script phase (after "Embed Frameworks") copies the
stdlib out of the xcframework into `<bundle>/python/lib/python3.13` and processes
binary modules:

```sh
set -e
source "$PROJECT_DIR/Keraunos/PythonRuntime/Python.xcframework/build/utils.sh"
install_python "Keraunos/PythonRuntime/Python.xcframework" "Keraunos/PythonRuntime/app" "Keraunos/PythonRuntime/app_packages"
```

At runtime the C bridge sets `PYTHONHOME = <bundle>/python`, reads site config,
adds `app_packages` via `site.addsitedir`, and appends `app` to `sys.path`.

[Python-Apple-support]: https://github.com/beeware/Python-Apple-support
