//! The network (docs/adr/0011): Apple's URL loading system, driven for tab
//! workers. A worker asks for a URL and gets a request id; the session's
//! delegate collects the bytes on a serial queue of its own, and when the
//! request ends posts `MSG_NET` to the worker's mailbox (tabs.rs), which
//! wakes it. Neither Goose thread waits on the network or polls it.
//!
//! A profile is a session, with its own cookies and cache (docs/adr/0008).
//! What crosses into Goose is UTF-8: documents and sheets in any other
//! charset are decoded here, on the delegate's queue.
//!
//! Locks: NET and SESSIONS are never held while taking tabs.rs's lock, and
//! tasks are cancelled outside NET, so no two locks are ever waited on in
//! opposite orders.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, MutexGuard};

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{AnyThread, DefinedClass, define_class, msg_send};
use objc2_core_foundation::{CFString, kCFStringEncodingInvalidId};
use objc2_foundation::{
    NSData, NSError, NSHTTPURLResponse, NSMutableURLRequest, NSObject, NSObjectProtocol,
    NSOperationQueue, NSQualityOfService, NSString, NSURL, NSURLCache, NSURLRequestCachePolicy,
    NSURLSession, NSURLSessionConfiguration, NSURLSessionDataDelegate, NSURLSessionDataTask,
    NSURLSessionDelegate, NSURLSessionTask, NSURLSessionTaskDelegate,
};

use crate::{ERR_ARGUMENT, GSlice, guarded, tabs};

// What a request is for; the Goose side mirrors these numbers.
pub const NET_DOCUMENT: i32 = 1;
pub const NET_STYLE: i32 = 2;
pub const NET_IMAGE: i32 = 3;

// Profiles (docs/adr/0008): Sandbox keeps nothing; Default is ours.
pub const PROFILE_SANDBOX: i32 = 0;
pub const PROFILE_DEFAULT: i32 = 1;
const PROFILES: usize = 2;

// Flags for tp_net_open.
pub const NET_RELOAD: i32 = 1; // past the cache, to the server

/// A URL a page may not load: not http or https, or http asked for by an
/// https page.
pub const ERR_BLOCKED: i32 = -6;

// Why a finished request has no body, beside NSURLErrorDomain's own codes
// (all negative, -1001 a timeout, -1003 no such host, -1200 TLS...).
pub const NET_TOO_BIG: i32 = -30001;
pub const NET_FAILED: i32 = -30002; // an error from another domain

// What one response may weigh, by kind: a sanity limit, not a budget.
const CAPS: [usize; 4] = [0, 64 << 20, 16 << 20, 32 << 20];

// Request ids travel in a TabMsg's f32, exact below 2^24.
const MAX_ID: i32 = 1 << 24;

// Safari's own, so sites send what they send Safari, and our name after it.
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
                          (KHTML, like Gecko) Version/26.5 Safari/605.1.15 Tusk/0.1";

/// A request's state, laid out as Goose's `struct NetHead`: its id, the HTTP
/// status, why it failed (0 when it didn't), what it is for, how many bytes
/// its body, final URL, MIME type and error text have, and the body's
/// expected size (-1 when the server didn't say).
#[repr(C, packed)]
#[derive(Clone, Copy, Debug, Default)]
pub struct NetHead {
    pub req: i32,
    pub status: i32,
    pub error: i32,
    pub kind: i32,
    pub body: i64,
    pub url: i64,
    pub mime: i64,
    pub text: i64,
    pub expected: i64,
}

struct Req {
    tab: i32,
    kind: i32,
    profile: usize,
    task: Retained<NSURLSessionDataTask>,
    done: bool,
    status: i32,
    error: i32,
    expected: i64,
    body: Vec<u8>,
    url: Vec<u8>,
    mime: Vec<u8>,
    text: Vec<u8>,
}

#[derive(Default)]
struct Net {
    last: i32,
    reqs: HashMap<i32, Req>,
    /// A session's task, by profile and task identifier, to its request.
    tasks: HashMap<(usize, usize), i32>,
}

static NET: LazyLock<Mutex<Net>> = LazyLock::new(Default::default);
static SESSIONS: Mutex<[Option<Retained<NSURLSession>>; PROFILES]> =
    Mutex::new([const { None }; PROFILES]);

fn net() -> MutexGuard<'static, Net> {
    // Every change under the lock is whole: a panic can't leave half of one.
    NET.lock().unwrap_or_else(|e| e.into_inner())
}

struct Ivars {
    profile: usize,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements, and Delegate doesn't
    // implement Drop.
    #[unsafe(super(NSObject))]
    #[name = "TuskNetDelegate"]
    #[ivars = Ivars]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}
    unsafe impl NSURLSessionDelegate for Delegate {}

    unsafe impl NSURLSessionTaskDelegate for Delegate {
        #[unsafe(method(URLSession:task:didCompleteWithError:))]
        fn did_complete(
            &self,
            _session: &NSURLSession,
            task: &NSURLSessionTask,
            error: Option<&NSError>,
        ) {
            finish(self.ivars().profile, task, error);
        }
    }

    unsafe impl NSURLSessionDataDelegate for Delegate {
        #[unsafe(method(URLSession:dataTask:didReceiveData:))]
        fn did_receive_data(
            &self,
            _session: &NSURLSession,
            task: &NSURLSessionDataTask,
            data: &NSData,
        ) {
            receive(self.ivars().profile, task, data);
        }
    }
);

impl Delegate {
    fn new(profile: usize) -> Retained<Self> {
        let this = Self::alloc().set_ivars(Ivars { profile });
        unsafe { msg_send![super(this), init] }
    }
}

/// Profile `profile`'s session, made on first use: its own cookies and a
/// memory cache, its delegate on a serial queue at user-initiated priority.
fn session(profile: usize) -> Result<Retained<NSURLSession>, i32> {
    let mut sessions = SESSIONS.lock().unwrap_or_else(|e| e.into_inner());
    let slot = sessions.get_mut(profile).ok_or(ERR_ARGUMENT)?;
    if let Some(s) = slot {
        return Ok(s.clone());
    }
    let config = NSURLSessionConfiguration::ephemeralSessionConfiguration();
    config.setTimeoutIntervalForRequest(30.0);
    let cache = unsafe {
        NSURLCache::initWithMemoryCapacity_diskCapacity_directoryURL(
            NSURLCache::alloc(),
            16 << 20,
            0,
            None,
        )
    };
    config.setURLCache(Some(&cache));
    let queue = NSOperationQueue::new();
    queue.setMaxConcurrentOperationCount(1);
    queue.setQualityOfService(NSQualityOfService::UserInitiated);
    queue.setName(Some(&NSString::from_str("tusk.net")));
    let delegate = Delegate::new(profile);
    let s = unsafe {
        NSURLSession::sessionWithConfiguration_delegate_delegateQueue(
            &config,
            Some(ProtocolObject::from_ref(&*delegate)),
            Some(&queue),
        )
    };
    *slot = Some(s.clone());
    Ok(s)
}

/// Makes both profiles' sessions now, so the first page doesn't wait for
/// them: call once at launch, from any thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_start() -> i32 {
    guarded(|| {
        for p in 0..PROFILES {
            session(p)?;
        }
        Ok(0)
    })
}

/// The scheme of `url`, lower case, or "" with none.
fn scheme_of(url: &str) -> String {
    match url.split_once(':') {
        Some((s, _))
            if !s.is_empty()
                && s.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"+-.".contains(&c)) =>
        {
            s.to_ascii_lowercase()
        }
        _ => String::new(),
    }
}

/// Whether a page at `from` (empty for a load we asked for ourselves) may
/// load `url` for `kind`: http and https only, and nothing over http for an
/// https page but the next document.
fn allowed(kind: i32, url: &str, from: &str) -> bool {
    let scheme = scheme_of(url);
    if scheme != "http" && scheme != "https" {
        return false;
    }
    !(kind != NET_DOCUMENT && scheme == "http" && scheme_of(from) == "https")
}

/// In a tab's worker: starts loading `url` (UTF-8, absolute) for `kind` on
/// profile `profile`'s session, for the page at `from` (empty when we asked
/// for it). When it ends, the tab gets MSG_NET with the returned id; read it
/// with tp_net_head and tp_net_take. Returns the id (above 0), ERR_BLOCKED
/// for a URL the page may not load, or ERR_ARGUMENT for one NSURL can't read.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_open(
    tab: i32,
    profile: i32,
    kind: i32,
    url: GSlice<u8>,
    from: GSlice<u8>,
    flags: i32,
) -> i32 {
    guarded(|| {
        let url = std::str::from_utf8(unsafe { url.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        let from = std::str::from_utf8(unsafe { from.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        if !(NET_DOCUMENT..=NET_IMAGE).contains(&kind) {
            return Err(ERR_ARGUMENT);
        }
        if !allowed(kind, url, from) {
            return Err(ERR_BLOCKED);
        }
        let profile = usize::try_from(profile).map_err(|_| ERR_ARGUMENT)?;
        let session = session(profile)?;
        let nsurl = NSURL::URLWithString(&NSString::from_str(url)).ok_or(ERR_ARGUMENT)?;
        let request = NSMutableURLRequest::requestWithURL(&nsurl);
        request.setValue_forHTTPHeaderField(
            Some(&NSString::from_str(USER_AGENT)),
            &NSString::from_str("User-Agent"),
        );
        let accept = match kind {
            NET_DOCUMENT => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            NET_STYLE => "text/css,*/*;q=0.1",
            _ => "image/webp,image/avif,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
        };
        request.setValue_forHTTPHeaderField(
            Some(&NSString::from_str(accept)),
            &NSString::from_str("Accept"),
        );
        // Cookies follow the page the request is for.
        let main = if from.is_empty() {
            None
        } else {
            NSURL::URLWithString(&NSString::from_str(from))
        };
        request.setMainDocumentURL(Some(main.as_deref().unwrap_or(&nsurl)));
        if flags & NET_RELOAD != 0 {
            request.setCachePolicy(NSURLRequestCachePolicy::ReloadIgnoringLocalCacheData);
        }
        let task = session.dataTaskWithRequest(&request);
        let id = {
            let mut n = net();
            n.last = n.last % (MAX_ID - 1) + 1;
            let id = n.last;
            n.tasks.insert((profile, task.taskIdentifier()), id);
            n.reqs.insert(
                id,
                Req {
                    tab,
                    kind,
                    profile,
                    task: task.clone(),
                    done: false,
                    status: 0,
                    error: 0,
                    expected: -1,
                    body: Vec::new(),
                    url: Vec::new(),
                    mime: Vec::new(),
                    text: Vec::new(),
                },
            );
            id
        };
        // Started once it is in the table: its delegate looks it up there.
        task.resume();
        Ok(id)
    })
}

/// On the delegate's queue: `data` came for a task. A body past its kind's
/// cap ends the request.
fn receive(profile: usize, task: &NSURLSessionDataTask, data: &NSData) {
    let cancel = {
        let mut n = net();
        let Some(&id) = n.tasks.get(&(profile, task.taskIdentifier())) else {
            return;
        };
        let Some(r) = n.reqs.get_mut(&id) else {
            return;
        };
        if r.error != 0 {
            return;
        }
        let bytes = unsafe { data.as_bytes_unchecked() };
        if r.body.len() + bytes.len() > CAPS[r.kind as usize] {
            r.error = NET_TOO_BIG;
            r.body = Vec::new();
            true
        } else {
            if r.body.is_empty() {
                r.expected = task.countOfBytesExpectedToReceive();
            }
            r.body.extend_from_slice(bytes);
            false
        }
    };
    if cancel {
        task.cancel();
    }
}

/// On the delegate's queue: a task ended. Its response is read, its body
/// decoded to UTF-8 for a document or a sheet, and its tab woken.
fn finish(profile: usize, task: &NSURLSessionTask, error: Option<&NSError>) {
    let (id, tab, kind, too_big, body) = {
        let mut n = net();
        let Some(id) = n.tasks.remove(&(profile, task.taskIdentifier())) else {
            return;
        };
        let Some(r) = n.reqs.get_mut(&id) else {
            return;
        };
        (
            id,
            r.tab,
            r.kind,
            r.error == NET_TOO_BIG,
            std::mem::take(&mut r.body),
        )
    };
    let response = task.response();
    let http = response
        .as_ref()
        .and_then(|r| r.downcast_ref::<NSHTTPURLResponse>());
    let status = http.map_or(0, |h| h.statusCode() as i32);
    let url = response
        .as_ref()
        .and_then(|r| r.URL())
        .and_then(|u| u.absoluteString())
        .map(|s| s.to_string().into_bytes())
        .unwrap_or_default();
    let mime = response
        .as_ref()
        .and_then(|r| r.MIMEType())
        .map(|s| s.to_string().into_bytes())
        .unwrap_or_default();
    let charset = response
        .as_ref()
        .and_then(|r| r.textEncodingName())
        .map(|s| s.to_string());
    let (code, text) = if too_big {
        (NET_TOO_BIG, b"too big to load".to_vec())
    } else {
        match error {
            None => (0, Vec::new()),
            Some(e) => {
                let domain = e.domain().to_string();
                let code = if domain == "NSURLErrorDomain" {
                    e.code() as i32
                } else {
                    NET_FAILED
                };
                (code, e.localizedDescription().to_string().into_bytes())
            }
        }
    };
    let body = if code != 0 {
        Vec::new()
    } else if kind == NET_IMAGE {
        body
    } else {
        to_utf8(body, charset.as_deref(), kind)
    };
    {
        let mut n = net();
        // Cancelled in the meantime: no one waits for it.
        let Some(r) = n.reqs.get_mut(&id) else {
            return;
        };
        r.done = true;
        r.status = status;
        r.error = code;
        r.body = body;
        r.url = url;
        r.mime = mime;
        r.text = text;
    }
    tabs::post_net(tab, id);
}

/// Request `req`'s state into `out`. Returns 1 when it has ended, 0 while it
/// runs (with the body's bytes so far), ERR_ARGUMENT for no such request.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_head(req: i32, out: *mut NetHead) -> i32 {
    guarded(|| {
        if out.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let n = net();
        let r = n.reqs.get(&req).ok_or(ERR_ARGUMENT)?;
        let head = NetHead {
            req,
            status: r.status,
            error: r.error,
            kind: r.kind,
            body: r.body.len() as i64,
            url: r.url.len() as i64,
            mime: r.mime.len() as i64,
            text: r.text.len() as i64,
            expected: r.expected,
        };
        unsafe { out.write_unaligned(head) };
        Ok(r.done as i32)
    })
}

/// Takes ended request `req`: copies its body, final URL, MIME type and error
/// text into slices as long as tp_net_head said, and forgets it.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_take(
    req: i32,
    body: GSlice<u8>,
    url: GSlice<u8>,
    mime: GSlice<u8>,
    text: GSlice<u8>,
) -> i32 {
    guarded(|| {
        let mut n = net();
        let r = n.reqs.get(&req).ok_or(ERR_ARGUMENT)?;
        if !r.done {
            return Err(ERR_ARGUMENT);
        }
        for (into, from) in [
            (body, &r.body),
            (url, &r.url),
            (mime, &r.mime),
            (text, &r.text),
        ] {
            if !unsafe { into.copy_from(from) } {
                return Err(ERR_ARGUMENT);
            }
        }
        n.reqs.remove(&req);
        Ok(0)
    })
}

/// Stops request `req` and forgets it: its tab gets no MSG_NET for it.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_cancel(req: i32) -> i32 {
    guarded(|| {
        let r = {
            let mut n = net();
            let r = n.reqs.remove(&req).ok_or(ERR_ARGUMENT)?;
            n.tasks.remove(&(r.profile, r.task.taskIdentifier()));
            r
        };
        r.task.cancel();
        Ok(0)
    })
}

/// Stops and forgets every request of tab `tab`, as its mailbox closes.
pub(crate) fn cancel_tab(tab: i32) {
    let gone: Vec<Req> = {
        let mut n = net();
        let ids: Vec<i32> = n
            .reqs
            .iter()
            .filter(|(_, r)| r.tab == tab)
            .map(|(&id, _)| id)
            .collect();
        let mut gone = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(r) = n.reqs.remove(&id) {
                n.tasks.remove(&(r.profile, r.task.taskIdentifier()));
                gone.push(r);
            }
        }
        gone
    };
    for r in gone {
        r.task.cancel();
    }
}

// ------------------------------------------------------------------ charsets

/// `body` as UTF-8, given the charset its response named, if any. In order:
/// a byte order mark, then that charset, then for a document a `<meta>` one
/// in its first 1024 bytes and for a sheet an `@charset` rule, then UTF-8
/// if the bytes are UTF-8, and windows-1252 if not (WHATWG Encoding's
/// fallback for English). What doesn't decode becomes U+FFFD.
fn to_utf8(body: Vec<u8>, charset: Option<&str>, kind: i32) -> Vec<u8> {
    if let Some(rest) = body.strip_prefix(b"\xEF\xBB\xBF") {
        return utf8_or_replaced(rest.to_vec());
    }
    if body.starts_with(b"\xFE\xFF") {
        return decode(&body[2..], "utf-16be").unwrap_or_default();
    }
    if body.starts_with(b"\xFF\xFE") {
        return decode(&body[2..], "utf-16le").unwrap_or_default();
    }
    let declared = charset.map(str::to_owned).or_else(|| {
        if kind == NET_DOCUMENT {
            meta_charset(&body)
        } else {
            css_charset(&body)
        }
    });
    match declared.as_deref().map(label) {
        Some("utf-8") | None if std::str::from_utf8(&body).is_ok() => body,
        Some("utf-8") => utf8_or_replaced(body),
        Some(other) => decode(&body, other)
            .or_else(|| decode(&body, "windows-1252"))
            .unwrap_or_else(|| utf8_or_replaced(body)),
        None => decode(&body, "windows-1252").unwrap_or_else(|| utf8_or_replaced(body)),
    }
}

fn utf8_or_replaced(body: Vec<u8>) -> Vec<u8> {
    match String::from_utf8(body) {
        Ok(s) => s.into_bytes(),
        Err(e) => String::from_utf8_lossy(e.as_bytes())
            .into_owned()
            .into_bytes(),
    }
}

/// A charset label as WHATWG Encoding reads it: the Latin-1 and ASCII names
/// mean windows-1252, and UTF-8's aliases mean UTF-8.
fn label(name: &str) -> &str {
    let n = name.trim().trim_matches(|c| c == '"' || c == '\'');
    if ["utf-8", "utf8", "unicode-1-1-utf-8"]
        .iter()
        .any(|l| n.eq_ignore_ascii_case(l))
    {
        return "utf-8";
    }
    if [
        "iso-8859-1",
        "iso8859-1",
        "latin1",
        "l1",
        "us-ascii",
        "ascii",
        "cp1252",
        "x-cp1252",
    ]
    .iter()
    .any(|l| n.eq_ignore_ascii_case(l))
    {
        return "windows-1252";
    }
    n
}

/// `bytes` in the charset called `name`, through Core Foundation, as UTF-8;
/// None for a name it doesn't know or bytes that aren't in that charset.
fn decode(bytes: &[u8], name: &str) -> Option<Vec<u8>> {
    let cf = CFString::convert_iana_char_set_name_to_encoding(&CFString::from_str(name));
    if cf == kCFStringEncodingInvalidId {
        return None;
    }
    let encoding = CFString::convert_encoding_to_ns_string_encoding(cf) as usize;
    let start = std::ptr::NonNull::new(bytes.as_ptr().cast_mut().cast())
        .unwrap_or(std::ptr::NonNull::dangling());
    let s: Option<Retained<NSString>> = unsafe {
        NSString::initWithBytes_length_encoding(NSString::alloc(), start, bytes.len(), encoding)
    };
    s.map(|s| s.to_string().into_bytes())
}

/// The charset a `<meta>` names in the first 1024 bytes of `body`: as
/// `charset=` in the tag, either alone or in `content`.
fn meta_charset(body: &[u8]) -> Option<String> {
    let head = &body[..body.len().min(1024)];
    let lower: Vec<u8> = head.to_ascii_lowercase();
    let mut at = 0;
    while let Some(k) = find(&lower[at..], b"<meta") {
        let start = at + k;
        let end = find(&lower[start..], b">").map_or(lower.len(), |e| start + e);
        let tag = &lower[start..end];
        if let Some(c) = find(tag, b"charset=") {
            let v = &head[start + c + 8..end];
            let v: Vec<u8> = v
                .iter()
                .copied()
                .skip_while(|&b| b == b'"' || b == b'\'' || b == b' ')
                .take_while(|&b| !b" \"';/>\t\n\r".contains(&b))
                .collect();
            if !v.is_empty() {
                return String::from_utf8(v).ok();
            }
        }
        at = end;
    }
    None
}

/// The charset a sheet names in a leading `@charset "...";`.
fn css_charset(body: &[u8]) -> Option<String> {
    let rest = body.strip_prefix(b"@charset \"")?;
    let end = find(rest, b"\";")?;
    String::from_utf8(rest[..end].to_vec()).ok()
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tabs::{MSG_NET, TabMsg, tp_tab_drop, tp_tab_next, tp_tab_open};
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::time::Duration;

    #[test]
    fn the_head_matches_the_goose_layout() {
        assert_eq!(std::mem::size_of::<NetHead>(), 56);
    }

    #[test]
    fn pages_load_http_and_https_and_https_pages_no_http_sheets() {
        assert!(allowed(NET_DOCUMENT, "https://a.org/", ""));
        assert!(allowed(NET_DOCUMENT, "HTTP://a.org/", "https://b.org/"));
        assert!(allowed(NET_STYLE, "http://a.org/s.css", "http://b.org/"));
        assert!(!allowed(NET_STYLE, "http://a.org/s.css", "https://b.org/"));
        assert!(!allowed(NET_IMAGE, "http://a.org/i.png", "HTTPS://b.org/"));
        assert!(!allowed(NET_DOCUMENT, "file:///etc/passwd", ""));
        assert!(!allowed(NET_STYLE, "javascript:alert(1)", "https://b.org/"));
        assert!(!allowed(NET_DOCUMENT, "no scheme", ""));
    }

    #[test]
    fn charsets_decode_to_utf8() {
        // windows-1252 for Latin-1's name: 0x93 and 0x94 are curly quotes.
        assert_eq!(
            to_utf8(
                b"caf\xe9 \x93q\x94".to_vec(),
                Some("ISO-8859-1"),
                NET_DOCUMENT
            ),
            "café “q”".as_bytes()
        );
        let cp1251 = b"<html><head><meta charset=\"windows-1251\"></head>\xcf\xf0\xe8".to_vec();
        assert!(to_utf8(cp1251, None, NET_DOCUMENT).ends_with("При".as_bytes()));
        let http_equiv =
            b"<meta http-equiv=Content-Type content='text/html; charset=koi8-r'>\xf0\xd2\xc9"
                .to_vec();
        assert!(to_utf8(http_equiv, None, NET_DOCUMENT).ends_with("При".as_bytes()));
        // The header wins over the meta; a BOM wins over both.
        let both = b"<meta charset=windows-1251>\xe9".to_vec();
        assert!(
            to_utf8(both.clone(), Some("windows-1252"), NET_DOCUMENT).ends_with("é".as_bytes())
        );
        let mut bom = b"\xFF\xFE".to_vec();
        for c in "Ж!".encode_utf16() {
            bom.extend_from_slice(&c.to_le_bytes());
        }
        assert_eq!(
            to_utf8(bom, Some("windows-1252"), NET_DOCUMENT),
            "Ж!".as_bytes()
        );
        assert_eq!(to_utf8(b"\xEF\xBB\xBFok".to_vec(), None, NET_STYLE), b"ok");
        assert_eq!(
            to_utf8(b"@charset \"windows-1251\";\xc6".to_vec(), None, NET_STYLE),
            "@charset \"windows-1251\";Ж".as_bytes()
        );
        // Bytes that aren't UTF-8, with no charset named, are windows-1252;
        // UTF-8 named but broken has its bad bytes replaced.
        assert_eq!(
            to_utf8(b"na\xefve".to_vec(), None, NET_DOCUMENT),
            "naïve".as_bytes()
        );
        assert_eq!(
            to_utf8(b"a\xffb".to_vec(), Some("utf-8"), NET_DOCUMENT),
            "a\u{FFFD}b".as_bytes()
        );
        // A name no one knows reads as windows-1252.
        assert_eq!(
            to_utf8(b"\xe9".to_vec(), Some("x-nonsense"), NET_DOCUMENT),
            "é".as_bytes()
        );
        // UTF-8 stays as it is.
        let utf8 = "Focaccia – Wikipedia".as_bytes().to_vec();
        assert_eq!(to_utf8(utf8.clone(), None, NET_DOCUMENT), utf8);
    }

    /// A server on 127.0.0.1 that answers each request from `route` on its
    /// path, then closes the connection.
    fn serve(route: fn(&str) -> (Vec<u8>, u64)) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let path = line.split(' ').nth(1).unwrap_or("/").to_string();
                    loop {
                        let mut h = String::new();
                        if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                            break;
                        }
                    }
                    let (reply, delay) = route(&path);
                    std::thread::sleep(Duration::from_millis(delay));
                    let _ = stream.write_all(&reply);
                });
            }
        });
        port
    }

    fn reply(status: &str, headers: &str, body: &[u8]) -> Vec<u8> {
        let mut r = format!(
            "HTTP/1.1 {status}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        r.extend_from_slice(body);
        r
    }

    fn route(path: &str) -> (Vec<u8>, u64) {
        match path {
            "/page" => (
                reply(
                    "200 OK",
                    "Content-Type: text/html; charset=utf-8\r\n",
                    "<p>héllo</p>".as_bytes(),
                ),
                0,
            ),
            "/latin1" => (
                reply(
                    "200 OK",
                    "Content-Type: text/html; charset=iso-8859-1\r\n",
                    b"caf\xe9",
                ),
                0,
            ),
            "/sheet" => (
                reply("200 OK", "Content-Type: text/css\r\n", b"p { color: red }"),
                0,
            ),
            "/moved" => (reply("302 Found", "Location: /page\r\n", b""), 0),
            "/missing" => (
                reply("404 Not Found", "Content-Type: text/plain\r\n", b"nope"),
                0,
            ),
            "/big" => (
                reply(
                    "200 OK",
                    "Content-Type: text/css\r\n",
                    &vec![b'x'; (16 << 20) + 1],
                ),
                0,
            ),
            "/slow" => (
                reply("200 OK", "Content-Type: text/html\r\n", b"late"),
                3000,
            ),
            _ => (reply("500 Internal Server Error", "", b""), 0),
        }
    }

    fn open(tab: i32, kind: i32, url: &str, from: &str) -> i32 {
        let mut url = url.as_bytes().to_vec();
        let mut from = from.as_bytes().to_vec();
        let slice = |v: &mut Vec<u8>| GSlice {
            data: if v.is_empty() {
                std::ptr::null_mut()
            } else {
                v.as_mut_ptr()
            },
            len: v.len() as i64,
        };
        tp_net_open(
            tab,
            PROFILE_SANDBOX,
            kind,
            slice(&mut url),
            slice(&mut from),
            0,
        )
    }

    /// Waits for tab `tab`'s next MSG_NET and takes that request.
    fn take(tab: i32) -> (NetHead, Vec<u8>, String, String, String) {
        let mut m = TabMsg::default();
        assert_eq!(tp_tab_next(tab, 10_000, &mut m), 1, "no message");
        let (kind, a) = (m.kind, m.a);
        assert_eq!(kind, MSG_NET);
        let req = a as i32;
        let mut head = NetHead::default();
        assert_eq!(tp_net_head(req, &mut head), 1);
        let mut bufs: Vec<Vec<u8>> = [head.body, head.url, head.mime, head.text]
            .iter()
            .map(|&n| vec![0u8; n as usize])
            .collect();
        let s: Vec<GSlice<u8>> = bufs
            .iter_mut()
            .map(|b| GSlice {
                data: if b.is_empty() {
                    std::ptr::null_mut()
                } else {
                    b.as_mut_ptr()
                },
                len: b.len() as i64,
            })
            .collect();
        assert_eq!(tp_net_take(req, s[0], s[1], s[2], s[3]), 0);
        assert_eq!(tp_net_head(req, &mut head), ERR_ARGUMENT, "taken once");
        let text = |b: &Vec<u8>| String::from_utf8(b.clone()).unwrap();
        (
            head,
            bufs[0].clone(),
            text(&bufs[1]),
            text(&bufs[2]),
            text(&bufs[3]),
        )
    }

    #[test]
    fn a_request_ends_in_its_tabs_mailbox_decoded() {
        let port = serve(route);
        let tab = 9101;
        assert_eq!(tp_tab_open(tab), 0);
        let base = format!("http://127.0.0.1:{port}");

        assert!(open(tab, NET_DOCUMENT, &format!("{base}/page"), "") > 0);
        let (head, body, url, mime, _) = take(tab);
        let (status, error) = (head.status, head.error);
        assert_eq!((status, error), (200, 0));
        assert_eq!(body, "<p>héllo</p>".as_bytes());
        assert_eq!(url, format!("{base}/page"));
        assert_eq!(mime, "text/html");

        // Decoded from the header's charset.
        open(tab, NET_DOCUMENT, &format!("{base}/latin1"), "");
        assert_eq!(take(tab).1, "café".as_bytes());

        // A redirect ends at its target, which becomes the URL.
        open(tab, NET_DOCUMENT, &format!("{base}/moved"), "");
        let (head, body, url, _, _) = take(tab);
        let status = head.status;
        assert_eq!(
            (status, body.len(), url),
            (200, "<p>héllo</p>".len(), format!("{base}/page"))
        );

        // A 404 is a response, not a failure.
        open(
            tab,
            NET_STYLE,
            &format!("{base}/missing"),
            &format!("{base}/page"),
        );
        let (head, body, ..) = take(tab);
        let (status, error) = (head.status, head.error);
        assert_eq!((status, error, body), (404, 0, b"nope".to_vec()));

        // Past its kind's cap, a body fails the request: 16 MB for a sheet.
        open(tab, NET_STYLE, &format!("{base}/big"), "");
        let (head, body, _, _, text) = take(tab);
        let error = head.error;
        assert_eq!(
            (error, body.len(), text.as_str()),
            (NET_TOO_BIG, 0, "too big to load")
        );

        // No server there: NSURLErrorDomain's code and its text.
        let closed = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        open(
            tab,
            NET_DOCUMENT,
            &format!("http://127.0.0.1:{closed}/"),
            "",
        );
        let (head, _, _, _, text) = take(tab);
        let error = head.error;
        assert!(error < 0 && error != NET_TOO_BIG, "{error}");
        assert!(!text.is_empty());

        assert_eq!(tp_tab_drop(tab), 0);
    }

    #[test]
    fn several_requests_run_at_once_and_a_cancelled_one_never_answers() {
        let port = serve(route);
        let tab = 9102;
        assert_eq!(tp_tab_open(tab), 0);
        let base = format!("http://127.0.0.1:{port}");
        let slow = open(tab, NET_DOCUMENT, &format!("{base}/slow"), "");
        let sheets: Vec<i32> = (0..4)
            .map(|_| {
                open(
                    tab,
                    NET_STYLE,
                    &format!("{base}/sheet"),
                    &format!("{base}/page"),
                )
            })
            .collect();
        assert!(sheets.iter().all(|&s| s > 0));
        // The sheets end long before the slow page would.
        let start = std::time::Instant::now();
        for _ in 0..4 {
            let (head, body, ..) = take(tab);
            assert!(sheets.contains(&{ head.req }));
            assert_eq!(body, b"p { color: red }");
        }
        assert!(start.elapsed() < Duration::from_millis(2500));
        assert_eq!(tp_net_cancel(slow), 0);
        assert_eq!(tp_net_cancel(slow), ERR_ARGUMENT);
        let mut m = TabMsg::default();
        assert_eq!(
            tp_tab_next(tab, 3500, &mut m),
            0,
            "a cancelled request answered"
        );
        assert_eq!(tp_tab_drop(tab), 0);
    }

    #[test]
    fn closing_a_tab_cancels_its_requests_and_blocked_urls_never_start() {
        let port = serve(route);
        let tab = 9103;
        assert_eq!(tp_tab_open(tab), 0);
        let slow = open(
            tab,
            NET_DOCUMENT,
            &format!("http://127.0.0.1:{port}/slow"),
            "",
        );
        assert!(slow > 0);
        assert_eq!(
            open(
                tab,
                NET_STYLE,
                &format!("http://127.0.0.1:{port}/sheet"),
                "https://a.org/"
            ),
            ERR_BLOCKED
        );
        assert_eq!(
            open(tab, NET_DOCUMENT, "file:///etc/hosts", ""),
            ERR_BLOCKED
        );
        assert_eq!(open(tab, 9, "https://a.org/", ""), ERR_ARGUMENT);
        assert_eq!(tp_tab_drop(tab), 0);
        let mut head = NetHead::default();
        assert_eq!(tp_net_head(slow, &mut head), ERR_ARGUMENT);
    }

    /// The live web, by hand: `cargo test --release -- --ignored live`.
    /// Plain http needs App Transport Security to let a bare binary through.
    #[test]
    #[ignore]
    fn live_plain_http_and_https() {
        let tab = 9199;
        assert_eq!(tp_tab_open(tab), 0);
        for url in [
            "http://info.cern.ch/",
            "https://en.wikipedia.org/wiki/Focaccia",
        ] {
            let start = std::time::Instant::now();
            open(tab, NET_DOCUMENT, url, "");
            let (head, body, final_url, mime, text) = take(tab);
            let (status, error) = (head.status, head.error);
            println!(
                "{url}: {status} {error} {} bytes {mime} {final_url} {text} in {:?}",
                body.len(),
                start.elapsed()
            );
            assert_eq!((status, error), (200, 0));
        }
        assert_eq!(tp_tab_drop(tab), 0);
    }
}
