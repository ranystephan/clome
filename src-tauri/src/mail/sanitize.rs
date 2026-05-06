//! HTML sanitiser for inbound message bodies. Two layers of defence:
//!
//!   1. **`ammonia`** — strips `<script>`, `<style>`, `<iframe>`,
//!      `<object>`, `<embed>`, `<link>`, `<meta>` (including
//!      `<meta http-equiv=refresh>`), event handlers (`on*`), and
//!      anything not on a vetted whitelist. Hostile authors lose the
//!      easy paths to script execution and CSS-based exfiltration.
//!
//!   2. **CSP via `<meta http-equiv>`** — when the renderer mounts
//!      this HTML inside its sandboxed iframe, the browser enforces
//!      `default-src 'none'` so the rendered DOM cannot fetch *any*
//!      remote resource without an explicit allow. Tracking pixels
//!      and remote stylesheets fail at the network layer, not the
//!      HTML layer — which means even bugs in our HTML allowlist
//!      can't leak the user's IP/session/UA.
//!
//! Per-sender remote-image opt-in is a separate UI concern: the
//! frontend re-invokes us with `allow_remote_images = true` after the
//! user clicks "Load remote images for this sender". Same .eml,
//! relaxed CSP, ammonia output reused.

use ammonia::Builder;

#[derive(Debug, Clone, Copy)]
pub struct SanitizeOptions {
    /// When false, the emitted CSP forbids `img-src` from `https:` /
    /// `http:` — image elements remain in the DOM but the browser
    /// refuses to fetch their bytes. Default false.
    pub allow_remote_images: bool,
    /// Strip 1x1 pixel-style tracking GIFs even with images allowed.
    /// Phase 5 wires the URL pattern list; for now this is a flag we
    /// expose but always treat as false until that pass lands.
    pub strip_tracking_pixels: bool,
}

impl Default for SanitizeOptions {
    fn default() -> Self {
        Self {
            allow_remote_images: false,
            // Strip even when CSP is blocking remote images — costs
            // nothing, hardens future paths (e.g. when a sender is
            // allowlisted), and removes visual debris for senders
            // that embed 1×1 trackers as inline placeholders.
            strip_tracking_pixels: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SanitizeOutput {
    pub html: String,
    /// True when the input contained at least one `<img src="http(s)://…">`.
    /// Drives the "Load images?" banner in the reading pane.
    pub had_remote_images: bool,
}

pub fn sanitize(html: &str, opts: &SanitizeOptions) -> SanitizeOutput {
    let cleaner = builder();
    let cleaned = cleaner.clean(html).to_string();
    let scrubbed = if opts.strip_tracking_pixels {
        strip_tracking_pixels(&cleaned)
    } else {
        cleaned
    };
    let collapsed = wrap_blockquotes_in_details(&scrubbed);
    let had_remote_images = contains_remote_image(html);
    let with_csp = wrap_with_csp(&collapsed, opts.allow_remote_images);
    SanitizeOutput {
        html: with_csp,
        had_remote_images,
    }
}

/// Known-tracker URL substrings. Tested case-insensitively against
/// each `<img src="…">` value. Conservative list — we'd rather miss a
/// pixel than nuke a real image. Add patterns as new senders surface
/// in dogfood.
const TRACKER_PATTERNS: &[&str] = &[
    "google-analytics.com",
    "googletagmanager.com",
    "fb.com/tr",
    "facebook.com/tr",
    "list-manage.com/track",
    "mailchimp.com/open",
    "mandrillapp.com/track",
    "sendgrid.net/wf/open",
    "sendgrid.net/asm/open",
    "constantcontact.com/track",
    "doubleclick.net",
    "linkedin.com/px",
    "/track/open",
    "/track/click",
    "/o.gif",
    "/open.gif",
    "/pixel.gif",
    "/spacer.gif",
    "stat-track",
    "click.linksynergy",
    "rs6.net/tn.jsp",
    "et.intuit.com/open",
    "open.aspx",
    "klclick.com",
    "klaviyomail.com/manage",
];

/// Strip `<img>` tags whose `src` URL matches a known tracker pattern,
/// or whose declared dimensions are 1×1 (a common cloak). Runs over
/// post-ammonia HTML so the tag boundaries are well-formed.
fn strip_tracking_pixels(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut chars = html.char_indices().peekable();
    while let Some((i, ch)) = chars.next() {
        if ch == '<' {
            // Byte-level checks so a nearby multi-byte char (e.g. `©`)
            // can't make the slice cross a UTF-8 boundary.
            let rest_bytes: &[u8] = &html.as_bytes()[i..];
            if rest_bytes.len() >= 4
                && rest_bytes[..4].eq_ignore_ascii_case(b"<img")
            {
                let after = rest_bytes.get(4).copied();
                if matches!(after, Some(b' ') | Some(b'\t') | Some(b'\n') | Some(b'/') | Some(b'>'))
                {
                    if let Some(end_rel) = rest_bytes.iter().position(|b| *b == b'>') {
                        // `>` is ASCII so end_rel is a valid char boundary.
                        let tag = &html[i..=i + end_rel];
                        if is_tracking_pixel(tag) {
                            for _ in 0..end_rel {
                                chars.next();
                            }
                            continue;
                        }
                        out.push_str(tag);
                        for _ in 0..end_rel {
                            chars.next();
                        }
                        continue;
                    }
                }
            }
        }
        out.push(ch);
    }
    out
}

fn is_tracking_pixel(tag: &str) -> bool {
    let lower = tag.to_ascii_lowercase();
    // Pattern-list match against any string in the tag (the src= value).
    if TRACKER_PATTERNS.iter().any(|p| lower.contains(p)) {
        return true;
    }
    // 1×1 sized image — even if URL is unknown, declared dimensions
    // 1×1 strongly imply a beacon. Match patterns:
    //   width="1" height="1"
    //   width=1 height=1
    //   style="width:1px;height:1px"
    let one_by_one = (lower.contains("width=\"1\"") || lower.contains("width=1"))
        && (lower.contains("height=\"1\"") || lower.contains("height=1"));
    if one_by_one {
        return true;
    }
    if lower.contains("width:1px") && lower.contains("height:1px") {
        return true;
    }
    false
}

/// Wrap top-level `<blockquote>` regions in `<details><summary>` so
/// the user can fold quoted-reply chains. Native HTML5 disclosure —
/// works without `allow-scripts` in the iframe sandbox.
///
/// Depth-tracking state machine: only the outermost blockquote gets
/// the wrapper. Nested quotes render as nested `<blockquote>` content
/// inside the same `<details>` (the user expands once and sees the
/// full quote tree).
fn wrap_blockquotes_in_details(html: &str) -> String {
    let mut out = String::with_capacity(html.len() + 64);
    let mut depth: u32 = 0;
    let mut chars = html.char_indices().peekable();
    while let Some((i, ch)) = chars.next() {
        if ch == '<' {
            // Compare on bytes (the tag name is ASCII-only) so we
            // don't risk slicing into the middle of a multi-byte
            // char like `©` that may sit nearby in the document.
            let rest_bytes: &[u8] = &html.as_bytes()[i..];
            // Closing tag </blockquote>
            if rest_bytes.len() >= 13
                && rest_bytes[..13].eq_ignore_ascii_case(b"</blockquote>")
            {
                if depth == 1 {
                    out.push_str("</blockquote></details>");
                } else {
                    out.push_str("</blockquote>");
                }
                depth = depth.saturating_sub(1);
                for _ in 0..12 {
                    chars.next();
                }
                continue;
            }
            // Opening tag <blockquote …>
            if rest_bytes.len() >= 11
                && rest_bytes[..11].eq_ignore_ascii_case(b"<blockquote")
            {
                let after = rest_bytes.get(11).copied();
                if matches!(
                    after,
                    Some(b'>') | Some(b' ') | Some(b'\t') | Some(b'\n') | Some(b'/')
                ) {
                    // Find end of opening tag — search bytes for `>`.
                    let end_rel = match rest_bytes.iter().position(|b| *b == b'>') {
                        Some(p) => p,
                        None => {
                            out.push(ch);
                            continue;
                        }
                    };
                    // Slice on the original `&str` is safe here
                    // because `>` is ASCII and we found its byte
                    // position; everything between `<` and `>` is
                    // either ASCII or a multi-byte char that ends
                    // before `>`, so end_rel sits at a valid char
                    // boundary.
                    let opening = &html[i..=i + end_rel];
                    if depth == 0 {
                        out.push_str("<details><summary>Show quoted text</summary>");
                    }
                    out.push_str(opening);
                    depth += 1;
                    for _ in 0..end_rel {
                        chars.next();
                    }
                    continue;
                }
            }
        }
        out.push(ch);
    }
    // Defensive: if depth > 0 at the end (unbalanced HTML), the
    // unclosed blockquote means we already inserted an opener but no
    // closer. Append the missing close to keep the page valid.
    while depth > 0 {
        out.push_str("</details>");
        depth -= 1;
    }
    out
}

fn builder() -> Builder<'static> {
    let mut b = Builder::default();
    // Default ammonia whitelist is conservative — it's almost what we
    // want. The two key hostile elements (`<script>`, `<style>`) are
    // already disallowed; `<link>`, `<meta>`, `<iframe>`, `<object>`,
    // `<embed>`, `<form>`, `<input>`, `<button>` are also out.
    //
    // We *add* a few inline-formatting tags ammonia happens to omit
    // but real email uses heavily, and we open up the `style`
    // attribute on common elements (CSP blocks remote @import, so the
    // remaining risk is layout-via-CSS exfiltration which the iframe
    // sandbox neutralises).
    b.add_generic_attributes(&["style"]);
    b.add_tags(&["font", "center", "tt", "big", "small"]);
    b.add_tag_attributes("font", &["size", "color", "face"]);
    b.add_tag_attributes("img", &["alt", "title", "width", "height", "style"]);
    // `rel` is reserved by ammonia (it auto-adds
    // `rel="noopener noreferrer"` and panics if userland tries to
    // override). We only opt into `target`.
    b.add_tag_attributes("a", &["target"]);
    b
}

fn contains_remote_image(html: &str) -> bool {
    // Cheap scan: walk every `<img` opening tag and check whether any
    // `src=…` value within its attribute span starts with `http`. We
    // avoid pulling in `regex` for a one-liner that the linker would
    // happily inline. Case-insensitive on the tag name and `src`.
    let bytes = html.as_bytes();
    let mut i = 0;
    while i + 4 < bytes.len() {
        if bytes[i] == b'<'
            && (bytes[i + 1] == b'i' || bytes[i + 1] == b'I')
            && (bytes[i + 2] == b'm' || bytes[i + 2] == b'M')
            && (bytes[i + 3] == b'g' || bytes[i + 3] == b'G')
            && !bytes[i + 4].is_ascii_alphanumeric()
        {
            // Find the closing `>` of this tag.
            let mut j = i + 4;
            while j < bytes.len() && bytes[j] != b'>' {
                j += 1;
            }
            let tag = &html[i + 4..j.min(bytes.len())];
            if attr_starts_with(tag, "src", "http") {
                return true;
            }
            i = j;
        } else {
            i += 1;
        }
    }
    false
}

/// True iff `tag` (the inside of an HTML open tag, no `<` `>`) has
/// an attribute named `name` (case-insensitive) whose value starts
/// with `prefix` (case-insensitive). Quotes / whitespace tolerated.
fn attr_starts_with(tag: &str, name: &str, prefix: &str) -> bool {
    let lower = tag.to_ascii_lowercase();
    let needle = name.to_ascii_lowercase();
    let mut search = lower.as_str();
    while let Some(pos) = search.find(&needle) {
        // Must start at a word boundary.
        let pre = search.as_bytes().get(pos.wrapping_sub(1)).copied();
        let prev_ok = pos == 0 || matches!(pre, Some(b) if !b.is_ascii_alphanumeric());
        let after = pos + needle.len();
        let post = search.as_bytes().get(after).copied();
        let next_ok = matches!(post, Some(b' ') | Some(b'\t') | Some(b'='));
        if prev_ok && next_ok {
            // Skip whitespace + `=` + whitespace + optional quote.
            let mut k = after;
            let bytes = search.as_bytes();
            while k < bytes.len() && (bytes[k] == b' ' || bytes[k] == b'\t') {
                k += 1;
            }
            if k < bytes.len() && bytes[k] == b'=' {
                k += 1;
                while k < bytes.len() && (bytes[k] == b' ' || bytes[k] == b'\t') {
                    k += 1;
                }
                if k < bytes.len() && (bytes[k] == b'"' || bytes[k] == b'\'') {
                    k += 1;
                }
                if search[k..].to_ascii_lowercase().starts_with(prefix) {
                    return true;
                }
            }
        }
        search = &search[pos + needle.len()..];
    }
    false
}

fn wrap_with_csp(body: &str, allow_remote_images: bool) -> String {
    // Mail HTML is normally a fragment. The renderer hosts it inside
    // a sandboxed iframe via `srcdoc`, so we wrap it in a minimal
    // <html>+CSP shell here. The CSP is the load-bearing security
    // boundary — even if ammonia's whitelist had a hole, the browser
    // still won't fetch http(s):// resources.
    let img_src = if allow_remote_images {
        // `https:` covers the wide-open case; `data:` for inline
        // base64 already-decoded images; `cid:` for inline parts the
        // renderer will rewrite to local file URLs.
        "data: cid: https:"
    } else {
        "data: cid:"
    };
    // Note on omissions:
    //   * `frame-ancestors` is HTTP-header-only — browsers ignore it
    //     when delivered via <meta>. The iframe-sandbox already
    //     blocks navigation/embed escape paths it would have covered.
    //   * `sandbox` directive likewise must come from the renderer
    //     (we set `sandbox="allow-same-origin"` on the iframe element
    //     in MailApp.tsx).
    let csp = format!(
        "default-src 'none'; \
         img-src {img_src}; \
         style-src 'unsafe-inline'; \
         font-src data:; \
         form-action 'none'; \
         base-uri 'none';"
    );
    // Defensive reset stylesheet. Marketing emails routinely declare
    // `<table width="800">` / `<img width="...">` and overflow the
    // reading pane (horizontal scroll, the bane of email UX). The
    // forced `max-width: 100% !important` rules cover ~95% of those
    // pathological layouts. We deliberately do NOT theme content —
    // the sender's branding wins; we only force structural sanity.
    //
    // `<details>`-based quote collapsing works because it's an HTML5
    // primitive (no JS needed) — the iframe's `sandbox=allow-same-origin`
    // restriction blocks scripts but allows native form/disclosure UI.
    let reset = "html,body{margin:0;padding:0;max-width:100%!important;\
                 word-wrap:break-word;overflow-wrap:break-word;\
                 font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",\
                 sans-serif;font-size:14px;line-height:1.55;\
                 color:#202124;background:transparent}\
                 *{max-width:100%!important;box-sizing:border-box}\
                 table{max-width:100%!important;table-layout:auto;\
                 border-collapse:collapse}\
                 td,th{word-break:break-word}\
                 img,video{max-width:100%!important;height:auto!important;\
                 display:inline-block;border:0}\
                 a{color:#1a73e8;text-decoration:underline;\
                 text-decoration-color:rgba(26,115,232,0.4)}\
                 blockquote{margin:0.6em 0;padding:0 0 0 0.85em;\
                 border-left:3px solid rgba(127,127,127,0.3)}\
                 details>summary{cursor:pointer;display:inline-block;\
                 padding:0.3em 0.6em;border-radius:6px;\
                 background:rgba(127,127,127,0.08);\
                 border:1px solid rgba(127,127,127,0.2);\
                 font-size:12px;color:rgba(80,80,80,0.85);\
                 list-style:none;user-select:none}\
                 details>summary::-webkit-details-marker{display:none}\
                 details[open]>summary{margin-bottom:0.4em}\
                 pre{white-space:pre-wrap;word-wrap:break-word;\
                 overflow-x:auto;max-width:100%!important}";
    format!(
        "<!doctype html>\
         <html><head>\
         <meta charset=\"utf-8\">\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">\
         <style>{reset}</style>\
         </head><body>{body}</body></html>"
    )
}

/// Returns true when the address looks like a typical bulk-mail /
/// list-server sender. Used by the renderer to nudge the user toward
/// per-sender allowlist decisions ("This is a newsletter — load
/// images?"). Phase 5 polish; stub here so the API exists.
pub fn looks_like_bulk_sender(_from_addr: &str) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_script_tags() {
        let out = sanitize("<p>hi<script>alert(1)</script></p>", &SanitizeOptions::default());
        assert!(!out.html.contains("<script"));
        assert!(out.html.contains("hi"));
    }

    #[test]
    fn drops_event_handlers() {
        let out = sanitize(
            "<a href=\"https://example.com\" onclick=\"steal()\">click</a>",
            &SanitizeOptions::default(),
        );
        assert!(!out.html.contains("onclick"));
        assert!(out.html.contains("href"));
    }

    #[test]
    fn detects_remote_images() {
        let out = sanitize(
            r#"<p>hi</p><img src="https://tracker.example/p.gif">"#,
            &SanitizeOptions::default(),
        );
        assert!(out.had_remote_images);
    }

    #[test]
    fn csp_blocks_remote_by_default() {
        let out = sanitize("<p>x</p>", &SanitizeOptions::default());
        assert!(out.html.contains("default-src 'none'"));
        assert!(out.html.contains("img-src data: cid:"));
        assert!(!out.html.contains("https:"));
    }

    #[test]
    fn csp_relaxes_when_allowed() {
        let opts = SanitizeOptions {
            allow_remote_images: true,
            strip_tracking_pixels: false,
        };
        let out = sanitize("<p>x</p>", &opts);
        assert!(out.html.contains("https:"));
    }

    #[test]
    fn no_remote_images_when_absent() {
        let out = sanitize("<p>plain text</p>", &SanitizeOptions::default());
        assert!(!out.had_remote_images);
    }

    #[test]
    fn outer_blockquote_wrapped_in_details() {
        let out = sanitize(
            "<p>reply</p><blockquote><p>quoted</p></blockquote>",
            &SanitizeOptions::default(),
        );
        assert!(out.html.contains("<details><summary>Show quoted text</summary><blockquote>"));
        assert!(out.html.contains("</blockquote></details>"));
    }

    #[test]
    fn nested_blockquotes_only_outer_wrapped() {
        let out = sanitize(
            "<blockquote>outer<blockquote>inner</blockquote>outer</blockquote>",
            &SanitizeOptions::default(),
        );
        // Only one <details> — depth-tracking wraps just the outer.
        let count = out.html.matches("<details>").count();
        assert_eq!(count, 1);
    }

    #[test]
    fn no_blockquote_no_details() {
        let out = sanitize("<p>just a paragraph</p>", &SanitizeOptions::default());
        assert!(!out.html.contains("<details>"));
    }

    #[test]
    fn strips_known_tracker_url() {
        let out = sanitize(
            r#"<p>hi</p><img src="https://www.google-analytics.com/collect?v=1"><p>bye</p>"#,
            &SanitizeOptions::default(),
        );
        assert!(!out.html.contains("google-analytics"));
        assert!(out.html.contains("hi"));
        assert!(out.html.contains("bye"));
    }

    #[test]
    fn strips_one_by_one_pixel() {
        let out = sanitize(
            r#"<img src="https://example.com/p.gif" width="1" height="1">"#,
            &SanitizeOptions::default(),
        );
        assert!(!out.html.contains("example.com/p.gif"));
    }

    #[test]
    fn keeps_real_image() {
        let out = sanitize(
            r#"<img src="https://example.com/photo.jpg" width="600" height="400">"#,
            &SanitizeOptions::default(),
        );
        assert!(out.html.contains("photo.jpg"));
    }

    /// Regression: marketing emails commonly drop a `©` symbol near
    /// closing tags. Earlier versions of `wrap_blockquotes_in_details`
    /// and `strip_tracking_pixels` byte-sliced the `&str` past the
    /// `©` byte boundary and panicked.
    #[test]
    fn handles_multibyte_chars_near_tags() {
        let body = "<p>hi</p><br>\n            © 2026 Best Buy.\n<blockquote>q</blockquote>";
        // Just shouldn't panic. The contents are sanitised + wrapped
        // and we assert the © survives.
        let out = sanitize(body, &SanitizeOptions::default());
        assert!(out.html.contains("©"));
        assert!(out.html.contains("<details>"));
    }
}
