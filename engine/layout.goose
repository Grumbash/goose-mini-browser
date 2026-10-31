// Layout and paint (docs/adr/0004): block and inline layout of the styled
// document, painted into the flat display list the compositor draws
// (docs/adr/0001). Text is measured once, after styling: Core Text shapes each
// text node and gives the pen position before every byte, so laying the page
// out again at another width is arithmetic in Goose that never calls the
// platform. Blocks stack with their margins collapsed, inline content breaks
// into lines at spaces, and list items get markers. Positioned boxes are
// placed once the flow is done, then everything is put in CSS's paint order
// and cut to the boxes that clip it. Flex containers lay out their items;
// inline-blocks sit on lines as one piece. Transforms come last: a
// translation moves items, anything else gives them a matrix. Floats, grid,
// tables as grids and inline backgrounds wait.

import std;
import math;
import .dom;
import .css;

// Display item kinds, as the compositor numbers them (platform/src/compositor.rs).
let ITEM_NONE: i32 = 0;          // dropped: cut away by a clip or an ellipsis
let ITEM_RECT: i32 = 1;
let ITEM_TEXT: i32 = 2;
let ITEM_BOX: i32 = 3;

// A box item's border style.
let BORDER_SOLID: i32 = 0;
let BORDER_DASHED: i32 = 1;

// One item of the display list, laid out as the compositor's DItem: positions
// in points from the page's top-left; a text item's y is its baseline and its
// text a span of the layout's text. A box is a rectangle with rounded corners
// filled with `color`, and borders inside its edge in one colour and style:
// `border` wide at the top, the others as wide as they say. An item with a
// clip (clip_w above 0) shows only inside that rectangle, its corners rounded
// by clip_tl, clip_tr, clip_br and clip_bl. A transformed item has a matrix
// (m_a … m_f, as CSS's matrix() takes them, points to points; all 0: none),
// and its clip one that takes its points to the clip's (c_a … c_f; all 0:
// they are the same). A second clip (oclip_w above 0) cuts it square on the
// page, after its transform.
struct DItem {
    kind: i32,
    x: f32, y: f32, w: f32, h: f32,
    color: u32,              // 0xAARRGGBB
    font: i32, size: f32,    // text: the font id (see font_of) and size in points
    text: i32, text_len: i32,
    node: i32,               // the node it paints
    rad_tl: f32, rad_tr: f32, rad_br: f32, rad_bl: f32,   // a box's corner radii, top left first, clockwise
    border: f32, border_color: u32, border_style: i32,
    border_right: f32, border_bottom: f32, border_left: f32,
    clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32,
    clip_tl: f32, clip_tr: f32, clip_br: f32, clip_bl: f32,
    m_a: f32, m_b: f32, m_c: f32, m_d: f32, m_e: f32, m_f: f32,
    c_a: f32, c_b: f32, c_c: f32, c_d: f32, c_e: f32, c_f: f32,
    oclip_x: f32, oclip_y: f32, oclip_w: f32, oclip_h: f32,
}

struct Rect { x: f32, y: f32, w: f32, h: f32 }

// A font's vertical metrics, from the platform layer (platform/src/text.rs).
struct Metrics {
    ascent: f32, descent: f32, leading: f32, x_height: f32,
    underline_position: f32,   // from the baseline, up positive
    underline_thickness: f32,
}

extern "tusk_platform" {
    fn tp_font_metrics(font: i32, size: f32, out: Metrics&) -> i32;
    fn tp_text_carets(font: i32, size: f32, text: const u8[:], carets: f32[:]) -> i32;
}

// A font at one size, with what layout needs from it.
struct FontInfo { font: i32, size: f32, m: Metrics, space: f32 }

// One text node's text after white-space processing, or one list item's
// marker: a span of Layout.text, and where the pen positions before its bytes
// (and after its last) start in Layout.carets.
struct Run { node: i32, start: i32, len: i32, caret: i32, font: i32 }

// Everything layout reads and writes, owned by the caller.
struct Layout {
    d: Doc,
    styles: Style[>..]&,
    text: u8[>..]&,          // every run's text; the display list points into it
    carets: f32[>..]&,
    runs: Run[>..]&,
    run_of: i32[>..]&,       // per node: its text run, or a list item's marker run; -1 for none
    fonts: FontInfo[>..]&,
    boxes: Rect[>..]&,       // per node: its border box, or the lines a text spans; empty if not drawn
    items: DItem[>..<]&,     // shrinks only when a flex container measures an item, see measure_sized
    flex: FlexItem[>..<]&,   // the items of the flex containers being laid out, one above another
    atoms: i32[>..<]&,       // the inline-blocks on the lines being laid out, see place_atomic
    measured: Measured[>..]&, // per node, what measure_sized last found
}

// What measure_sized found for a node: its border-box height and first
// baseline laid out `w` wide and `h` high (w -1: nothing yet).
struct Measured { w: f32, h: f32, height: f32, baseline: f32 }

// The line being filled.
struct Line {
    left: f32, width: f32,       // the content box it fills
    y: f32,                      // its top
    x: f32,                      // the pen, from `left`
    first_item: i64,             // its display items start here
    ascent: f32, descent: f32,   // the room it needs above and below its baseline
    strut_ascent: f32, strut_descent: f32,
    content: bool,               // something is on it
    space: bool,                 // it ends in a collapsible space...
    trailing: f32,               // ...this wide
    align: i32,
    first_baseline: f32,         // the first line's baseline once it is closed; -1 before
    ellipsis: i32,               // the run of the "…" that ends a line too long for its box, or -1
    soft: bool,                  // its last text wraps, so a break may follow it
    first_atom: i64,             // its inline-blocks start here in L.atoms
    atom: bool,                  // an inline-block came last, so a break may follow
}

// The platform's font id: the family, then bold and italic bits.
fn font_of(s: Style) -> i32 {
    var f = s.family;
    if s.bold != 0 { f = f | 16; }
    if s.italic != 0 { f = f | 32; }
    return f;
}

fn font_index(L: Layout, font: i32, size: f32) -> i32 {
    for f, i in L.fonts {
        if f.font == font && f.size == size { return i as i32; }
    }
    var m = Metrics { ascent: 0.0, descent: 0.0, leading: 0.0, x_height: 0.0, underline_position: 0.0, underline_thickness: 0.0 };
    if tp_font_metrics(font, size, m) != 0 {
        // No platform fonts: rough metrics, so layout still runs.
        m.ascent = size * 0.8; m.descent = size * 0.2; m.x_height = size * 0.5;
        m.underline_position = -size * 0.1; m.underline_thickness = size / 16.0;
    }
    var c: f32[2];
    fill(c[..], 0.0);
    var space = size * 0.25;
    if tp_text_carets(font, size, " ", c[..]) == 0 { space = c[1]; }
    L.fonts.push(FontInfo { font: font, size: size, m: m, space: space });
    return (L.fonts.len - 1) as i32;
}

// ------------------------------------------------------------------ measuring

// Measures the document's text: each rendered text node after white-space
// processing, and each list item's marker. Runs once per document; layout at
// any width afterwards reads what it found.
fn measure(L: Layout) {
    while L.run_of.len < L.d.nodes.len { L.run_of.push(-1); }
    measure_children(L, 0);
}

recursive fn measure_children(L: Layout, n: i32) {
    var ordinal: i32 = 1;
    if is_element(L.d, n, "ol") {
        let v, has = attr_value(L.d, n, "start");
        if has {
            let k, ok = parse_int(trim(v));
            if ok && k > -1000000000 && k < 1000000000 { ordinal = k as i32; }
        }
    }
    var c = L.d.nodes[n].first;
    while c >= 0 {
        let node = L.d.nodes[c];
        if node.kind == NODE_TEXT {
            add_text_run(L, c);
        } else if node.kind == NODE_ELEMENT && L.styles[c].display != K_NONE {
            let s = L.styles[c];
            if s.display == K_LIST_ITEM {
                add_marker_run(L, c, ordinal);
                ordinal += 1;
            } else if s.ellipsis != 0 && s.clips != 0 && s.display != K_INLINE {
                add_ellipsis_run(L, c);
            }
            measure_children(L, c);
        }
        c = node.next;
    }
}

fn add_text_run(L: Layout, n: i32) {
    let s = L.styles[n];
    let start = L.text.len;
    let keep = s.ws == K_PRE || s.ws == K_PRE_WRAP;
    var last_space = false;
    for ch in node_text(L.d, n) {
        if keep {
            if ch == 9 { L.text.append("        "); }      // tab stops wait; a tab is 8 spaces
            else if ch != 13 { L.text.push(ch); }
        } else if is_ws(ch) {
            if !last_space { L.text.push(' '); }
            last_space = true;
        } else {
            L.text.push(ch);
            last_space = false;
        }
    }
    add_run(L, n, s, start);
}

fn add_marker_run(L: Layout, li: i32, ordinal: i32) {
    let s = L.styles[li];
    guard s.list != K_NONE;
    let start = L.text.len;
    if s.list == K_DISC { push_utf8(L.text, 0x2022); }
    else if s.list == K_CIRCLE { push_utf8(L.text, 0x25E6); }
    else if s.list == K_SQUARE { push_utf8(L.text, 0x25AA); }
    else {
        if s.list == K_LOWER_ALPHA || s.list == K_UPPER_ALPHA { append_alpha(L.text, ordinal, s.list == K_UPPER_ALPHA); }
        else if s.list == K_LOWER_ROMAN || s.list == K_UPPER_ROMAN { append_roman(L.text, ordinal, s.list == K_UPPER_ROMAN); }
        else { format(L.text, ordinal); }
        L.text.push('.');
    }
    add_run(L, li, s, start);
}

// The "…" that ends block n's lines when they are too long for it, in its
// font, as its run.
fn add_ellipsis_run(L: Layout, n: i32) {
    let start = L.text.len;
    push_utf8(L.text, 0x2026);
    add_run(L, n, L.styles[n], start);
}

// Measures the text appended to L.text since `start` as node n's run.
fn add_run(L: Layout, n: i32, s: Style, start: i64) {
    let len = L.text.len - start;
    guard len > 0;
    let font = font_of(s);
    let fi = font_index(L, font, s.font_size);
    let caret = L.carets.len;
    for k in len + 1 { L.carets.push(0.0); }
    if len == 1 && L.text[start] == ' ' {
        L.carets[caret + 1] = L.fonts[fi].space;
    } else if tp_text_carets(font, s.font_size, L.text[start..start + len], L.carets[caret..caret + len + 1]) != 0 {
        // No platform text: even steps, so layout still runs.
        for k in len + 1 { L.carets[caret + k] = k * s.font_size * 0.5; }
    }
    L.run_of[n] = L.runs.len as i32;
    L.runs.push(Run { node: n, start: start as i32, len: len as i32, caret: caret as i32, font: fi });
}

fn append_alpha(out: u8[>..]&, n: i32, upper: bool) {
    guard n > 0 else { format(out, n); return; }
    var letters: u8[>..] = [];
    var k = n;
    while k > 0 {
        k -= 1;
        letters.push((if upper { 'A' } else { 'a' }) + (k % 26) as u8);
        k = k / 26;
    }
    var i = letters.len - 1;
    while i >= 0 { out.push(letters[i]); i -= 1; }
}

fn append_roman(out: u8[>..]&, n: i32, upper: bool) {
    guard n > 0 && n < 4000 else { format(out, n); return; }
    let ones = "ixcm";
    let fives = "vld";
    var unit: i32 = 1000;
    var p: i64 = 3;
    while p >= 0 {
        let d = (n / unit) % 10;
        if d == 9 { roman_char(out, ones[p], upper); roman_char(out, ones[p + 1], upper); }
        else if d == 4 { roman_char(out, ones[p], upper); roman_char(out, fives[p], upper); }
        else {
            if d >= 5 { roman_char(out, fives[p], upper); }
            for k in (d % 5) as i64 { roman_char(out, ones[p], upper); }
        }
        unit = unit / 10;
        p -= 1;
    }
}

fn roman_char(out: u8[>..]&, ch: u8, upper: bool) { out.push(if upper { ch - 32 } else { ch }); }

// ------------------------------------------------------------------ blocks

// Lays the document out `width` points wide and paints it into L.items.
// Returns the page's height. An absolute box with no positioned element
// around it, and a fixed one, are placed on the first screen: `width` ×
// `height` at the top of the page.
fn layout_page(L: Layout, width: f32, height: f32) -> f32 {
    while L.boxes.len < L.d.nodes.len { L.boxes.push(Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }); }
    let h, first, trailing = layout_children(L, 0, 0.0, 0.0, width, false);
    inline_boxes(L, 0);
    var page_h = h + trailing;
    var positioned = false;
    var relative = false;
    var clips = false;
    var transformed = false;
    for s, n in L.styles {
        guard L.d.nodes[n].kind == NODE_ELEMENT && s.display != K_NONE else { continue; }
        if s.position != K_STATIC { positioned = true; }
        if s.position == K_RELATIVE { relative = true; }
        if s.clips != 0 && s.display != K_INLINE { clips = true; }
        if transforms(L, n as i32) { transformed = true; }
    }
    if positioned {
        place_positioned(L, 0, width, height);
        if relative { shift_relative(L); }
        page_h = max(page_h, positioned_bottom(L));
    }
    if positioned || transformed { stack(L); }
    // Transforms, each node's with those of the elements around it.
    var mats: Mat[>..] = [];
    if transformed {
        for n in L.d.nodes.len { mats.push(identity()); }
        node_matrices(L, 0, identity(), mats);
    }
    if clips { clip_items(L, mats); }
    if transformed {
        transform_items(L, mats);
        transform_boxes(L, mats);
        page_h = max(page_h, transformed_bottom(L, mats));
    }
    // Opacity: each item at its element's alpha, which already holds its
    // ancestors'. Overlapping items show through each other, where CSS would
    // flatten the element first.
    for k in L.items.len {
        let it .= L.items[k];
        guard it.node >= 0 else { continue; }
        let a = L.styles[it.node].alpha;
        if a < 1.0 {
            it.color = fade(it.color, a);
            it.border_color = fade(it.border_color, a);
        }
    }
    return page_h;
}

fn is_block_level(L: Layout, n: i32) -> bool {
    guard L.d.nodes[n].kind == NODE_ELEMENT else { return false; }
    let d = L.styles[n].display;
    return d == K_BLOCK || d == K_LIST_ITEM || d == K_FLEX;
}

// Whether element n lays its children out as flex items.
fn is_flex(L: Layout, n: i32) -> bool {
    let d = L.styles[n].display;
    return d == K_FLEX || d == K_INLINE_FLEX;
}

// An inline-block or inline-flex: on its line as one piece, laid out inside
// as a block (place_atomic).
fn is_atomic(L: Layout, n: i32) -> bool {
    guard L.d.nodes[n].kind == NODE_ELEMENT else { return false; }
    let d = L.styles[n].display;
    return d == K_INLINE_BLOCK || d == K_INLINE_FLEX;
}

// A block-level element in the flow, which stacks below the one before.
fn flow_block(L: Layout, n: i32) -> bool { return is_block_level(L, n) && !is_out(L, n); }

// Whether n is an element out of the flow, absolute or fixed: the flow only
// notes in its box where it would have gone (its static position), and
// place_box lays it out once the flow is done.
fn is_out(L: Layout, n: i32) -> bool {
    guard L.d.nodes[n].kind == NODE_ELEMENT else { return false; }
    let p = L.styles[n].position;
    return p == K_ABSOLUTE || p == K_FIXED;
}

// Whether block n keeps its children's margins inside it, so that they don't
// collapse with its own: the root, a box out of the flow, one that clips, a
// flex container and a flex item, and an inline-block.
fn keeps_margins(L: Layout, n: i32) -> bool {
    let p = L.d.nodes[n].parent;
    return p == 0 || is_out(L, n) || clips_content(L, n) || is_flex(L, n) || is_atomic(L, n) || (p > 0 && is_flex(L, p));
}

// Whether n draws nothing: white space between blocks, a hidden element, or
// an inline element with only such things in it.
recursive fn is_blank(L: Layout, n: i32) -> bool {
    let node = L.d.nodes[n];
    if node.kind == NODE_ELEMENT {
        if L.styles[n].display == K_NONE || is_out(L, n) { return true; }
        if is_block_level(L, n) || is_atomic(L, n) || node_name(L.d, n) == "br" { return false; }
        var c = node.first;
        while c >= 0 {
            if !is_blank(L, c) { return false; }
            c = L.d.nodes[c].next;
        }
        return true;
    }
    guard node.kind == NODE_TEXT else { return true; }
    let r = L.run_of[n];
    return r < 0 || (L.runs[r].len == 1 && L.text[L.runs[r].start] == ' ');
}

// Two adjoining vertical margins become one (CSS 2.2 §8.3.1).
fn collapse(a: f32, b: f32) -> f32 {
    if a >= 0.0 && b >= 0.0 { return max(a, b); }
    if a < 0.0 && b < 0.0 { return min(a, b); }
    return a + b;
}

// n's top margin after collapsing with its first child's, and that child's
// with its own, while no border, padding or line comes between them. Empty
// blocks on the way let the margins through. The root's margins don't
// collapse with anything.
recursive fn top_margin(L: Layout, n: i32) -> f32 {
    let s = L.styles[n];
    guard !keeps_margins(L, n) && s.bt == 0.0 && s.pt == 0.0 else { return s.mt; }
    var m = s.mt;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if flow_block(L, c) {
            guard is_empty_block(L, c) else { return collapse(m, top_margin(L, c)); }
            m = collapse(m, collapse(L.styles[c].mt, L.styles[c].mb));
        } else if !is_blank(L, c) {
            return m;
        }
        c = L.d.nodes[c].next;
    }
    return m;
}

// A block with nothing in it: no border or padding, and only blank content
// or empty blocks. Its margins collapse through it (CSS 2.2 §8.3.1). A list
// item isn't one: it still shows its marker.
recursive fn is_empty_block(L: Layout, n: i32) -> bool {
    let s = L.styles[n];
    guard s.display == K_BLOCK && s.bt == 0.0 && s.pt == 0.0 && s.pb == 0.0 && s.bb == 0.0
          && s.height <= 0.0 && s.min_height <= 0.0 && !keeps_margins(L, n) else { return false; }
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if flow_block(L, c) {
            if !is_empty_block(L, c) { return false; }
        } else if !is_blank(L, c) {
            return false;
        }
        c = L.d.nodes[c].next;
    }
    return true;
}

// Lays out block-level element n, its top border edge at y, in a containing
// block that starts at x and is `avail` wide. Returns its border-box height,
// its first baseline (-1 if it has no lines) and its bottom margin after
// collapsing with its last child's.
recursive fn layout_block(L: Layout, n: i32, x: f32, y: f32, avail: f32) -> f32, f32, f32 {
    let s = L.styles[n];
    let hz = s.bl + s.pl + s.pr + s.br;        // across, besides the content
    let vt = s.bt + s.pt + s.pb + s.bb;        // down, besides the content
    let w = content_width(s, avail, hz);
    var ml = s.ml;
    let room = avail - w - hz;
    if s.auto_ml != 0 && s.auto_mr != 0 { ml = max(room / 2.0, 0.0); }
    else if s.auto_ml != 0 { ml = max(room - s.mr, 0.0); }
    let bx = x + ml;
    let bw = w + hz;

    // Its shadows, background and borders go under its content: their items
    // are kept here and written once its height is known.
    let paint_at = L.items.len;
    var ps = s;
    if paints_canvas(L, n) { ps.bg = 0; }
    for k in box_paint_count(ps) { L.items.push(rect_item(n, bx, y, 0.0, 0.0, 0)); }
    let contained = keeps_margins(L, n);
    let auto_height = s.height < 0.0 && s.min_height <= 0.0;
    let absorb_bottom = !contained && s.bb == 0.0 && s.pb == 0.0 && auto_height;
    var inner: f32 = 0.0;
    var first: f32 = -1.0;
    var trailing: f32 = 0.0;
    if is_flex(L, n) {
        // A height it has makes its items' room definite; percentages wait.
        var fh: f32 = -1.0;
        if s.height >= 0.0 { fh = content_height(s, 0.0, vt); }
        let lo, hi = height_limits(s);
        let ih, ib = layout_flex(L, n, bx + s.bl + s.pl, y + s.bt + s.pt, w, fh, lo, hi);
        inner = ih;
        first = ib;
    } else {
        let ih, ib, im = layout_children(L, n, bx + s.bl + s.pl, y + s.bt + s.pt, w, !contained && s.bt == 0.0 && s.pt == 0.0);
        inner = ih;
        first = ib;
        trailing = im;
    }
    var ch = inner;
    var mb = s.mb;
    if absorb_bottom { mb = collapse(mb, trailing); } else { ch += trailing; }
    ch = content_height(s, ch, vt);
    let h = vt + ch;
    box_paint(L, n, ps, paint_at, bx, y, bw, h);
    if s.display == K_LIST_ITEM { paint_marker(L, n, bx + s.bl + s.pl, first); }
    L.boxes[n] = Rect { x: bx, y: y, w: bw, h: h };
    return h, first, mb;
}

// Whether element n's background is the canvas's, which the window is
// cleared to instead of an item painting it: the root's, or the body's when
// the root has none (CSS Backgrounds 3 §2.11.2).
fn paints_canvas(L: Layout, n: i32) -> bool {
    guard (L.styles[n].bg >> 24) != 0 else { return false; }
    let p = L.d.nodes[n].parent;
    if p == 0 { return true; }
    return L.d.nodes[p].parent == 0 && (L.styles[p].bg >> 24) == 0 && node_name(L.d, n) == "body";
}

// A block's content width in a containing block `avail` wide: what its width
// says, or what is left beside its margins, between its minimum and maximum.
// `hz` is its padding and border across, which a border-box width includes.
fn content_width(s: Style, avail: f32, hz: f32) -> f32 {
    let inside: f32 = if s.border_box != 0 { hz } else { 0.0 };
    var w = avail - s.ml - s.mr - hz;
    if s.width >= 0.0 { w = s.width - inside; }
    else if s.width_pct >= 0.0 { w = avail * s.width_pct / 100.0 - inside; }
    var limit: f32 = -1.0;
    if s.max_width >= 0.0 { limit = max(s.max_width - inside, 0.0); }
    else if s.max_width_pct >= 0.0 { limit = max(avail * s.max_width_pct / 100.0 - inside, 0.0); }
    if limit >= 0.0 && w > limit { w = limit; }
    let least = (if s.min_width_pct >= 0.0 { avail * s.min_width_pct / 100.0 } else { s.min_width }) - inside;
    if w < least { w = least; }
    return max(w, 0.0);
}

// A block's content height, given what its content needs: what its height
// says, between its minimum and maximum. `vt` is its padding and border down,
// which a border-box height includes. Percentage heights wait for a
// containing block of known height, so they count as auto for now.
fn content_height(s: Style, needed: f32, vt: f32) -> f32 {
    let inside: f32 = if s.border_box != 0 { vt } else { 0.0 };
    var h = needed;
    if s.height >= 0.0 { h = s.height - inside; }
    if s.max_height >= 0.0 && h > s.max_height - inside { h = s.max_height - inside; }
    if h < s.min_height - inside { h = s.min_height - inside; }
    return max(h, 0.0);
}

// currentColor, a border's colour unless it has its own, is the text's.
fn border_color(c: u32, s: Style) -> u32 { return if c == CURRENT_COLOR { s.color } else { c }; }

fn rect_item(n: i32, x: f32, y: f32, w: f32, h: f32, color: u32) -> DItem {
    return DItem { kind: ITEM_RECT, x: x, y: y, w: w, h: h, color: color, font: 0, size: 0.0, text: 0, text_len: 0, node: n,
                   rad_tl: 0.0, rad_tr: 0.0, rad_br: 0.0, rad_bl: 0.0, border: 0.0, border_color: 0, border_style: BORDER_SOLID,
                   border_right: 0.0, border_bottom: 0.0, border_left: 0.0,
                   clip_x: 0.0, clip_y: 0.0, clip_w: 0.0, clip_h: 0.0, clip_tl: 0.0, clip_tr: 0.0, clip_br: 0.0, clip_bl: 0.0,
                   m_a: 0.0, m_b: 0.0, m_c: 0.0, m_d: 0.0, m_e: 0.0, m_f: 0.0,
                   c_a: 0.0, c_b: 0.0, c_c: 0.0, c_d: 0.0, c_e: 0.0, c_f: 0.0,
                   oclip_x: 0.0, oclip_y: 0.0, oclip_w: 0.0, oclip_h: 0.0 };
}

fn text_item(n: i32, x: f32, y: f32, w: f32, color: u32, font: i32, size: f32, text: i32, text_len: i32) -> DItem {
    var it = rect_item(n, x, y, w, 0.0, color);
    it.kind = ITEM_TEXT;
    it.font = font;
    it.size = size;
    it.text = text;
    it.text_len = text_len;
    return it;
}

// A box item: a rectangle filled with `fill`, corners rounded by r, and
// borders inside its edge as wide as b says on each side, in one colour.
fn box_item(n: i32, x: f32, y: f32, w: f32, h: f32, fill: u32, r: Radii, b: Sides, border_color: u32, dashed: bool) -> DItem {
    var it = rect_item(n, x, y, w, h, fill);
    it.kind = ITEM_BOX;
    it.rad_tl = r.tl; it.rad_tr = r.tr; it.rad_br = r.br; it.rad_bl = r.bl;
    it.border = b.t;
    it.border_right = b.r;
    it.border_bottom = b.b;
    it.border_left = b.l;
    it.border_color = border_color;
    it.border_style = if dashed { BORDER_DASHED } else { BORDER_SOLID };
    return it;
}

struct Radii { tl: f32, tr: f32, br: f32, bl: f32 }

// Widths on each side: top, right, bottom, left.
struct Sides { t: f32, r: f32, b: f32, l: f32 }

fn even(w: f32) -> Sides { return Sides { t: w, r: w, b: w, l: w }; }

fn any_radius(s: Style) -> bool { return s.rad_tl > 0.0 || s.rad_tr > 0.0 || s.rad_br > 0.0 || s.rad_bl > 0.0; }

// Element n's corner radii on a border box w × h: percentages of its shorter
// side, fitted to the box.
fn radii_of(s: Style, w: f32, h: f32) -> Radii {
    let side = min(w, h);
    var r = Radii { tl: s.rad_tl, tr: s.rad_tr, br: s.rad_br, bl: s.rad_bl };
    if (s.rad_pct & 1) != 0 { r.tl = s.rad_tl / 100.0 * side; }
    if (s.rad_pct & 2) != 0 { r.tr = s.rad_tr / 100.0 * side; }
    if (s.rad_pct & 4) != 0 { r.br = s.rad_br / 100.0 * side; }
    if (s.rad_pct & 8) != 0 { r.bl = s.rad_bl / 100.0 * side; }
    return fit_radii(r, w, h);
}

// Radii scaled down together when two on one side of a box w × h would
// overlap (CSS Backgrounds 3 §5.5).
fn fit_radii(r: Radii, w: f32, h: f32) -> Radii {
    var f: f32 = 1.0;
    if r.tl + r.tr > w { f = min(f, w / (r.tl + r.tr)); }
    if r.bl + r.br > w { f = min(f, w / (r.bl + r.br)); }
    if r.tl + r.bl > h { f = min(f, h / (r.tl + r.bl)); }
    if r.tr + r.br > h { f = min(f, h / (r.tr + r.br)); }
    var out = r;
    if f < 1.0 { out.tl *= f; out.tr *= f; out.br *= f; out.bl *= f; }
    return out;
}

// The radius of a shadow's corner spread by `spread` from a corner of radius
// r (CSS Backgrounds 3 §7.1.1): r plus the spread, but a corner sharper than
// the spread keeps some of its sharpness, and a square one stays square.
fn spread_radius(r: f32, spread: f32) -> f32 {
    let a = abs(spread);
    guard a > 0.0 else { return r; }
    if r >= a { return max(r + spread, 0.0); }
    let k = r / a - 1.0;
    return max(r + spread * (1.0 + k * k * k), 0.0);
}

// A shadow's radii, spread from a box's and fitted to its own size w × h.
fn shadow_radii(r: Radii, spread: f32, w: f32, h: f32) -> Radii {
    return fit_radii(Radii { tl: spread_radius(r.tl, spread), tr: spread_radius(r.tr, spread),
                             br: spread_radius(r.br, spread), bl: spread_radius(r.bl, spread) }, w, h);
}

// The radii of the padding box: each corner's less its wider border.
fn inner_radii(r: Radii, s: Style) -> Radii {
    return Radii { tl: max(r.tl - max(s.bt, s.bl), 0.0), tr: max(r.tr - max(s.bt, s.br), 0.0),
                   br: max(r.br - max(s.bb, s.br), 0.0), bl: max(r.bl - max(s.bb, s.bl), 0.0) };
}

// Side k's border (0 top, 1 right, 2 bottom, 3 left): its width, colour and style.
fn side_border(s: Style, k: i64) -> f32, u32, i32 {
    if k == 0 { return s.bt, border_color(s.bt_color, s), s.bt_style; }
    if k == 1 { return s.br, border_color(s.br_color, s), s.br_style; }
    if k == 2 { return s.bb, border_color(s.bb_color, s), s.bb_style; }
    return s.bl, border_color(s.bl_color, s), s.bl_style;
}

// Whether one box item draws the background with the borders: the box is
// rounded or a border dashed, and the sides that have a border share its
// colour and style (their widths may differ). Otherwise the background is
// one item (a box if rounded) and each border a rect.
fn one_box(s: Style) -> bool {
    var color: u32 = 0;
    var style: i32 = -1;
    var any = false;
    var dashed = false;
    for k in 4 {
        let w, c, st = side_border(s, k);
        guard w > 0.0 else { continue; }
        if !any { color = c; style = st; any = true; }
        else if c != color || st != style { return false; }
        if st == K_DASHED { dashed = true; }
    }
    return any && (any_radius(s) || dashed);
}

// What one_box's borders share: their colour, and whether they are dashed.
fn shared_border(s: Style) -> u32, bool {
    for k in 4 {
        let w, c, st = side_border(s, k);
        if w > 0.0 { return c, st == K_DASHED; }
    }
    return 0, false;
}

// How many items box_paint writes for a block styled s: known before its
// height is, so they can be reserved under its content.
fn box_paint_count(s: Style) -> i64 {
    var n: i64 = 0;
    let hides = (s.bg >> 24) == 255 || any_radius(s);
    for k in s.shadow_count {
        let sd = s.shadows[k];
        guard sd.blur == 0.0 else { continue; }
        let still = sd.ox == 0.0 && sd.oy == 0.0;
        if sd.inset == 0 {
            if still || hides { n += 1; }
            else {
                if sd.oy - sd.spread < 0.0 { n += 1; }
                if sd.oy + sd.spread > 0.0 { n += 1; }
                if sd.ox - sd.spread < 0.0 { n += 1; }
                if sd.ox + sd.spread > 0.0 { n += 1; }
            }
        }
        else if still { n += 1; }
        else {
            if sd.oy + sd.spread > 0.0 { n += 1; }
            if sd.spread - sd.oy > 0.0 { n += 1; }
            if sd.ox + sd.spread > 0.0 { n += 1; }
            if sd.spread - sd.ox > 0.0 { n += 1; }
        }
    }
    let bg = (s.bg >> 24) != 0;
    if one_box(s) { return n + 1; }
    if bg { n += 1; }
    if s.bt > 0.0 && (border_color(s.bt_color, s) >> 24) != 0 { n += 1; }
    if s.br > 0.0 && (border_color(s.br_color, s) >> 24) != 0 { n += 1; }
    if s.bb > 0.0 && (border_color(s.bb_color, s) >> 24) != 0 { n += 1; }
    if s.bl > 0.0 && (border_color(s.bl_color, s) >> 24) != 0 { n += 1; }
    return n;
}

// Writes block n's shadows, background and borders into the items reserved at
// `at` (box_paint_count of them), now that its border box (x, y, w, h) is
// known: outset shadows, then the background and borders, then inset shadows,
// as CSS paints them, all under the content; of several shadows the first is
// on top. Blurred shadows aren't drawn. An offset shadow shows only outside
// the box: one item when the box's background hides the rest (or the box is
// rounded, which it then doesn't always), else strips round it. Inset
// shadows with an offset are straight bars, their corners left square.
fn box_paint(L: Layout, n: i32, s: Style, at: i64, x: f32, y: f32, w: f32, h: f32) {
    var k = at;
    let r = radii_of(s, w, h);
    let rounded = any_radius(s);
    let hides = (s.bg >> 24) == 255 || rounded;
    for j in s.shadow_count {
        let sd = s.shadows[s.shadow_count - 1 - j];
        guard sd.blur == 0.0 && sd.inset == 0 else { continue; }
        let sx = x + sd.ox - sd.spread;
        let sy = y + sd.oy - sd.spread;
        let sw = w + 2.0 * sd.spread;
        let sh = h + 2.0 * sd.spread;
        let sr = shadow_radii(r, sd.spread, sw, sh);
        if sd.ox == 0.0 && sd.oy == 0.0 {
            // A ring round the box, so a box without a background shows through.
            L.items[k] = box_item(n, sx, sy, sw, sh, 0, sr, even(max(sd.spread, 0.0)), sd.color, false);
            k += 1;
        } else if hides {
            L.items[k] = box_item(n, sx, sy, sw, sh, sd.color, sr, even(0.0), 0, false);
            k += 1;
        } else {
            let top = min(y, sy + sh);
            let bottom = max(y + h, sy);
            let my0 = max(sy, y);
            let my1 = min(sy + sh, y + h);
            if sd.oy - sd.spread < 0.0 { L.items[k] = rect_item(n, sx, sy, sw, top - sy, sd.color); k += 1; }
            if sd.oy + sd.spread > 0.0 { L.items[k] = rect_item(n, sx, bottom, sw, sy + sh - bottom, sd.color); k += 1; }
            if sd.ox - sd.spread < 0.0 { L.items[k] = rect_item(n, sx, my0, min(x, sx + sw) - sx, my1 - my0, sd.color); k += 1; }
            if sd.ox + sd.spread > 0.0 {
                let rx = max(x + w, sx);
                L.items[k] = rect_item(n, rx, my0, sx + sw - rx, my1 - my0, sd.color);
                k += 1;
            }
        }
    }
    if one_box(s) {
        let c, dashed = shared_border(s);
        L.items[k] = box_item(n, x, y, w, h, s.bg, r, Sides { t: s.bt, r: s.br, b: s.bb, l: s.bl }, c, dashed);
        k += 1;
    } else if (s.bg >> 24) != 0 {
        L.items[k] = if rounded { box_item(n, x, y, w, h, s.bg, r, even(0.0), 0, false) } else { rect_item(n, x, y, w, h, s.bg) };
        k += 1;
    }
    // The padding box, where inset shadows go.
    let px = x + s.bl;
    let py = y + s.bt;
    let pw = max(w - s.bl - s.br, 0.0);
    let ph = max(h - s.bt - s.bb, 0.0);
    for j in s.shadow_count {
        let sd = s.shadows[s.shadow_count - 1 - j];
        guard sd.blur == 0.0 && sd.inset != 0 else { continue; }
        if sd.ox == 0.0 && sd.oy == 0.0 {
            L.items[k] = box_item(n, px, py, pw, ph, 0, inner_radii(r, s), even(max(sd.spread, 0.0)), sd.color, false);
            k += 1;
            continue;
        }
        let top = sd.oy + sd.spread;
        let bottom = sd.spread - sd.oy;
        let left = sd.ox + sd.spread;
        let right = sd.spread - sd.ox;
        let t = clamp(top, 0.0, ph);
        let b = clamp(bottom, 0.0, ph - t);
        if top > 0.0 { L.items[k] = rect_item(n, px, py, pw, t, sd.color); k += 1; }
        if bottom > 0.0 { L.items[k] = rect_item(n, px, py + ph - b, pw, b, sd.color); k += 1; }
        if left > 0.0 { L.items[k] = rect_item(n, px, py + t, min(left, pw), ph - t - b, sd.color); k += 1; }
        if right > 0.0 { L.items[k] = rect_item(n, px + pw - min(right, pw), py + t, min(right, pw), ph - t - b, sd.color); k += 1; }
    }
    if !one_box(s) {
        let top = border_color(s.bt_color, s);
        let right = border_color(s.br_color, s);
        let bottom = border_color(s.bb_color, s);
        let left = border_color(s.bl_color, s);
        if s.bt > 0.0 && (top >> 24) != 0 { L.items[k] = rect_item(n, x, y, w, s.bt, top); k += 1; }
        if s.br > 0.0 && (right >> 24) != 0 { L.items[k] = rect_item(n, x + w - s.br, y + s.bt, s.br, h - s.bt - s.bb, right); k += 1; }
        if s.bb > 0.0 && (bottom >> 24) != 0 { L.items[k] = rect_item(n, x, y + h - s.bb, w, s.bb, bottom); k += 1; }
        if s.bl > 0.0 && (left >> 24) != 0 { L.items[k] = rect_item(n, x, y + s.bt, s.bl, h - s.bt - s.bb, left); k += 1; }
    }
}

// The colour c with its alpha multiplied by a.
fn fade(c: u32, a: f32) -> u32 {
    let alpha = ((c >> 24) * a + 0.5) as u32;
    return (min(alpha, 255) << 24) | (c & 0xFFFFFF);
}

// Lays out n's children from y in a column at x, w wide: blocks stack with
// adjoining margins collapsed, and each run of inline content between them
// becomes lines (an anonymous block). With `absorbed_top`, n has already
// taken its first child's top margin as its own. Returns the height, the first
// baseline (-1 if none) and the last child's bottom margin, which the caller
// places or collapses with n's.
recursive fn layout_children(L: Layout, n: i32, x: f32, y: f32, w: f32, absorbed_top: bool) -> f32, f32, f32 {
    var cy = y;
    var margin: f32 = 0.0;       // the margin below the last block, not yet placed
    var at_top = absorbed_top;   // nothing placed yet whose margin could separate
    var first: f32 = -1.0;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if is_out(L, c) {
            static_position(L, c, x, cy + (if at_top { 0.0 } else { margin }));
            c = L.d.nodes[c].next;
            continue;
        }
        if flow_block(L, c) && is_empty_block(L, c) {
            // Its margins collapse through it into the ones around it; at the
            // top, top_margin has already passed them up to n. It is still laid
            // out, with no height, for its box and for what is out of the flow
            // in it.
            if !at_top { margin = collapse(margin, collapse(L.styles[c].mt, L.styles[c].mb)); }
            let eh, eb, em = layout_block(L, c, x, cy + (if at_top { 0.0 } else { margin }), w);
            c = L.d.nodes[c].next;
            continue;
        }
        if flow_block(L, c) {
            if at_top { at_top = false; }
            else { cy += collapse(margin, top_margin(L, c)); }
            let h, b, mb = layout_block(L, c, x, cy, w);
            if first < 0.0 && b >= 0.0 { first = b; }
            cy += h;
            margin = mb;
            c = L.d.nodes[c].next;
            continue;
        }
        // A run of inline content, up to the next block. A box out of the flow
        // in it stays where the run starts, unless the lines place it.
        var end = c;
        var blank = true;
        while end >= 0 && !flow_block(L, end) {
            if !is_blank(L, end) { blank = false; }
            note_static(L, end, x, cy + (if at_top { 0.0 } else { margin }));
            end = L.d.nodes[end].next;
        }
        if !blank {
            at_top = false;
            let h, b = layout_lines(L, n, c, end, x, cy + margin, w);
            if h > 0.0 {
                cy += margin + h;
                margin = 0.0;
                if first < 0.0 && b >= 0.0 { first = b; }
            }
        }
        c = end;
    }
    return cy - y, first, margin;
}

// ------------------------------------------------------------------ lines

// Lays the inline nodes from `from` up to `to` (a sibling, or -1) into lines
// in the content box of their parent block. Returns the lines' height and the
// first baseline.
fn layout_lines(L: Layout, parent: i32, from: i32, to: i32, x: f32, y: f32, w: f32) -> f32, f32 {
    let s = L.styles[parent];
    // font_index may add a font: take its index before indexing L.fonts.
    let fi = font_index(L, font_of(s), s.font_size);
    let f = L.fonts[fi];
    let half = (line_height(s) - (f.m.ascent + f.m.descent)) / 2.0;
    var line = Line { left: x, width: w, y: y, x: 0.0, first_item: L.items.len,
                      ascent: f.m.ascent + half, descent: f.m.descent + half,
                      strut_ascent: f.m.ascent + half, strut_descent: f.m.descent + half,
                      content: false, space: false, trailing: 0.0, align: s.align, first_baseline: -1.0, ellipsis: -1,
                      soft: true, first_atom: L.atoms.len, atom: false };
    // A block that clips with text-overflow: ellipsis has its "…" as its run.
    if s.ellipsis != 0 && s.clips != 0 && s.display != K_LIST_ITEM { line.ellipsis = L.run_of[parent]; }
    if from == L.d.nodes[parent].first { line.x = s.indent; }
    var c = from;
    while c != to {
        flow_node(L, line, c);
        c = L.d.nodes[c].next;
    }
    close_line(L, line, false);
    return line.y - y, line.first_baseline;
}

recursive fn flow_node(L: Layout, line: Line&, n: i32) {
    let node = L.d.nodes[n];
    if node.kind == NODE_TEXT { flow_text(L, line, n); return; }
    guard node.kind == NODE_ELEMENT && L.styles[n].display != K_NONE;
    if is_out(L, n) { static_position(L, n, line.left + line.x, line.y); return; }
    if is_atomic(L, n) { place_atomic(L, line, n); return; }
    if node_name(L.d, n) == "br" { close_line(L, line, true); return; }
    let s = L.styles[n];
    // A block inside inline content gets lines of its own; its margins and
    // markers wait for block-in-inline splitting.
    let own_lines = flow_block(L, n);
    if own_lines { close_line(L, line, false); }
    let top = line.y;
    line.x += s.ml + s.pl;
    var c = node.first;
    while c >= 0 {
        flow_node(L, line, c);
        c = L.d.nodes[c].next;
    }
    line.x += s.mr + s.pr;
    if own_lines {
        close_line(L, line, false);
        L.boxes[n] = Rect { x: line.left, y: top, w: line.width, h: line.y - top };
    }
}

// Breaks text node n's run into the current line and the lines after it, at
// spaces; a word longer than a whole line breaks between characters. A word
// that runs on into the next text without a space (a link and its comma, a
// word and its citation) moves to the next line whole, and so does text
// that mustn't wrap.
fn flow_text(L: Layout, line: Line&, n: i32) {
    let r = L.run_of[n];
    guard r >= 0;
    let run = L.runs[r];
    let s = L.styles[n];
    let f = L.fonts[run.font];
    let wraps = s.ws == K_NORMAL || s.ws == K_PRE_WRAP;
    let collapsible = s.ws == K_NORMAL || s.ws == K_NOWRAP;
    let half = (line_height(s) - (f.m.ascent + f.m.descent)) / 2.0;
    let raise = raise_of(L, n);
    let above = f.m.ascent + half + raise;
    let below = f.m.descent + half - raise;
    let t = run.start;
    let c = run.caret;
    var i: i32 = 0;
    var piece: i32 = -1;          // where the run's piece on the current line starts
    var piece_x: f32 = 0.0;
    while i < run.len {
        let ch = L.text[t + i];
        if ch == ' ' && collapsible && (!line.content || line.space) {
            i += 1;               // a space at a line's start or after another collapses away
            continue;
        }
        if ch == '\n' {
            if piece >= 0 { emit_text(L, line, run, s, piece, i, piece_x, raise); piece = -1; }
            close_line(L, line, true);
            i += 1;
            continue;
        }
        // The next unit: a word and the spaces after it, or, where lines
        // don't wrap, all of it up to a line break.
        var j = i;
        if wraps { while j < run.len && L.text[t + j] != ' ' && L.text[t + j] != '\n' { j += 1; } }
        else { while j < run.len && L.text[t + j] != '\n' { j += 1; } }
        var word_end = j;
        if wraps { while j < run.len && L.text[t + j] == ' ' { j += 1; } }
        else { while word_end > i && L.text[t + word_end - 1] == ' ' { word_end -= 1; } }
        let own_w = L.carets[c + word_end] - L.carets[c + i];
        let unit_w = own_w + (if word_end == run.len { glued_after(L, n) } else { 0.0 });
        // No break between this run and the text before it without a space, nor
        // where neither may wrap.
        let glued = i == 0 && line.content && ((!line.space && !line.atom) || (!wraps && !line.soft));
        if line.content && !glued && line.x + unit_w > line.width + 0.01 {
            if piece >= 0 { emit_text(L, line, run, s, piece, i, piece_x, raise); piece = -1; }
            close_line(L, line, false);
            continue;
        }
        if wraps && !line.content && word_end > i && line.x + own_w > line.width + 0.01 {
            // Longer than the line: as many characters as fit, at least one.
            var k = next_char(L, t, i, word_end);
            while k < word_end {
                let after = next_char(L, t, k, word_end);
                if line.x + L.carets[c + after] - L.carets[c + i] > line.width { break; }
                k = after;
            }
            place(line, L.carets[c + k] - L.carets[c + i], false, 0.0, above, below);
            emit_text(L, line, run, s, i, k, line.x - (L.carets[c + k] - L.carets[c + i]), raise);
            close_line(L, line, false);
            i = k;
            continue;
        }
        if piece < 0 { piece = i; piece_x = line.x; }
        place(line, L.carets[c + j] - L.carets[c + i], j > word_end, L.carets[c + j] - L.carets[c + word_end], above, below);
        line.soft = wraps;
        line.atom = false;
        i = j;
    }
    if piece >= 0 { emit_text(L, line, run, s, piece, run.len, piece_x, raise); }
}

// How far above its line's baseline text node n sits: the shifts of the
// superscripts and subscripts it is in, up to its block.
fn raise_of(L: Layout, n: i32) -> f32 {
    var raise: f32 = 0.0;
    var e = L.d.nodes[n].parent;
    while e >= 0 && L.d.nodes[e].kind == NODE_ELEMENT && !is_block_level(L, e) && !is_atomic(L, e) {
        let s = L.styles[e];
        if s.valign == K_SUPER { raise += s.font_size * 0.45; }
        else if s.valign == K_SUB { raise -= s.font_size * 0.2; }
        e = L.d.nodes[e].parent;
    }
    return raise;
}

// The width of what follows text node n with no break opportunity between:
// the next text up to its first space, and on through texts with none.
fn glued_after(L: Layout, n: i32) -> f32 {
    var w: f32 = 0.0;
    var m = next_inline_text(L, n);
    while m >= 0 {
        let r = L.run_of[m];
        if r >= 0 {
            let run = L.runs[r];
            let ws = L.styles[m].ws;
            let wraps = ws == K_NORMAL || ws == K_PRE_WRAP;
            var k: i32 = 0;
            while k < run.len && L.text[run.start + k] != '\n' && (!wraps || L.text[run.start + k] != ' ') { k += 1; }
            w += L.carets[run.caret + k] - L.carets[run.caret];
            if k < run.len { return w; }
        }
        m = next_inline_text(L, m);
    }
    return w;
}

// The next text node after n on the same lines, or -1 where a block, a <br>
// or a table cell or list item comes first: those end the line or allow a
// break.
fn next_inline_text(L: Layout, n: i32) -> i32 {
    var at = n;
    var enter = false;
    loop {
        if enter && L.d.nodes[at].first >= 0 {
            at = L.d.nodes[at].first;
        } else {
            while L.d.nodes[at].next < 0 {
                at = L.d.nodes[at].parent;
                guard at >= 0 && L.d.nodes[at].kind == NODE_ELEMENT && !is_block_level(L, at) && !is_atomic(L, at) && !ends_unit(L, at) else { return -1; }
            }
            at = L.d.nodes[at].next;
        }
        let node = L.d.nodes[at];
        if node.kind == NODE_TEXT { return at; }
        enter = node.kind == NODE_ELEMENT && L.styles[at].display != K_NONE;
        guard !enter || (!is_block_level(L, at) && !is_atomic(L, at) && !ends_unit(L, at) && node_name(L.d, at) != "br") else { return -1; }
    }
}

// Cells and list items laid out inline: their edges allow a break.
fn ends_unit(L: Layout, e: i32) -> bool {
    let t = node_name(L.d, e);
    return t == "td" || t == "th" || t == "li";
}

// The index after the character that starts at byte i of a run's text.
fn next_char(L: Layout, t: i32, i: i32, end: i32) -> i32 {
    var k = i + 1;
    while k < end && (L.text[t + k] & 0xC0) == 0x80 { k += 1; }
    return k;
}

fn place(line: Line&, w: f32, space: bool, trailing: f32, above: f32, below: f32) {
    line.x += w;
    line.content = true;
    line.space = space;
    line.trailing = trailing;
    if above > line.ascent { line.ascent = above; }
    if below > line.descent { line.descent = below; }
}

// Paints bytes [from, to) of a run as one text item at x on the current line,
// with its decoration. Until the line closes, y is relative to its baseline.
fn emit_text(L: Layout, line: Line&, run: Run, s: Style, from: i32, to: i32, x: f32, raise: f32) {
    let c = run.caret;
    L.items.push(text_item(run.node, line.left + x, -raise, L.carets[c + to] - L.carets[c + from], s.color, font_of(s),
                           s.font_size, run.start + from, to - from));
    guard s.deco == K_UNDERLINE || s.deco == K_LINE_THROUGH;
    var ink = to;                 // decoration stops at the last visible character
    while ink > from && L.text[run.start + ink - 1] == ' ' { ink -= 1; }
    guard ink > from;
    let m = L.fonts[run.font].m;
    let th = max(m.underline_thickness, 0.5);
    let y = if s.deco == K_UNDERLINE { -m.underline_position } else { -m.x_height / 2.0 - th / 2.0 };
    L.items.push(rect_item(run.node, line.left + x, y - raise, L.carets[c + ink] - L.carets[c + from], th, s.color));
}

// Ends the current line: sets its items on its baseline, aligns them, and
// starts the next line below. An empty line takes no room unless forced (<br>).
fn close_line(L: Layout, line: Line&, forced: bool) {
    if line.content || forced {
        let baseline = line.y + line.ascent;
        var used = line.x - (if line.space { line.trailing } else { 0.0 });
        if line.ellipsis >= 0 && used > line.width + 0.01 { used = ellipsize(L, line); }
        var shift: f32 = 0.0;
        if line.align == K_CENTER { shift = max((line.width - used) / 2.0, 0.0); }
        else if line.align == K_RIGHT { shift = max(line.width - used, 0.0); }
        let height = line.ascent + line.descent;
        for k in line.first_item..L.items.len {
            L.items[k].x += shift;
            L.items[k].y += baseline;
            if L.items[k].kind == ITEM_TEXT {
                grow_box(L, L.items[k].node, Rect { x: L.items[k].x, y: line.y, w: L.items[k].w, h: height });
            }
        }
        for k in line.first_atom..L.atoms.len { shift_boxes(L, L.atoms[k], shift, baseline); }
        if line.first_baseline < 0.0 { line.first_baseline = baseline; }
        line.y += height;
    }
    L.atoms.resize(line.first_atom);
    line.atom = false;
    line.x = 0.0;
    line.ascent = line.strut_ascent;
    line.descent = line.strut_descent;
    line.first_item = L.items.len;
    line.content = false;
    line.space = false;
    line.trailing = 0.0;
}

// Cuts a line that runs past the end of its box so that it ends in "…" (CSS
// text-overflow): the text up to the last character that fits with the
// ellipsis after it; what is past that is dropped. Returns the line's new
// width. Its items are still relative to its baseline, x from the page.
fn ellipsize(L: Layout, line: Line&) -> f32 {
    let er = L.runs[line.ellipsis];
    let ew = L.carets[er.caret + er.len] - L.carets[er.caret];
    let limit = line.left + max(line.width - ew, 0.0);
    var end_x = line.left;
    var cut = false;
    var cut_node: i32 = -1;     // the text cut short, whose decoration follows it
    var cut_x: f32 = 0.0;
    var cut_w: f32 = 0.0;
    for k in line.first_item..L.items.len {
        let it = L.items[k];
        if cut {
            if it.kind == ITEM_RECT && it.node == cut_node && it.x == cut_x { L.items[k].w = min(it.w, cut_w); }
            else { L.items[k].kind = ITEM_NONE; }
            continue;
        }
        if it.x + it.w <= limit + 0.01 { end_x = max(end_x, it.x + it.w); continue; }
        cut = true;
        L.items[k].kind = ITEM_NONE;
        guard it.kind == ITEM_TEXT && L.run_of[it.node] >= 0 else { continue; }
        // The characters that fit, without the spaces they end in.
        let run = L.runs[L.run_of[it.node]];
        let from = it.text - run.start;
        let to = from + it.text_len;
        var end = from;
        while end < to {
            let next = next_char(L, run.start, end, to);
            if it.x + L.carets[run.caret + next] - L.carets[run.caret + from] > limit + 0.01 { break; }
            end = next;
        }
        while end > from && L.text[run.start + end - 1] == ' ' { end -= 1; }
        guard end > from else { continue; }
        L.items[k].kind = ITEM_TEXT;
        L.items[k].text_len = end - from;
        L.items[k].w = L.carets[run.caret + end] - L.carets[run.caret + from];
        cut_node = it.node;
        cut_x = it.x;
        cut_w = L.items[k].w;
        end_x = max(end_x, it.x + cut_w);
    }
    let s = L.styles[er.node];
    L.items.push(text_item(er.node, end_x, 0.0, ew, s.color, font_of(s), s.font_size, er.start, er.len));
    return end_x + ew - line.left;
}

// Sets inline-block or inline-flex n on the line as one piece: laid out as a
// block as wide as it says, else as its content needs within the line, with
// its first baseline on the line's (its bottom margin edge when it has no
// lines). It moves to the next line when it doesn't fit and its white-space
// wraps, and a line may break after it. Its items wait on the line, relative
// to its baseline like text, and its boxes go on L.atoms until close_line
// moves them too.
recursive fn place_atomic(L: Layout, line: Line&, n: i32) {
    let s = L.styles[n];
    let hz = s.bl + s.pl + s.pr + s.br;
    let inside: f32 = if s.border_box != 0 { hz } else { 0.0 };
    var w: f32 = 0.0;
    if s.width >= 0.0 { w = s.width - inside; }
    else if s.width_pct >= 0.0 { w = line.width * s.width_pct / 100.0 - inside; }
    else {
        let least, most = content_widths(L, n);
        w = min(max(least, line.width - s.ml - s.mr), most) - hz;
    }
    if s.max_width >= 0.0 { w = min(w, s.max_width - inside); }
    else if s.max_width_pct >= 0.0 { w = min(w, line.width * s.max_width_pct / 100.0 - inside); }
    w = max(max(w, (if s.min_width_pct >= 0.0 { line.width * s.min_width_pct / 100.0 } else { s.min_width }) - inside), 0.0);
    let outer = s.ml + w + hz + s.mr;
    let wraps = s.ws == K_NORMAL || s.ws == K_PRE_WRAP;
    if wraps && line.content && line.x + outer > line.width + 0.01 { close_line(L, line, false); }
    let from = L.items.len;
    let lo, hi = height_limits(s);
    let bh, b = layout_sized(L, n, line.left + line.x + s.ml, 0.0, w, -1.0, lo, hi);
    let base = if b >= 0.0 { b } else { bh + s.mb };
    for k in from..L.items.len { L.items[k].y -= base; }
    shift_boxes(L, n, 0.0, -base);
    L.atoms.push(n);
    place(line, outer, false, 0.0, base + s.mt, bh - base + s.mb);
    line.soft = wraps;
    line.atom = true;
}

// A list item's marker, outside its content box, on its first line.
fn paint_marker(L: Layout, li: i32, content_x: f32, baseline: f32) {
    let r = L.run_of[li];
    guard r >= 0 && baseline >= 0.0;
    let run = L.runs[r];
    let s = L.styles[li];
    let w = L.carets[run.caret + run.len] - L.carets[run.caret];
    L.items.push(text_item(li, content_x - w - s.font_size * 0.45, baseline, w, s.color, font_of(s), s.font_size,
                           run.start, run.len));
}

fn union(a: Rect, b: Rect) -> Rect {
    if a.w == 0.0 && a.h == 0.0 { return b; }
    if b.w == 0.0 && b.h == 0.0 { return a; }
    let x0 = min(a.x, b.x);
    let y0 = min(a.y, b.y);
    return Rect { x: x0, y: y0, w: max(a.x + a.w, b.x + b.w) - x0, h: max(a.y + a.h, b.y + b.h) - y0 };
}

// The union of two boxes on the first line either is on. A text or inline
// element that wraps is given the box of its first line only: the box of
// all its lines would also cover other text, and its middle could be on
// another link.
fn first_line(a: Rect, b: Rect) -> Rect {
    if a.w == 0.0 && a.h == 0.0 { return b; }
    if b.w == 0.0 && b.h == 0.0 { return a; }
    if b.y > a.y + 0.01 { return a; }
    if a.y > b.y + 0.01 { return b; }
    return union(a, b);
}

fn grow_box(L: Layout, n: i32, r: Rect) { L.boxes[n] = first_line(L.boxes[n], r); }

// An inline element's box is the first line of what it contains.
recursive fn inline_boxes(L: Layout, n: i32) -> Rect {
    var b = L.boxes[n];
    let inline = L.d.nodes[n].kind == NODE_ELEMENT && !is_block_level(L, n) && !is_atomic(L, n) && L.styles[n].display != K_NONE;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        let cb = inline_boxes(L, c);
        if inline { b = first_line(b, cb); }
        c = L.d.nodes[c].next;
    }
    L.boxes[n] = b;
    return b;
}

// ------------------------------------------------------------------ positioned boxes

// Notes (x, y) as the static position of n if it is out of the flow, else of
// those out of the flow in it, until lines place them better.
recursive fn note_static(L: Layout, n: i32, x: f32, y: f32) {
    guard L.d.nodes[n].kind == NODE_ELEMENT && L.styles[n].display != K_NONE;
    if is_out(L, n) {
        static_position(L, n, x, y);
        return;
    }
    var c = L.d.nodes[n].first;
    while c >= 0 {
        note_static(L, c, x, y);
        c = L.d.nodes[c].next;
    }
}

// Notes where out-of-flow element n would have gone in the flow (its static
// position), for place_box: in its box, which has no size yet.
fn static_position(L: Layout, n: i32, x: f32, y: f32) { L.boxes[n] = Rect { x: x, y: y, w: 0.0, h: 0.0 }; }

// Lays out the absolute and fixed elements under n in document order, so
// that one is placed before those inside it, whose containing block it may be.
recursive fn place_positioned(L: Layout, n: i32, width: f32, height: f32) {
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if L.d.nodes[c].kind == NODE_ELEMENT && L.styles[c].display != K_NONE {
            if is_out(L, c) { place_box(L, c, width, height); }
            place_positioned(L, c, width, height);
        }
        c = L.d.nodes[c].next;
    }
}

// Lays out out-of-flow element e against its containing block (CSS 2.2
// §10.3.7, §10.6.4). The insets it has place it; with neither of a pair it
// stays where it would have been in the flow. An auto width stretches between
// two insets, else shrinks to fit its content; an auto height is its
// content's, unless top and bottom stretch it, and a box hung from its bottom
// moves up once its height is known. layout_block lays it out with its style
// briefly saying the width and height worked out here.
fn place_box(L: Layout, e: i32, vw: f32, vh: f32) {
    let s = L.styles[e];
    let cb = containing_block(L, e, vw, vh);
    let stat = L.boxes[e];
    let auto_t = (s.inset_auto & 1) != 0;
    let auto_r = (s.inset_auto & 2) != 0;
    let auto_b = (s.inset_auto & 4) != 0;
    let auto_l = (s.inset_auto & 8) != 0;
    let top = inset_px(s.top, (s.inset_pct & 1) != 0, cb.h);
    let right = inset_px(s.right, (s.inset_pct & 2) != 0, cb.w);
    let bottom = inset_px(s.bottom, (s.inset_pct & 4) != 0, cb.h);
    let left = inset_px(s.left, (s.inset_pct & 8) != 0, cb.w);
    let hz = s.bl + s.pl + s.pr + s.br;
    let vt = s.bt + s.pt + s.pb + s.bb;
    let inside_w: f32 = if s.border_box != 0 { hz } else { 0.0 };
    let inside_h: f32 = if s.border_box != 0 { vt } else { 0.0 };

    // Across: its width; with none, stretched between two insets, else shrunk
    // to fit the room from its left inset (or where it would have been) to the
    // far side. Then its limits.
    var w: f32 = 0.0;
    if s.width >= 0.0 { w = s.width - inside_w; }
    else if s.width_pct >= 0.0 { w = cb.w * s.width_pct / 100.0 - inside_w; }
    else if !auto_l && !auto_r { w = cb.w - left - right - s.ml - s.mr - hz; }
    else {
        let from = if !auto_l { left } else if auto_r { stat.x - cb.x } else { 0.0 };
        let room = cb.w - from - (if auto_r { 0.0 } else { right }) - s.ml - s.mr;
        let least, most = content_widths(L, e);
        w = min(max(least, room), most) - hz;
    }
    if s.max_width >= 0.0 { w = min(w, s.max_width - inside_w); }
    else if s.max_width_pct >= 0.0 { w = min(w, cb.w * s.max_width_pct / 100.0 - inside_w); }
    w = max(max(w, (if s.min_width_pct >= 0.0 { cb.w * s.min_width_pct / 100.0 } else { s.min_width }) - inside_w), 0.0);
    // Room left between two insets goes to auto margins; two centre it.
    var ml = s.ml;
    if !auto_l && !auto_r {
        let free = cb.w - left - right - s.ml - s.mr - w - hz;
        if s.auto_ml != 0 && s.auto_mr != 0 { ml = max(free / 2.0, 0.0); }
        else if s.auto_ml != 0 { ml = free; }
    }
    var x = stat.x + ml;
    if !auto_l { x = cb.x + left + ml; }
    else if !auto_r { x = cb.x + cb.w - right - s.mr - w - hz; }

    // Down: its height, or stretched between top and bottom, within limits
    // that may be percentages of the containing block's height; else its
    // content's. Auto margins share what is left.
    var h: f32 = -1.0;
    if s.height >= 0.0 { h = s.height - inside_h; }
    else if s.height_pct >= 0.0 { h = cb.h * s.height_pct / 100.0 - inside_h; }
    else if !auto_t && !auto_b { h = cb.h - top - bottom - s.mt - s.mb - vt; }
    let max_h = if s.max_height >= 0.0 { s.max_height - inside_h }
                else if s.max_height_pct >= 0.0 { cb.h * s.max_height_pct / 100.0 - inside_h } else { -1.0 };
    let min_h = max((if s.min_height_pct >= 0.0 { cb.h * s.min_height_pct / 100.0 } else { s.min_height }) - inside_h, 0.0);
    if h >= 0.0 {
        if max_h >= 0.0 { h = min(h, max_h); }
        h = max(h, min_h);
    }
    var mt = s.mt;
    if h >= 0.0 && !auto_t && !auto_b {
        let free = cb.h - top - bottom - s.mt - s.mb - h - vt;
        if s.auto_mt != 0 && s.auto_mb != 0 { mt = free / 2.0; }
        else if s.auto_mt != 0 { mt = free; }
    }
    let y = if auto_t { stat.y + mt } else { cb.y + top + mt };

    let from = L.items.len;
    let bh, base = layout_sized(L, e, x, y, w, h, min_h, max_h);
    if auto_t && !auto_b {
        let dy = cb.y + cb.h - bottom - s.mb - bh - y;
        for k in from..L.items.len { L.items[k].y += dy; }
        shift_boxes(L, e, 0.0, dy);
    }
    inline_boxes(L, e);
}

// Lays out element c as a block whose border box starts at (x, y), its
// content `w` wide and `h` high, with its style briefly saying so. With h
// -1 it is as high as its own height says, else as its content needs; with
// -2 as its content needs, whatever its height says; either way between `lo`
// and `hi` (content box; hi -1: no limit). Returns its border-box height
// and its first baseline (-1 if none).
recursive fn layout_sized(L: Layout, c: i32, x: f32, y: f32, w: f32, h: f32, lo: f32, hi: f32) -> f32, f32 {
    let s = L.styles[c];
    let vt = s.bt + s.pt + s.pb + s.bb;
    var o = s;
    o.width = w; o.width_pct = -1.0; o.min_width = 0.0; o.min_width_pct = -1.0; o.max_width = -1.0; o.max_width_pct = -1.0;
    o.ml = 0.0; o.mr = 0.0; o.auto_ml = 0; o.auto_mr = 0; o.border_box = 0;
    if h >= 0.0 { o.height = h; }
    else if h == -1.0 && s.height >= 0.0 { o.height = max(s.height - (if s.border_box != 0 { vt } else { 0.0 }), 0.0); }
    else { o.height = -1.0; }
    o.height_pct = -1.0;
    o.min_height = if h >= 0.0 { 0.0 } else { max(lo, 0.0) };
    o.max_height = if h >= 0.0 { -1.0 } else { hi };
    o.min_height_pct = -1.0;
    o.max_height_pct = -1.0;
    L.styles[c] = o;
    let bh, base, mb = layout_block(L, c, x, y, w + s.bl + s.pl + s.pr + s.br);
    L.styles[c] = s;
    return bh, base;
}

// Element s's own min-height and max-height, content box (max -1: none).
fn height_limits(s: Style) -> f32, f32 {
    let inside: f32 = if s.border_box != 0 { s.bt + s.pt + s.pb + s.bb } else { 0.0 };
    return max(s.min_height - inside, 0.0), if s.max_height >= 0.0 { max(s.max_height - inside, 0.0) } else { -1.0 };
}

// What out-of-flow element e is placed against: the padding box of its
// containing element, or the first screen when there is none.
fn containing_block(L: Layout, e: i32, vw: f32, vh: f32) -> Rect {
    let a = containing_element(L, e);
    guard a > 0 else { return Rect { x: 0.0, y: 0.0, w: vw, h: vh }; }
    let s = L.styles[a];
    let b = L.boxes[a];
    return Rect { x: b.x + s.bl, y: b.y + s.bt, w: max(b.w - s.bl - s.br, 0.0), h: max(b.h - s.bt - s.bb, 0.0) };
}

// The element out-of-flow element e is placed against, or 0 for the first
// screen: an absolute box's nearest positioned or transformed element, a
// fixed box's nearest transformed one.
fn containing_element(L: Layout, e: i32) -> i32 {
    let fixed = L.styles[e].position == K_FIXED;
    var a = L.d.nodes[e].parent;
    while a > 0 && !transforms(L, a) && (fixed || L.styles[a].position == K_STATIC) { a = L.d.nodes[a].parent; }
    return max(a, 0);
}

fn inset_px(v: f32, pct: bool, base: f32) -> f32 { return if pct { v / 100.0 * base } else { v }; }

// Moves the boxes of n and everything in it by (dx, dy).
recursive fn shift_boxes(L: Layout, n: i32, dx: f32, dy: f32) {
    L.boxes[n].x += dx;
    L.boxes[n].y += dy;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        shift_boxes(L, c, dx, dy);
        c = L.d.nodes[c].next;
    }
}

// The lowest bottom edge of an absolute box that nothing clips, which the
// page must reach down to.
fn positioned_bottom(L: Layout) -> f32 {
    var bottom: f32 = 0.0;
    for n in L.d.nodes.len {
        guard L.d.nodes[n].kind == NODE_ELEMENT && L.styles[n].position == K_ABSOLUTE && L.boxes[n].h > 0.0 else { continue; }
        if !is_clipped(L, n as i32) { bottom = max(bottom, L.boxes[n].y + L.boxes[n].h); }
    }
    return bottom;
}

// Whether an element that clips cuts element n, through the elements its
// containing blocks are, as clip_items walks them.
fn is_clipped(L: Layout, n: i32) -> bool {
    var e = n;
    loop {
        let up = clip_parent(L, e);
        if up <= 0 { return false; }
        if clips_content(L, up) { return true; }
        e = up;
    }
}

// The next element up whose overflow could cut node e: its parent, or an
// out-of-flow box's containing element (none, 0, for the first screen).
fn clip_parent(L: Layout, e: i32) -> i32 {
    if is_out(L, e) { return containing_element(L, e); }
    return L.d.nodes[e].parent;
}

// Whether element n cuts what is in it: its overflow isn't visible, and it
// holds blocks (overflow doesn't apply to inline boxes).
fn clips_content(L: Layout, n: i32) -> bool {
    return L.styles[n].clips != 0 && L.styles[n].display != K_INLINE;
}

// Moves each relatively positioned element, and everything in it, by its
// offsets (CSS 2.2 §9.4.3): the items they paint and their boxes.
fn shift_relative(L: Layout) {
    for k in L.items.len {
        let n = L.items[k].node;
        guard n >= 0 else { continue; }
        let dx, dy = relative_offset(L, n);
        L.items[k].x += dx;
        L.items[k].y += dy;
    }
    for n in L.boxes.len {
        let dx, dy = relative_offset(L, n as i32);
        L.boxes[n].x += dx;
        L.boxes[n].y += dy;
    }
}

// How far the relatively positioned elements around node n, and n itself,
// move it: their left (else minus their right) and top (else minus their
// bottom), percentages of their parent's content box. A fixed box inside one
// moves only with those around its containing element, when a transformed
// one is it.
fn relative_offset(L: Layout, n: i32) -> f32, f32 {
    var dx: f32 = 0.0;
    var dy: f32 = 0.0;
    var e = n;
    while e > 0 {
        if L.d.nodes[e].kind == NODE_ELEMENT {
            let s = L.styles[e];
            if s.position == K_FIXED {
                e = containing_element(L, e);
                continue;
            }
            if s.position == K_RELATIVE {
                let p = L.d.nodes[e].parent;
                let ps = L.styles[p];
                let pb = L.boxes[p];
                let cw = max(pb.w - ps.bl - ps.pl - ps.pr - ps.br, 0.0);
                let ch = max(pb.h - ps.bt - ps.pt - ps.pb - ps.bb, 0.0);
                if (s.inset_auto & 8) == 0 { dx += inset_px(s.left, (s.inset_pct & 8) != 0, cw); }
                else if (s.inset_auto & 2) == 0 { dx -= inset_px(s.right, (s.inset_pct & 2) != 0, cw); }
                if (s.inset_auto & 1) == 0 { dy += inset_px(s.top, (s.inset_pct & 1) != 0, ch); }
                else if (s.inset_auto & 4) == 0 { dy -= inset_px(s.bottom, (s.inset_pct & 4) != 0, ch); }
            }
        }
        e = L.d.nodes[e].parent;
    }
    return dx, dy;
}

// ------------------------------------------------------------------ content widths

// What a box's content needs across, gathered child by child: `min`, its
// widest piece that can't break (a word, or a line that mustn't wrap), and
// `max`, its longest line when only forced breaks break it. `line` and
// `word` are the line and the word being added up, `space` the spaces
// waiting after it, and `start` that the line has nothing yet.
struct Widths { min: f32, max: f32, line: f32, word: f32, space: f32, start: bool }

// Element n's border box across at its min-content and max-content widths
// (CSS Sizing 3), for shrink-to-fit: its width if it has one, else what its
// content needs, within its min-width and max-width.
recursive fn content_widths(L: Layout, n: i32) -> f32, f32 {
    let s = L.styles[n];
    let hz = s.bl + s.pl + s.pr + s.br;
    let inside: f32 = if s.border_box != 0 { 0.0 } else { hz };
    if s.width >= 0.0 {
        let w = s.width + inside;
        return w, w;
    }
    var least, most = inner_widths(L, n);
    if s.max_width >= 0.0 {
        least = min(least, s.max_width + inside);
        most = min(most, s.max_width + inside);
    }
    least = max(least, s.min_width + inside);
    most = max(most, s.min_width + inside);
    return least, most;
}

// Element n's border box across at the min-content and max-content widths
// of what is in it, whatever width it says it has.
recursive fn inner_widths(L: Layout, n: i32) -> f32, f32 {
    let s = L.styles[n];
    let hz = s.bl + s.pl + s.pr + s.br;
    var p = Widths { min: 0.0, max: 0.0, line: 0.0, word: 0.0, space: 0.0, start: true };
    if is_flex(L, n) {
        flex_widths(L, n, p);
    } else {
        var c = L.d.nodes[n].first;
        while c >= 0 {
            add_widths(L, c, p);
            c = L.d.nodes[c].next;
        }
        end_widths(p);
    }
    return p.min + hz, p.max + hz;
}

// Adds node n to the widths being gathered: text word by word, inline
// elements with their margins and padding, and a block on lines of its own.
recursive fn add_widths(L: Layout, n: i32, p: Widths&) {
    let node = L.d.nodes[n];
    if node.kind == NODE_TEXT {
        let r = L.run_of[n];
        guard r >= 0 else { return; }
        let run = L.runs[r];
        let ws = L.styles[n].ws;
        let wraps = ws == K_NORMAL || ws == K_PRE_WRAP;
        let collapsible = ws == K_NORMAL || ws == K_NOWRAP;
        let t = run.start;
        let c = run.caret;
        var i: i32 = 0;
        while i < run.len {
            let ch = L.text[t + i];
            if ch == '\n' { end_widths(p); i += 1; continue; }
            var j = i + 1;
            if ch == ' ' {
                while j < run.len && L.text[t + j] == ' ' { j += 1; }
                if !(collapsible && p.start) {
                    if wraps { p.min = max(p.min, p.word); p.word = 0.0; }
                    p.space += L.carets[c + j] - L.carets[c + i];
                }
            } else {
                while j < run.len && L.text[t + j] != ' ' && L.text[t + j] != '\n' { j += 1; }
                let w = L.carets[c + j] - L.carets[c + i];
                p.line += p.space + w;
                p.word += (if wraps { 0.0 } else { p.space }) + w;
                p.space = 0.0;
                p.start = false;
            }
            i = j;
        }
        return;
    }
    guard node.kind == NODE_ELEMENT && L.styles[n].display != K_NONE && !is_out(L, n);
    if node_name(L.d, n) == "br" { end_widths(p); return; }
    let s = L.styles[n];
    if is_atomic(L, n) {
        // One piece, with a chance to break on either side.
        let least, most = content_widths(L, n);
        p.min = max(max(p.min, p.word), least + s.ml + s.mr);
        p.word = 0.0;
        p.line += p.space + most + s.ml + s.mr;
        p.space = 0.0;
        p.start = false;
        return;
    }
    if flow_block(L, n) {
        end_widths(p);
        let least, most = content_widths(L, n);
        let m = s.ml + s.mr;
        p.min = max(p.min, least + m);
        p.max = max(p.max, most + m);
        return;
    }
    let before = s.ml + s.pl;
    p.line += p.space + before;
    p.word += before;
    p.space = 0.0;
    var c = node.first;
    while c >= 0 {
        add_widths(L, c, p);
        c = L.d.nodes[c].next;
    }
    p.line += s.mr + s.pr;
    p.word += s.mr + s.pr;
}

// Ends the line being added up: spaces at its end take no room.
fn end_widths(p: Widths&) {
    p.max = max(p.max, p.line);
    p.min = max(p.min, p.word);
    p.line = 0.0;
    p.word = 0.0;
    p.space = 0.0;
    p.start = true;
}

// ------------------------------------------------------------------ paint order

// Each node's items, found through the items sorted by node, and the order
// being built (CSS 2.2 Appendix E, in short). `scratch` holds the positioned
// elements of the stacking contexts being painted, one above another.
struct Paint { first: i32[>..]&, count: i32[>..]&, by_node: i32[>..]&, order: i32[>..]&, scratch: i32[>..<]& }

// Puts the items in paint order. In each stacking context: its own
// background and borders, then the contexts in it with a negative z-index,
// then the content that isn't positioned, then the positioned elements with
// z-index auto or 0, then those with a positive one; document order among
// equals. A positioned element with a z-index, and a fixed one, start a
// stacking context; one with z-index auto paints its own content at its
// place, while what is positioned inside it joins the context around it.
// Opacity doesn't start one here (each item is faded on its own).
fn stack(L: Layout) {
    var first: i32[>..] = [];
    var count: i32[>..] = [];
    for n in L.d.nodes.len { first.push(0); count.push(0); }
    for it in L.items { if it.node >= 0 { count[it.node] += 1; } }
    var at: i32 = 0;
    for n in L.d.nodes.len {
        first[n] = at;
        at += count[n];
    }
    var by_node: i32[>..] = [];
    var next: i32[>..] = [];
    for n in L.d.nodes.len { next.push(first[n]); }
    for k in at { by_node.push(0); }
    for it, k in L.items {
        guard it.node >= 0 else { continue; }
        by_node[next[it.node]] = k as i32;
        next[it.node] += 1;
    }
    var order: i32[>..] = [];
    var scratch: i32[>..<] = [];
    let P = Paint { first: first, count: count, by_node: by_node, order: order, scratch: scratch };
    paint_context(L, P, 0);
    // Items the walk didn't reach (none should be) keep their order, last.
    var placed: bool[>..] = [];
    for k in L.items.len { placed.push(false); }
    for k in order { placed[k] = true; }
    for k in L.items.len { if !placed[k] { order.push(k as i32); } }
    var sorted: DItem[>..] = [];
    for k in order { sorted.push(L.items[k]); }
    for it, k in sorted { L.items[k] = it; }
}

// An element's z-index, which only positioned boxes and flex items have (CSS
// 2.2 §9.9.1, Flexbox 1 §4.3): 0 for the others, and for auto.
fn z_index(L: Layout, e: i32) -> i32 {
    let p = L.d.nodes[e].parent;
    if L.styles[e].position != K_STATIC || (p >= 0 && is_flex(L, p)) { return L.styles[e].z; }
    return 0;
}

// Whether a styled element starts a stacking context of its own: a
// positioned one with a z-index, a fixed one, and a transformed one.
fn stacks(s: Style) -> bool {
    return s.position == K_FIXED || (s.position != K_STATIC && s.z_auto == 0) || (s.xf_count > 0 && s.display != K_INLINE);
}

fn emit_own(P: Paint, n: i32) {
    for k in P.first[n]..P.first[n] + P.count[n] { P.order.push(P.by_node[k]); }
}

// Paints the stacking context of n, the document or an element that starts one.
recursive fn paint_context(L: Layout, P: Paint, n: i32) {
    emit_own(P, n);
    let mark = P.scratch.len;
    gather(L, P, n);
    let end = P.scratch.len;
    // Its stacking contexts again, above, sorted by z-index.
    for i in mark..end { if stacks(L.styles[P.scratch[i]]) { P.scratch.push(P.scratch[i]); } }
    let sorted = P.scratch.len;
    sort_by_z(L, P, end, sorted);
    for i in end..sorted { if z_index(L, P.scratch[i]) < 0 { paint_context(L, P, P.scratch[i]); } }
    paint_flow(L, P, n);
    for i in mark..end {
        let e = P.scratch[i];
        let s = L.styles[e];
        if !stacks(s) {
            emit_own(P, e);
            paint_flow(L, P, e);
        } else if z_index(L, e) == 0 {
            paint_context(L, P, e);
        }
    }
    for i in end..sorted { if z_index(L, P.scratch[i]) > 0 { paint_context(L, P, P.scratch[i]); } }
    P.scratch.resize(mark);
}

// Collects in P.scratch the positioned elements in n's stacking context, in
// document order: not those inside one that starts its own.
recursive fn gather(L: Layout, P: Paint, n: i32) {
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if L.d.nodes[c].kind == NODE_ELEMENT && L.styles[c].display != K_NONE {
            let s = L.styles[c];
            if s.position != K_STATIC || stacks(s) { P.scratch.push(c); }
            if !stacks(s) { gather(L, P, c); }
        }
        c = L.d.nodes[c].next;
    }
}

// Sorts P.scratch[a..b] by z-index, document order kept among equals: a
// merge sort, merging into room above b.
fn sort_by_z(L: Layout, P: Paint, a: i64, b: i64) {
    let n = b - a;
    guard n > 1;
    for i in n { P.scratch.push(0); }
    var width: i64 = 1;
    while width < n {
        var lo: i64 = 0;
        while lo < n {
            let mid = min(lo + width, n);
            let hi = min(lo + 2 * width, n);
            var i = lo;
            var j = mid;
            var t = lo;
            while i < mid || j < hi {
                if j >= hi || (i < mid && z_index(L, P.scratch[a + i]) <= z_index(L, P.scratch[a + j])) {
                    P.scratch[b + t] = P.scratch[a + i];
                    i += 1;
                } else {
                    P.scratch[b + t] = P.scratch[a + j];
                    j += 1;
                }
                t += 1;
            }
            lo = hi;
        }
        for k in n { P.scratch[a + k] = P.scratch[b + k]; }
        width *= 2;
    }
    P.scratch.resize(b);
}

// Paints what is in n and isn't positioned, in document order.
recursive fn paint_flow(L: Layout, P: Paint, n: i32) {
    var c = L.d.nodes[n].first;
    while c >= 0 {
        let node = L.d.nodes[c];
        if node.kind != NODE_ELEMENT || (L.styles[c].display != K_NONE && L.styles[c].position == K_STATIC && !stacks(L.styles[c])) {
            emit_own(P, c);
            paint_flow(L, P, c);
        }
        c = node.next;
    }
}

// ------------------------------------------------------------------ clips

// Cuts each item to the padding boxes of the elements around it whose
// overflow isn't visible (CSS Overflow 3), to where they all meet. Those in
// the innermost one's space, or a shift and a scale from it, meet there: a
// corner of that is rounded when it is a clipping box's corner, as that
// box's inner radius (the rounder, when two meet there), and a transform
// between the item and that space takes the item's points to it. Those
// turned another way cut on the page, square, where they reach. An absolute
// box is cut only by those around its containing block, a fixed one only by
// those around a transformed one; a block's own "…", or a list item's
// marker, by the element itself too. An item with nothing left to show is
// dropped; one wholly inside a square clip with no transform between needs
// none.
fn clip_items(L: Layout, mats: Mat[>..]&) {
    for k in L.items.len {
        let it = L.items[k];
        guard it.node >= 0 && it.kind != ITEM_NONE else { continue; }
        var inner: i32 = -1;
        var space = identity();
        var x0: f32 = -1000000000.0;
        var y0: f32 = -1000000000.0;
        var x1: f32 = 1000000000.0;
        var y1: f32 = 1000000000.0;
        var r = Radii { tl: 0.0, tr: 0.0, br: 0.0, bl: 0.0 };
        var ox0: f32 = -1000000000.0;
        var oy0: f32 = -1000000000.0;
        var ox1: f32 = 1000000000.0;
        var oy1: f32 = 1000000000.0;
        var outer = false;
        var e = it.node;
        var own = it.kind == ITEM_TEXT && L.d.nodes[e].kind == NODE_ELEMENT;
        loop {
            let up = if own { e } else { clip_parent(L, e) };
            own = false;
            if up <= 0 { break; }
            if clips_content(L, up) {
                if inner < 0 {
                    inner = up;
                    if mats.len > 0 { space = mats[up]; }
                }
                let s = L.styles[up];
                let b = L.boxes[up];
                var px0 = b.x + s.bl;
                var py0 = b.y + s.bt;
                var px1 = b.x + b.w - s.br;
                var py1 = b.y + b.h - s.bb;
                var pr = inner_radii(radii_of(s, b.w, b.h), s);
                // From its space to the innermost clip's.
                var rel = identity();
                if mats.len > 0 && !same(mats[up], space) { rel = mat_mul(mat_inv(space), mats[up]); }
                if !is_axis_aligned(rel) {
                    // Turned another way: it cuts on the page, square, where it reaches.
                    let m = mats[up];
                    var qx0: f32 = 1000000000.0;
                    var qy0: f32 = 1000000000.0;
                    var qx1: f32 = -1000000000.0;
                    var qy1: f32 = -1000000000.0;
                    for c in 4 {
                        let cx = if c == 1 || c == 2 { px1 } else { px0 };
                        let cy = if c >= 2 { py1 } else { py0 };
                        let tx = m.a * cx + m.c * cy + m.e;
                        let ty = m.b * cx + m.d * cy + m.f;
                        qx0 = min(qx0, tx);
                        qy0 = min(qy0, ty);
                        qx1 = max(qx1, tx);
                        qy1 = max(qy1, ty);
                    }
                    ox0 = max(ox0, qx0);
                    oy0 = max(oy0, qy0);
                    ox1 = min(ox1, qx1);
                    oy1 = min(oy1, qy1);
                    outer = true;
                    e = up;
                    continue;
                }
                if !is_identity(rel) {
                    let ax0 = rel.a * px0 + rel.e;
                    let ax1 = rel.a * px1 + rel.e;
                    let ay0 = rel.d * py0 + rel.f;
                    let ay1 = rel.d * py1 + rel.f;
                    px0 = min(ax0, ax1);
                    px1 = max(ax0, ax1);
                    py0 = min(ay0, ay1);
                    py1 = max(ay0, ay1);
                    let sc = min(abs(rel.a), abs(rel.d));
                    pr = Radii { tl: pr.tl * sc, tr: pr.tr * sc, br: pr.br * sc, bl: pr.bl * sc };
                }
                let nx0 = max(x0, px0);
                let ny0 = max(y0, py0);
                let nx1 = min(x1, px1);
                let ny1 = min(y1, py1);
                r = Radii { tl: corner_radius(nx0, ny0, px0, py0, pr.tl, x0, y0, r.tl),
                            tr: corner_radius(nx1, ny0, px1, py0, pr.tr, x1, y0, r.tr),
                            br: corner_radius(nx1, ny1, px1, py1, pr.br, x1, y1, r.br),
                            bl: corner_radius(nx0, ny1, px0, py1, pr.bl, x0, y1, r.bl) };
                x0 = nx0;
                y0 = ny0;
                x1 = nx1;
                y1 = ny1;
            }
            e = up;
        }
        guard inner >= 0 else { continue; }
        if x1 <= x0 || y1 <= y0 || (outer && (ox1 <= ox0 || oy1 <= oy0)) {
            L.items[k].kind = ITEM_NONE;
            continue;
        }
        if outer {
            L.items[k].oclip_x = ox0;
            L.items[k].oclip_y = oy0;
            L.items[k].oclip_w = ox1 - ox0;
            L.items[k].oclip_h = oy1 - oy0;
        }
        var cm = identity();
        if mats.len > 0 && !same(space, mats[it.node]) { cm = mat_mul(mat_inv(space), mats[it.node]); }
        if is_identity(cm) {
            // A text item's extent, roughly: from about its ascent to its descent.
            let ty = if it.kind == ITEM_TEXT { it.y - it.size } else { it.y };
            let th = if it.kind == ITEM_TEXT { it.size * 1.3 } else { it.h };
            if it.x >= x1 || ty >= y1 || it.x + it.w <= x0 || ty + th <= y0 {
                L.items[k].kind = ITEM_NONE;
                continue;
            }
            let rounded = r.tl > 0.0 || r.tr > 0.0 || r.br > 0.0 || r.bl > 0.0;
            if !rounded && it.x >= x0 && ty >= y0 && it.x + it.w <= x1 && ty + th <= y1 { continue; }
        } else {
            set_clip_matrix(L, k, cm);
        }
        let fit = fit_radii(r, x1 - x0, y1 - y0);
        L.items[k].clip_x = x0;
        L.items[k].clip_y = y0;
        L.items[k].clip_w = x1 - x0;
        L.items[k].clip_h = y1 - y0;
        L.items[k].clip_tl = fit.tl;
        L.items[k].clip_tr = fit.tr;
        L.items[k].clip_br = fit.br;
        L.items[k].clip_bl = fit.bl;
    }
}

// The radius of the clip's corner at (x, y): a clipping box's corner radius
// where that box's corner (bx, by) is it, the clip so far's where its corner
// (px, py) is it, the rounder when both are; else square.
fn corner_radius(x: f32, y: f32, bx: f32, by: f32, br: f32, px: f32, py: f32, pr: f32) -> f32 {
    var out: f32 = 0.0;
    if abs(x - bx) < 0.01 && abs(y - by) < 0.01 { out = br; }
    if abs(x - px) < 0.01 && abs(y - py) < 0.01 { out = max(out, pr); }
    return out;
}

// ------------------------------------------------------------------ flex

// One flex item while its container lays it out (CSS Flexbox 1 §9): element
// `node`, or, when `last` isn't -2, the run of text from `node` up to its
// sibling `last` (-1: to the end), laid out as an anonymous block. Main sizes
// are of the content box: `edge` is its padding and borders along the main
// axis, and `margin` its margins there (auto ones count 0).
struct FlexItem {
    node: i32, last: i32, order: i32,
    grow: f32, shrink: f32,
    base: f32, lo: f32, hi: f32,     // its flex base size, and its min and max main size (hi -1: none)
    main: f32, frozen: bool,         // its hypothetical main size, then its flexed one
    edge: f32, margin: f32,
    width: f32,                      // in a column: its content width
    cross: f32, baseline: f32,       // its outer size across, and its first baseline from its outer edge (-1: none)
    line: i32, pos: f32,             // its line, and its border box's main start from the content box's
    lcross: f32, lpos: f32, lbase: f32, // its line's size across, start across, and the baseline its items line up on
}

fn flex_item(node: i32, last: i32, s: Style) -> FlexItem {
    let element = last == -2;
    return FlexItem { node: node, last: last, order: if element { s.order } else { 0 },
                      grow: if element { s.grow } else { 0.0 }, shrink: if element { s.shrink } else { 1.0 },
                      base: 0.0, lo: 0.0, hi: -1.0, main: 0.0, frozen: false, edge: 0.0, margin: 0.0, width: 0.0,
                      cross: 0.0, baseline: -1.0, line: 0, pos: 0.0, lcross: 0.0, lpos: 0.0, lbase: 0.0 };
}

// Lays out flex container n's items in its content box at (x, y), `w` wide
// and `h` high (-1 when its height is auto, `hmin` to `hmax` then: its min-
// and max-height, content box, hmax -1 for none): their base and
// hypothetical sizes, lines when it wraps, flexing, their sizes across, and
// then each laid out where justify-content, auto margins, align-content and
// align-self put it. A row item's height is found by laying it out once and
// dropping what that painted (measure_sized, which remembers), then laying it
// out for real. Returns the height the items take and the container's first
// baseline (-1 if none).
recursive fn layout_flex(L: Layout, n: i32, x: f32, y: f32, w: f32, h: f32, hmin: f32, hmax: f32) -> f32, f32 {
    let s = L.styles[n];
    let row = s.flex_dir == K_ROW || s.flex_dir == K_ROW_REVERSE;
    let reverse = s.flex_dir == K_ROW_REVERSE || s.flex_dir == K_COLUMN_REVERSE;
    let single = s.flex_wrap == K_NOWRAP;
    var main_size = if row { w } else { h };
    let cross_size = if row { h } else { w };
    let col_gap = if (s.gap_pct & 2) != 0 { s.col_gap / 100.0 * w } else { s.col_gap };
    let row_gap = if (s.gap_pct & 1) == 0 { s.row_gap } else if h >= 0.0 { s.row_gap / 100.0 * h } else { 0.0 };
    let gap = if row { col_gap } else { row_gap };
    let line_gap = if row { row_gap } else { col_gap };
    let mark = L.flex.len;
    collect_items(L, n, x, y);
    let end = L.flex.len;
    for i in mark..end { size_item(L, i, n, row, main_size, cross_size); }

    // Lines: one, unless it wraps and its main size is known.
    var lines: i32 = 1;
    var used: f32 = 0.0;
    var count = 0;
    for i in mark..end {
        let outer = L.flex[i].main + L.flex[i].edge + L.flex[i].margin;
        if !single && main_size >= 0.0 && count > 0 && used + gap + outer > main_size + 0.01 {
            lines += 1;
            used = 0.0;
            count = 0;
        }
        used += (if count > 0 { gap } else { 0.0 }) + outer;
        count += 1;
        L.flex[i].line = lines - 1;
    }
    // A column whose height is auto gives its items the room they take,
    // within its min-height and max-height, to flex into.
    if !row && main_size < 0.0 {
        let room = clamp_size(used, hmin, hmax);
        if room != used { main_size = room; }
    }
    if main_size >= 0.0 {
        var a = mark;
        while a < end {
            let b = line_end(L, a, end);
            resolve_flex(L, a, b, main_size, gap);
            a = b;
        }
    }
    for i in mark..end { cross_of(L, i, n, row, cross_size); }

    // Each line's size across: its biggest item, or its items' baselines lined
    // up. The container's: its own, else its lines' within its min-height
    // and max-height. A single line (nowrap) fills it.
    var total: f32 = 0.0;
    var a = mark;
    while a < end {
        let b = line_end(L, a, end);
        var biggest: f32 = 0.0;
        var above: f32 = 0.0;
        var below: f32 = 0.0;
        for i in a..b {
            let it = L.flex[i];
            if row && item_align(L, it, s) == K_BASELINE && it.baseline >= 0.0 {
                above = max(above, it.baseline);
                below = max(below, it.cross - it.baseline);
            } else {
                biggest = max(biggest, it.cross);
            }
        }
        let lc = max(biggest, above + below);
        for i in a..b {
            L.flex[i].lcross = lc;
            L.flex[i].lbase = above;
        }
        total += lc + (if a > mark { line_gap } else { 0.0 });
        a = b;
    }
    var cross_len = total;
    if cross_size >= 0.0 { cross_len = cross_size; }
    else if row { cross_len = clamp_size(total, hmin, hmax); }
    // align-content: the lines of one that wraps, in its room across.
    var lead: f32 = 0.0;
    var between = line_gap;
    var grow_each: f32 = 0.0;
    if !single && cross_len != total {
        let free = cross_len - total;
        let k = lines as f32;
        let ac = s.align_content;
        if ac == K_NORMAL || ac == K_STRETCH { if free > 0.0 { grow_each = free / k; } }
        else if ac == K_FLEX_END { lead = free; }
        else if ac == K_CENTER { lead = free / 2.0; }
        else if ac == K_SPACE_BETWEEN { if free > 0.0 && k > 1.0 { between += free / (k - 1.0); } }
        else if ac == K_SPACE_AROUND { if free > 0.0 { lead = free / k / 2.0; between += free / k; } else { lead = free / 2.0; } }
        else if ac == K_SPACE_EVENLY { if free > 0.0 { lead = free / (k + 1.0); between += free / (k + 1.0); } else { lead = free / 2.0; } }
    }
    var cpos = lead;
    a = mark;
    while a < end {
        let b = line_end(L, a, end);
        let lc = if single { cross_len } else { L.flex[a].lcross + grow_each };
        for i in a..b {
            L.flex[i].lcross = lc;
            L.flex[i].lpos = cpos;
        }
        cpos += lc + between;
        a = b;
    }

    // Along each line: auto margins take the room to spare, else
    // justify-content spreads it. Reversed, an item's margins swap ends, so
    // that they stay on their own sides.
    var main_used: f32 = 0.0;
    a = mark;
    while a < end {
        let b = line_end(L, a, end);
        let k = (b - a) as f32;
        var sum = gap * (k - 1.0);
        var autos: i32 = 0;
        for i in a..b {
            let it = L.flex[i];
            sum += it.main + it.edge + it.margin;
            if it.last == -2 {
                let cs = L.styles[it.node];
                autos += if row { cs.auto_ml + cs.auto_mr } else { cs.auto_mt + cs.auto_mb };
            }
        }
        main_used = max(main_used, sum);
        let free = if main_size >= 0.0 { main_size - sum } else { 0.0 };
        var start: f32 = 0.0;
        var spacing = gap;
        var share: f32 = 0.0;
        let jc = s.justify;
        if free > 0.0 && autos > 0 { share = free / autos; }
        else if jc == K_FLEX_END { start = free; }
        else if jc == K_CENTER { start = free / 2.0; }
        else if jc == K_SPACE_BETWEEN { if free > 0.0 && k > 1.0 { spacing += free / (k - 1.0); } }
        else if jc == K_SPACE_AROUND { if free > 0.0 { start = free / k / 2.0; spacing += free / k; } else { start = free / 2.0; } }
        else if jc == K_SPACE_EVENLY { if free > 0.0 { start = free / (k + 1.0); spacing += free / (k + 1.0); } else { start = free / 2.0; } }
        var pos = start;
        for i in a..b {
            let it = L.flex[i];
            var before: f32 = 0.0;
            var after: f32 = 0.0;
            if it.last == -2 {
                let cs = L.styles[it.node];
                let m0 = if row { (if cs.auto_ml != 0 { share } else { cs.ml }) } else { (if cs.auto_mt != 0 { share } else { cs.mt }) };
                let m1 = if row { (if cs.auto_mr != 0 { share } else { cs.mr }) } else { (if cs.auto_mb != 0 { share } else { cs.mb }) };
                before = if reverse { m1 } else { m0 };
                after = if reverse { m0 } else { m1 };
            }
            L.flex[i].pos = pos + before;
            pos += before + it.main + it.edge + after + spacing;
        }
        a = b;
    }
    let main_len = if main_size >= 0.0 { main_size } else { main_used };

    // Each item, where align-self puts it across its line; a run of text
    // aligns as the container's items do. Wrapped in reverse, a line's start
    // across is its far side.
    var baseline: f32 = -1.0;
    for i in mark..end {
        let it = L.flex[i];
        var mpos = it.pos;
        if reverse { mpos = main_len - mpos - it.main - it.edge; }
        var cp = if s.flex_wrap == K_WRAP_REVERSE { cross_len - it.lpos - it.lcross } else { it.lpos };
        var al = item_align(L, it, s);
        if s.flex_wrap == K_WRAP_REVERSE {
            if al == K_FLEX_START { al = K_FLEX_END; } else if al == K_FLEX_END { al = K_FLEX_START; }
        }
        let free = it.lcross - it.cross;
        var got: f32 = -1.0;
        if it.last != -2 {
            if al == K_FLEX_END { cp += free; }
            else if al == K_CENTER { cp += free / 2.0; }
            else if al == K_BASELINE && row && it.baseline >= 0.0 { cp += it.lbase - it.baseline; }
            let tw = if row { it.main } else { it.width };
            let lh, lb = layout_lines(L, n, it.node, it.last, x + (if row { mpos } else { cp }), y + (if row { cp } else { mpos }), tw);
            got = lb;
        } else {
            let cs = L.styles[it.node];
            let m0 = if row { cs.mt } else { cs.ml };
            let m1 = if row { cs.mb } else { cs.mr };
            let a0 = if row { cs.auto_mt } else { cs.auto_ml };
            let a1 = if row { cs.auto_mb } else { cs.auto_mr };
            var item_h = if row { pct_height(cs, cross_size) } else { it.main };
            if a0 != 0 || a1 != 0 {
                if a0 != 0 && a1 != 0 { cp += max(free / 2.0, 0.0); } else if a0 != 0 { cp += max(free, 0.0); }
            } else if al == K_STRETCH {
                if row && cs.height < 0.0 && item_h < 0.0 {
                    let vt = cs.bt + cs.pt + cs.pb + cs.bb;
                    let inside: f32 = if cs.border_box != 0 { vt } else { 0.0 };
                    item_h = it.lcross - m0 - m1 - vt;
                    if cs.max_height >= 0.0 { item_h = min(item_h, cs.max_height - inside); }
                    item_h = max(max(item_h, cs.min_height - inside), 0.0);
                }
            } else if al == K_FLEX_END { cp += free; }
            else if al == K_CENTER { cp += free / 2.0; }
            else if al == K_BASELINE && row && it.baseline >= 0.0 { cp += it.lbase - it.baseline; }
            cp += m0;
            let lo, hi = height_limits(cs);
            if row {
                let bh, bl = layout_sized(L, it.node, x + mpos, y + cp, it.main, item_h, lo, hi);
                got = bl;
            } else {
                let bh, bl = layout_sized(L, it.node, x + cp, y + mpos, it.width, item_h, lo, hi);
                got = bl;
            }
        }
        if baseline < 0.0 && got >= 0.0 { baseline = got; }
    }
    L.flex.resize(mark);
    return (if row { cross_len } else { main_len }), baseline;
}

// v within lo and hi (hi -1: none); lo wins when they cross.
fn clamp_size(v: f32, lo: f32, hi: f32) -> f32 {
    return max(if hi >= 0.0 { min(v, hi) } else { v }, lo);
}

// A row item's height when it is a percentage of its container's, known
// across (content box); else -1.
fn pct_height(cs: Style, cross_size: f32) -> f32 {
    guard cs.height < 0.0 && cs.height_pct >= 0.0 && cross_size >= 0.0 else { return -1.0; }
    let inside: f32 = if cs.border_box != 0 { cs.bt + cs.pt + cs.pb + cs.bb } else { 0.0 };
    return max(cross_size * cs.height_pct / 100.0 - inside, 0.0);
}

// The index after the last item on the line item a is on.
fn line_end(L: Layout, a: i64, end: i64) -> i64 {
    var b = a;
    while b < end && L.flex[b].line == L.flex[a].line { b += 1; }
    return b;
}

// Pushes n's flex items onto L.flex, sorted by order (document order among
// equals): its elements in the flow, and each run of text between them that
// isn't blank. One out of the flow only notes its static position.
fn collect_items(L: Layout, n: i32, x: f32, y: f32) {
    let mark = L.flex.len;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        let node = L.d.nodes[c];
        if is_out(L, c) {
            static_position(L, c, x, y);
            c = node.next;
            continue;
        }
        if node.kind == NODE_ELEMENT {
            if L.styles[c].display != K_NONE { L.flex.push(flex_item(c, -2, L.styles[c])); }
            c = node.next;
            continue;
        }
        var end = c;
        var blank = true;
        while end >= 0 && L.d.nodes[end].kind != NODE_ELEMENT {
            if !is_blank(L, end) { blank = false; }
            end = L.d.nodes[end].next;
        }
        if !blank { L.flex.push(flex_item(c, end, L.styles[n])); }
        c = end;
    }
    for i in mark + 1..L.flex.len {
        let it = L.flex[i];
        var j = i;
        while j > mark && L.flex[j - 1].order > it.order {
            L.flex[j] = L.flex[j - 1];
            j -= 1;
        }
        L.flex[j] = it;
    }
}

// How item `it` of a container styled cs aligns across its line: its
// align-self, else the container's align-items; normal is stretch.
fn item_align(L: Layout, it: FlexItem, cs: Style) -> i32 {
    var a = cs.align_items;
    if it.last == -2 && L.styles[it.node].align_self != K_AUTO { a = L.styles[it.node].align_self; }
    return if a == K_NORMAL { K_STRETCH } else { a };
}

// Item i's flex base size, its min and max main sizes and its hypothetical
// main size (in `main`), as CSS Flexbox 1 §9.2 has them. An item whose
// min-width (min-height down a column) is auto and that doesn't clip can't
// shrink below its content. Down a column, also its width: its own, else
// stretched across, else fitted to its content.
recursive fn size_item(L: Layout, i: i64, n: i32, row: bool, main_size: f32, cross_size: f32) {
    var it = L.flex[i];
    if it.last != -2 {
        // A run of text: its content's widths along a row; down a column, the
        // height of its lines across the container.
        var p = Widths { min: 0.0, max: 0.0, line: 0.0, word: 0.0, space: 0.0, start: true };
        var c = it.node;
        while c != it.last {
            add_widths(L, c, p);
            c = L.d.nodes[c].next;
        }
        end_widths(p);
        if row {
            it.base = p.max;
            it.lo = p.min;
        } else {
            let room = max(cross_size, 0.0);
            it.width = if item_align(L, it, L.styles[n]) == K_STRETCH { room } else { min(max(p.min, room), p.max) };
            let lh, lb = measure_lines(L, n, it.node, it.last, it.width);
            it.base = lh;
            it.lo = lh;
        }
        it.main = max(it.base, it.lo);
        L.flex[i] = it;
        return;
    }
    let c = it.node;
    let s = L.styles[c];
    let hz = s.bl + s.pl + s.pr + s.br;
    let vt = s.bt + s.pt + s.pb + s.bb;
    it.edge = if row { hz } else { vt };
    it.margin = if row { s.ml + s.mr } else { s.mt + s.mb };
    let inside: f32 = if s.border_box != 0 { it.edge } else { 0.0 };
    if !row {
        let in_w: f32 = if s.border_box != 0 { hz } else { 0.0 };
        let room = cross_size - s.ml - s.mr;
        var cw: f32 = -1.0;
        if s.width >= 0.0 { cw = s.width - in_w; }
        else if s.width_pct >= 0.0 { cw = cross_size * s.width_pct / 100.0 - in_w; }
        else if item_align(L, it, L.styles[n]) == K_STRETCH && s.auto_ml == 0 && s.auto_mr == 0 { cw = room - hz; }
        else {
            let least, most = content_widths(L, c);
            cw = min(max(least, room), most) - hz;
        }
        if s.max_width >= 0.0 { cw = min(cw, s.max_width - in_w); }
        it.width = max(max(cw, s.min_width - in_w), 0.0);
    }
    // The size it says along the main axis, if it says one.
    var size: f32 = -1.0;
    if row {
        if s.width >= 0.0 { size = s.width - inside; }
        else if s.width_pct >= 0.0 && main_size >= 0.0 { size = main_size * s.width_pct / 100.0 - inside; }
    } else {
        if s.height >= 0.0 { size = s.height - inside; }
        else if s.height_pct >= 0.0 && main_size >= 0.0 { size = main_size * s.height_pct / 100.0 - inside; }
    }
    var base: f32 = -1.0;
    if s.basis_kind == 1 { base = s.basis - inside; }
    else if s.basis_kind == 2 && main_size >= 0.0 { base = main_size * s.basis / 100.0 - inside; }
    else if s.basis_kind == K_AUTO { base = size; }
    let auto_min = (if row { s.min_w_auto } else { s.min_h_auto }) != 0 && s.clips == 0;
    var least: f32 = 0.0;
    var most: f32 = 0.0;
    if base < 0.0 || auto_min {
        if row {
            let a, b = inner_widths(L, c);
            least = a - hz;
            most = b - hz;
        } else {
            // Its content's height, whatever height it says.
            let bh, bl = measure_sized(L, c, it.width, -2.0);
            least = bh - vt;
            most = least;
        }
    }
    if base < 0.0 { base = most; }
    var lo: f32 = 0.0;
    if auto_min { lo = if size >= 0.0 { min(size, least) } else { least }; }
    else if row { lo = (if s.min_width_pct >= 0.0 && main_size >= 0.0 { main_size * s.min_width_pct / 100.0 } else { s.min_width }) - inside; }
    else { lo = s.min_height - inside; }
    var hi: f32 = -1.0;
    if row {
        if s.max_width >= 0.0 { hi = s.max_width - inside; }
        else if s.max_width_pct >= 0.0 && main_size >= 0.0 { hi = main_size * s.max_width_pct / 100.0 - inside; }
    } else if s.max_height >= 0.0 {
        hi = s.max_height - inside;
    }
    lo = max(lo, 0.0);
    if hi >= 0.0 {
        if auto_min { lo = min(lo, hi); }
        hi = max(hi, lo);
    }
    it.base = max(base, 0.0);
    it.lo = lo;
    it.hi = hi;
    it.main = max(if hi >= 0.0 { min(it.base, hi) } else { it.base }, lo);
    L.flex[i] = it;
}

// Flexes the items of one line, L.flex[a..b], to fill `main_size` (CSS
// Flexbox 1 §9.7): room to spare goes to them by flex-grow, room short is
// taken from them by flex-shrink times their base size. An item its min or
// max size stops is frozen there, and the others flex again.
fn resolve_flex(L: Layout, a: i64, b: i64, main_size: f32, gap: f32) {
    let gaps = gap * (b - a - 1);
    var used = gaps;
    for i in a..b { used += L.flex[i].main + L.flex[i].edge + L.flex[i].margin; }
    let growing = used < main_size;
    for i in a..b {
        let it = L.flex[i];
        let factor = if growing { it.grow } else { it.shrink };
        L.flex[i].frozen = factor == 0.0 || (growing && it.base > it.main) || (!growing && it.base < it.main);
    }
    var initial: f32 = 0.0;
    var rounds: i64 = 0;
    while rounds <= b - a {
        var free = main_size - gaps;
        var factors: f32 = 0.0;
        var scaled: f32 = 0.0;
        var open = false;
        for i in a..b {
            let it = L.flex[i];
            free -= (if it.frozen { it.main } else { it.base }) + it.edge + it.margin;
            if !it.frozen {
                open = true;
                factors += if growing { it.grow } else { it.shrink };
                scaled += it.shrink * it.base;
            }
        }
        if !open { return; }
        if rounds == 0 { initial = free; }
        rounds += 1;
        // Factors that add up to less than 1 take only that share of the room.
        if factors < 1.0 && abs(initial * factors) < abs(free) { free = initial * factors; }
        var total: f32 = 0.0;
        for i in a..b {
            let it = L.flex[i];
            guard !it.frozen else { continue; }
            var target = it.base;
            if growing { if factors > 0.0 { target = it.base + free * it.grow / factors; } }
            else if scaled > 0.0 { target = it.base + free * it.shrink * it.base / scaled; }
            var clamped = target;
            if it.hi >= 0.0 { clamped = min(clamped, it.hi); }
            clamped = max(clamped, it.lo);
            total += clamped - target;
            L.flex[i].main = clamped;
            L.flex[i].pos = clamped - target;       // how far its limits moved it, for the freezing below
        }
        for i in a..b {
            let it = L.flex[i];
            guard !it.frozen else { continue; }
            if total == 0.0 || (total > 0.0 && it.pos > 0.0) || (total < 0.0 && it.pos < 0.0) { L.flex[i].frozen = true; }
        }
    }
}

// Item i's outer size across, and its first baseline from its outer edge:
// along a row, laid out at its main size to see; down a column, its width.
recursive fn cross_of(L: Layout, i: i64, n: i32, row: bool, cross_size: f32) {
    var it = L.flex[i];
    if it.last != -2 {
        if row {
            let lh, lb = measure_lines(L, n, it.node, it.last, it.main);
            it.cross = lh;
            it.baseline = lb;
        } else {
            it.cross = it.width;
        }
    } else {
        let s = L.styles[it.node];
        if row {
            let bh, bl = measure_sized(L, it.node, it.main, pct_height(s, cross_size));
            it.cross = bh + s.mt + s.mb;
            it.baseline = if bl >= 0.0 { bl + s.mt } else { -1.0 };
        } else {
            it.cross = it.width + s.bl + s.pl + s.pr + s.br + s.ml + s.mr;
        }
    }
    L.flex[i] = it;
}

// The border-box height and first baseline (from its top, -1 if none) of
// element c laid out with its content `w` wide and `h` high (as layout_sized
// takes them), painting nothing: what layout_sized paints is dropped and the
// boxes it set are cleared. It remembers the last answer for each node, so
// that a nested flex container's items, measured again when the container is
// laid out for real, aren't laid out again: without it the work doubled at
// each level.
recursive fn measure_sized(L: Layout, c: i32, w: f32, h: f32) -> f32, f32 {
    while L.measured.len < L.d.nodes.len { L.measured.push(Measured { w: -1.0, h: 0.0, height: 0.0, baseline: -1.0 }); }
    let known = L.measured[c];
    if known.w == w && known.h == h { return known.height, known.baseline; }
    let mark = L.items.len;
    let lo, hi = height_limits(L.styles[c]);
    let bh, b = layout_sized(L, c, 0.0, 0.0, w, h, lo, hi);
    L.items.resize(mark);
    clear_boxes(L, c);
    L.measured[c] = Measured { w: w, h: h, height: bh, baseline: b };
    return bh, b;
}

// The height and first baseline (from its top, -1 if none) of the run of
// text from `from` up to `to` in n laid out `w` wide, painting nothing.
fn measure_lines(L: Layout, n: i32, from: i32, to: i32, w: f32) -> f32, f32 {
    let mark = L.items.len;
    let h, b = layout_lines(L, n, from, to, 0.0, 0.0, w);
    L.items.resize(mark);
    var c = from;
    while c != to {
        clear_boxes(L, c);
        c = L.d.nodes[c].next;
    }
    return h, b;
}

recursive fn clear_boxes(L: Layout, n: i32) {
    L.boxes[n] = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    var c = L.d.nodes[n].first;
    while c >= 0 {
        clear_boxes(L, c);
        c = L.d.nodes[c].next;
    }
}

// A flex container's min-content and max-content widths, into p: along a
// row its items side by side (a row that wraps needs only its widest at
// min-content), down a column its widest item.
recursive fn flex_widths(L: Layout, n: i32, p: Widths&) {
    let s = L.styles[n];
    let row = s.flex_dir == K_ROW || s.flex_dir == K_ROW_REVERSE;
    let gap = if row && (s.gap_pct & 2) == 0 { s.col_gap } else { 0.0 };
    var count = 0;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        let node = L.d.nodes[c];
        var least: f32 = 0.0;
        var most: f32 = 0.0;
        var item = false;
        if node.kind == NODE_ELEMENT {
            if L.styles[c].display != K_NONE && !is_out(L, c) {
                let a, b = content_widths(L, c);
                let m = L.styles[c].ml + L.styles[c].mr;
                least = a + m;
                most = b + m;
                item = true;
            }
            c = node.next;
        } else {
            var q = Widths { min: 0.0, max: 0.0, line: 0.0, word: 0.0, space: 0.0, start: true };
            while c >= 0 && L.d.nodes[c].kind != NODE_ELEMENT {
                if !is_blank(L, c) { item = true; }
                add_widths(L, c, q);
                c = L.d.nodes[c].next;
            }
            end_widths(q);
            least = q.min;
            most = q.max;
        }
        guard item else { continue; }
        let g = if count > 0 { gap } else { 0.0 };
        if row {
            p.max += most + g;
            p.min = if s.flex_wrap == K_NOWRAP { p.min + least + g } else { max(p.min, least) };
        } else {
            p.max = max(p.max, most);
            p.min = max(p.min, least);
        }
        count += 1;
    }
}

// ------------------------------------------------------------------ transforms

// A 2D transform as CSS's matrix(a, b, c, d, e, f): (x, y) goes to
// (a·x + c·y + e, b·x + d·y + f).
struct Mat { a: f32, b: f32, c: f32, d: f32, e: f32, f: f32 }

fn identity() -> Mat { return Mat { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 }; }

fn translation(x: f32, y: f32) -> Mat { return Mat { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: x, f: y }; }

// m after n: what n does to a point, then m.
fn mat_mul(m: Mat, n: Mat) -> Mat {
    return Mat { a: m.a * n.a + m.c * n.b, b: m.b * n.a + m.d * n.b,
                 c: m.a * n.c + m.c * n.d, d: m.b * n.c + m.d * n.d,
                 e: m.a * n.e + m.c * n.f + m.e, f: m.b * n.e + m.d * n.f + m.f };
}

// The transform that undoes m (identity when m flattens everything).
fn mat_inv(m: Mat) -> Mat {
    let det = m.a * m.d - m.b * m.c;
    guard abs(det) > 0.000001 else { return identity(); }
    return Mat { a: m.d / det, b: -m.b / det, c: -m.c / det, d: m.a / det,
                 e: (m.c * m.f - m.d * m.e) / det, f: (m.b * m.e - m.a * m.f) / det };
}

fn is_identity(m: Mat) -> bool { return is_translation(m) && m.e == 0.0 && m.f == 0.0; }

// Whether two transforms are the same: one inverted and multiplied by the
// other wouldn't quite come to identity.
fn same(m: Mat, n: Mat) -> bool { return m.a == n.a && m.b == n.b && m.c == n.c && m.d == n.d && m.e == n.e && m.f == n.f; }

fn is_translation(m: Mat) -> bool { return m.a == 1.0 && m.b == 0.0 && m.c == 0.0 && m.d == 1.0; }

// Whether m keeps a rectangle's sides level: it scales and shifts, nothing more.
fn is_axis_aligned(m: Mat) -> bool { return abs(m.b) < 0.000001 && abs(m.c) < 0.000001; }

// Whether element n is transformed: it has a transform and is a block or an
// inline-block (CSS Transforms 1 §3: an inline box isn't transformable).
fn transforms(L: Layout, n: i32) -> bool {
    guard L.d.nodes[n].kind == NODE_ELEMENT else { return false; }
    let s = L.styles[n];
    return s.xf_count > 0 && s.display != K_INLINE && s.display != K_NONE;
}

// Element n's transform about its origin, in page points: its functions in
// order, percentages of its border box.
fn element_matrix(L: Layout, n: i32) -> Mat {
    let s = L.styles[n];
    let b = L.boxes[n];
    let ox = b.x + (if (s.origin_pct & 1) != 0 { s.origin_x / 100.0 * b.w } else { s.origin_x });
    let oy = b.y + (if (s.origin_pct & 2) != 0 { s.origin_y / 100.0 * b.h } else { s.origin_y });
    var m = translation(ox, oy);
    var k: i32 = 0;
    while k < s.xf_count {
        let f = s.xf[k];
        if f.kind == XF_TRANSLATE {
            m = mat_mul(m, translation(if (f.pct & 1) != 0 { f.x / 100.0 * b.w } else { f.x },
                                       if (f.pct & 2) != 0 { f.y / 100.0 * b.h } else { f.y }));
        } else if f.kind == XF_SCALE {
            m = mat_mul(m, Mat { a: f.x, b: 0.0, c: 0.0, d: f.y, e: 0.0, f: 0.0 });
        } else if f.kind == XF_ROTATE {
            let cs = cos(f.x);
            let sn = sin(f.x);
            m = mat_mul(m, Mat { a: cs, b: sn, c: -sn, d: cs, e: 0.0, f: 0.0 });
        } else if f.kind == XF_MATRIX && k + 2 < s.xf_count {
            m = mat_mul(m, Mat { a: f.x, b: f.y, c: s.xf[k + 1].x, d: s.xf[k + 1].y, e: s.xf[k + 2].x, f: s.xf[k + 2].y });
            k += 2;
        }
        k += 1;
    }
    return mat_mul(m, translation(-ox, -oy));
}

// mats[n] for n and everything in it: what moves its content on the page,
// m (its parent's) after its own transform.
recursive fn node_matrices(L: Layout, n: i32, m: Mat, mats: Mat[>..]&) {
    var own = m;
    if transforms(L, n) { own = mat_mul(m, element_matrix(L, n)); }
    mats[n] = own;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        node_matrices(L, c, own, mats);
        c = L.d.nodes[c].next;
    }
}

// Gives each item its node's transform. A translation alone moves it, so
// that its text stays on whole pixels, with its clip's matrix changed to
// match; anything else goes to the compositor as its matrix. One flattened
// to nothing is dropped.
fn transform_items(L: Layout, mats: Mat[>..]&) {
    for k in L.items.len {
        let it = L.items[k];
        guard it.node >= 0 && it.kind != ITEM_NONE else { continue; }
        let m = mats[it.node];
        guard !is_identity(m) else { continue; }
        if abs(m.a * m.d - m.b * m.c) < 0.000001 {
            L.items[k].kind = ITEM_NONE;
            continue;
        }
        if !is_translation(m) {
            L.items[k].m_a = m.a; L.items[k].m_b = m.b; L.items[k].m_c = m.c;
            L.items[k].m_d = m.d; L.items[k].m_e = m.e; L.items[k].m_f = m.f;
            continue;
        }
        L.items[k].x += m.e;
        L.items[k].y += m.f;
        guard it.clip_w > 0.0 else { continue; }
        // Its points moved by (e, f): the clip's matrix takes them back first.
        let moved = mat_mul(clip_matrix(it), translation(-m.e, -m.f));
        if is_translation(moved) {
            L.items[k].clip_x -= moved.e;
            L.items[k].clip_y -= moved.f;
            set_clip_matrix(L, k, identity());
        } else {
            set_clip_matrix(L, k, moved);
        }
    }
}

// Item it's clip matrix (identity when it has none).
fn clip_matrix(it: DItem) -> Mat {
    guard it.c_a != 0.0 || it.c_b != 0.0 || it.c_c != 0.0 || it.c_d != 0.0 else { return identity(); }
    return Mat { a: it.c_a, b: it.c_b, c: it.c_c, d: it.c_d, e: it.c_e, f: it.c_f };
}

// Sets item k's clip matrix; identity is all zeros.
fn set_clip_matrix(L: Layout, k: i64, m: Mat) {
    let none = is_identity(m);
    L.items[k].c_a = if none { 0.0 } else { m.a };
    L.items[k].c_b = if none { 0.0 } else { m.b };
    L.items[k].c_c = if none { 0.0 } else { m.c };
    L.items[k].c_d = if none { 0.0 } else { m.d };
    L.items[k].c_e = if none { 0.0 } else { m.e };
    L.items[k].c_f = if none { 0.0 } else { m.f };
}

// The lowest bottom edge a transform takes an element's box to, where
// nothing clips it: the page must reach down to it, as to an absolute box.
fn transformed_bottom(L: Layout, mats: Mat[>..]&) -> f32 {
    var bottom: f32 = 0.0;
    for n in L.d.nodes.len {
        guard L.d.nodes[n].kind == NODE_ELEMENT && !is_identity(mats[n]) && L.boxes[n].h > 0.0 else { continue; }
        if !is_clipped(L, n as i32) { bottom = max(bottom, L.boxes[n].y + L.boxes[n].h); }
    }
    return bottom;
}

// Each transformed node's box becomes the smallest one round where its
// transform takes it, for hit testing and the snapshot.
fn transform_boxes(L: Layout, mats: Mat[>..]&) {
    for n in L.boxes.len {
        let m = mats[n];
        guard !is_identity(m) else { continue; }
        let b = L.boxes[n];
        if is_translation(m) {
            L.boxes[n].x += m.e;
            L.boxes[n].y += m.f;
            continue;
        }
        var x0: f32 = 1000000000.0;
        var y0: f32 = 1000000000.0;
        var x1: f32 = -1000000000.0;
        var y1: f32 = -1000000000.0;
        for k in 4 {
            let px = if k == 1 || k == 2 { b.x + b.w } else { b.x };
            let py = if k >= 2 { b.y + b.h } else { b.y };
            let tx = m.a * px + m.c * py + m.e;
            let ty = m.b * px + m.d * py + m.f;
            x0 = min(x0, tx);
            y0 = min(y0, ty);
            x1 = max(x1, tx);
            y1 = max(y1, ty);
        }
        L.boxes[n] = Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    }
}
