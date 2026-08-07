# Privacy Policy for Keraunos

**Last updated:** 8 August 2026

Keraunos is a video downloader for iPhone and iPad. This policy explains what the
app does with your information. The short version: **Keraunos collects nothing.**
There is no account, no analytics, no tracking, and no server operated by the
developer. Everything the app stores stays on your device.

Keraunos is free and open source under the GPLv3. If you want to verify any claim
below, the entire source is at <https://github.com/LiLiKazine/Keraunos>.

## Data collected by the developer

**None.** Keraunos has no backend. Nothing you do in the app is transmitted to
the developer, and no data is sold, rented, or shared with anyone.

The app contains no analytics, advertising, attribution, or crash-reporting
software, and no third-party software development kits of any kind.

## What Keraunos stores on your device

All of the following is written to Keraunos' own storage on your device and is
removed when you delete the app:

- **Downloaded media** — saved in the app's Documents folder, which is also
  visible under *On My iPhone → Keraunos* in the Files app. You can delete any
  download from within the app or from Files.
- **Download queue state** — the list of in-progress and pending transfers, kept
  so a download survives the app being backgrounded, suspended, or relaunched.
- **Preferences** — your settings, such as preferred quality.
- **A failure log** — a redacted, on-device record of download errors that you
  can read inside the app. It exists so a failure can be diagnosed without you
  having to send anything to anyone.
- **Sign-in cookies** — see below.

## Network connections

Keraunos only contacts the addresses you give it: the link you paste or share,
and the media servers that link resolves to. There is no other network traffic.

Those third-party sites and servers necessarily see the request as it arrives —
which includes your IP address, your device's user agent, and any cookies you
have for that site. That processing is governed by **their** privacy policies,
not this one. Keraunos has no control over and no visibility into what they do
with it.

## Signing in to a site

Keraunos lets you optionally sign in to a site so you can reach content your own
account has access to — your private uploads, members-only material, or
age-restricted videos.

- Sign-in happens in a web view provided by the operating system. **Your username
  and password are entered on the site's own page and are never seen, handled, or
  stored by Keraunos.**
- The resulting login cookies are stored on your device only, in the system web
  data store.
- When a download needs those cookies, they are written to a temporary,
  file-protected file for the duration of that download and then discarded. The
  temporary folder is also cleared at launch.
- You can sign out of any site from the Accounts screen, which deletes that
  site's cookies from your device.
- Cookies are never transmitted anywhere except back to the site they belong to.

Note that this web view can load whatever site you enter, so it can reach the
open web. Nothing you browse in it is recorded by Keraunos.

## Photos

If you tap *Save to Photos*, Keraunos asks iOS for add-only permission to your
photo library and writes that one video to it. The app cannot read, browse, or
modify your existing photos, and it never requests that ability.

## Sharing a link to Keraunos

The Keraunos share extension accepts a web URL or text you share to it from
another app. That link is passed to the main app to be downloaded. It is not
logged or transmitted anywhere else.

## Children

Keraunos is not directed at children and does not knowingly collect information
from anyone. Because the optional sign-in web view can reach the open web, the
app carries a 17+ age rating on the App Store.

## Your choices

Because nothing leaves your device, there is no account to close and no data for
the developer to hand over or delete. You have direct control:

- Delete individual downloads in the app or in the Files app.
- Sign out of a site to erase its cookies.
- Delete Keraunos to remove everything it has stored.

## Changes to this policy

If this policy changes, the updated version will be published at this address
and the date at the top will change. Because the app is open source, the full
revision history of this document is public in the repository.

## Contact

Questions or concerns about privacy in Keraunos are welcome as an issue at
<https://github.com/LiLiKazine/Keraunos/issues>.
