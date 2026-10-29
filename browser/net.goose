// A thin wrapper around libgoosenet (../goosenet, a Rust cdylib) that gives
// Goose v1 one thing its stdlib does not have: HTTP(S) GET, with TLS and
// redirects handled on the Rust side.
//
// "goosenet" is dynamically bound at the first call that reaches it
// (reference.md #24): it opens libgoosenet.dylib/.so/.dll found by the
// loader's normal search, so the library must sit beside the program or
// somewhere the OS loader looks (DYLD_LIBRARY_PATH / LD_LIBRARY_PATH / PATH).

import ffi;

extern "goosenet" {
    fn goosenet_fetch(url: const u8&, url_len: i64, out_ptr: u64&, out_len: i64&,
                       out_status: i32&) -> i32;
    fn goosenet_fetch_image(url: const u8&, url_len: i64, out_ptr: u64&, out_len: i64&,
                             out_w: i32&, out_h: i32&) -> i32;
    fn goosenet_free(ptr: u64, len: i64);
}

// Fetches `url` (http:// or https://), following redirects and negotiating
// TLS as needed. On success returns the HTTP status code and appends the
// body to `body`. A negative return is a transport-level failure (bad URL,
// DNS, connect, TLS, timeout, too many redirects) -- there is no status
// code for those, since no response ever came back.
fn http_get_page(url: u8[:], body: u8[>..]&) -> i64 {
    var ptr: u64 = 0;
    var len: i64 = 0;
    var status: i32 = 0;
    let rc = goosenet_fetch(url[0], url.len, ptr, len, status);
    if rc != 0 { return rc as i64; }
    ffi::bytes(ptr, len, body);
    goosenet_free(ptr, len);
    return status as i64;
}

// Fetches `url`, decodes it as PNG/JPEG/GIF/WebP, downsamples it to at
// most 480px on its longest side (decode time, the copy across the thread
// queue, and the GPU upload all stay cheap no matter how big the original
// was), and appends raw RGBA8 pixels (width*height*4 bytes, row-major) to
// `pixels`. Returns true and sets `w`/`h` on success; false (and appends
// nothing) on a transport failure or an unsupported/corrupt image format.
fn fetch_image_rgba(url: u8[:], pixels: u8[>..]&, w: i32&, h: i32&) -> bool {
    var ptr: u64 = 0;
    var len: i64 = 0;
    var width: i32 = 0;
    var height: i32 = 0;
    let rc = goosenet_fetch_image(url[0], url.len, ptr, len, width, height);
    if rc != 0 { return false; }
    ffi::bytes(ptr, len, pixels);
    goosenet_free(ptr, len);
    w = width;
    h = height;
    return true;
}
