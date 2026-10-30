//! URLs (docs/adr/0011): a link or a sheet's href against its page's URL,
//! by WHATWG's URL parser (the url crate, Servo's), into its serialization:
//! one page has one URL in history, the cache and the bar, and NSURLSession
//! gets an absolute URL with its host already in ASCII.
//!
//! Measured on 30 Oct 2026 against WPT's urltestdata.json, the cases with an
//! http or https base: NSURL with a pre-pass of WHATWG's agreed with 111 of
//! 202 (it reads `0xffffffff` and `256` as names, takes invalid hosts and
//! ports, and resolves `///host` as a path); the url crate with 195. It adds
//! 230 KB to the platform library, mostly Unicode tables for IDNA.

use crate::{ERR_ARGUMENT, GSlice, guarded};

/// The scheme `url` starts with, lower case, or "" with none.
pub(crate) fn scheme_of(url: &str) -> String {
    match url.split_once(':') {
        Some((s, _))
            if s.starts_with(|c: char| c.is_ascii_alphabetic())
                && s.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"+-.".contains(&c)) =>
        {
            s.to_ascii_lowercase()
        }
        _ => String::new(),
    }
}

/// `href` resolved against `base` (absolute) by WHATWG's URL parser, in its
/// serialization; None when it can't be.
pub fn resolve(base: &str, href: &str) -> Option<String> {
    let base = ::url::Url::parse(base).ok()?;
    base.join(href).ok().map(String::from)
}

/// Resolves `href` against `base`, both UTF-8, into `out` when `out` is as
/// long as the result. Returns the result's length either way: call with an
/// empty `out` to learn it. ERR_ARGUMENT when `href` doesn't resolve.
#[unsafe(no_mangle)]
pub extern "C" fn tp_url_resolve(base: GSlice<u8>, href: GSlice<u8>, out: GSlice<u8>) -> i32 {
    guarded(|| {
        let base = std::str::from_utf8(unsafe { base.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        let href = std::str::from_utf8(unsafe { href.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        let url = resolve(base, href).ok_or(ERR_ARGUMENT)?;
        let len = i32::try_from(url.len()).map_err(|_| ERR_ARGUMENT)?;
        if out.count() == Some(url.len()) {
            unsafe { out.copy_from(url.as_bytes()) };
        }
        Ok(len)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tab's base and what pages write, as they reach us: Wikipedia's,
    /// MDN's, the Rust book's and Hacker News's own hrefs among them.
    #[test]
    fn hrefs_resolve_as_browsers_resolve_them() {
        let wiki = "https://en.wikipedia.org/wiki/Focaccia?x=1#top";
        for (href, want) in [
            (
                "/w/load.php?lang=en&modules=a%7Cb",
                "https://en.wikipedia.org/w/load.php?lang=en&modules=a%7Cb",
            ),
            (
                "./Category:Bread",
                "https://en.wikipedia.org/wiki/Category:Bread",
            ),
            (
                "../w/a b/ü.css",
                "https://en.wikipedia.org/w/a%20b/%C3%BC.css",
            ),
            ("//cdn.example.com/x.css", "https://cdn.example.com/x.css"),
            (
                "?only=styles",
                "https://en.wikipedia.org/wiki/Focaccia?only=styles",
            ),
            (
                "#History",
                "https://en.wikipedia.org/wiki/Focaccia?x=1#History",
            ),
            ("", "https://en.wikipedia.org/wiki/Focaccia?x=1"),
            ("  /trim/me \n", "https://en.wikipedia.org/trim/me"),
            ("/a\tb\nc", "https://en.wikipedia.org/abc"),
            (
                "\\back\\slash?q=\\",
                "https://en.wikipedia.org/back/slash?q=\\",
            ),
            (
                "https://münchen.de/straße",
                "https://xn--mnchen-3ya.de/stra%C3%9Fe",
            ),
            (
                "HTTPS://EN.Wikipedia.org:443/./a/../b",
                "https://en.wikipedia.org/b",
            ),
            ("http://Example.COM:80", "http://example.com/"),
            ("http://0xffffffff/", "http://255.255.255.255/"),
            ("https://example.com:8443/x", "https://example.com:8443/x"),
            ("mailto:x@y.z", "mailto:x@y.z"),
        ] {
            assert_eq!(resolve(wiki, href).as_deref(), Some(want), "{href:?}");
        }
        let book = "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html";
        assert_eq!(
            resolve(book, "css/variables-8adf115d.css").as_deref(),
            Some("https://doc.rust-lang.org/book/css/variables-8adf115d.css")
        );
        assert_eq!(
            resolve(
                "https://news.ycombinator.com/",
                "news.css?Z6eHuL4AiZDrSCqdz7DG"
            )
            .as_deref(),
            Some("https://news.ycombinator.com/news.css?Z6eHuL4AiZDrSCqdz7DG")
        );
        assert_eq!(resolve(wiki, "https://exa mple.com/"), None);
        assert_eq!(resolve("not a url", "/x"), None);
    }

    #[test]
    fn the_result_is_copied_only_into_a_slice_of_its_length() {
        let mut base = *b"https://a.org/b/c";
        let mut href = *b"../d";
        let slice = |v: &mut [u8]| GSlice {
            data: v.as_mut_ptr(),
            len: v.len() as i64,
        };
        let none = GSlice::<u8> {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let want = "https://a.org/d";
        assert_eq!(
            tp_url_resolve(slice(&mut base), slice(&mut href), none),
            want.len() as i32
        );
        let mut out = vec![0u8; want.len()];
        assert_eq!(
            tp_url_resolve(slice(&mut base), slice(&mut href), slice(&mut out)),
            want.len() as i32
        );
        assert_eq!(out, want.as_bytes());
        let mut bad = *b"https://exa mple.com/";
        assert_eq!(
            tp_url_resolve(slice(&mut base), slice(&mut bad), none),
            ERR_ARGUMENT
        );
    }

    /// WPT's url/resources/urltestdata.json, by hand: the cases with an http
    /// or https base, against what we resolve. `WPT_URLS=path cargo test
    /// --release -- --ignored wpt --nocapture`.
    #[test]
    #[ignore]
    fn wpt_urltestdata() {
        let path = std::env::var("WPT_URLS").expect("WPT_URLS");
        let text = std::fs::read_to_string(path).unwrap();
        // A JSON reader of our own is too much for a check by hand: python3
        // flattens the file first, to input, base and href (or FAILURE)
        // apart by U+001F, cases apart by U+001E.
        let mut pass = 0;
        let mut fail = Vec::new();
        for line in text.split('\x1e') {
            let f: Vec<&str> = line.split('\x1f').collect();
            let [input, base, want] = f[..] else { continue };
            let got = resolve(base, input).unwrap_or_else(|| "FAILURE".into());
            if got == want {
                pass += 1;
            } else {
                fail.push(format!("{input:?} on {base:?}: want {want:?}, got {got:?}"));
            }
        }
        for f in &fail {
            println!("{f}");
        }
        println!("{pass} of {} as WHATWG says", pass + fail.len());
    }
}
