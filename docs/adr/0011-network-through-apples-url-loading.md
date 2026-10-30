# 0011. The network goes through Apple's URL loading system

Date: 30 Oct 2026 · Status: Proposed · Decided by: Vlad

## Context

M2 opens the live web (ADR 0004). ADR 0001 put networking in Rust as "HTTP/1.1
and HTTP/2, TLS (rustls), cookies, cache". Before writing it we measured the
pages we read (30 Oct 2026, from this Mac):

- The network decides the wait. Opening a connection took 130–630 ms and the
  first byte 180–860 ms. A second request on a reused HTTP/2 connection to
  Wikipedia had its first byte in 81 ms.
- Pages bring many sheets: 2 on Wikipedia, 12 in the Rust book, 18 on MDN, 37 on
  a GitHub repository. Most have content-hashed names, so a disk cache keeps them.
- danluu.com, the Rust book and GitHub's assets offer HTTP/3. danluu.com opened
  in 60 ms over HTTP/3 against 178 ms over HTTP/2.

Our own stack (hyper, h2, tokio, rustls) would mean writing HTTP caching and a
cookie jar with the public suffix list, and adding HTTP/3 on top. Apple's URL
loading system (NSURLSession) already does HTTP/1.1, /2 and /3, caching, cookies,
Safari's certificate trust and per-phase timing. Its bindings are in
objc2-foundation, which the platform layer already uses.

## Decision

- Networking stays in the Rust platform layer, as ADR 0001 says, but Rust drives
  NSURLSession instead of a TLS and HTTP stack of its own. This replaces "TLS
  (rustls)" in ADR 0001's table, the same way text goes through Core Text.
- **A profile is a session** (ADR 0008). Each has its own cookies and cache.
  Default keeps them on disk, under
  `~/Library/Application Support/Tusk/Default/`; Sandbox keeps nothing (ADR
  0007). Tests, CI, screenshots and snapshots use Sandbox.
- **Requests never block the main thread.** A tab's worker asks for a URL and
  gets a request id. The session's delegate, on a serial queue of its own,
  collects the bytes and the timing. When a request ends, it posts a message to
  that tab's mailbox and wakes the worker. Closing a tab cancels its requests.
- **Goose sees UTF-8 only.** The platform layer decodes any other charset as
  WHATWG Encoding says (BOM, then the HTTP header, then `<meta charset>`), with
  encoding_rs, before the bytes cross. Core Foundation's decoders turn a whole
  page to nothing over one bad byte and know CJK only by its strict subsets;
  encoding_rs adds 206 KB to the platform library.
- **URLs are resolved as WHATWG says**, by the url crate (Servo's), and the
  session gets them in their serialization. Against WPT's `urltestdata.json`
  (its 202 cases with an http or https base), NSURL with a WHATWG pre-pass
  agreed with 111 and the url crate with 195. The crate adds 230 KB to the
  platform library, mostly Unicode tables for international domain names.
- **Pages are untrusted.**
  - A page may load http and https.
  - `file://` opens only when we ask for it: from the command line or the
    address bar.
  - An http sheet on an https page is blocked.
  - Sizes are capped: a document at 64 MB, a sheet at 16 MB, 256 sheets per page.
  - A TLS error fails the load; there is no way past it.

## Consequences

- No TLS or HTTP code of our own, and two new crates (url, encoding_rs); trust
  follows the system keychain.
- Less control: there's no public way to open a connection ahead of a click,
  and the cache follows Apple's rules. A response over about 5% of the disk
  cache isn't kept.
- The C interface between Goose and the network names nothing of Apple's, so an
  own Rust stack can replace this one without touching Goose.
- The dev panel's Network tab shows the session's own timing: DNS, connect, TLS,
  waiting, download, the protocol and whether the connection was reused.
