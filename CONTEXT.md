# Keraunos

A video downloader for iOS. This context covers everything between a pasted page link and a
finished video file on the device: choosing what to fetch, carrying it out durably in the
background, and delivering the result.

## Language

### What the user asks for

**Download**:
One video the user asked for, from pasted link to finished file. This is the only word for the
concept that crosses to the user — error copy, the Library, and the UI all say Download.
_Avoid_: transfer, job, item, task

**Source page**:
The link the user pastes. A page on a hosting site, not a media file — the media URLs are not
knowable until extraction runs.
_Avoid_: link, URL, source URL

**Library**:
Every finished Download held on the device. A Download enters the Library once and stays until
the user removes it.
_Avoid_: Downloads folder, saved files, gallery

### Choosing what to fetch

**Extraction**:
Resolving a Source page to direct media URL(s). Run by embedded yt-dlp, and the only step that
talks to the hosting site's page.
_Avoid_: scraping, parsing, probing

**Format**:
One rendition of a video a site offers — a height, a codec, and whether it arrives Progressive
or DASH. Sites offer many; a Download uses one.
_Avoid_: quality, variant, rendition

**Format selection**:
The durable record of which Format a Download chose. Deliberately enough to re-pick the *same*
Format on a later Extraction, so a resumed Download continues the byte-identical file rather
than silently switching renditions.

**Progressive**:
A Format whose video and audio arrive already combined in one stream. Needs no Merge.
_Avoid_: muxed, combined, single-file

**DASH**:
A Format whose video and audio arrive as two separate streams that must be merged into one
file. The distinction matters because only DASH Downloads can fail at Merge.
_Avoid_: adaptive, split, separate-stream

**Track**:
One media stream within a Download — the single stream of a Progressive Download, or the video
or the audio of a DASH pair. A Download has one Track or two, never more.
_Avoid_: stream, part, component

### Carrying it out

**Transfer**:
The durable background execution of a Download. Survives suspension, relaunch, and crash, and
is reconciled on launch. Internal machinery — a Transfer never appears in user-facing language.
_Avoid_: download (for the machinery), sync, upload

**Queue**:
The Transfers currently waiting, running, or awaiting Merge. Finished and cancelled Downloads
leave the Queue — the Queue is what is still happening, not a history.

**Part file**:
A Track's bytes on disk while still incomplete. Named, owned by the Transfer, and reconciled
against the Transfer's durable record on launch.
_Avoid_: temp file, body, chunk, fragment

**Refresh**:
Re-running Extraction because a media URL expired mid-Transfer, in order to continue the same
Download. A Refresh is invisible when the site needs no credential and becomes a sign-in prompt
when it does.
_Avoid_: retry, reload, re-resolve

**Integrity check**:
Verifying a completed Track's bytes against the length that was expected. Failing it means the
data is wrong or incomplete.

**Merge**:
Combining a DASH Download's two Tracks into one playable file. A Merge failure means the bytes
were intact but the codecs could not be combined — deliberately distinct from a failed Integrity
check, so the UI never blames the data for a codec problem.
_Avoid_: mux, remux, combine, join

**Finalization**:
The step that turns a verified Transfer into a Download in the Library. Crash-safe: a Download
is either absent from the Library or completely there, never half-written.
_Avoid_: completion, saving, commit

### Access

**Credential**:
The stored sign-in a Download uses to reach a site that requires one. Bound to a Download at
enqueue so a Refresh can re-authenticate as the same user.
_Avoid_: cookie, session, login, token

**Signed-in host**:
A site the user has an active Credential for. The unit the user signs in and out of — sign-out
is per host, never per Download.
