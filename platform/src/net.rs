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
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::Duration;

use block2::DynBlock;

use encoding_rs::{Encoding, UTF_8, UTF_16BE, UTF_16LE, WINDOWS_1252, X_USER_DEFINED};
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::runtime::ProtocolObject;
use objc2::{AnyThread, DefinedClass, define_class, msg_send};
use objc2_foundation::{
    NSArray, NSCopying, NSData, NSDate, NSDictionary, NSError, NSHTTPCookie,
    NSHTTPCookiePropertyKey, NSHTTPCookieStorage, NSHTTPURLResponse, NSMutableCopying,
    NSMutableURLRequest, NSObject, NSObjectProtocol, NSOperationQueue, NSPropertyListFormat,
    NSPropertyListMutabilityOptions, NSPropertyListSerialization, NSQualityOfService, NSString,
    NSURL, NSURLCache, NSURLRequest, NSURLRequestCachePolicy, NSURLSession,
    NSURLSessionConfiguration, NSURLSessionDataDelegate, NSURLSessionDataTask,
    NSURLSessionDelegate, NSURLSessionTask, NSURLSessionTaskDelegate, NSURLSessionTaskMetrics,
    NSURLSessionTaskMetricsResourceFetchType,
};

use crate::url::scheme_of;
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
pub const NET_FAILED: i32 = -30002; // an error from another domain, or a panic here
pub const NET_BLOCKED: i32 = -30003; // redirected to a URL the page may not load

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

/// A request in a page's network log, laid out as Goose's `struct NetRow`:
/// its id, what it was for, its HTTP status and why it failed (0 when it
/// didn't), its protocol (1 HTTP/1.1, 2 HTTP/2, 3 HTTP/3, 0 none: a file,
/// or not known), flags (ROW_REUSED, ROW_CACHED, ROW_TIMED), its body's
/// bytes and those that came over the wire, where its URL is in the log's
/// text, and its times in ms: when it started after the page's first, then
/// looking up, connecting, the TLS handshake, waiting for the first byte,
/// the download, and in all.
#[repr(C, packed)]
#[derive(Clone, Copy, Debug, Default)]
pub struct NetRow {
    pub req: i32,
    pub kind: i32,
    pub status: i32,
    pub error: i32,
    pub proto: i32,
    pub flags: i32,
    pub bytes: i64,
    pub wire: i64,
    pub url_at: i64,
    pub url_len: i64,
    pub start: f32,
    pub dns: f32,
    pub connect: f32,
    pub tls: f32,
    pub wait: f32,
    pub download: f32,
    pub total: f32,
}

pub const ROW_REUSED: i32 = 1; // on a connection already open
pub const ROW_CACHED: i32 = 2; // from the cache, not the network
pub const ROW_TIMED: i32 = 4; // its times have come
const LOG_ROWS: usize = 500; // per page: a sanity limit

/// A page's requests as they ended, and their URLs; and when its first
/// started, in seconds since 1970, that the others count from.
#[derive(Default)]
struct PageLog {
    origin: f64,
    rows: Vec<NetRow>,
    urls: Vec<u8>,
}

static LOGS: LazyLock<Mutex<HashMap<i32, PageLog>>> = LazyLock::new(Default::default);

fn logs() -> MutexGuard<'static, HashMap<i32, PageLog>> {
    LOGS.lock().unwrap_or_else(|e| e.into_inner())
}

/// What a request's metrics say, kept until it ends.
#[derive(Clone, Copy, Default)]
struct Timing {
    fetch: f64, // when it started, in seconds since 1970
    proto: i32,
    flags: i32,
    wire: i64,
    dns: f32,
    connect: f32,
    tls: f32,
    wait: f32,
    download: f32,
    total: f32,
}

struct Req {
    tab: i32,
    kind: i32,
    profile: usize,
    from: String, // the page it is for; empty for a page we asked for
    got: i64,     // the body's bytes received so far
    timing: Option<Timing>,
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
    /// Tasks that ended before their metrics came: their tab and request.
    ended: HashMap<(usize, usize), (i32, i32)>,
}

static NET: LazyLock<Mutex<Net>> = LazyLock::new(Default::default);
/// Where the Default profile keeps its cache and cookies (tp_net_storage);
/// none: in memory, as Sandbox.
static STORAGE: Mutex<Option<PathBuf>> = Mutex::new(None);
/// A save of the Default profile's cookies is on its way.
static SAVING: AtomicBool = AtomicBool::new(false);

const CACHE_MEMORY: usize = 16 << 20;
const CACHE_DISK: usize = 256 << 20; // the Default profile's, on disk
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

    // A panic here would unwind into Foundation and end the whole browser:
    // each method catches its own, and the request fails instead.
    unsafe impl NSURLSessionTaskDelegate for Delegate {
        #[unsafe(method(URLSession:task:didCompleteWithError:))]
        fn did_complete(
            &self,
            _session: &NSURLSession,
            task: &NSURLSessionTask,
            error: Option<&NSError>,
        ) {
            let profile = self.ivars().profile;
            if catch_unwind(AssertUnwindSafe(|| finish(profile, task, error))).is_err() {
                fail(profile, task);
            }
        }

        #[unsafe(method(URLSession:task:didFinishCollectingMetrics:))]
        fn did_collect_metrics(
            &self,
            _session: &NSURLSession,
            task: &NSURLSessionTask,
            metrics: &NSURLSessionTaskMetrics,
        ) {
            let profile = self.ivars().profile;
            let _ = catch_unwind(AssertUnwindSafe(|| timed(profile, task, metrics)));
        }

        #[unsafe(method(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:))]
        fn will_redirect(
            &self,
            _session: &NSURLSession,
            task: &NSURLSessionTask,
            _response: &NSHTTPURLResponse,
            request: &NSURLRequest,
            completion: &DynBlock<dyn Fn(*mut NSURLRequest)>,
        ) {
            let profile = self.ivars().profile;
            let next =
                catch_unwind(AssertUnwindSafe(|| redirect(profile, task, request))).unwrap_or(None);
            match next {
                Some(r) => completion.call((Retained::as_ptr(&r).cast_mut(),)),
                None => completion.call((std::ptr::null_mut(),)),
            }
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
            let profile = self.ivars().profile;
            if catch_unwind(AssertUnwindSafe(|| receive(profile, task, data))).is_err() {
                task.cancel();
            }
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
    // Default keeps its cache in its folder and its cookies in a cookie
    // storage of its own, saved there (save_cookies); Sandbox, and Default
    // with no folder, keep both in memory only (docs/adr/0008).
    let folder = if profile == PROFILE_DEFAULT as usize {
        profile_folder()
    } else {
        None
    };
    let config = match &folder {
        Some(dir) => {
            let config = NSURLSessionConfiguration::defaultSessionConfiguration();
            let own =
                NSURLSessionConfiguration::ephemeralSessionConfiguration().HTTPCookieStorage();
            if let Some(cookies) = &own {
                restore_cookies(cookies, &dir.join("cookies.plist"));
            }
            config.setHTTPCookieStorage(own.as_deref());
            config
        }
        None => NSURLSessionConfiguration::ephemeralSessionConfiguration(),
    };
    // 30 s with no bytes ends a request, and 5 minutes in all: a server that
    // drips can't hold a page past that.
    config.setTimeoutIntervalForRequest(30.0);
    config.setTimeoutIntervalForResource(300.0);
    let cache_dir = folder
        .as_ref()
        .map(|d| NSURL::fileURLWithPath(&NSString::from_str(&d.join("Cache").to_string_lossy())));
    let cache = unsafe {
        NSURLCache::initWithMemoryCapacity_diskCapacity_directoryURL(
            NSURLCache::alloc(),
            CACHE_MEMORY,
            if cache_dir.is_some() { CACHE_DISK } else { 0 },
            cache_dir.as_deref(),
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

/// Keeps the Default profile on disk in `dir` (UTF-8), in its folder
/// "Default": its cache and its cookies. Call before Default's session is
/// made; tests and the modes without a window never do, and keep it in
/// memory.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_storage(dir: GSlice<u8>) -> i32 {
    guarded(|| {
        let dir = std::str::from_utf8(unsafe { dir.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        set_storage(&Path::new(dir).join("Default")).map_err(|_| ERR_ARGUMENT)?;
        Ok(0)
    })
}

/// Makes `folder` the Default profile's, only its owner's to read.
fn set_storage(folder: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(folder)?;
    std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
    *STORAGE.lock().unwrap_or_else(|e| e.into_inner()) = Some(folder.to_path_buf());
    Ok(())
}

fn profile_folder() -> Option<PathBuf> {
    STORAGE.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// The cookies in `file`, a property list save_cookies wrote, into `into`;
/// those that have expired since stay out.
fn restore_cookies(into: &NSHTTPCookieStorage, file: &Path) {
    let Some(data) = NSData::dataWithContentsOfFile(&NSString::from_str(&file.to_string_lossy()))
    else {
        return;
    };
    let Ok(list) = (unsafe {
        NSPropertyListSerialization::propertyListWithData_options_format_error(
            &data,
            NSPropertyListMutabilityOptions::Immutable,
            std::ptr::null_mut(),
        )
    }) else {
        return;
    };
    let Some(list) = list.downcast_ref::<NSArray>() else {
        return;
    };
    let now = NSDate::now();
    for item in list.iter() {
        let Some(dict) = item.downcast_ref::<NSDictionary>() else {
            continue;
        };
        // A cookie's properties: its keys are NSHTTPCookiePropertyKey strings.
        let props: &NSDictionary<NSHTTPCookiePropertyKey, AnyObject> =
            unsafe { &*(dict as *const NSDictionary).cast() };
        let Some(cookie) = (unsafe { NSHTTPCookie::cookieWithProperties(props) }) else {
            continue;
        };
        if cookie
            .expiresDate()
            .is_some_and(|d| d.timeIntervalSinceDate(&now) > 0.0)
        {
            into.setCookie(&cookie);
        }
    }
}

/// Writes the Default profile's cookies to its folder, as a property list
/// only its owner can read: those that outlive the session, not yet
/// expired. Session cookies end with the session, as in browsers.
fn save_cookies() {
    let Some(dir) = profile_folder() else {
        return;
    };
    let Ok(s) = session(PROFILE_DEFAULT as usize) else {
        return;
    };
    let Some(cookies) = s
        .configuration()
        .HTTPCookieStorage()
        .and_then(|c| c.cookies())
    else {
        return;
    };
    let now = NSDate::now();
    let kept: Vec<Retained<NSDictionary<NSHTTPCookiePropertyKey, AnyObject>>> = cookies
        .iter()
        .filter(|c| {
            !c.isSessionOnly()
                && c.expiresDate()
                    .is_some_and(|d| d.timeIntervalSinceDate(&now) > 0.0)
        })
        .filter_map(|c| c.properties())
        .collect();
    let list = NSArray::from_retained_slice(&kept);
    let Ok(data) = (unsafe {
        NSPropertyListSerialization::dataWithPropertyList_format_options_error(
            &list,
            NSPropertyListFormat::BinaryFormat_v1_0,
            0,
        )
    }) else {
        return;
    };
    let file = dir.join("cookies.plist");
    if data.writeToFile_atomically(&NSString::from_str(&file.to_string_lossy()), true) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600));
    }
}

/// After a response sets a cookie on the Default profile: its cookies are
/// saved a second later, once for however many come meanwhile, so a Dock
/// Quit loses at most that second.
fn cookies_changed() {
    if profile_folder().is_none() || SAVING.swap(true, Ordering::AcqRel) {
        return;
    }
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(1));
        SAVING.store(false, Ordering::Release);
        let _ = catch_unwind(save_cookies);
    });
}

/// Saves the Default profile's cookies now: as Tusk quits.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_save() -> i32 {
    guarded(|| {
        save_cookies();
        Ok(0)
    })
}

/// Makes profile `profile`'s session now, so the first page doesn't wait
/// for it: call at launch, from any thread.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_start(profile: i32) -> i32 {
    guarded(|| {
        session(usize::try_from(profile).map_err(|_| ERR_ARGUMENT)?)?;
        Ok(0)
    })
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
        // A request no mailbox would hear of would stay forever.
        if !tabs::is_open(tab) {
            return Err(ERR_ARGUMENT);
        }
        let session = session(profile)?;
        let nsurl = NSURL::URLWithString(&NSString::from_str(&rfc3986(url))).ok_or(ERR_ARGUMENT)?;
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
            // Past ids still in use, once they wrap.
            n.last = n.last % (MAX_ID - 1) + 1;
            while n.reqs.contains_key(&n.last) {
                n.last = n.last % (MAX_ID - 1) + 1;
            }
            let id = n.last;
            n.tasks.insert((profile, task.taskIdentifier()), id);
            n.reqs.insert(
                id,
                Req {
                    tab,
                    kind,
                    profile,
                    from: from.to_string(),
                    got: 0,
                    timing: None,
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
            r.got = r.body.len() as i64;
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
    let key = (profile, task.taskIdentifier());
    let (id, tab, kind, preset, body, timing) = {
        let mut n = net();
        let Some(id) = n.tasks.remove(&key) else {
            return;
        };
        let Some(r) = n.reqs.get_mut(&id) else {
            return;
        };
        (
            id,
            r.tab,
            r.kind,
            r.error,
            std::mem::take(&mut r.body),
            r.timing,
        )
    };
    let response = task.response();
    let http = response
        .as_ref()
        .and_then(|r| r.downcast_ref::<NSHTTPURLResponse>());
    let status = http.map_or(0, |h| h.statusCode() as i32);
    if profile == PROFILE_DEFAULT as usize
        && http.is_some_and(|h| {
            h.valueForHTTPHeaderField(&NSString::from_str("Set-Cookie"))
                .is_some()
        })
    {
        cookies_changed();
    }
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
    let (code, text) = if preset == NET_TOO_BIG {
        (NET_TOO_BIG, b"too big to load".to_vec())
    } else if preset == NET_BLOCKED {
        (
            NET_BLOCKED,
            b"redirected to a URL the page may not load".to_vec(),
        )
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
    log_row(tab, id, kind, status, code, &url, body.len() as i64, timing);
    {
        let mut n = net();
        if timing.is_none() {
            // Its metrics are still to come: they find its row this way.
            if n.ended.len() > 1000 {
                n.ended.clear();
            }
            n.ended.insert(key, (tab, id));
        }
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
    // A tab gone meanwhile hears nothing, and no one will take it.
    if !tabs::post_net(tab, id) {
        net().reqs.remove(&id);
    }
}

/// On the delegate's queue: `task`'s metrics, kept with its request, or
/// put in its row when it has already ended.
fn timed(profile: usize, task: &NSURLSessionTask, metrics: &NSURLSessionTaskMetrics) {
    let tx = metrics.transactionMetrics();
    let (Some(first), Some(last)) = (tx.firstObject(), tx.lastObject()) else {
        return;
    };
    let secs = |d: Option<Retained<NSDate>>| d.map(|d| d.timeIntervalSince1970());
    let span = |a: Option<Retained<NSDate>>, b: Option<Retained<NSDate>>| match (secs(a), secs(b)) {
        (Some(a), Some(b)) if b >= a => ((b - a) * 1000.0) as f32,
        _ => 0.0,
    };
    let proto = match last.networkProtocolName().map(|p| p.to_string()).as_deref() {
        Some("h3") => 3,
        Some("h2") => 2,
        Some("http/1.1") | Some("http/1.0") => 1,
        _ => 0,
    };
    let mut flags = ROW_TIMED;
    if last.isReusedConnection() {
        flags |= ROW_REUSED;
    }
    if last.resourceFetchType() == NSURLSessionTaskMetricsResourceFetchType::LocalCache {
        flags |= ROW_CACHED;
    }
    let tls_start = last.secureConnectionStartDate();
    let t = Timing {
        fetch: secs(first.fetchStartDate()).unwrap_or(0.0),
        proto,
        flags,
        wire: tx
            .iter()
            .map(|m| m.countOfResponseBodyBytesReceived())
            .sum(),
        dns: span(last.domainLookupStartDate(), last.domainLookupEndDate()),
        connect: span(
            last.connectStartDate(),
            tls_start.clone().or_else(|| last.connectEndDate()),
        ),
        tls: span(tls_start, last.secureConnectionEndDate()),
        wait: span(last.requestStartDate(), last.responseStartDate()),
        download: span(last.responseStartDate(), last.responseEndDate()),
        total: (metrics.taskInterval().duration() * 1000.0) as f32,
    };
    let key = (profile, task.taskIdentifier());
    let ended = {
        let mut n = net();
        match n.tasks.get(&key).copied() {
            Some(id) => {
                if let Some(r) = n.reqs.get_mut(&id) {
                    r.timing = Some(t);
                }
                None
            }
            None => n.ended.remove(&key),
        }
    };
    if let Some((tab, id)) = ended {
        let mut logs = logs();
        if let Some(log) = logs.get_mut(&tab) {
            if log.origin == 0.0 {
                log.origin = t.fetch;
            }
            let origin = log.origin;
            if let Some(row) = log.rows.iter_mut().rev().find(|r| r.req == id) {
                fill_row(row, &t, origin);
            }
        }
    }
}

/// Request `req` of page `tab` has ended: a row in the page's log.
#[allow(clippy::too_many_arguments)]
fn log_row(
    tab: i32,
    req: i32,
    kind: i32,
    status: i32,
    error: i32,
    url: &[u8],
    bytes: i64,
    timing: Option<Timing>,
) {
    let mut logs = logs();
    let log = logs.entry(tab).or_default();
    if log.rows.len() >= LOG_ROWS {
        return;
    }
    let mut row = NetRow {
        req,
        kind,
        status,
        error,
        bytes,
        url_at: log.urls.len() as i64,
        url_len: url.len() as i64,
        ..Default::default()
    };
    log.urls.extend_from_slice(url);
    if let Some(t) = timing {
        if log.origin == 0.0 {
            log.origin = t.fetch;
        }
        fill_row(&mut row, &t, log.origin);
    }
    log.rows.push(row);
}

fn fill_row(row: &mut NetRow, t: &Timing, origin: f64) {
    row.proto = t.proto;
    row.flags |= t.flags;
    row.wire = t.wire;
    row.start = (((t.fetch - origin) * 1000.0).max(0.0)) as f32;
    row.dns = t.dns;
    row.connect = t.connect;
    row.tls = t.tls;
    row.wait = t.wait;
    row.download = t.download;
    row.total = t.total;
}

/// How many rows page `tab`'s network log has, into `rows`, and how many
/// bytes of URLs, into `bytes`.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_log_size(tab: i32, rows: *mut i64, bytes: *mut i64) -> i32 {
    guarded(|| {
        if rows.is_null() || bytes.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let logs = logs();
        let (r, b) = logs
            .get(&tab)
            .map_or((0, 0), |l| (l.rows.len(), l.urls.len()));
        unsafe {
            rows.write_unaligned(r as i64);
            bytes.write_unaligned(b as i64);
        }
        Ok(0)
    })
}

/// Page `tab`'s network log: its rows into `rows` and their URLs into
/// `urls`, each as long as tp_net_log_size said.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_log(tab: i32, rows: GSlice<NetRow>, urls: GSlice<u8>) -> i32 {
    guarded(|| {
        let logs = logs();
        let empty = PageLog::default();
        let log = logs.get(&tab).unwrap_or(&empty);
        if !unsafe { rows.copy_from(&log.rows) } || !unsafe { urls.copy_from(&log.urls) } {
            return Err(ERR_ARGUMENT);
        }
        Ok(0)
    })
}

/// On the delegate's queue: a panic made `task` end where it was. Its
/// request fails, and its tab hears of it.
fn fail(profile: usize, task: &NSURLSessionTask) {
    let found = {
        let mut n = net();
        let id = n.tasks.remove(&(profile, task.taskIdentifier()));
        id.and_then(|id| n.reqs.get_mut(&id).map(|r| (id, r)))
            .map(|(id, r)| {
                r.done = true;
                r.error = NET_FAILED;
                r.body = Vec::new();
                r.text = b"Tusk failed loading it".to_vec();
                (id, r.tab)
            })
    };
    if let Some((id, tab)) = found {
        tabs::post_net(tab, id);
    }
}

/// On the delegate's queue: `task` is redirected to `request`. The new URL
/// must pass what the first did (`allowed`): http and https only, and no
/// http sheet or image for an https page. A page we asked for follows its
/// own redirects for its cookies, so each hop's request has the new URL as
/// its main document. None to stop there: the request then fails as
/// NET_BLOCKED.
fn redirect(
    profile: usize,
    task: &NSURLSessionTask,
    request: &NSURLRequest,
) -> Option<Retained<NSURLRequest>> {
    let url = request.URL()?.absoluteString()?.to_string();
    let mut n = net();
    let id = *n.tasks.get(&(profile, task.taskIdentifier()))?;
    let r = n.reqs.get_mut(&id)?;
    if !allowed(r.kind, &url, &r.from) {
        r.error = NET_BLOCKED;
        return None;
    }
    if r.kind != NET_DOCUMENT || !r.from.is_empty() {
        return Some(request.copy());
    }
    let next: Retained<NSMutableURLRequest> = request.mutableCopy();
    next.setMainDocumentURL(request.URL().as_deref());
    Some(Retained::into_super(next))
}

/// `url` (the url crate's serialization) as RFC 3986 takes it: past the
/// authority, a byte RFC 3986 doesn't allow there (`[ ] | ^ \ { } "` and the
/// like) becomes %XX, as does a % that starts no escape and a # after the
/// first. NSURL would otherwise escape the whole URL again, %20 into %2520.
fn rfc3986(url: &str) -> String {
    let b = url.as_bytes();
    let start = url.find("://").map_or(0, |k| {
        let host = k + 3;
        url[host..]
            .find(['/', '?', '#'])
            .map_or(url.len(), |e| host + e)
    });
    let mut out = String::with_capacity(url.len());
    out.push_str(&url[..start]);
    let mut hashed = false;
    for (i, &c) in b.iter().enumerate().skip(start) {
        let plain = c.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@/?".contains(&c);
        let escape = c == b'%'
            && i + 2 < b.len()
            && b[i + 1].is_ascii_hexdigit()
            && b[i + 2].is_ascii_hexdigit();
        if plain || escape {
            out.push(c as char);
        } else if c == b'#' && !hashed {
            hashed = true;
            out.push('#');
        } else {
            out.push_str(&format!("%{c:02X}"));
        }
    }
    out
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

/// How far tab `tab`'s document has come: the bytes received so far into
/// `received`, and those expected into `expected` (-1 when the server didn't
/// say). Returns 1 while a document request of the tab runs, 0 when none
/// does.
#[unsafe(no_mangle)]
pub extern "C" fn tp_net_progress(tab: i32, received: *mut i64, expected: *mut i64) -> i32 {
    guarded(|| {
        if received.is_null() || expected.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let n = net();
        let Some(r) = n
            .reqs
            .values()
            .find(|r| r.tab == tab && r.kind == NET_DOCUMENT && !r.done)
        else {
            return Ok(0);
        };
        unsafe {
            received.write_unaligned(r.got);
            expected.write_unaligned(r.expected);
        }
        Ok(1)
    })
}

/// The size in bytes of the file at `path` (UTF-8), if it is a regular file:
/// what a file's page may read as a sheet. A device, a pipe, a folder or
/// nothing at all is ERR_ARGUMENT, so a page can't make its tab wait on one.
#[unsafe(no_mangle)]
pub extern "C" fn tp_file_size(path: GSlice<u8>) -> i64 {
    let mut size = ERR_ARGUMENT as i64;
    guarded(|| {
        let path = std::str::from_utf8(unsafe { path.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        let meta = std::fs::metadata(path).map_err(|_| ERR_ARGUMENT)?;
        if !meta.is_file() {
            return Err(ERR_ARGUMENT);
        }
        size = meta.len() as i64;
        Ok(0)
    });
    size
}

/// Opens `url` (UTF-8; http, https or file) in Safari, for a page Tusk can't
/// show yet (docs/adr/0001).
#[unsafe(no_mangle)]
pub extern "C" fn tp_open_in_safari(url: GSlice<u8>) -> i32 {
    guarded(|| {
        let url = std::str::from_utf8(unsafe { url.as_slice() }.ok_or(ERR_ARGUMENT)?)
            .map_err(|_| ERR_ARGUMENT)?;
        if !matches!(scheme_of(url).as_str(), "http" | "https" | "file") {
            return Err(ERR_ARGUMENT);
        }
        let mut child = std::process::Command::new("/usr/bin/open")
            .args(["-b", "com.apple.Safari", url])
            .spawn()
            .map_err(|_| ERR_ARGUMENT)?;
        // Reaped once it is done, so it leaves no zombie behind.
        std::thread::spawn(move || child.wait());
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
        // One that had ended and was told of says nothing more.
        tabs::forget_net(r.tab, req);
        Ok(0)
    })
}

/// Stops and forgets every request of tab `tab`, and its log, as its
/// mailbox closes.
pub(crate) fn cancel_tab(tab: i32) {
    logs().remove(&tab);
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

/// `body` as UTF-8, as WHATWG Encoding decodes it (encoding_rs): in order,
/// a byte order mark; the charset its response named, if WHATWG knows the
/// label; for a document a `<meta>` in its first 1024 bytes (HTML's
/// prescan), for a sheet a leading `@charset`; then UTF-8 if the bytes are
/// UTF-8, and windows-1252 if not (WHATWG's fallback for English). What
/// doesn't decode becomes U+FFFD, a sequence at a time.
fn to_utf8(body: Vec<u8>, charset: Option<&str>, kind: i32) -> Vec<u8> {
    if let Some((enc, bom)) = Encoding::for_bom(&body) {
        return decoded(enc, body, bom);
    }
    let declared = charset
        .and_then(|l| Encoding::for_label(l.trim().as_bytes()))
        .or_else(|| {
            if kind == NET_DOCUMENT {
                meta_charset(&body)
            } else {
                css_charset(&body)
            }
        });
    match declared {
        Some(enc) => decoded(enc, body, 0),
        None if std::str::from_utf8(&body).is_ok() => body,
        None => decoded(WINDOWS_1252, body, 0),
    }
}

/// `body` from byte `from` on, decoded from `enc` into UTF-8. UTF-8 that is
/// already whole is handed back as it is.
fn decoded(enc: &'static Encoding, body: Vec<u8>, from: usize) -> Vec<u8> {
    if enc == UTF_8 && from == 0 && std::str::from_utf8(&body).is_ok() {
        return body;
    }
    let (text, _) = enc.decode_without_bom_handling(&body[from..]);
    text.into_owned().into_bytes()
}

/// A charset a document or a sheet declares itself in: UTF-16 there can only
/// be a mistake (the bytes were read as ASCII to find it), so it means UTF-8,
/// and x-user-defined means windows-1252 (HTML §13.2.3.2).
fn declared_in_text(label: &[u8]) -> Option<&'static Encoding> {
    let enc = Encoding::for_label(label)?;
    if enc == UTF_16BE || enc == UTF_16LE {
        return Some(UTF_8);
    }
    if enc == X_USER_DEFINED {
        return Some(WINDOWS_1252);
    }
    Some(enc)
}

/// The charset the first 1024 bytes of a document declare in a `<meta>`, by
/// HTML's prescan (§13.2.3.2): comments and other tags are stepped over; a
/// `<meta charset>` counts, and a `<meta content="...; charset=x">` only with
/// `http-equiv="content-type"`.
fn meta_charset(body: &[u8]) -> Option<&'static Encoding> {
    let b = &body[..body.len().min(1024)];
    let mut i = 0;
    while i < b.len() {
        if b[i..].starts_with(b"<!--") {
            i = find(&b[i + 2..], b"-->").map_or(b.len(), |e| i + 2 + e + 3);
            continue;
        }
        if b[i] != b'<' {
            i += 1;
            continue;
        }
        let tag_start = i + 1;
        let is_meta = b.len() >= tag_start + 5
            && b[tag_start..tag_start + 4].eq_ignore_ascii_case(b"meta")
            && (b[tag_start + 4].is_ascii_whitespace() || b[tag_start + 4] == b'/');
        let is_tag = b.get(tag_start).is_some_and(|c| c.is_ascii_alphabetic())
            || (b.get(tag_start) == Some(&b'/')
                && b.get(tag_start + 1)
                    .is_some_and(|c| c.is_ascii_alphabetic()));
        if !is_tag {
            // <!...>, <?...> and the like run to the next '>'.
            i = find(&b[i..], b">").map_or(b.len(), |e| i + e + 1);
            continue;
        }
        // The tag's name, then its attributes.
        let mut j = tag_start;
        while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'>' {
            j += 1;
        }
        let mut pragma = false;
        let mut need_pragma: Option<bool> = None;
        let mut charset: Option<&'static Encoding> = None;
        while let Some((name, value, next)) = attribute(b, j) {
            j = next;
            if !is_meta {
                continue;
            }
            match name.as_str() {
                "http-equiv" => pragma = value.eq_ignore_ascii_case(b"content-type"),
                "content" if charset.is_none() => {
                    if let Some(label) = charset_in_content(&value) {
                        charset = declared_in_text(&label);
                        need_pragma = Some(true);
                    }
                }
                "charset" => {
                    charset = declared_in_text(value.trim_ascii());
                    need_pragma = Some(false);
                }
                _ => {}
            }
        }
        if is_meta
            && charset.is_some()
            && (need_pragma == Some(false) || (need_pragma == Some(true) && pragma))
        {
            return charset;
        }
        i = j.max(i + 1);
    }
    None
}

/// The attribute at or after byte `i` of a tag in `b`: its name in lower
/// case, its value, and where reading goes on; None at the tag's end.
fn attribute(b: &[u8], mut i: usize) -> Option<(String, Vec<u8>, usize)> {
    while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b'/') {
        i += 1;
    }
    if i >= b.len() || b[i] == b'>' {
        return None;
    }
    let mut name = Vec::new();
    while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' && b[i] != b'>' && b[i] != b'/'
    {
        name.push(b[i].to_ascii_lowercase());
        i += 1;
    }
    while i < b.len() && b[i].is_ascii_whitespace() {
        i += 1;
    }
    let mut value = Vec::new();
    if i < b.len() && b[i] == b'=' {
        i += 1;
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
            let q = b[i];
            i += 1;
            while i < b.len() && b[i] != q {
                value.push(b[i]);
                i += 1;
            }
            i += 1;
        } else {
            while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'>' {
                value.push(b[i]);
                i += 1;
            }
        }
    }
    Some((String::from_utf8_lossy(&name).into_owned(), value, i.max(1)))
}

/// The charset in a `<meta content>` such as "text/html; charset=x" (HTML
/// §2.6.3).
fn charset_in_content(v: &[u8]) -> Option<Vec<u8>> {
    let lower = v.to_ascii_lowercase();
    let mut from = 0;
    while let Some(k) = find(&lower[from..], b"charset") {
        let mut i = from + k + 7;
        while i < v.len() && v[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= v.len() || v[i] != b'=' {
            from = from + k + 7;
            continue;
        }
        i += 1;
        while i < v.len() && v[i].is_ascii_whitespace() {
            i += 1;
        }
        let (start, end) = if i < v.len() && (v[i] == b'"' || v[i] == b'\'') {
            let q = v[i];
            let e = v[i + 1..].iter().position(|&c| c == q)?;
            (i + 1, i + 1 + e)
        } else {
            let e = v[i..]
                .iter()
                .position(|&c| c == b';' || c.is_ascii_whitespace())
                .unwrap_or(v.len() - i);
            (i, i + e)
        };
        return if end > start {
            Some(v[start..end].to_vec())
        } else {
            None
        };
    }
    None
}

/// The charset a sheet names in a leading `@charset "...";` (CSS Syntax 3
/// §3.2).
fn css_charset(body: &[u8]) -> Option<&'static Encoding> {
    let rest = body.strip_prefix(b"@charset \"")?;
    let end = find(rest, b"\";")?;
    declared_in_text(&rest[..end])
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

    /// The Default profile on disk, in a folder of the test's own: a sheet
    /// the server says keeps 10 minutes comes from the cache the second time,
    /// and a cookie that outlives the session is saved, and restored, while
    /// a session cookie isn't. The only test that uses Default.
    #[test]
    fn the_default_profile_keeps_its_cache_and_cookies() {
        use std::sync::atomic::AtomicUsize;
        static HITS: AtomicUsize = AtomicUsize::new(0);
        fn route3(path: &str) -> (Vec<u8>, u64) {
            HITS.fetch_add(1, Ordering::SeqCst);
            match path {
                "/kept.css" => (
                    reply(
                        "200 OK",
                        "Content-Type: text/css\r\nCache-Control: max-age=600\r\n",
                        b"p { color: red }",
                    ),
                    0,
                ),
                "/login" => (
                    reply(
                        "200 OK",
                        "Content-Type: text/html\r\nSet-Cookie: kept=1; Max-Age=3600; Path=/\r\nSet-Cookie: gone=1; Path=/\r\n",
                        b"ok",
                    ),
                    0,
                ),
                _ => route(path),
            }
        }
        let dir = std::env::temp_dir().join(format!("tusk-profile-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        set_storage(&dir.join("Default")).unwrap();
        let port = serve(route3);
        let tab = 9105;
        assert_eq!(tp_tab_open(tab), 0);
        let open_default = |url: &str| {
            let mut url = url.as_bytes().to_vec();
            let none = GSlice::<u8> {
                data: std::ptr::null_mut(),
                len: 0,
            };
            let s = GSlice {
                data: url.as_mut_ptr(),
                len: url.len() as i64,
            };
            tp_net_open(tab, PROFILE_DEFAULT, NET_STYLE, s, none, 0)
        };
        for _ in 0..2 {
            assert!(open_default(&format!("http://127.0.0.1:{port}/kept.css")) > 0);
            assert_eq!(take(tab).1, b"p { color: red }");
        }
        assert_eq!(
            HITS.load(Ordering::SeqCst),
            1,
            "the second came from the server"
        );
        assert!(open_default(&format!("http://127.0.0.1:{port}/login")) > 0);
        take(tab);
        assert_eq!(tp_net_save(), 0);
        let file = dir.join("Default/cookies.plist");
        let mode = {
            use std::os::unix::fs::PermissionsExt;
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777
        };
        assert_eq!(mode, 0o600);
        let fresh = NSURLSessionConfiguration::ephemeralSessionConfiguration()
            .HTTPCookieStorage()
            .unwrap();
        restore_cookies(&fresh, &file);
        let names: Vec<String> = fresh
            .cookies()
            .unwrap()
            .iter()
            .map(|c| c.name().to_string())
            .collect();
        assert_eq!(names, ["kept"]);
        assert_eq!(tp_tab_drop(tab), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_page_logs_each_request_with_its_times() {
        assert_eq!(std::mem::size_of::<NetRow>(), 84);
        let port = serve(route);
        let tab = 9106;
        assert_eq!(tp_tab_open(tab), 0);
        let base = format!("http://127.0.0.1:{port}");
        open(tab, NET_DOCUMENT, &format!("{base}/page"), "");
        take(tab);
        open(
            tab,
            NET_STYLE,
            &format!("{base}/missing"),
            &format!("{base}/page"),
        );
        take(tab);
        // The metrics may come just after the end.
        std::thread::sleep(Duration::from_millis(200));
        let (mut rows, mut bytes) = (0i64, 0i64);
        assert_eq!(tp_net_log_size(tab, &mut rows, &mut bytes), 0);
        assert_eq!(rows, 2);
        let mut got = vec![NetRow::default(); rows as usize];
        let mut urls = vec![0u8; bytes as usize];
        let r = GSlice {
            data: got.as_mut_ptr(),
            len: rows,
        };
        let u = GSlice {
            data: urls.as_mut_ptr(),
            len: bytes,
        };
        assert_eq!(tp_net_log(tab, r, u), 0);
        let (status, proto, flags, size) =
            (got[0].status, got[0].proto, got[0].flags, got[0].bytes);
        assert_eq!((status, proto, size), (200, 1, "<p>héllo</p>".len() as i64));
        assert!(flags & ROW_TIMED != 0);
        let (at, len) = (got[0].url_at as usize, got[0].url_len as usize);
        assert_eq!(&urls[at..at + len], format!("{base}/page").as_bytes());
        let (status, kind, total, start) = (got[1].status, got[1].kind, got[1].total, got[1].start);
        assert_eq!((status, kind), (404, NET_STYLE));
        assert!(total > 0.0 && start >= 0.0);
        assert_eq!(tp_tab_drop(tab), 0);
        assert_eq!(tp_net_log_size(tab, &mut rows, &mut bytes), 0);
        assert_eq!(rows, 0, "a closed page's log goes");
    }

    #[test]
    fn only_a_regular_file_has_a_size() {
        let slice = |s: &str| GSlice {
            data: s.as_ptr().cast_mut(),
            len: s.len() as i64,
        };
        let here = format!("{}/src/net.rs", env!("CARGO_MANIFEST_DIR"));
        assert!(tp_file_size(slice(&here)) > 1000);
        assert_eq!(tp_file_size(slice("/dev/stdin")), ERR_ARGUMENT as i64);
        assert_eq!(tp_file_size(slice("/dev/zero")), ERR_ARGUMENT as i64);
        assert_eq!(tp_file_size(slice("/tmp")), ERR_ARGUMENT as i64);
        assert_eq!(tp_file_size(slice("/no/such/file")), ERR_ARGUMENT as i64);
    }

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
        let (mut got, mut of) = (-2i64, -2i64);
        assert_eq!(
            tp_net_progress(tab, &mut got, &mut of),
            1,
            "a document runs"
        );
        assert_eq!(got, 0);
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
        assert_eq!(tp_net_progress(tab, &mut got, &mut of), 0, "none runs");
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

    // ------------------------------------------------------ redirects, ids and charsets

    fn route2(path: &str) -> (Vec<u8>, u64) {
        match path {
            "/tofile" => (
                reply("302 Found", "Location: file:///etc/hosts\r\n", b""),
                0,
            ),
            "/todata" => (
                reply(
                    "302 Found",
                    "Location: data:text/css,p%7Bcolor:red%7D\r\n",
                    b"",
                ),
                0,
            ),
            "/gzip" => (
                reply(
                    "200 OK",
                    "Content-Type: text/html\r\nContent-Encoding: gzip\r\n",
                    include_bytes!("testdata/body.gz"),
                ),
                0,
            ),
            // UTF-16LE with a BOM and one unpaired surrogate (D800).
            "/utf16" => (
                reply(
                    "200 OK",
                    "Content-Type: text/html\r\n",
                    b"\xFF\xFEa\x00\x00\xD8b\x00",
                ),
                0,
            ),
            "/slowA" => (reply("200 OK", "Content-Type: text/css\r\n", b"AAAA"), 1500),
            "/slowB" => (reply("200 OK", "Content-Type: text/css\r\n", b"BBBB"), 4000),
            other => route(other),
        }
    }

    #[test]
    fn a_redirect_to_another_scheme_is_not_followed() {
        let port = serve(route2);
        let tab = 9201;
        assert_eq!(tp_tab_open(tab), 0);
        let base = format!("http://127.0.0.1:{port}");
        for p in ["/tofile", "/todata"] {
            assert!(
                open(
                    tab,
                    NET_STYLE,
                    &format!("{base}{p}"),
                    &format!("{base}/page")
                ) > 0
            );
            let (head, body, url, _, _) = take(tab);
            // The policy says http and https only: no body from another scheme.
            assert!(
                !url.starts_with("file:") && !url.starts_with("data:"),
                "{p} followed to {url}"
            );
            let error = head.error;
            assert!(error != 0 && body.is_empty(), "{p}: {error}");
        }
        assert_eq!(tp_tab_drop(tab), 0);
    }

    /// An https page's sheet that redirects to http: the policy is checked on
    /// the first URL only. Live: `cargo test --release -- --ignored mixed_content`.
    #[test]
    #[ignore]
    fn mixed_content_through_a_redirect_is_blocked() {
        let tab = 9202;
        assert_eq!(tp_tab_open(tab), 0);
        let req = open(
            tab,
            NET_STYLE,
            "https://httpbin.org/redirect-to?url=http://example.com/",
            "https://a.org/",
        );
        assert!(req > 0);
        let (head, _, url, ..) = take(tab);
        let error = head.error;
        assert_eq!(tp_tab_drop(tab), 0);
        assert!(
            !(url.starts_with("http:") && error == 0),
            "an https page loaded an http sheet through a redirect: {url}"
        );
    }

    #[test]
    fn progress_with_a_gzipped_body() {
        let port = serve(route2);
        let tab = 9203;
        assert_eq!(tp_tab_open(tab), 0);
        open(
            tab,
            NET_DOCUMENT,
            &format!("http://127.0.0.1:{port}/gzip"),
            "",
        );
        let (head, body, ..) = take(tab);
        let expected = head.expected;
        assert_eq!(tp_tab_drop(tab), 0);
        assert!(
            expected < 0 || expected >= body.len() as i64,
            "progress would read {} of {expected}",
            body.len()
        );
    }

    #[test]
    fn a_lone_surrogate_becomes_a_replacement_character() {
        // Straight through the decoder first.
        let got = to_utf8(b"\xFF\xFEa\x00\x00\xD8b\x00".to_vec(), None, NET_DOCUMENT);
        let odd = to_utf8(b"\xFF\xFEa\x00b".to_vec(), None, NET_DOCUMENT);
        assert_eq!(got, "a\u{FFFD}b".as_bytes(), "lone surrogate");
        assert_eq!(odd, "a\u{FFFD}".as_bytes(), "odd length");
    }

    #[test]
    fn a_request_cancelled_after_it_ended_never_answers() {
        let port = serve(route2);
        let tab = 9204;
        assert_eq!(tp_tab_open(tab), 0);
        let req = open(
            tab,
            NET_STYLE,
            &format!("http://127.0.0.1:{port}/sheet"),
            "",
        );
        // Ends; its MSG_NET is posted. The worker then gives up on it (a
        // wave's timeout landing at the same moment).
        let mut head = NetHead::default();
        let start = std::time::Instant::now();
        while tp_net_head(req, &mut head) != 1 {
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::yield_now();
        }
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(tp_net_cancel(req), 0);
        let mut m = TabMsg::default();
        let got = tp_tab_next(tab, 500, &mut m);
        let (kind, a) = (m.kind, m.a);
        assert_eq!(tp_tab_drop(tab), 0);
        assert_eq!(
            got, 0,
            "cancelled request {req} still answered: kind {kind} a {a}"
        );
    }

    #[test]
    fn wrapped_ids_pass_over_live_requests() {
        let port = serve(route2);
        let tab = 9205;
        assert_eq!(tp_tab_open(tab), 0);
        let base = format!("http://127.0.0.1:{port}");
        let a = open(tab, NET_STYLE, &format!("{base}/slowA"), "");
        // 2^24 requests later the counter comes round to `a` again, while
        // `a` still runs.
        net().last = a - 1;
        let b = open(tab, NET_STYLE, &format!("{base}/slowB"), "");
        let (head, body, url, ..) = take(tab);
        let req = head.req;
        assert_eq!(tp_tab_drop(tab), 0);
        assert!(
            a != b,
            "B got A's id {a}; the first answer for it was {url} {:?} (req {req})",
            String::from_utf8_lossy(&body)
        );
    }

    #[test]
    fn charset_labels_as_whatwg_reads_them() {
        let doc = |bytes: &[u8], cs: Option<&str>| {
            String::from_utf8(to_utf8(bytes.to_vec(), cs, NET_DOCUMENT)).unwrap()
        };
        let mut bad = Vec::new();
        let mut check = |what: &str, got: String, want: &str| {
            if !got.ends_with(want) {
                bad.push(what.to_string());
            }
        };
        // WHATWG: gb2312 is a label of GBK; 0x81 0x40 is GBK-only.
        check(
            "gb2312+GBK",
            doc(b"\xc4\xe3\xba\xc3\x81\x40", Some("gb2312")),
            "你好丂",
        );
        // WHATWG: shift_jis is windows-31J; 0x87 0x40 is NEC's circled 1.
        check(
            "shift_jis+NEC",
            doc(b"\x82\xa0\x87\x40", Some("shift_jis")),
            "あ①",
        );
        // WHATWG: euc-kr is windows-949; 0x8C 0x63 is UHC-only.
        check(
            "euc-kr+UHC",
            doc(b"\xc7\xd1\x8c\x63", Some("euc-kr")),
            "한똠",
        );
        check(
            "ks_c_5601-1987",
            doc(b"\xc7\xd1", Some("ks_c_5601-1987")),
            "한",
        );
        // WHATWG: iso_8859-1 and iso88591 are windows-1252 labels too.
        check("iso_8859-1", doc(b"\x93q\x94", Some("iso_8859-1")), "“q”");
        check("iso88591", doc(b"\x93q\x94", Some("iso88591")), "“q”");
        // WHATWG: iso-8859-9 is windows-1254; tis-620 windows-874.
        check("iso-8859-9", doc(b"\x93", Some("iso-8859-9")), "“");
        check("tis-620", doc(b"\x93", Some("tis-620")), "“");
        // WHATWG prescan: a meta naming UTF-16 means UTF-8.
        check(
            "meta utf-16",
            doc("<meta charset=\"utf-16\"><p>héllo".as_bytes(), None),
            "héllo",
        );
        // WHATWG prescan: comments are skipped.
        check(
            "meta in comment",
            doc("<!-- <meta charset=\"koi8-r\"> --><p>café".as_bytes(), None),
            "café",
        );
        // WHATWG prescan: spaces around '=' are allowed.
        check(
            "meta charset = x",
            doc(b"<meta charset = \"windows-1251\">\xcf\xf0\xe8", None),
            "При",
        );
        // A charset in another meta's content, not http-equiv: ignored.
        check(
            "meta name content",
            doc(
                "<meta name=\"description\" content=\"About charset=koi8-r\"><p>café".as_bytes(),
                None,
            ),
            "café",
        );
        assert!(bad.is_empty(), "decoded unlike WHATWG: {bad:?}");
    }
}

#[cfg(test)]
mod redirects_and_urls {
    use super::*;
    use crate::tabs::{MSG_NET, TabMsg, tp_tab_drop, tp_tab_next, tp_tab_open};
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    fn open(tab: i32, kind: i32, url: &str, from: &str) -> i32 {
        let mut url = url.as_bytes().to_vec();
        let mut from = from.as_bytes().to_vec();
        let s = |v: &mut Vec<u8>| GSlice {
            data: if v.is_empty() {
                std::ptr::null_mut()
            } else {
                v.as_mut_ptr()
            },
            len: v.len() as i64,
        };
        tp_net_open(tab, PROFILE_SANDBOX, kind, s(&mut url), s(&mut from), 0)
    }

    fn wait(tab: i32) -> (i32, String) {
        let mut m = TabMsg::default();
        assert_eq!(tp_tab_next(tab, 10_000, &mut m), 1);
        let (kind, a) = (m.kind, m.a);
        assert_eq!(kind, MSG_NET);
        let req = a as i32;
        let mut head = NetHead::default();
        assert_eq!(tp_net_head(req, &mut head), 1);
        let n = net();
        let r = n.reqs.get(&req).unwrap();
        (r.status, String::from_utf8_lossy(&r.url).into_owned())
    }

    #[test]
    fn a_page_keeps_the_cookies_its_redirects_set() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen: Arc<Mutex<Vec<(String, String)>>> = Arc::default();
        let log = seen.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let path = line.split(' ').nth(1).unwrap_or("/").to_string();
                let mut cookie = String::new();
                let mut host = String::new();
                loop {
                    let mut h = String::new();
                    if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                        break;
                    }
                    let l = h.to_ascii_lowercase();
                    if l.starts_with("cookie:") {
                        cookie = h.trim().to_string();
                    }
                    if l.starts_with("host:") {
                        host = h.trim().to_string();
                    }
                }
                log.lock().unwrap().push((format!("{host} {path}"), cookie));
                let resp = match path.as_str() {
                    // On 127.0.0.1: sends the page on to localhost.
                    "/go" => format!(
                        "HTTP/1.1 302 Found\r\nLocation: http://localhost:{port}/login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    ),
                    // On localhost: the site's own session cookie.
                    "/login" => "HTTP/1.1 200 OK\r\nSet-Cookie: sid=1; Path=/\r\nContent-Type: text/html\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_string(),
                    _ => "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_string(),
                };
                let _ = stream.write_all(resp.as_bytes());
            }
        });
        let tab = 9301;
        assert_eq!(tp_tab_open(tab), 0);
        // A document through a cross-site redirect (a link shortener, a
        // sign-in), then the site's next page.
        open(
            tab,
            NET_DOCUMENT,
            &format!("http://127.0.0.1:{port}/go"),
            "",
        );
        wait(tab);
        open(
            tab,
            NET_DOCUMENT,
            &format!("http://localhost:{port}/next"),
            "",
        );
        wait(tab);
        assert_eq!(tp_tab_drop(tab), 0);
        let seen = seen.lock().unwrap().clone();
        let next = seen.iter().find(|(p, _)| p.ends_with("/next")).unwrap();
        assert!(
            !next.1.is_empty(),
            "the redirect target's cookie was dropped: {seen:?}"
        );
    }

    #[test]
    fn nsurl_keeps_what_rfc3986_hands_it() {
        for s in [
            "https://a.org/x?q=a|b",
            "https://a.org/back/slash?q=\\",
            "https://a.org/a^b{c}`d",
            "https://a.org/%zz?x=%",
            "https://a.org/p#frag|x",
            "https://a.org/wiki/Ü|x",
            "https://a.org/css?family=Roboto|Open+Sans&t=%E2%9C%93",
            "https://a.org/caf%C3%A9?d=50%",
            "https://a.org/a b^c.css",
            "https://a.org/q?a=[1]&b=%20",
        ] {
            let ser = rfc3986(::url::Url::parse(s).unwrap().as_str());
            let ns = NSURL::URLWithString(&NSString::from_str(&ser))
                .and_then(|u| u.absoluteString())
                .map(|u| u.to_string());
            assert_eq!(ns.as_deref(), Some(ser.as_str()), "{s}");
        }
    }

    #[test]
    fn the_server_gets_the_url_crates_serialization() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let paths: Arc<Mutex<Vec<String>>> = Arc::default();
        let log = paths.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                loop {
                    let mut h = String::new();
                    if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                        break;
                    }
                }
                log.lock()
                    .unwrap()
                    .push(line.split(' ').nth(1).unwrap_or("").to_string());
                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/css\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            }
        });
        let tab = 9302;
        assert_eq!(tp_tab_open(tab), 0);
        // What tp_url_resolve hands the worker for href="q?filter[tag]=a%20b".
        let url = crate::url::resolve(&format!("http://127.0.0.1:{port}/"), "q?filter[tag]=a%20b")
            .unwrap();
        assert!(open(tab, NET_STYLE, &url, "") > 0);
        wait(tab);
        assert_eq!(tp_tab_drop(tab), 0);
        let got = paths.lock().unwrap().clone();
        assert!(
            !got[0].contains("%2520"),
            "a%20b reached the server as {}",
            got[0]
        );
    }
}

#[cfg(test)]
mod surrogates {
    use super::*;
    #[test]
    fn other_routes_to_a_lone_surrogate() {
        // UTF-7 is no label WHATWG knows: the bytes are read as UTF-8.
        let utf7 = to_utf8(b"a+2AA-b".to_vec(), Some("utf-7"), NET_DOCUMENT);
        assert_eq!(utf7, b"a+2AA-b");
        // An Arabic page in UTF-8 that mislabels itself UTF-16 in its meta:
        // a page that says so in itself is UTF-8.
        let mut arabic = b"<meta charset=\"utf-16\">".to_vec();
        arabic.extend_from_slice("مرحبا بالعالم".as_bytes());
        let len = arabic.len();
        let got = to_utf8(arabic, None, NET_DOCUMENT);
        assert_eq!(got.len(), len);
        assert!(
            std::str::from_utf8(&got)
                .unwrap()
                .ends_with("مرحبا بالعالم")
        );
        // So is a sheet: what isn't UTF-8 in it becomes U+FFFD.
        let sheet = to_utf8(b"@charset \"utf-16le\";\x00\xd8".to_vec(), None, NET_STYLE);
        assert!(
            std::str::from_utf8(&sheet)
                .unwrap()
                .ends_with("\u{0}\u{FFFD}")
        );
    }
}

#[cfg(test)]
mod header_labels {
    use super::*;
    #[test]
    fn an_unknown_header_label_falls_through_to_the_meta() {
        let got = to_utf8(
            b"<meta charset=windows-1251>\xcf\xf0\xe8".to_vec(),
            Some("x-nonsense"),
            NET_DOCUMENT,
        );
        assert!(got.ends_with("При".as_bytes()));
    }
}

#[cfg(test)]
mod closing_mailboxes {
    use crate::tabs::{TabMsg, tp_tab_drop, tp_tab_next, tp_tab_open};
    use std::time::{Duration, Instant};
    #[test]
    fn closing_a_mailbox_wakes_a_worker_waiting_on_it() {
        let tab = 9401;
        assert_eq!(tp_tab_open(tab), 0);
        let worker = std::thread::spawn(move || {
            let start = Instant::now();
            let mut m = TabMsg::default();
            let got = tp_tab_next(tab, 3000, &mut m);
            (got, start.elapsed())
        });
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(tp_tab_drop(tab), 0);
        let (got, took) = worker.join().unwrap();
        assert!(
            took < Duration::from_millis(1000),
            "slept {took:?} past the close"
        );
        // Woken, it finds the mailbox gone: an error, which ends a worker.
        assert!(got < 0, "{got}");
    }
}
