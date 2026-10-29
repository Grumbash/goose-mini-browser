// A tiny networking shim for Goose, exposed with a plain C ABI so Goose's
// `extern "goosenet" { ... }` can dynamically bind it (reference.md #24).
// Goose v1 has no sockets and no TLS of its own; this fills that one gap
// with a single call: give it a URL, get back a status code and a body,
// following redirects and negotiating TLS where the scheme needs it.
//
// Build: cargo build --release
// Produces target/release/libgoosenet.dylib (macOS) / .so (Linux) / .dll (Windows).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::slice;
use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

const MAX_REDIRECTS: u32 = 8;
const MAX_BODY: usize = 32 * 1024 * 1024; // 32 MB: a sanity cap, not a real limit

/// Fetches `url` (http:// or https://), follows redirects, and writes the
/// final response body into `out_ptr`/`out_len` (a heap buffer the caller
/// must pass to `goosenet_free` exactly once) and the final status code
/// into `out_status`. Returns 0 on success, a negative code on failure
/// (bad URL, DNS/connect/TLS/timeout, too many redirects); on failure the
/// out parameters are left at zero/untouched and must not be freed.
#[no_mangle]
pub extern "C" fn goosenet_fetch(
    url_ptr: *const u8,
    url_len: i64,
    out_ptr: *mut u64,
    out_len: *mut i64,
    out_status: *mut i32,
) -> i32 {
    let url = match read_str(url_ptr, url_len) {
        Some(s) => s,
        None => return -1,
    };
    match fetch_follow(&url) {
        Ok((status, body)) => {
            let len = body.len() as i64;
            let boxed = body.into_boxed_slice();
            let ptr = Box::into_raw(boxed) as *mut u8 as u64;
            unsafe {
                *out_ptr = ptr;
                *out_len = len;
                *out_status = status;
            }
            0
        }
        Err(_) => -2,
    }
}

/// Releases a buffer `goosenet_fetch` handed back.
#[no_mangle]
pub extern "C" fn goosenet_free(ptr: u64, len: i64) {
    if ptr == 0 || len <= 0 {
        return;
    }
    unsafe {
        let p = ptr as *mut u8;
        drop(Box::from_raw(slice::from_raw_parts_mut(p, len as usize)));
    }
}

// A display image never needs to be bigger than this on either side: it
// keeps decode time, the memcpy across the thread queue, and the GPU
// texture upload all cheap regardless of what the server actually sent
// (a phone photo can be 4000px wide for a 400px-wide `<img>`). Aspect
// ratio is preserved; only images already smaller are left alone.
const MAX_IMAGE_SIDE: u32 = 480;

/// Fetches `url`, decodes it as an image (PNG/JPEG/GIF/WebP), downsamples
/// it to at most `MAX_IMAGE_SIDE` on its longest side, and writes RGBA8
/// pixels into `out_ptr`/`out_len` (`width*height*4` bytes, row-major, no
/// padding) plus `out_w`/`out_h`. Returns 0 on success, a negative code on
/// failure (fetch failed, or the bytes don't decode as a supported image
/// format) -- on failure the out parameters are left untouched.
#[no_mangle]
pub extern "C" fn goosenet_fetch_image(
    url_ptr: *const u8,
    url_len: i64,
    out_ptr: *mut u64,
    out_len: *mut i64,
    out_w: *mut i32,
    out_h: *mut i32,
) -> i32 {
    let url = match read_str(url_ptr, url_len) {
        Some(s) => s,
        None => return -1,
    };
    let (status, body) = match fetch_follow(&url) {
        Ok(r) => r,
        Err(_) => return -2,
    };
    if !(200..300).contains(&status) {
        return -3;
    }
    let img = match image::load_from_memory(&body) {
        Ok(i) => i,
        Err(_) => return -4,
    };
    let (w0, h0) = (img.width(), img.height());
    let img = if w0 > MAX_IMAGE_SIDE || h0 > MAX_IMAGE_SIDE {
        img.resize(MAX_IMAGE_SIDE, MAX_IMAGE_SIDE, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let raw = rgba.into_raw();
    let len = raw.len() as i64;
    let boxed = raw.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut u8 as u64;
    unsafe {
        *out_ptr = ptr;
        *out_len = len;
        *out_w = w as i32;
        *out_h = h as i32;
    }
    0
}

fn read_str(ptr: *const u8, len: i64) -> Option<String> {
    if ptr.is_null() || len < 0 {
        return None;
    }
    let bytes = unsafe { slice::from_raw_parts(ptr, len as usize) };
    std::str::from_utf8(bytes).ok().map(|s| s.to_owned())
}

#[derive(Clone)]
struct Url {
    https: bool,
    host: String,
    port: u16,
    path: String,
}

fn parse_url(url: &str) -> Result<Url, String> {
    let (https, rest) = if let Some(r) = url.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = url.strip_prefix("http://") {
        (false, r)
    } else {
        return Err(format!("unsupported scheme: {url}"));
    };
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().unwrap_or(if https { 443 } else { 80 })),
        None => (authority, if https { 443 } else { 80 }),
    };
    Ok(Url { https, host: host.to_string(), port, path: path.to_string() })
}

// Resolves a redirect's Location header against the URL it came from:
// absolute URLs pass through, "/path" replaces the path on the same host,
// anything else is taken as relative to the current directory.
fn resolve_redirect(base: &Url, location: &str) -> String {
    if location.starts_with("http://") || location.starts_with("https://") {
        return location.to_string();
    }
    let scheme = if base.https { "https" } else { "http" };
    if let Some(rest) = location.strip_prefix('/') {
        return format!("{scheme}://{}:{}/{}", base.host, base.port, rest);
    }
    let dir = match base.path.rfind('/') {
        Some(i) => &base.path[..=i],
        None => "/",
    };
    format!("{scheme}://{}:{}{}{}", base.host, base.port, dir, location)
}

fn fetch_follow(start_url: &str) -> Result<(i32, Vec<u8>), String> {
    let mut current = start_url.to_string();
    for _ in 0..MAX_REDIRECTS {
        let parsed = parse_url(&current)?;
        let raw = if parsed.https { fetch_https(&parsed)? } else { fetch_http(&parsed)? };
        let (status, headers, mut body) = split_response(&raw)?;
        if let Some(te) = header_get(&headers, "transfer-encoding") {
            if te.to_ascii_lowercase().contains("chunked") {
                body = dechunk(&body);
            }
        }
        if (300..400).contains(&status) {
            if let Some(loc) = header_get(&headers, "location") {
                current = resolve_redirect(&parsed, &loc);
                continue;
            }
        }
        return Ok((status, body));
    }
    Err("too many redirects".to_string())
}

// Undoes HTTP/1.1 chunked transfer-encoding: "<hex size>[;ext]\r\n<data>\r\n"
// repeated, ending at a zero-size chunk. Tolerant of a response truncated
// mid-chunk (returns what it decoded so far) since a dropped connection is
// common and a partial page is better than none.
fn dechunk(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < body.len() {
        let line_end = match body[i..].windows(2).position(|w| w == b"\r\n") {
            Some(p) => i + p,
            None => break,
        };
        let size_line = String::from_utf8_lossy(&body[i..line_end]);
        let size_str = size_line.split(';').next().unwrap_or("0").trim();
        let size = match usize::from_str_radix(size_str, 16) {
            Ok(n) => n,
            Err(_) => break,
        };
        if size == 0 {
            break;
        }
        let data_start = line_end + 2;
        let data_end = (data_start + size).min(body.len());
        out.extend_from_slice(&body[data_start..data_end]);
        if data_end < body.len() {
            i = data_end + 2; // skip the chunk's trailing \r\n
        } else {
            break;
        }
    }
    out
}

fn request_bytes(host: &str, path: &str) -> Vec<u8> {
    format!(
        "GET {path} HTTP/1.0\r\nHost: {host}\r\nUser-Agent: goose-mini-browser/0.2\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    )
    .into_bytes()
}

fn fetch_http(u: &Url) -> Result<Vec<u8>, String> {
    let mut stream = TcpStream::connect((u.host.as_str(), u.port)).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(15))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(15))).ok();
    stream.write_all(&request_bytes(&u.host, &u.path)).map_err(|e| e.to_string())?;
    read_capped(&mut stream)
}

fn fetch_https(u: &Url) -> Result<Vec<u8>, String> {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = ClientConfig::builder().with_root_certificates(roots).with_no_client_auth();
    let server_name = ServerName::try_from(u.host.clone()).map_err(|e| e.to_string())?;
    let conn = ClientConnection::new(Arc::new(config), server_name).map_err(|e| e.to_string())?;
    let sock = TcpStream::connect((u.host.as_str(), u.port)).map_err(|e| e.to_string())?;
    sock.set_read_timeout(Some(Duration::from_secs(15))).ok();
    sock.set_write_timeout(Some(Duration::from_secs(15))).ok();
    let mut tls = StreamOwned::new(conn, sock);
    tls.write_all(&request_bytes(&u.host, &u.path)).map_err(|e| e.to_string())?;
    read_capped(&mut tls)
}

// read_to_end, but tolerant of a peer that closes the TCP connection
// without a clean TLS close_notify (very common) and capped so a
// misbehaving server cannot exhaust memory.
fn read_capped<R: Read>(r: &mut R) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        match r.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() >= MAX_BODY {
                    break;
                }
            }
            Err(_) if !buf.is_empty() => break, // truncated TLS close etc: keep what we got
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(buf)
}

fn header_get(headers: &str, name: &str) -> Option<String> {
    for line in headers.split("\r\n") {
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case(name) {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}

fn split_response(raw: &[u8]) -> Result<(i32, String, Vec<u8>), String> {
    let split_at = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| (i, 4))
        .or_else(|| raw.windows(2).position(|w| w == b"\n\n").map(|i| (i, 2)));
    let (head, body) = match split_at {
        Some((i, skip)) => (&raw[..i], &raw[i + skip..]),
        None => (raw, &raw[raw.len()..]),
    };
    let head_str = String::from_utf8_lossy(head);
    let mut lines = head_str.split("\r\n").flat_map(|l| l.split('\n'));
    let status_line = lines.next().unwrap_or("");
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(0);
    let headers = head_str.splitn(2, '\n').nth(1).unwrap_or("").to_string();
    Ok((status, headers, body.to_vec()))
}
