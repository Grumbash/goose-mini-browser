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
