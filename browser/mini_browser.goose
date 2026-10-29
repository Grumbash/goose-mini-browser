// A tiny HTML "browser": no networking (Goose v1 has none in its stdlib),
// so it renders local .html files instead of fetching URLs. It understands
// <h1>/<h2>/<h3>, <p>, <a href="...">, <br>, plain text, and nothing else --
// enough to click between a few linked pages inside a gfx+ui window.
//
//   goose mini_browser.goose -- page1.html

import std;
import os;
import gfx;
import ui;
import .net;

struct Item { kind: i64, text: u8[varint], href: u8[varint], color: u32 }

let K_PARA = 0;
let K_HEADING = 1;
let K_LINK = 2;
let K_BREAK = 3;
let K_IMAGE = 4;

fn extract_href(tag: u8[:]) -> u8[:] {
    let k = find(tag, "href=\"");
    if k < 0 { return tag[0..0]; }
    let start = k + 6;
    var j = start;
    while j < tag.len && tag[j] != '"' { j += 1; }
    return tag[start..j];
}

fn extract_src(tag: u8[:]) -> u8[:] {
    let k = find(tag, "src=\"");
    if k < 0 { return tag[0..0]; }
    let start = k + 5;
    var j = start;
    while j < tag.len && tag[j] != '"' { j += 1; }
    return tag[start..j];
}

fn extract_poster(tag: u8[:]) -> u8[:] {
    let k = find(tag, "poster=\"");
    if k < 0 { return tag[0..0]; }
    let start = k + 8;
    var j = start;
    while j < tag.len && tag[j] != '"' { j += 1; }
    return tag[start..j];
}

fn tag_name(tag: u8[:]) -> u8[:] {
    var end = 0;
    while end < tag.len && tag[end] != ' ' { end += 1; }
    var name = tag[0..end];
    if name.len > 0 && name[name.len - 1] == '/' { name = name[0..name.len - 1]; }
    return name;
}

// Pulls `color: ...` out of a `style="..."` attribute: a 6-digit hex
// (#rrggbb) or one of a handful of named colors picked to stay readable on
// the dark background this browser always draws on. Returns 0 (meaning
// "no override, use the block kind's own default") for anything else --
// not a CSS parser, just enough to show a page author's inline color/
// emphasis chose to say something.
fn extract_style_color(tag: u8[:]) -> u32 {
    let k = find(tag, "style=\"");
    if k < 0 { return 0; }
    let start = k + 7;
    var j = start;
    while j < tag.len && tag[j] != '"' { j += 1; }
    let style = tag[start..min(j, tag.len)];
    let ck = find(style, "color:");
    if ck < 0 { return 0; }
    var p = ck + 6;
    while p < style.len && style[p] == ' ' { p += 1; }
    if p < style.len && style[p] == '#' {
        var e = p + 1;
        while e < style.len && style[e] != ';' && style[e] != ' ' { e += 1; }
        let hex = style[p + 1..e];
        if hex.len == 6 {
            let n, ok = parse_int(hex, 16);
            if ok { return n as u32; }
        }
        return 0;
    }
    var e = p;
    while e < style.len && style[e] != ';' { e += 1; }
    let name = trim(style[p..e]);
    if name == "red" { return 0xDC3232; }
    if name == "green" { return 0x3CB44B; }
    if name == "blue" { return 0x5A8CFF; }
    if name == "yellow" { return 0xE6C83C; }
    if name == "orange" { return 0xFF9632; }
    if name == "gray" || name == "grey" { return 0xA0A0A0; }
    if name == "white" { return 0xFFFFFF; }
    return 0;
}

// The color an item should render with: an explicit inline style wins,
// otherwise <b>/<strong>/<i>/<em> anywhere in the block bump it to a pale
// green (there is no second font loaded, so true bold/italic glyphs are
// not an option -- this is the stand-in). 0 means "no override".
fn block_color(cur_color: u32, emphasized: bool) -> u32 {
    if cur_color != 0 { return cur_color; }
    if emphasized { return 0x9FE6B8; } // pale green: visibly not the default body color
    return 0;
}

// Decodes the handful of HTML entities real pages actually use: the five
// named ones XML also has, &nbsp;, and numeric &#NN;/&#xHH; refs. Anything
// else (there are hundreds of named entities in the full HTML spec) passes
// through as literal text -- good enough for reading a page, not a full
// decoder.
fn decode_entities(s: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var i = 0;
    while i < s.len {
        if s[i] == '&' {
            var j = i + 1;
            while j < s.len && j < i + 12 && s[j] != ';' && s[j] != '&' && s[j] != ' ' { j += 1; }
            if j < s.len && s[j] == ';' && j > i + 1 {
                let ent = s[i + 1..j];
                if ent == "amp" { out.push('&'); i = j + 1; continue; }
                if ent == "lt" { out.push('<'); i = j + 1; continue; }
                if ent == "gt" { out.push('>'); i = j + 1; continue; }
                if ent == "quot" { out.push('"'); i = j + 1; continue; }
                if ent == "apos" { out.push('\''); i = j + 1; continue; }
                if ent == "nbsp" { out.push(' '); i = j + 1; continue; }
                if ent.len > 1 && ent[0] == '#' {
                    var code = 0;
                    var ok = false;
                    if ent.len > 2 && (ent[1] == 'x' || ent[1] == 'X') {
                        let n, pok = parse_int(ent[2..], 16);
                        code = n;
                        ok = pok;
                    } else {
                        let n, pok = parse_int(ent[1..]);
                        code = n;
                        ok = pok;
                    }
                    if ok { push_utf8(out, code); i = j + 1; continue; }
                }
            }
        }
        out.push(s[i]);
        i += 1;
    }
    return out;
}

// A hand-rolled scanner, not a real HTML parser: good enough for the tags
// above, nothing more. <head>/<style>/<script>/<title> content is skipped
// outright -- it is never meant to be read as the page's text.
fn parse_html(src: u8[:]) -> Item[>..] {
    var items: Item[>..] = [];
    var buf: u8[>..] = [];
    var cur_href: u8[>..] = [];
    var kind = K_PARA;
    var cur_color: u32 = 0;
    var emphasized = false;
    var skip_tag: const u8[:] = src[0..0];
    var i = 0;
    while i < src.len {
        if src[i] == '<' {
            var j = i + 1;
            while j < src.len && src[j] != '>' { j += 1; }
            let tag = src[i + 1..min(j, src.len)];
            let name = tag_name(tag);
            if skip_tag.len > 0 {
                if name.len > 0 && name[0] == '/' && name[1..] == skip_tag { skip_tag = src[0..0]; }
                // any other tag while skipping is ignored, open or close
            } else if name == "style" || name == "script" || name == "head" || name == "title" {
                buf.resize(0);
                skip_tag = name;
            } else if name == "b" || name == "strong" || name == "i" || name == "em" {
                emphasized = true;
            } else if name == "img" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                let src = extract_src(tag);
                if src.len > 0 { items.push(Item { kind: K_IMAGE, text: "", href: src, color: 0 }); }
            } else if name == "video" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                let poster = extract_poster(tag);
                if poster.len > 0 {
                    items.push(Item { kind: K_IMAGE, text: "", href: poster, color: 0 });
                } else {
                    // no poster to show a frame of, and this scanner does not
                    // decode video -- say so rather than silently drop it
                    items.push(Item { kind: K_PARA, text: "[video, no poster]", href: "", color: 0xA0A0A0 });
                }
            } else if name == "h1" || name == "h2" || name == "h3" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                kind = K_HEADING;
                cur_color = extract_style_color(tag);
                emphasized = false;
            } else if name == "/h1" || name == "/h2" || name == "/h3" {
                let t = decode_entities(trim(buf[..]));
                items.push(Item { kind: K_HEADING, text: t[..], href: "", color: block_color(cur_color, emphasized) });
                buf.resize(0);
                kind = K_PARA;
                cur_color = 0;
                emphasized = false;
            } else if name == "p" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                kind = K_PARA;
                cur_color = extract_style_color(tag);
                emphasized = false;
            } else if name == "/p" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: K_PARA, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                kind = K_PARA;
                cur_color = 0;
                emphasized = false;
            } else if name == "a" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                cur_href.resize(0);
                cur_href.append(extract_href(tag));
                kind = K_LINK;
                cur_color = extract_style_color(tag);
                emphasized = false;
            } else if name == "/a" {
                let t = decode_entities(trim(buf[..]));
                items.push(Item { kind: K_LINK, text: t[..], href: cur_href[..], color: block_color(cur_color, emphasized) });
                buf.resize(0);
                kind = K_PARA;
                cur_color = 0;
                emphasized = false;
            } else if name == "br" {
                let t = decode_entities(trim(buf[..]));
                if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
                buf.resize(0);
                items.push(Item { kind: K_BREAK, text: "", href: "", color: 0 });
            }
            // any other tag (html, body, div, ...) is ignored outright
            i = j + 1;
        } else {
            let c = src[i];
            if skip_tag.len > 0 {
                // swallowed: this byte belongs to a tag we are not reading
            } else if c == ' ' || c == '\n' || c == '\t' || c == '\r' {
                if buf.len > 0 && buf[buf.len - 1] != ' ' { buf.push(' '); }
            } else {
                buf.push(c);
            }
            i += 1;
        }
    }
    let t = decode_entities(trim(buf[..]));
    if t.len > 0 { items.push(Item { kind: kind, text: t[..], href: "", color: block_color(cur_color, emphasized) }); }
    return items;
}

// Resolves an href against the page it was found on: local files resolve
// relative to their directory, remote pages the same way against their URL
// (not a real RFC 3986 resolver -- no "..", no site-root "/", just "same
// directory" which is what these demo pages need).
fn resolve(base: u8[:], href: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if is_http(href) || is_https(href) { out.append(href); return out; }
    var slash = -1;
    for i in base.len { if base[i] == '/' { slash = i; } }
    if slash >= 0 { out.append(base[0..slash + 1]); }
    out.append(href);
    return out;
}

fn is_http(href: u8[:]) -> bool { starts_with(href, "http://") }
fn is_https(href: u8[:]) -> bool { starts_with(href, "https://") }

// Network fetches run on a separate worker thread so the UI keeps
// rendering (and stays clickable) while a request is in flight. Goose
// threads share no memory; a job/result crosses the typed queue as one
// flat copy (reference.md #22), so both structs hold their text inline
// (u8[varint]) rather than as a slice or builder.
struct FetchJob { id: i64, url: u8[varint] }
struct FetchResult { id: i64, status: i64, body: u8[varint] }

thread_fn fetch_worker() {
    loop {
        let job = qget<FetchJob>();
        guard job.id >= 0 else { break; }       // -1 is the stop signal
        var body: u8[>..] = [];
        let status = http_get_page(job.url[..], body);
        qput(FetchResult { id: job.id, status: status, body: body[..] });
    }
}

// A second queue/worker pair, parallel to the page-fetch one above and
// running on its own thread: an image decode (network + PNG/JPEG/GIF/WebP
// decode + downsample, all in goosenet/Rust) is its own potentially-slow
// job and must not make page navigation wait on it, or vice versa.
// `item_index` + `gen` let the main loop drop a result that arrived after
// the user navigated to a different page (the array of items the index
// pointed into no longer exists).
struct ImageJob { id: i64, item_index: i64, gen: i64, url: u8[varint] }
struct ImageResult { id: i64, item_index: i64, gen: i64, ok: bool, w: i32, h: i32, pixels: u8[varint] }

thread_fn image_worker() {
    loop {
        let job = qget<ImageJob>();
        guard job.id >= 0 else { break; }
        var pixels: u8[>..] = [];
        var w: i32 = 0;
        var h: i32 = 0;
        let ok = fetch_image_rgba(job.url[..], pixels, w, h);
        qput(ImageResult { id: job.id, item_index: job.item_index, gen: job.gen,
                            ok: ok, w: w, h: h, pixels: pixels[..] });
    }
}

fn main() {
    var path: u8[..200] = [];
    let argv = args();
    if argv.len >= 2 { path.append(argv[1]); } else { path.append("page1.html"); }

    guard gfx::open("Goose mini browser", 820, 600, gfx::WINDOW_RESIZABLE) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();
    var ctx = ui::create(15.0);
    guard ctx.id != 0 else {
        write_stderr(str("ui: ", ui::error(), "\n"));
        return;
    }
    defer ui::destroy(ctx);

    let worker_id = thread_spawn(fetch_worker);
    defer { qput(FetchJob { id: -1, url: "" }); thread_wait(worker_id); };
    let img_worker_id = thread_spawn(image_worker);
    defer { qput(ImageJob { id: -1, item_index: 0, gen: 0, url: "" }); thread_wait(img_worker_id); };

    var addr: u8[..200] = [];
    addr.append(path[..]);
    var status: u8[>..] = [];
    var items: Item[>..] = [];
    var history: u8[..200][>..] = [];
    var next_id: i64 = 0;
    var pending_id: i64 = -1;
    var loading = false;

    // Per-item image state, parallel to `items` and rebuilt every time it
    // changes. 0 = not yet requested, 1 = loading, 2 = loaded (img_tex/
    // img_w/img_h valid), 3 = failed.
    var img_state: i64[>..] = [];
    var img_tex: gfx::Texture[>..] = [];
    var img_w: i64[>..] = [];
    var img_h: i64[>..] = [];
    var page_gen: i64 = 0;
    var next_img_id: i64 = 0;

    fn reset_img_state() {
        page_gen += 1;      // orphans any ImageResult already in flight
        img_state = [];
        img_tex = [];
        img_w = [];
        img_h = [];
        for it in items {
            img_state.push(0);
            img_tex.push(gfx::Texture { id: 0 });
            img_w.push(0);
            img_h.push(0);
        }
    }

    fn load_local(p: u8[:]) -> bool {
        var data: u8[>..] = [];
        if !read_file(p, data) {
            status.resize(0);
            format(status, "cannot read ", p);
            items = [];
            reset_img_state();
            return false;
        }
        items = parse_html(data[..]);
        reset_img_state();
        status.resize(0);
        format(status, p, " (", items.len, " blocks)");
        return true;
    }

    // Local files load synchronously (instant anyway); a URL is handed to
    // the worker thread and picked up by the polling code below once its
    // FetchResult arrives. Superseded requests (the user navigated again
    // before a slow fetch finished) are dropped by id mismatch.
    fn start_load(p: u8[:]) {
        if is_http(p) || is_https(p) {
            var u: u8[..200] = [];
            u.append(p);
            qput(FetchJob { id: next_id, url: u[..] });
            pending_id = next_id;
            next_id += 1;
            loading = true;
            items = [];
            reset_img_state();
            status.resize(0);
            format(status, "loading ", p, " ...");
        } else {
            loading = false;
            load_local(p);
        }
    }

    start_load(path[..]);

    let window = ui::WINDOW_BORDER | ui::WINDOW_TITLE;
    var frames = -1;
    if argv.len == 4 && argv[2] == "--frames" {
        let n, ok = parse_int(argv[3]);
        if ok { frames = n; }
    }
    var drawn = 0;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        ui::input_from_gfx(ctx);
        let size = gfx::screen_size();

        if loading {
            let r, got = qpoll<FetchResult>();
            if got && r.id == pending_id {
                loading = false;
                if r.status <= 0 {
                    status.resize(0);
                    format(status, "fetch failed: ", path[..]);
                    items = [];
                    reset_img_state();
                } else {
                    items = parse_html(r.body[..]);
                    reset_img_state();
                    status.resize(0);
                    format(status, path[..], " -> HTTP ", r.status);
                }
            }
            // a got-but-mismatched id is a stale result from a superseded
            // request: silently dropped, the current one is still pending
        }

        // Drain whatever image decodes finished, capped per frame so a
        // page with many images can't stall a frame uploading all of them
        // to the GPU at once.
        var drained = 0;
        loop {
            let r, got = qpoll<ImageResult>();
            if !got { break; }
            drained += 1;
            if r.gen == page_gen && r.item_index >= 0 && r.item_index < img_state.len {
                if r.ok && r.w > 0 && r.h > 0 {
                    var tex = gfx::texture2d(r.w as i64, r.h as i64);
                    gfx::update_texture(tex, r.pixels[..]);
                    img_tex[r.item_index] = tex;
                    img_w[r.item_index] = r.w as i64;
                    img_h[r.item_index] = r.h as i64;
                    img_state[r.item_index] = 2;
                } else {
                    img_state[r.item_index] = 3;
                }
            }
            // a gen mismatch is a result for a page the user already left:
            // the item_index it refers to may not even exist any more
            if drained >= 4 { break; }
        }

        if ui::begin(ctx, "browser", ui::rect(0, 0, size.x as f32, size.y as f32), window) {
            let back_ratio: f32[3] = [0.08, 0.72, 0.20];
            ui::layout_row(ctx, ui::DYNAMIC, 28.0, back_ratio);
            let back = ui::button_label(ctx, "<-");
            ui::edit_string(ctx, ui::EDIT_FIELD, addr, ui::FILTER_DEFAULT);
            let go = ui::button_label(ctx, "Go");

            var target: u8[..200] = [];
            var navigate = false;
            if back && history.len > 0 {
                target.append(history[history.len - 1][..]);
                remove_at(history, history.len - 1);
                navigate = true;
            } else if go {
                target.append(addr[..]);
                navigate = true;
            }
            if navigate {
                if path.len > 0 && target[..] != path[..] {
                    if !back { history.push(path); }
                }
                path.resize(0);
                path.append(target[..]);
                addr.resize(0);
                addr.append(path[..]);
                start_load(path[..]);
            }

            ui::layout_row_dynamic(ctx, 18.0, 1);
            ui::label_colored(ctx, status[..], ui::TEXT_LEFT, ui::rgb(150, 150, 150));

            ui::layout_row_dynamic(ctx, (size.y as f32) - 120.0, 1);
            if ui::group_begin(ctx, "page", ui::WINDOW_BORDER) {
                var clicked: u8[..200] = [];
                var did_click = false;
                var idx = 0;
                for it in items {
                    if it.kind == K_HEADING {
                        ui::layout_row_dynamic(ctx, 30.0, 1);
                        let hc = if it.color != 0 { it.color } else { 0xFFDC78 };
                        ui::label_colored(ctx, it.text, ui::TEXT_LEFT,
                                           ui::rgb((hc >> 16) & 0xFF, (hc >> 8) & 0xFF, hc & 0xFF));
                    } else if it.kind == K_LINK {
                        ui::layout_row_dynamic(ctx, 22.0, 1);
                        if ui::link_label(ctx, it.text, ui::TEXT_LEFT) {
                            clicked.append(it.href);
                            did_click = true;
                        }
                    } else if it.kind == K_BREAK {
                        ui::layout_row_dynamic(ctx, 10.0, 1);
                        ui::spacer(ctx);
                    } else if it.kind == K_IMAGE {
                        if img_state[idx] == 0 {
                            let img_url = resolve(path[..], it.href);
                            qput(ImageJob { id: next_img_id, item_index: idx, gen: page_gen, url: img_url[..] });
                            next_img_id += 1;
                            img_state[idx] = 1;
                        }
                        if img_state[idx] == 2 {
                            ui::layout_row_static(ctx, img_h[idx] as f32, img_w[idx], 1);
                            ui::image(ctx, ui::texture_image(img_tex[idx]));
                        } else if img_state[idx] == 1 {
                            ui::layout_row_dynamic(ctx, 20.0, 1);
                            ui::label_colored(ctx, "[loading image...]", ui::TEXT_LEFT, ui::rgb(140, 140, 140));
                        } else {
                            ui::layout_row_dynamic(ctx, 20.0, 1);
                            ui::label_colored(ctx, "[image failed to load]", ui::TEXT_LEFT, ui::rgb(200, 90, 90));
                        }
                    } else if it.color != 0 {
                        // a colored paragraph draws on one line (no colored
                        // wrap exists in ui) -- a real tradeoff, not a bug
                        ui::layout_row_dynamic(ctx, 20.0, 1);
                        ui::label_colored(ctx, it.text, ui::TEXT_LEFT,
                                           ui::rgb((it.color >> 16) & 0xFF, (it.color >> 8) & 0xFF, it.color & 0xFF));
                    } else {
                        ui::layout_row_dynamic(ctx, 20.0, 1);
                        ui::label_wrap(ctx, it.text);
                    }
                    idx += 1;
                }
                ui::group_end(ctx);

                if did_click {
                    let dest = resolve(path[..], clicked[..]);
                    history.push(path);
                    path.resize(0);
                    path.append(dest[..]);
                    addr.resize(0);
                    addr.append(path[..]);
                    start_load(path[..]);
                }
            }
        }
        ui::end(ctx);

        gfx::begin_screen(float4 { 0.12, 0.12, 0.14, 1.0 });
        gfx::end_pass();
        ui::render(ctx);
        drawn++;
        if drawn == frames { break; }
    }

    let saved = gfx::screenshot("mini_browser.png");
    print("drew ", drawn, " frames, ended on ", path[..], "; saved mini_browser.png: ", saved);
}
