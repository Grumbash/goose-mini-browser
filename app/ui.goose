// Tusk's interface (docs/adr/0010): one HTML document Goose makes from the
// browser's state, laid out here on the main thread when that state changes,
// and drawn as a layer under the pages, which go where it marks their slots
// (data-slot). Its CSS, icons and boar are in app/ui/; it runs no scripts.
// The focus view: the bar (where you are), the page with its header, the dev
// panel with the page's line and five tabs, and the bottom panel with the
// boar's bay, the window's line and the hand of boards. A load that takes
// over 400 ms sends the boar running along a rail, in a small document and
// layer of its own, so his steps don't lay the interface out again.

import std;
import os;
import math;
import engine from "../engine";
import engine.dom;
import engine.html;
import engine.css;
import engine.layout;
import .tab;

extern "tusk_platform" {
    fn tp_set_layer(layer: i32, items: const DItem[:], text: const u8[:], paths: const f32[:], scale: f32) -> i32;
}

// The files the interface is made of, read once.
struct UiFiles { css: u8[>..]&, sprite: u8[>..]&, rest: u8[>..]&, run: u8[>..]& }

// What the interface shows that isn't a tab's: the window's size, where the
// traffic lights end in its bar (0: none), which tab is shown, the dev panel
// and its tab, the window's oil (MB), the Mac's memory in use and in all
// (MB), the window's CPU and the whole Mac's (%, of all its cores), its
// frames a second, and whether the boar is out running a load.
struct Ui {
    w: f32, h: f32, lights: f32, cur: i64, dev: bool, dev_tab: i32,
    oil: f32, mac_used: f32, mac_total: f32, cpu: f32, mac_cpu: f32, fps: i32, running: bool,
}

// What it reads of the main thread's strings: the notes the tabs' spans
// point into (Tab).
struct UiText { notes: u8[>..]& }

// The dev panel's tabs.
let DEV_CONSOLE: i32 = 0;
let DEV_NETWORK: i32 = 1;
let DEV_ELEMENTS: i32 = 2;
let DEV_FRAMES: i32 = 3;
let DEV_OIL: i32 = 4;

let BAR_H: f32 = 40.0;           // the top bar
let PANEL_H: f32 = 60.0;         // the bottom panel; it never grows
let DEV_W: f32 = 360.0;          // the dev panel, beside the content
let LOADER_H: f32 = 56.0;        // the loader, over the content's foot
let DROP: const u8[:] = "M12 1C12 1 2 13 2 20a10 10 0 0 0 20 0C22 13 12 1 12 1Z";

fn read_ui(F: UiFiles) -> bool {
    let dir = str(resource_dir(), "ui/");
    return read_file(str(dir, "tusk.css")[..], F.css) && read_file(str(dir, "sprite.svg")[..], F.sprite)
        && read_file(str(dir, "boar-rest.svg")[..], F.rest) && read_file(str(dir, "boar-run.svg")[..], F.run);
}

// ------------------------------------------------------------------ strings

// s onto out, safe in HTML text and attribute values.
fn esc(out: u8[>..]&, s: const u8[:]) {
    for c in s {
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else { out.push(c); }
    }
}

// n with its thousands separated by commas.
recursive fn group(out: u8[>..]&, n: i64) {
    if n >= 1000 {
        group(out, n / 1000);
        out.push(',');
        format_int(out, n % 1000, 10, 3, '0');
    } else {
        format(out, n);
    }
}

// v in points, as CSS takes it.
fn px(out: u8[>..]&, v: f32) {
    format_flt(out, v, 1);
    out.append("px");
}

fn icon(out: u8[>..]&, name: const u8[:]) {
    format(out, "<svg class=\"i\" aria-hidden=\"true\"><use href=\"#", name, "\"/></svg>");
}

fn drop_icon(out: u8[>..]&) {
    format(out, "<svg viewBox=\"0 0 24 31\" aria-hidden=\"true\"><path d=\"", DROP, "\"/></svg>");
}

fn note(T: UiText, at: i64, len: i64) -> const u8[:] { return T.notes[at..at + len]; }

// How many things went wrong loading tab t's page: itself failing, and each
// line of its log.
fn errors_of(t: Tab, T: UiText) -> i64 {
    var n: i64 = if t.failed { 1 } else { 0 };
    for c in note(T, t.log_at, t.log_len) { if c == '\n' { n += 1; } }
    return n;
}

// Where tab t is: its file's path, or its page's URL.
fn loc_of(t: Tab, T: UiText) -> const u8[:] { return note(T, t.loc_at, t.loc_len); }

// Where the host of web address `loc` starts and ends, its port included:
// past "://", up to the path. For a file's path, 0 and 0.
fn host_span(loc: const u8[:]) -> i64, i64 {
    let s = find(loc, "://");
    guard s > 0 else { return 0, 0; }
    var a = s + 3;
    var b = a;
    while b < loc.len && loc[b] != '/' && loc[b] != '?' && loc[b] != '#' {
        if loc[b] == '@' { a = b + 1; }      // past a user's name and password
        b += 1;
    }
    return a, b;
}

// Where the last step of `loc`'s path starts: past its last '/' before any
// query or fragment.
fn last_step(loc: const u8[:]) -> i64 {
    var end = loc.len;
    for c, j in loc { if (c == '?' || c == '#') && j < end { end = j; break; } }
    var name: i64 = 0;
    for j in 0..end { if loc[j] == '/' { name = j + 1; } }
    return name;
}

// What tab t's page is called without a title: its file's name, or the last
// step of its URL's path, or its host.
fn name_of(t: Tab, T: UiText) -> const u8[:] {
    let loc = loc_of(t, T);
    let h0, h1 = host_span(loc);
    let name = last_step(loc);
    var end = loc.len;
    for c, j in loc { if (c == '?' || c == '#') && j >= name { end = j; break; } }
    if h1 > h0 && (name <= h1 || name >= end) { return loc[h0..h1]; }
    return loc[name..end];
}

// Where tab t's page comes from, for its header: its host, or its file's name.
fn site_of(t: Tab, T: UiText) -> const u8[:] {
    let loc = loc_of(t, T);
    let h0, h1 = host_span(loc);
    return if h1 > h0 { loc[h0..h1] } else { name_of(t, T) };
}

// What a tab is called: its title, or else name_of.
fn title_of(t: Tab, T: UiText) -> const u8[:] {
    return if t.title_len > 0 { note(T, t.title_at, t.title_len) } else { name_of(t, T) };
}

// The board the pages are on: the folder the first one is in, or the host
// of its page.
fn board_of(tabs: const Tab[:], T: UiText) -> const u8[:] {
    let p = loc_of(tabs[0], T);
    let h0, h1 = host_span(p);
    guard h1 <= h0 else { return p[h0..h1]; }
    let end = last_step(p) - 1;
    var start: i64 = 0;
    guard end > 0 else { return "Pages"; }
    for j in 0..end { if p[j] == '/' { start = j + 1; } }
    return p[start..end];
}

// ------------------------------------------------------------------ the document

// The interface's document for tabs `tabs`, onto `out`.
fn ui_html(F: UiFiles, U: Ui, tabs: const Tab[:], T: UiText, frames: const f32[:], dropped: i32, rebuild_ms: f32,
           out: u8[>..]&) {
    out.append("<!doctype html><meta charset=\"utf-8\"><title>Tusk</title><style>");
    out.append(F.css);
    out.append("</style>");
    out.append(F.sprite);
    out.append("<div class=\"win\" style=\"width:");
    px(out, U.w);
    out.append("; height:");
    px(out, U.h);
    out.append("\">");
    let t = tabs[U.cur];
    let cw = if U.dev { max(U.w - DEV_W, 0.0) } else { U.w };
    let ch = max(U.h - BAR_H - PANEL_H, 0.0);
    bar(out, U, tabs, T);
    content(out, U, t, T, cw, ch);
    if U.dev { dev_panel(out, U, tabs, T, cw, ch, frames, dropped, rebuild_ms); }
    panel(out, F, U, tabs, T);
    out.append("</div>");
}

// The top bar: the board, back, forward, reload, the address; then board
// view, the command bar and the dev panel's switch.
fn bar(out: u8[>..]&, U: Ui, tabs: const Tab[:], T: UiText) {
    let t = tabs[U.cur];
    // The design leaves the traffic lights up to 72 points; AppKit's own may
    // need more, and the plate, the arrows and the address make way.
    let shift = max(U.lights + 10.0 - 72.0, 0.0);
    out.append("<div class=\"bar\" data-drag><span class=\"plate\" data-nodrag style=\"left:");
    px(out, 72.0 + shift);
    out.append("\"><span class=\"bn\">");
    esc(out, board_of(tabs, T));
    out.append("</span>");
    icon(out, "i-chev-r");
    out.append("</span><span class=\"nav\" data-nodrag style=\"left:");
    px(out, 168.0 + shift);
    out.append("\">");
    icon(out, "i-chev-l");
    icon(out, "i-chev-r");
    icon(out, "i-reload");
    let url_w = max(U.w - 290.0 - shift - 190.0, 120.0);
    out.append("</span><span class=\"url\" data-nodrag style=\"left:");
    px(out, 290.0 + shift);
    out.append("; width:");
    px(out, url_w);
    out.append("\">");
    address(out, loc_of(t, T), ((url_w - 120.0) / 7.5) as i64);
    out.append("</span><span class=\"tools\" data-nodrag><span class=\"bv\">");
    icon(out, "i-grid");
    out.append("<kbd>⌘B</kbd></span><kbd>⌘K</kbd><span");
    if U.dev { out.append(" class=\"on\""); }
    out.append(">");
    icon(out, "i-code");
    out.append("</span></span></div>");
}

// Where a page is, in the bar, as `room` characters at most fit (about 7.5
// points each, after the badge). The badge says what the address doesn't, so
// the scheme isn't written again after it. A file: FILE, and its path, which
// loses its start from a folder on so that its name shows. A web page: HTTPS
// or HTTP, its host in bold, its port, and its path, which loses its end; on
// this Mac, LOCAL, and then its scheme, which LOCAL doesn't say.
fn address(out: u8[>..]&, p: const u8[:], room: i64) {
    let h0, h1 = host_span(p);
    if h1 > h0 {
        var host_end = h1;
        for j in h0..h1 { if p[j] == ':' { host_end = j; } }
        if host_end < h1 && p[h1 - 1] == ']' { host_end = h1; }  // an IPv6 address, no port
        let host = p[h0..host_end];
        let local = host == "localhost" || host == "127.0.0.1" || host == "[::1]" || ends_with(host, ".localhost");
        out.append("<span class=\"env\">");
        if local { out.append("LOCAL"); }
        else { for c in p[..h0 - 3] { out.push(if c >= 'a' && c <= 'z' { c - 32 } else { c }); } }
        out.append("</span><span class=\"u\">");
        if local {
            out.append("<i>");
            esc(out, p[..h0]);
            out.append("</i>");
        }
        out.append("<b>");
        esc(out, host);
        out.append("</b>");
        if host_end < h1 {
            out.append("<em>");
            esc(out, p[host_end..h1]);
            out.append("</em>");
        }
        let rest = p[h1..];
        let left = room - (h1 - h0);
        if rest.len > left && left > 1 {
            // Cut before a character, not inside one.
            var cut = left - 1;
            while cut > 0 && (rest[cut] & 0xC0) == 0x80 { cut -= 1; }
            esc(out, rest[..cut]);
            out.append("…");
        } else {
            esc(out, rest);
        }
        out.append("</span>");
        return;
    }
    out.append("<span class=\"env\">FILE</span><span class=\"u\">");
    let name = last_step(p);
    var from: i64 = 0;
    if p.len > room {
        from = min(p.len - room, name);
        while from < name && p[from - 1] != '/' { from += 1; }
        out.append("…/");
    }
    esc(out, p[from..name]);
    out.append("<b>");
    esc(out, p[name..]);
    out.append("</b></span>");
}

// The content: the page in focus, its header over its slot.
fn content(out: u8[>..]&, U: Ui, t: Tab, T: UiText, cw: f32, ch: f32) {
    out.append("<div class=\"content\" style=\"width:");
    px(out, cw);
    out.append("; height:");
    px(out, ch);
    out.append("\"><div class=\"pane\" style=\"left:0px; top:0px; width:");
    px(out, cw);
    out.append("; height:");
    px(out, ch);
    out.append("\"><div class=\"pgh focus\"><span class=\"fv\">");
    icon(out, "i-globe");
    out.append("</span><b>");
    esc(out, title_of(t, T));
    out.append("</b><span class=\"host\">");
    esc(out, site_of(t, T));
    out.append("</span><span class=\"pgr\">");
    let errors = errors_of(t, T);
    if errors > 0 { format(out, "<span class=\"sdot er\" aria-label=\"", errors, if errors == 1 { " error" } else { " errors" }, "\">", errors, "</span>"); }
    else if t.ready { out.append("<span class=\"sdot ok\" aria-label=\"Loaded\"></span>"); }
    else { out.append("<span class=\"sdot run\" aria-label=\"Loading\"></span>"); }
    out.append("<span class=\"pga\">");
    icon(out, "i-x");
    out.append("</span></span></div><div class=\"pbody\" data-slot=\"");
    format(out, U.cur);
    out.append("\" style=\"background:#");
    format_int(out, t.info.background & 0xFFFFFF, 16, 6, '0');
    out.append("\">");
    if t.failed {
        out.append("<p class=\"pfail\">");
        esc(out, note(T, t.why_at, t.why_len));
        out.append("</p>");
    }
    out.append("</div></div></div>");
}

// The dev panel: the page's line, then its tabs.
fn dev_panel(out: u8[>..]&, U: Ui, tabs: const Tab[:], T: UiText, cw: f32, ch: f32,
             frames: const f32[:], dropped: i32, rebuild_ms: f32) {
    let t = tabs[U.cur];
    out.append("<aside class=\"devp\" style=\"left:");
    px(out, cw);
    out.append("; height:");
    px(out, ch);
    out.append("\"><div class=\"dph\"><div class=\"ro\"><div class=\"r1\">");
    page_line(out, t, errors_of(t, T));
    out.append("</div></div></div><div class=\"dpt\"><div class=\"dtabs\">");
    let names: const u8[:][5] = ["Console", "Network", "Elements", "Frames", "Oil"];
    for name, k in names {
        out.append(if k == U.dev_tab { "<span class=on>" } else { "<span>" });
        if k == DEV_OIL { drop_icon(out); }
        out.append(name);
        if k == DEV_CONSOLE && errors_of(t, T) > 0 { format(out, "<em>", errors_of(t, T), "</em>"); }
        out.append("</span>");
    }
    out.append("</div>");
    if U.dev_tab == DEV_CONSOLE { console(out, U, t, T); }
    else if U.dev_tab == DEV_NETWORK { network(out, U, t, T); }
    else if U.dev_tab == DEV_ELEMENTS { elements(out, t, T); }
    else if U.dev_tab == DEV_FRAMES { frame_graph(out, frames, dropped, rebuild_ms); }
    else { oil(out, U, tabs, T); }
    out.append("</div></aside>");
}

// The page's line: its status, requests, size, `errors` and load time. A
// file is one request; its status is OK once read.
fn page_line(out: u8[>..]&, t: Tab, errors: i64) {
    if t.failed {
        out.append("<span class=\"st er\">ERR</span><span><b>1</b> req</span><span><b>0.0</b> KB</span>");
        out.append("<span class=\"er\"><b>1</b> err</span>");
    } else if !t.ready {
        out.append("<span class=\"st run\">GET</span><span><b>0</b> / 1 req</span><span><b>0.0</b> KB</span><span><b>0</b> err</span>");
        out.append("<span class=\"run\"><b>");
        format(out, ms_since(t.opened) as i64);
        out.append("</b> ms</span>");
        return;
    } else {
        // An HTTP error is a page too: it shows, with its status.
        if t.status >= 400 { format(out, "<span class=\"st er\">", t.status, "</span>"); }
        else { out.append("<span class=\"st ok\">OK</span>"); }
        out.append("<span><b>1</b> req</span><span><b>");
        format_flt(out, t.info.bytes / 1000.0, 1);
        out.append("</b> KB</span>");
        format(out, if errors > 0 { "<span class=\"er\"><b>" } else { "<span><b>" }, errors, "</b> err</span>");
    }
    out.append("<span><b>");
    format(out, t.load_ms as i64);
    out.append("</b> ms</span>");
}

fn console(out: u8[>..]&, U: Ui, t: Tab, T: UiText) {
    out.append("<div class=\"nbar\"><span class=\"flt\">Filter</span><span class=\"chips\"><i class=\"on\">All</i><i>Errors</i><i>Warnings</i></span></div><div class=\"clist\">");
    if t.failed {
        out.append("<p class=\"cl er\"><span class=\"x\">✕</span><span class=\"msg\">");
        esc(out, note(T, t.why_at, t.why_len));
        out.append("</span><em>tusk</em></p>");
    } else if t.ready {
        out.append("<p class=\"cl inf\"><span class=\"x\"></span><span class=\"msg\">");
        out.append(if t.status > 0 { "Loaded " } else { "Read " });
        format_flt(out, t.info.bytes / 1000.0, 1);
        out.append(" KB; ");
        group(out, t.info.nodes);
        out.append(" nodes parsed, styled and laid out in ");
        format(out, t.load_ms as i64);
        out.append(" ms</span><em>tusk</em></p><p class=\"cl inf\"><span class=\"x\"></span><span class=\"msg\">Scripts don't run yet</span><em>tusk</em></p>");
    }
    // What went wrong loading it, a line each.
    let log = note(T, t.log_at, t.log_len);
    var from: i64 = 0;
    for c, j in log {
        guard c == '\n' else { continue; }
        out.append("<p class=\"cl er\"><span class=\"x\">✕</span><span class=\"msg\">");
        esc(out, log[from..j]);
        out.append("</span><em>css</em></p>");
        from = j + 1;
    }
    out.append("<p class=\"cl\"><span class=\"x pr\">›</span><i class=\"caret\"></i></p></div>");
}

// The file's one request on the scale of its load, and its phases.
fn network(out: u8[>..]&, U: Ui, t: Tab, T: UiText) {
    out.append("<div class=\"nbar\"><span class=\"flt\">Filter</span><span class=\"sum\">");
    guard t.ready else {
        out.append(if t.failed { "1 req · failed" } else { "loading…" });
        out.append("</span></div>");
        return;
    }
    let i = t.info;
    let dom = i.read + i.parse;
    let load = max(t.load_ms, i.read + i.parse + i.style + i.measure + i.layout);
    out.append("1 req · ");
    format_flt(out, i.bytes / 1000.0, 1);
    out.append(" KB · DOM ");
    format_flt(out, dom, 1);
    out.append(" · load ");
    format(out, load as i64);
    out.append(" ms</span></div><div class=\"nt\"><div class=\"nr hd\"><span>Name</span><span>Status</span><span class=\"r\">Time</span><span class=\"wfc ax\">");
    for q in 4 {
        out.append("<s style=\"left:");
        format_flt(out, q * 25.0, 1);
        out.append("%\">");
        format(out, (load * q / 4.0) as i64);
        out.append("</s>");
    }
    out.append("</span></div><div class=\"nr\"><span>");
    esc(out, name_of(t, T));
    out.append("</span><span>OK</span><span class=\"r\">");
    format(out, load as i64);
    out.append(" ms</span><span class=\"wfc\">");
    bar_at(out, "w", 0.0, max(i.read, load / 100.0), load);
    bar_at(out, "d", i.read, load - i.read, load);
    out.append("<b class=\"dom\" style=\"left:");
    format_flt(out, dom / load * 100.0, 2);
    out.append("%\"></b></span></div></div><div class=\"ndet\"><p><b>");
    esc(out, name_of(t, T));
    out.append("</b> · the document</p><ul class=\"tim\">");
    let phases: const u8[:][5] = ["Reading", "Parsing", "Styling", "Measuring text", "Layout"];
    let kinds: const u8[:][5] = ["w", "d", "d", "d", "d"];
    let times: f32[5] = [i.read, i.parse, i.style, i.measure, i.layout];
    var most: f32 = 0.01;
    for v in times { most = max(most, v); }
    for name, k in phases {
        format(out, "<li><span>", name, "</span><i class=\"", kinds[k], "\" style=\"width:");
        format_flt(out, times[k] / most * 100.0, 0);
        out.append("%\"></i><b>");
        format_flt(out, times[k], 1);
        out.append(" ms</b></li>");
    }
    out.append("</ul></div>");
}

// A waterfall bar of class `kind` from `from` for `len` ms, on a scale of `total`.
fn bar_at(out: u8[>..]&, kind: const u8[:], from: f32, len: f32, total: f32) {
    format(out, "<i class=\"", kind, "\" style=\"left:");
    format_flt(out, from / total * 100.0, 2);
    out.append("%; width:");
    format_flt(out, max(len / total * 100.0, 0.5), 2);
    out.append("%\"></i>");
}

// The page's elements as its worker listed them (elements_of).
fn elements(out: u8[>..]&, t: Tab, T: UiText) {
    let list = note(T, t.elems_at, t.elems_len);
    var lines: i64 = 0;
    for c in list { if c == '\n' { lines += 1; } }
    out.append("<div class=\"nbar\"><span class=\"flt\">Find</span><span class=\"sum\">");
    group(out, lines);
    out.append(if lines == 200 { "+ elements" } else { " elements" });
    out.append("</span></div><div class=\"el2\"><div class=\"tree\">");
    var start: i64 = 0;
    var shown = 0;
    for c, j in list {
        guard c == '\n' else { continue; }
        let line = list[start..j];
        start = j + 1;
        // depth TAB name TAB id TAB classes
        var cols: i64[3] = [0, 0, 0];
        var n = 0;
        for d, k in line { if d == '\t' && n < 3 { cols[n] = k; n += 1; } }
        guard n == 3 else { continue; }
        let depth, ok = parse_int(line[..cols[0]]);
        out.append("<p style=\"padding-left:");
        px(out, 10.0 + 14.0 * (if ok { min(depth, 20) } else { 0 }));
        out.append("\"><span class=\"t\">&lt;");
        esc(out, line[cols[0] + 1..cols[1]]);
        out.append("</span>");
        attr(out, "id", line[cols[1] + 1..cols[2]]);
        attr(out, "class", line[cols[2] + 1..]);
        out.append("<span class=\"t\">&gt;</span></p>");
        shown += 1;
        if shown >= 40 { break; }
    }
    out.append("</div></div>");
}

fn attr(out: u8[>..]&, name: const u8[:], value: const u8[:]) {
    guard value.len > 0 else { return; }
    format(out, " <span class=\"a\">", name, "</span>=<span class=\"v\">\"");
    esc(out, value);
    out.append("\"</span>");
}

// The last frames' CPU times under the line of a frame at 120 Hz, and what
// laying the interface out last cost.
fn frame_graph(out: u8[>..]&, frames: const f32[:], dropped: i32, rebuild_ms: f32) {
    let budget: f32 = 1000.0 / 120.0;
    let top = budget / 0.83;     // the line sits at 83% of the graph's height
    var worst: f32 = 0.0;
    for v in frames { worst = max(worst, v); }
    out.append("<div class=\"nbar\"><span class=\"ttl\">");
    if frames.len == 0 { out.append("No frames yet"); }
    else { format(out, "The last ", frames.len, " frames · CPU"); }
    out.append("</span></div><div class=\"fr\"><div class=\"frh\"><span><b>");
    format(out, dropped);
    out.append("</b> dropped since start</span><span>worst <b>");
    format_flt(out, worst, 2);
    out.append("</b> ms</span><span>interface <b>");
    format_flt(out, rebuild_ms, 1);
    out.append("</b> ms</span></div><div class=\"frg\">");
    for v in frames {
        out.append("<i style=\"height:");
        format_flt(out, min(max(v / top * 100.0, 1.0), 100.0), 1);
        out.append("%\"></i>");
    }
    out.append("<b class=\"budget\"><span>8.3 ms · 120 Hz</span></b></div><p class=\"frn\">");
    out.append(if worst <= budget { "Every frame under the line." } else { "A frame over the line drops." });
    out.append("</p></div>");
}

// The window's oil, and what each page weighs.
fn oil(out: u8[>..]&, U: Ui, tabs: const Tab[:], T: UiText) {
    out.append("<div class=\"oilv\"><div class=\"oilh\"><span>");
    weights(out, U);
    out.append("</span>");
    gauge(out, U);
    out.append("</div><ul><li class=\"bd\"><b>");
    esc(out, board_of(tabs, T));
    out.append("</b><small>in play</small><span class=\"v\">");
    format_flt(out, U.oil, 1);
    out.append(" MB</span><i style=\"width:");
    format_flt(out, min(U.oil / max(U.mac_total, 1.0) * 100.0, 100.0), 2);
    out.append("%\"></i></li>");
    for t, k in tabs {
        out.append("<li class=\"pgr\"><span>");
        icon(out, "i-globe");
        esc(out, title_of(t, T));
        out.append("</span><span class=\"v\">");
        format_flt(out, t.info.bytes / 1000.0, 1);
        out.append(" KB of HTML</span></li>");
    }
    out.append("</ul></div>");
}

// Ten drops of 100 MB against the budget; the last fills to the level.
// The oil as ten drops, each a tenth of the Mac's memory, filled from the
// left: with what the whole Mac uses, and over it, in the oil's colour, what
// Tusk does.
fn gauge(out: u8[>..]&, U: Ui) {
    let total = max(U.mac_total, 1.0);
    let mac = U.mac_used / total * 10.0;
    let tusk = min(U.oil, U.mac_used) / total * 10.0;
    out.append("<span class=\"oilg\" role=\"img\" aria-label=\"Oil: Tusk ");
    format_flt(out, U.oil, 1);
    out.append(" MB, the Mac ");
    format_flt(out, U.mac_used / 1024.0, 1);
    out.append(" of ");
    format_flt(out, U.mac_total / 1024.0, 1);
    out.append(" GB\">");
    for k in 10 {
        format(out, "<i><svg viewBox=\"0 0 24 31\"><path d=\"", DROP, "\"/></svg>");
        fill(out, "m", min(max(mac - k, 0.0), 1.0));
        fill(out, "f", min(max(tusk - k, 0.0), 1.0));
        out.append("</i>");
    }
    out.append("</span>");
}

// A drop filled to `f` (0 to 1) from the bottom, in class `kind`'s colour: a
// box that tall at its foot, cutting a whole drop. A fill that isn't empty
// shows at least a point, so that Tusk's few megabytes of a Mac's
// gigabytes still show.
fn fill(out: u8[>..]&, kind: const u8[:], f: f32) {
    guard f > 0.0 else { return; }
    format(out, "<b class=\"", kind, "\" style=\"height:");
    format_flt(out, max(f * 100.0, 100.0 / 12.0), 1);
    format(out, "%\"><svg viewBox=\"0 0 24 31\"><path d=\"", DROP, "\"/></svg></b>");
}

// What Tusk weighs, in MB, in the oil's colour; then what the whole Mac
// uses of all it has, in GB.
fn weights(out: u8[>..]&, U: Ui) {
    out.append("<b class=\"t\">");
    format_flt(out, U.oil, 1);
    out.append("</b> MB · <b class=\"m\">");
    format_flt(out, U.mac_used / 1024.0, 1);
    out.append("</b> / ");
    let gb = U.mac_total / 1024.0;
    format_flt(out, gb, if gb == round(gb) { 0 } else { 1 });
    out.append(" GB");
}

// The bottom panel: the boar's bay, the window's line, and the hand.
fn panel(out: u8[>..]&, F: UiFiles, U: Ui, tabs: const Tab[:], T: UiText) {
    out.append("<div class=\"panel\"><div class=\"bay\"><i class=\"bc tl\"></i><i class=\"bc tr\"></i><i class=\"bc bl\"></i><i class=\"bc br\"></i>");
    // He leaves his bay to run a load.
    if !U.running { out.append(F.rest); }
    out.append("</div><div class=\"ro\"><div class=\"r2\">");
    gauge(out, U);
    out.append("<span>");
    weights(out, U);
    // The CPU as the oil is: Tusk's in its colour, then the whole Mac's.
    out.append("</span><span class=\"k\">CPU</span><span><b class=\"t\">");
    format_flt(out, U.cpu, 1);
    out.append("</b>% · <b class=\"m\">");
    format_flt(out, U.mac_cpu, 1);
    out.append("</b>%</span><span><b>");
    format(out, U.fps);
    out.append(if U.fps == 0 { "</b> fps · idle</span>" } else { "</b> fps</span>" });
    out.append("</div></div></div>");
    // The hand: the board in play, then a new one, fanned like cards.
    var cards: u8[>..] = [];
    var ends: i64[>..] = [];
    cards.append("<div class=\"cd ghost\"><div class=\"nm\"><span class=\"bn\">");
    esc(cards, board_of(tabs, T));
    format(cards, "</span></div><small>In play · ", tabs.len, if tabs.len == 1 { " tab" } else { " tabs" }, "</small><kbd>⌘1</kbd></div>");
    ends.push(cards.len);
    cards.append("<div class=\"cd new\"><div class=\"nm\">");
    icon(cards, "i-plus");
    cards.append("New board</div></div>");
    ends.push(cards.len);
    fan(out, cards[..], ends[..], U.w * 470.0 / 1200.0, U.h - 48.0, 1100.0, 5.0);
}

// Cards on an arc, as a hand is held: centred on cx, the middle card's top at
// `top`, `step` degrees apart on a circle of `radius`. Card k is cards up to
// ends[k].
fn fan(out: u8[>..]&, cards: const u8[:], ends: const i64[:], cx: f32, top: f32, radius: f32, step: f32) {
    let w: f32 = 112.0;
    let h: f32 = 156.0;
    let n = ends.len;
    let pivot = top + h / 2.0 + radius;
    var start: i64 = 0;
    for end, k in ends {
        let a = (k - (n - 1) / 2.0) * step;
        let x = cx + radius * sin(radians(a)) - w / 2.0;
        let y = pivot - radius * cos(radians(a)) - h / 2.0;
        out.append("<div class=\"fc\" style=\"transform:translate(");
        px(out, x);
        out.append(", ");
        px(out, y);
        out.append(") rotate(");
        format_flt(out, a, 1);
        format(out, "deg); z-index:", k + 1, "\">");
        out.append(cards[start..end]);
        out.append("</div>");
        start = end;
    }
}

// ------------------------------------------------------------------ the loader

// The loader's document, `w` wide: a rail filled to `p` (0 to 1) in the
// colour of a load's wait, and the boar at its end, `t` seconds into his
// run. His legs swing through a stride every 0.4 s, each a little behind
// the one before, and his body bobs with them, as the design's keyframes
// have it.
fn loader_html(F: UiFiles, w: f32, p: f32, t: f32, out: u8[>..]&) {
    out.append("<!doctype html><meta charset=\"utf-8\"><style>");
    out.append(F.css);
    out.append("</style><div class=\"ldr\" style=\"top:0px; width:");
    px(out, w);
    out.append("\"><div class=\"rail\"><div class=\"ticks\">");
    var x: f32 = 22.0;
    while x < w {
        out.append("<i style=\"left:");
        px(out, x);
        out.append("\"></i>");
        x += 24.0;
    }
    out.append("</div><div class=\"segs\"><i class=\"ph-w\" style=\"left:0px; width:");
    px(out, p * w);
    out.append("\"></i></div></div><div class=\"runner\" style=\"left:");
    px(out, p * w - 60.0 * 0.72);
    out.append("\">");
    let delays: f32[4] = [0.0, 0.2, 0.04, 0.24];   // hf, ff, hn, fn
    let names: const u8[:][4] = ["$hf", "$ff", "$hn", "$fn"];
    var angles: f32[4] = [0.0, 0.0, 0.0, 0.0];
    for d, k in delays { angles[k] = leg_angle(t + d); }
    // The bob: up 2 at the stride's ends, down 1 in its middle.
    let u = fract(t / 0.4);
    let bob = -2.0 + 3.0 * (1.0 - abs(2.0 * u - 1.0));
    var run = F.run[..];
    var start: i64 = 0;
    var j: i64 = 0;
    while j < run.len {
        if run[j] == '$' {
            out.append(run[start..j]);
            var hit = false;
            for name, k in names {
                if starts_with(run[j..], name) {
                    format_flt(out, angles[k], 1);
                    j += name.len;
                    hit = true;
                    break;
                }
            }
            if !hit && starts_with(run[j..], "$bob") {
                format_flt(out, bob, 2);
                j += 4;
                hit = true;
            }
            if !hit { out.push('$'); j += 1; }
            start = j;
            continue;
        }
        j += 1;
    }
    out.append(run[start..]);
    out.append("</div></div>");
}

// A leg's angle `t` seconds into a stride: from -32° to 28° over 55% of 0.4 s,
// and back.
fn leg_angle(t: f32) -> f32 {
    let u = fract(t / 0.4);
    return if u < 0.55 { -32.0 + 60.0 * u / 0.55 } else { 28.0 - 60.0 * (u - 0.55) / 0.45 };
}

fn fract(v: f32) -> f32 { return v - floor(v); }

// ------------------------------------------------------------------ laying it out

// Lays document `html` out `w` × `h` at `scale` into layer `layer`, and finds
// its slot: the box of the element with data-slot (none: a width of 0); and
// where a press drags the window: the boxes of the elements with data-drag
// into `drag`, and of those with data-nodrag into `holes`, x, y, w, h each.
// Returns what it took, in ms.
fn show_doc(html: const u8[:], w: f32, h: f32, scale: f32, layer: i32, slot: Rect&,
            drag: f32[>..<]&, holes: f32[>..<]&) -> f32 {
    let t0 = clock_ns();
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(html, d);
    var rules: Rule[>..] = [];
    var comps: Compound[>..] = [];
    var classes: Span[>..] = [];
    var decls: Decl[>..] = [];
    var sheet_bytes: u8[>..] = [];
    var sel_attrs: AttrSel[>..] = [];
    var vars: Var[>..] = [];
    var var_bytes: u8[>..] = [];
    var media: Media[>..] = [];
    let sh = Sheet { rules: rules, comps: comps, classes: classes, attrs: sel_attrs, decls: decls, bytes: sheet_bytes,
                     vars: vars, var_bytes: var_bytes, media: media };
    load_sheets(d, sh);
    var styles: Style[>..] = [];
    compute_styles(d, sh, styles);
    var text: u8[>..] = [];
    var carets: f32[>..] = [];
    var runs: Run[>..] = [];
    var run_of: i32[>..] = [];
    var fonts: FontInfo[>..] = [];
    var boxes: Rect[>..] = [];
    var items: DItem[>..<] = [];
    var flex: FlexItem[>..<] = [];
    var atoms: i32[>..<] = [];
    var measured: Measured[>..] = [];
    var paths: f32[>..<] = [];
    var ids: i32[>..] = [];
    var definite: f32[>..] = [];
    let L = Layout { d: d, styles: styles, text: text, carets: carets, runs: runs, run_of: run_of,
                     fonts: fonts, boxes: boxes, items: items, flex: flex, atoms: atoms,
                     measured: measured, paths: paths, ids: ids, definite: definite };
    measure(L);
    layout_page(L, w, h);
    slot.w = 0.0;
    for n, k in nodes {
        guard n.kind == NODE_ELEMENT && k < boxes.len else { continue; }
        let v, has = attr_value(d, k as i32, "data-slot");
        if has { slot = boxes[k]; }
        let dv, dragged = attr_value(d, k as i32, "data-drag");
        let hv, hole = attr_value(d, k as i32, "data-nodrag");
        let b = boxes[k];
        if dragged { drag.push(b.x); drag.push(b.y); drag.push(b.w); drag.push(b.h); }
        if hole { holes.push(b.x); holes.push(b.y); holes.push(b.w); holes.push(b.h); }
    }
    let rc = tp_set_layer(layer, items[..], text[..], paths[..], scale);
    if rc != 0 {
        write_stderr(str("tusk: the compositor refused the interface (error ", rc, ")\n"));
        exit(1);
    }
    return ((clock_ns() - t0) / 1000000.0) as f32;
}
