# Blob-tolerant URL extraction

**Date:** 2026-06-25
**Status:** Approved, pending implementation

## Problem

Share buttons on Douyin, Bilibili, and RedNote (Xiaohongshu) don't copy a bare
link — they copy a promotional blob with the URL buried inside free text. Example
(Douyin):

```
2.02 复制打开抖音，看看【雉鸣minz的作品】凡凡 可爱美丽又迷人 # 萤火虫漫展 # 漫展养眼...https://v.douyin.com/9GUjWCxpa18/ 凡凡  可爱美丽又迷人 #萤火虫漫展 #漫展养眼造型大赏 #夜晚拍照才有感觉 #yi凡凡 - 抖音 A@G.iP NWz:/ :2pm 05/25
```

Today `URLNormalizer.normalize(_:)` trims the whole string and treats it as a single
URL candidate. A blob like the above fails the `URLComponents` parse (spaces, no
clean host), so the user gets "Enter a valid http(s) link." and has to hand-edit the
paste down to just the URL.

## Goal

Pasting one of these blobs and tapping **Download** should Just Work: the embedded
`http(s)://` link is extracted automatically and handed to the extractor.

## Decisions

- **When/where:** extraction happens at download time, silently, folded into
  `URLNormalizer.normalize(_:)`. The text field keeps showing the raw blob; the clean
  URL is used internally. This is the smallest change and benefits every entry point —
  the text field, `keraunos://` deep links, and Shortcuts all funnel through
  `normalize()` (via `IncomingURL`). No new public type, no call-site changes.
- **Detection:** match the **first explicit `http(s)://` substring**. Scheme-less
  embedded links (`v.douyin.com/xxx`) and host whitelists are explicitly out of scope —
  the noise in real blobs (`A@G.iP`, `凡凡 - 抖音`) is full of domain-shaped tokens, and
  requiring an explicit scheme is what makes detection robust against them.

## Design

A private helper added as the **first step** of `normalize(_:)`:

1. Trim surrounding whitespace/newlines (as today).
2. Case-insensitively find the first occurrence of `http://` or `https://`.
3. **If found:** take the run of characters from that point up to the first character
   *not* allowed in a URI. Allowed set: ASCII alphanumerics plus
   `-._~:/?#[]@!$&'()*+,;=%`. This stops the link at whitespace, CJK text, quotes,
   etc. Then strip trailing sentence punctuation (`.`, `,`, `;`, and an unmatched
   closing `)`) so a URL ending a sentence isn't captured with the period. The result
   is the candidate.
4. **If not found:** the candidate is the whole trimmed string — preserving today's
   scheme-less path (e.g. `youtube.com/watch?v=abc`).
5. Feed the candidate into the existing scheme/host validation unchanged (http(s)-only,
   dotted host, RFC 3986 lowercasing of scheme + host).

The blob scan is **purely additive**: when no `http(s)://` is present, behavior is
identical to today, so every existing `URLNormalizerTests` case still passes.

### Why short links need no special handling

`https://v.douyin.com/9GUjWCxpa18/`, `b23.tv/…`, and `xhslink.com/…` are redirect
shorteners. yt-dlp follows the redirect during extraction, so Swift hands the short
link over as-is — no client-side resolution.

## Out of scope

- Scheme-less embedded link detection (`v.douyin.com/xxx` without `https://`).
- Platform/host whitelisting.
- Cleaning the text field on paste / showing the extracted URL for confirmation.
- Picking among multiple links by platform — first `http(s)://` wins.

## Testing

Pure-Swift unit tests in `URLNormalizerTests` (TDD — written first):

- The Douyin blob above → `https://v.douyin.com/9GUjWCxpa18/`.
- A Bilibili `b23.tv` share blob → the embedded link.
- A RedNote `xhslink.com` share blob → the embedded link.
- URL immediately followed by CJK with no space (`…/9GUjWCxpa18凡凡`) → stops at `凡`.
- URL ending a sentence (`…/9GUjWCxpa18.`) → trailing `.` stripped.
- Two URLs in one blob → the first wins.
- All existing cases (clean URL, scheme-less, whitespace trim, reject non-URL / bad
  scheme, RFC case normalization) continue to pass unchanged.
