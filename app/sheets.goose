// A page's style sheets, for its tab's worker (docs/adr/0011): each <style>
// and each linked sheet, in document order, with what each @imports put
// before it. Linked sheets are fetched all at once, then what they import
// the same way, a wave at a time, at most four deep; a sheet that imports
// one it is itself imported by stops there. A page shows only once its
// sheets have come, as in browsers, but no wave waits more than 10 s: what
// hasn't come by then is left out, and the Console says so.

import std;
import os;
import engine from "../engine";
import engine.dom;
import engine.css;
import .tab;
import .net;

let SHEETS_MAX: i64 = 256;       // sheets per page, imports included
let IMPORT_DEPTH: i32 = 4;
let WAVE_MS: i64 = 10000;

// A sheet: the one that imports it (-1 for the page's own), how deep, its
// URL (what its imports resolve against), text and media (what its <link>,
// <style> or @import says; empty: all) as spans of the pool, and its
// request while it runs (0 when none does).
struct SheetFetch { parent: i32, depth: i32, url_at: i64, url_len: i64, text_at: i64, text_len: i64, media_at: i64,
                    media_len: i64, req: i32 }

// The sheets of document `d`, at `page` (its URL; "file://..." for a file),
// with relative URLs resolving against `base`, fetched with tp_net_open's
// `flags`: onto `texts`, one after
// another in the cascade's order (each one's imports before it), each
// ending where `ends` says, and the media each applies under onto `medias`,
// and `media_ends`, as load_sheets_with reads them. What went wrong goes on
// `log`, a line each. What the main thread asks meanwhile goes in `later`.
// False if the tab quits first.
fn gather_sheets(tab: i32, profile: i32, flags: i32, d: Doc, page: const u8[:], base: const u8[:], texts: u8[>..]&,
                 ends: i64[>..]&, medias: u8[>..]&, media_ends: i64[>..]&, later: TabMsg[>..]&, log: u8[>..]&) -> bool {
    var sources: i32[>..] = [];
    sheet_sources(d, sources);
    guard sources.len > 0 else { return true; }
    var fetches: SheetFetch[>..] = [];
    var pool: u8[>..] = [];
    for n in sources {
        guard fetches.len < SHEETS_MAX else { break; }
        let k = fetches.len as i32;
        fetches.push(SheetFetch { parent: -1, depth: 0, url_at: pool.len, url_len: 0, text_at: 0, text_len: 0, media_at: 0,
                                  media_len: 0, req: 0 });
        let media, has_media = attr_value(d, n, "media");
        if has_media {
            fetches[k].media_at = pool.len;
            pool.append(trim(media));
            fetches[k].media_len = pool.len - fetches[k].media_at;
        }
        if node_name(d, n) == "style" {
            pool.append(base);
            fetches[k].url_len = base.len;
            fetches[k].text_at = pool.len;
            pool.append(node_text(d, d.nodes[n].first));
            fetches[k].text_len = pool.len - fetches[k].text_at;
        } else {
            let href, has = attr_value(d, n, "href");
            start_sheet(tab, profile, flags, page, base, href, fetches, k, pool, log);
        }
    }
    // A wave: wait for what runs, then start what the sheets that came import.
    var wave_from: i64 = 0;
    loop {
        guard wait_sheets(tab, fetches, pool, later, log) else { return false; }
        let wave_to = fetches.len;
        for k in wave_from..wave_to {
            guard fetches[k].depth < IMPORT_DEPTH && fetches[k].text_len > 0 else { continue; }
            var hrefs: u8[>..] = [];
            var href_ends: i64[>..] = [];
            var import_medias: u8[>..] = [];
            var import_media_ends: i64[>..] = [];
            sheet_imports(pool[fetches[k].text_at..fetches[k].text_at + fetches[k].text_len], hrefs, href_ends,
                          import_medias, import_media_ends);
            var from: i64 = 0;
            var mfrom: i64 = 0;
            for e, h in href_ends {
                guard fetches.len < SHEETS_MAX else { break; }
                let at = fetches.len as i32;
                let media_at = pool.len;
                pool.append(import_medias[mfrom..import_media_ends[h]]);
                mfrom = import_media_ends[h];
                fetches.push(SheetFetch { parent: k as i32, depth: fetches[k].depth + 1, url_at: pool.len, url_len: 0,
                                          text_at: 0, text_len: 0, media_at: media_at, media_len: pool.len - media_at,
                                          req: 0 });
                var url: u8[>..] = [];
                url.append(pool[fetches[k].url_at..fetches[k].url_at + fetches[k].url_len]);
                start_sheet(tab, profile, flags, page, url[..], hrefs[from..e], fetches, at, pool, log);
                from = e;
            }
        }
        guard fetches.len > wave_to else { break; }
        wave_from = wave_to;
    }
    put_sheets(fetches[..], pool[..], texts, ends, medias, media_ends);
    return true;
}

// The sheets onto `out`, each ending where `ends` says, every one's imports
// before it; and onto `medias` the media each applies under: those of the
// sheets that import it, outermost first, then its own, apart by U+0001. A
// sheet comes after the one importing it in `fetches`, at most IMPORT_DEPTH
// below a page's own, so its chain is made from its parent's, and a stack
// that deep walks each page's sheet's imports first.
fn put_sheets(fetches: const SheetFetch[:], pool: const u8[:], out: u8[>..]&, ends: i64[>..]&, medias: u8[>..]&,
              media_ends: i64[>..]&) {
    var chains: u8[>..] = [];
    var chain_at: i64[>..] = [];
    var chain_len: i64[>..] = [];
    for f in fetches {
        let at = chains.len;
        if f.parent >= 0 { chains.append(chains[chain_at[f.parent]..chain_at[f.parent] + chain_len[f.parent]]); }
        if f.media_len > 0 {
            if chains.len > at { chains.push(0x01); }
            chains.append(pool[f.media_at..f.media_at + f.media_len]);
        }
        chain_at.push(at);
        chain_len.push(chains.len - at);
    }
    var stack: i32[8];
    var scan: i64[8];
    for f, root in fetches {
        guard f.parent < 0 else { continue; }
        stack[0] = root as i32;
        scan[0] = root + 1;
        var top: i64 = 1;
        while top > 0 {
            let n = stack[top - 1];
            var j = scan[top - 1];
            while j < fetches.len && fetches[j].parent != n { j += 1; }
            if j < fetches.len && top < 8 {
                scan[top - 1] = j + 1;
                stack[top] = j as i32;
                scan[top] = j + 1;
                top += 1;
                continue;
            }
            let g = fetches[n];
            out.append(pool[g.text_at..g.text_at + g.text_len]);
            ends.push(out.len);
            medias.append(chains[chain_at[n]..chain_at[n] + chain_len[n]]);
            media_ends.push(medias.len);
            top -= 1;
        }
    }
}

// Starts fetching sheet k, `href` against `base`. A page from the web loads
// it over the network, http or https; a file's page reads it from a file. A
// sheet already among those that import it is a cycle, and left out.
fn start_sheet(tab: i32, profile: i32, flags: i32, page: const u8[:], base: const u8[:], href: const u8[:],
               fetches: SheetFetch[>..]&,
               k: i32, pool: u8[>..]&, log: u8[>..]&) {
    var url: u8[>..] = [];
    guard resolve_url(base, href, url) else {
        format(log, "Sheet ", href, " has no URL\n");
        return;
    }
    var up = fetches[k].parent;
    while up >= 0 {
        if pool[fetches[up].url_at..fetches[up].url_at + fetches[up].url_len] == url[..] {
            format(log, "Sheet ", url, " imports itself\n");
            return;
        }
        up = fetches[up].parent;
    }
    fetches[k].url_at = pool.len;
    pool.append(url);
    fetches[k].url_len = url.len;
    if is_web(page) {
        let req = tp_net_open(tab, profile, NET_STYLE, url[..], page, flags);
        if req > 0 { fetches[k].req = req; }
        else if req == ERR_BLOCKED { format(log, "Sheet ", url, " is blocked: an https page loads no http sheets\n"); }
        else { format(log, "Sheet ", url, " can't be loaded\n"); }
        return;
    }
    // A file's page: its sheets are files too, and nothing else.
    var path: u8[>..] = [];
    guard starts_with(url[..], "file://") && percent_decoded(url[7..], path) else {
        format(log, "Sheet ", url, " isn't a file\n");
        return;
    }
    var text: u8[>..] = [];
    guard read_file(path[..], text) else {
        format(log, "Sheet ", path, " can't be read\n");
        return;
    }
    fetches[k].text_at = pool.len;
    pool.append(text);
    fetches[k].text_len = text.len;
}

// Waits until every sheet's request has ended, taking each one's text into
// the pool, or WAVE_MS has gone by, when what still runs is cancelled. A
// hit test meanwhile gets an arrow; what else the main thread asks goes in
// `later`. False if the tab quits first.
fn wait_sheets(tab: i32, fetches: SheetFetch[>..]&, pool: u8[>..]&, later: TabMsg[>..]&, log: u8[>..]&) -> bool {
    let until = clock_ns() + WAVE_MS * 1000000;
    var m = TabMsg { kind: 0, a: 0.0, b: 0.0, c: 0.0 };
    loop {
        var running = 0;
        for f in fetches { if f.req > 0 { running += 1; } }
        guard running > 0 else { return true; }
        let left = (until - clock_ns()) / 1000000;
        let got = if left > 0 { tp_tab_next(tab, left, m) } else { 0 };
        guard got >= 0 else { cancel_sheets(fetches); return false; }
        if got == 0 {
            for f, k in fetches {
                guard f.req > 0 else { continue; }
                tp_net_cancel(f.req);
                fetches[k].req = 0;
                format(log, "Sheet ", pool[f.url_at..f.url_at + f.url_len], " took over ", WAVE_MS / 1000,
                       " s, and is left out\n");
            }
            return true;
        }
        if m.kind == MSG_QUIT { cancel_sheets(fetches); return false; }
        if m.kind == MSG_HIT { tp_post_reply(tab, REPLY_HIT, CURSOR_ARROW, ""); continue; }
        guard m.kind == MSG_NET else { later.push(m); continue; }
        let req = m.a as i32;
        for f, k in fetches {
            guard f.req == req else { continue; }
            fetches[k].req = 0;
            take_sheet(req, fetches, k as i32, pool, log);
        }
    }
    return true;
}

// Takes ended request `req` as sheet k's text, unless it failed.
fn take_sheet(req: i32, fetches: SheetFetch[>..]&, k: i32, pool: u8[>..]&, log: u8[>..]&) {
    var head = NetHead { req: 0, status: 0, error: 0, kind: 0, body: 0, url: 0, mime: 0, text: 0, expected: 0 };
    var body: u8[>..] = [];
    var url: u8[>..] = [];
    var mime: u8[>..] = [];
    var why: u8[>..] = [];
    let name = pool[fetches[k].url_at..fetches[k].url_at + fetches[k].url_len];
    guard take_net(req, head, body, url, mime, why) else { format(log, "Sheet ", name, " was lost\n"); return; }
    guard head.error == 0 else { format(log, "Sheet ", name, ": ", why, "\n"); return; }
    guard head.status >= 200 && head.status < 300 else {
        format(log, "Sheet ", name, " answered ", head.status, "\n");
        return;
    }
    // Its imports resolve against where it ended up, after redirects.
    fetches[k].url_at = pool.len;
    pool.append(url);
    fetches[k].url_len = url.len;
    fetches[k].text_at = pool.len;
    pool.append(body);
    fetches[k].text_len = body.len;
}

fn cancel_sheets(fetches: SheetFetch[>..]&) {
    for f, k in fetches {
        if f.req > 0 { tp_net_cancel(f.req); }
        fetches[k].req = 0;
    }
}

// The file URL of absolute path `path` onto `out`: what isn't a letter, a
// digit or one of -._~/ escaped as %XX.
fn file_url(path: const u8[:], out: u8[>..]&) {
    out.append("file://");
    let digits = "0123456789ABCDEF";
    for c in path {
        let plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.'
                    || c == '_' || c == '~' || c == '/';
        if plain { out.push(c); continue; }
        out.push('%');
        out.push(digits[c >> 4]);
        out.push(digits[c & 15]);
    }
}

// `s` with its %XX escapes decoded, onto `out`; false for a broken escape.
fn percent_decoded(s: const u8[:], out: u8[>..]&) -> bool {
    var i: i64 = 0;
    while i < s.len {
        if s[i] != '%' { out.push(s[i]); i += 1; continue; }
        guard i + 2 < s.len else { return false; }
        let hi = hex_digit(s[i + 1]);
        let lo = hex_digit(s[i + 2]);
        guard hi >= 0 && lo >= 0 else { return false; }
        out.push((hi * 16 + lo) as u8);
        i += 3;
    }
    return true;
}

fn hex_digit(c: u8) -> i32 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}
