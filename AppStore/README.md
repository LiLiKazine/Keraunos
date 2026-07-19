# App Store screenshots

Marketing screenshots for the App Store Connect listing, composed from the
Keraunos design-system screens (Claude Design project → genericized sample
content). Dark UI, electric-blue accent, on-brand captions.

## Upload sets

| Folder | ASC display size | Pixels | Notes |
|--------|------------------|--------|-------|
| `screenshots/iPhone-6.9` | iPhone 6.9" | 1320 × 2868 | **Required.** Covers the whole iPhone lineup. |
| `screenshots/iPhone-6.5` | iPhone 6.5" | 1242 × 2688 | Optional legacy set (same story). |
| `screenshots/iPad-13`    | iPad 13"    | 2752 × 2064 | Landscape. Upload if the app ships on iPad. |

Files are numbered in intended display order.

Story: **Home** (paste → download) · **Quality** (audio → 4K) · **Library**
(offline) · **Share** (play/share/save to Photos, iPhone) · **Accounts**
(sign-in, iPhone).

## Genericization

Marketing shots use neutral sample content only — `example.com` URLs, generic
titles (`Warehouse Mix`, `Coding tips — 100 seconds`), and placeholder account
hosts (`example.com`, `clips.example`, `stream.example`). No third-party
trademarks or real URLs, to avoid App Review friction for a downloader app.

## Regenerate

```bash
cd generator
node gen.mjs        # writes posters/*.html at exact ASC pixel sizes
bash render.sh      # renders posters/ → out/png/*.png via headless Chrome
```

- `gen.mjs` — poster generator. Screen markup + CSS are copied verbatim from the
  design-system pages; edit the `screens` array to change captions or the story.
- `render.sh` — headless-Chrome renderer (`--force-device-scale-factor=1`, exact
  `--window-size`), so a 1320×2868 poster exports to a 1320×2868 PNG 1:1.
