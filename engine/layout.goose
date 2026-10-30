// Layout and paint (docs/adr/0004): block and inline layout of the styled
// document, painted into the flat display list the compositor draws
// (docs/adr/0001). Text is measured once, after styling: Core Text shapes each
// text node and gives the pen position before every byte, so laying the page
// out again at another width is arithmetic in Goose that never calls the
// platform. Blocks stack with their margins collapsed, inline content breaks
// into lines at spaces, and list items get markers. Floats, positioning,
// tables as grids, flex and inline backgrounds wait for M3.

import std;
import .dom;
import .css;

// Display item kinds, as the compositor numbers them (platform/src/compositor.rs).
let ITEM_RECT: i32 = 1;
let ITEM_TEXT: i32 = 2;
let ITEM_BOX: i32 = 3;

// A box item's border style.
let BORDER_SOLID: i32 = 0;
let BORDER_DASHED: i32 = 1;

// One item of the display list, laid out as the compositor's DItem: positions
// in points from the page's top-left; a text item's y is its baseline and its
// text a span of the layout's text. A box is a rectangle with rounded corners
// filled with `color`, and a border `border` wide inside its edge.
struct DItem {
    kind: i32,
    x: f32, y: f32, w: f32, h: f32,
    color: u32,              // 0xAARRGGBB
    font: i32, size: f32,    // text: the font id (see font_of) and size in points
    text: i32, text_len: i32,
    node: i32,               // the node it paints
    rad_tl: f32, rad_tr: f32, rad_br: f32, rad_bl: f32,   // a box's corner radii, top left first, clockwise
    border: f32, border_color: u32, border_style: i32,
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
    items: DItem[>..]&,
}

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
            if L.styles[c].display == K_LIST_ITEM {
                add_marker_run(L, c, ordinal);
                ordinal += 1;
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
// Returns the page's height.
fn layout_page(L: Layout, width: f32) -> f32 {
    while L.boxes.len < L.d.nodes.len { L.boxes.push(Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }); }
    let h, first, trailing = layout_children(L, 0, 0.0, 0.0, width, false);
    inline_boxes(L, 0);
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
    return h + trailing;
}

fn is_block_level(L: Layout, n: i32) -> bool {
    guard L.d.nodes[n].kind == NODE_ELEMENT else { return false; }
    let d = L.styles[n].display;
    return d == K_BLOCK || d == K_LIST_ITEM;
}

// Whether n draws nothing: white space between blocks, a hidden element, or
// an inline element with only such things in it.
recursive fn is_blank(L: Layout, n: i32) -> bool {
    let node = L.d.nodes[n];
    if node.kind == NODE_ELEMENT {
        if L.styles[n].display == K_NONE { return true; }
        if is_block_level(L, n) || node_name(L.d, n) == "br" { return false; }
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
    guard L.d.nodes[n].parent > 0 && s.bt == 0.0 && s.pt == 0.0 else { return s.mt; }
    var m = s.mt;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if is_block_level(L, c) {
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
          && s.height <= 0.0 && s.min_height <= 0.0 else { return false; }
    var c = L.d.nodes[n].first;
    while c >= 0 {
        if is_block_level(L, c) {
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
    for k in box_paint_count(s) { L.items.push(rect_item(n, bx, y, 0.0, 0.0, 0)); }
    let root = L.d.nodes[n].parent == 0;
    let auto_height = s.height < 0.0 && s.min_height <= 0.0;
    let absorb_bottom = !root && s.bb == 0.0 && s.pb == 0.0 && auto_height;
    let inner, first, trailing = layout_children(L, n, bx + s.bl + s.pl, y + s.bt + s.pt, w, !root && s.bt == 0.0 && s.pt == 0.0);
    var ch = inner;
    var mb = s.mb;
    if absorb_bottom { mb = collapse(mb, trailing); } else { ch += trailing; }
    ch = content_height(s, ch, vt);
    let h = vt + ch;
    box_paint(L, n, s, paint_at, bx, y, bw, h);
    if s.display == K_LIST_ITEM { paint_marker(L, n, bx + s.bl + s.pl, first); }
    L.boxes[n] = Rect { x: bx, y: y, w: bw, h: h };
    return h, first, mb;
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
    if s.max_width >= 0.0 { limit = s.max_width - inside; }
    else if s.max_width_pct >= 0.0 { limit = avail * s.max_width_pct / 100.0 - inside; }
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
                   rad_tl: 0.0, rad_tr: 0.0, rad_br: 0.0, rad_bl: 0.0, border: 0.0, border_color: 0, border_style: BORDER_SOLID };
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

// A box item: a rectangle filled with `fill`, corners rounded by r, and a
// border `border` wide.
fn box_item(n: i32, x: f32, y: f32, w: f32, h: f32, fill: u32, r: Radii, border: f32, border_color: u32, dashed: bool) -> DItem {
    var it = rect_item(n, x, y, w, h, fill);
    it.kind = ITEM_BOX;
    it.rad_tl = r.tl; it.rad_tr = r.tr; it.rad_br = r.br; it.rad_bl = r.bl;
    it.border = border;
    it.border_color = border_color;
    it.border_style = if dashed { BORDER_DASHED } else { BORDER_SOLID };
    return it;
}

struct Radii { tl: f32, tr: f32, br: f32, bl: f32 }

fn radii_plus(r: Radii, by: f32) -> Radii {
    return Radii { tl: max(r.tl + by, 0.0), tr: max(r.tr + by, 0.0), br: max(r.br + by, 0.0), bl: max(r.bl + by, 0.0) };
}

fn any_radius(s: Style) -> bool { return s.rad_tl > 0.0 || s.rad_tr > 0.0 || s.rad_br > 0.0 || s.rad_bl > 0.0; }

// Element n's corner radii on a border box w × h: percentages of its shorter
// side, and all scaled down together when two on one side would overlap
// (CSS Backgrounds 3 §5.5).
fn radii_of(s: Style, w: f32, h: f32) -> Radii {
    let side = min(w, h);
    var r = Radii { tl: s.rad_tl, tr: s.rad_tr, br: s.rad_br, bl: s.rad_bl };
    if (s.rad_pct & 1) != 0 { r.tl = s.rad_tl / 100.0 * side; }
    if (s.rad_pct & 2) != 0 { r.tr = s.rad_tr / 100.0 * side; }
    if (s.rad_pct & 4) != 0 { r.br = s.rad_br / 100.0 * side; }
    if (s.rad_pct & 8) != 0 { r.bl = s.rad_bl / 100.0 * side; }
    var f: f32 = 1.0;
    if r.tl + r.tr > w { f = min(f, w / (r.tl + r.tr)); }
    if r.bl + r.br > w { f = min(f, w / (r.bl + r.br)); }
    if r.tl + r.bl > h { f = min(f, h / (r.tl + r.bl)); }
    if r.tr + r.br > h { f = min(f, h / (r.tr + r.br)); }
    if f < 1.0 { r.tl *= f; r.tr *= f; r.br *= f; r.bl *= f; }
    return r;
}

// Whether all four borders match, so one box item can draw them.
fn uniform_border(s: Style) -> bool {
    return s.bt > 0.0 && s.bt == s.br && s.bt == s.bb && s.bt == s.bl
        && s.bt_color == s.br_color && s.bt_color == s.bb_color && s.bt_color == s.bl_color
        && s.bt_style == s.br_style && s.bt_style == s.bb_style && s.bt_style == s.bl_style;
}

// One box item draws the background with the borders when the borders match
// and the box is rounded or dashed; otherwise the background is one item
// (a box if rounded) and each border a rect.
fn one_box(s: Style) -> bool { return uniform_border(s) && (any_radius(s) || s.bt_style == K_DASHED); }

// How many items box_paint writes for a block styled s: known before its
// height is, so they can be reserved under its content.
fn box_paint_count(s: Style) -> i64 {
    var n: i64 = 0;
    for k in s.shadow_count {
        let sd = s.shadows[k];
        guard sd.blur == 0.0 else { continue; }
        if sd.inset == 0 { n += 1; }
        else if sd.ox == 0.0 && sd.oy == 0.0 { n += 1; }
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
// as CSS paints them, all under the content. Blurred shadows aren't drawn;
// the inset ones with an offset are straight bars, their corners left square.
fn box_paint(L: Layout, n: i32, s: Style, at: i64, x: f32, y: f32, w: f32, h: f32) {
    var k = at;
    let r = radii_of(s, w, h);
    let rounded = any_radius(s);
    for i in s.shadow_count {
        let sd = s.shadows[i];
        guard sd.blur == 0.0 && sd.inset == 0 else { continue; }
        let sr = if rounded { radii_plus(r, sd.spread) } else { radii_plus(r, 0.0) };
        if sd.ox == 0.0 && sd.oy == 0.0 {
            // A ring round the box, so a box without a background shows through.
            L.items[k] = box_item(n, x - sd.spread, y - sd.spread, w + 2.0 * sd.spread, h + 2.0 * sd.spread, 0, sr,
                                  max(sd.spread, 0.0), sd.color, false);
        } else {
            L.items[k] = box_item(n, x + sd.ox - sd.spread, y + sd.oy - sd.spread, w + 2.0 * sd.spread, h + 2.0 * sd.spread,
                                  sd.color, sr, 0.0, 0, false);
        }
        k += 1;
    }
    if one_box(s) {
        L.items[k] = box_item(n, x, y, w, h, s.bg, r, s.bt, border_color(s.bt_color, s), s.bt_style == K_DASHED);
        k += 1;
    } else {
        if (s.bg >> 24) != 0 {
            L.items[k] = if rounded { box_item(n, x, y, w, h, s.bg, r, 0.0, 0, false) } else { rect_item(n, x, y, w, h, s.bg) };
            k += 1;
        }
    }
    // The padding box, where inset shadows go.
    let px = x + s.bl;
    let py = y + s.bt;
    let pw = max(w - s.bl - s.br, 0.0);
    let ph = max(h - s.bt - s.bb, 0.0);
    for i in s.shadow_count {
        let sd = s.shadows[i];
        guard sd.blur == 0.0 && sd.inset != 0 else { continue; }
        if sd.ox == 0.0 && sd.oy == 0.0 {
            L.items[k] = box_item(n, px, py, pw, ph, 0, radii_plus(r, -s.bt), max(sd.spread, 0.0), sd.color, false);
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
        if is_block_level(L, c) && is_empty_block(L, c) {
            // Its margins collapse through it into the ones around it; at the
            // top, top_margin has already passed them up to n.
            if !at_top { margin = collapse(margin, collapse(L.styles[c].mt, L.styles[c].mb)); }
            c = L.d.nodes[c].next;
            continue;
        }
        if is_block_level(L, c) {
            if at_top { at_top = false; }
            else { cy += collapse(margin, top_margin(L, c)); }
            let h, b, mb = layout_block(L, c, x, cy, w);
            if first < 0.0 && b >= 0.0 { first = b; }
            cy += h;
            margin = mb;
            c = L.d.nodes[c].next;
            continue;
        }
        // A run of inline content, up to the next block.
        var end = c;
        var blank = true;
        while end >= 0 && !is_block_level(L, end) {
            if !is_blank(L, end) { blank = false; }
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
                      content: false, space: false, trailing: 0.0, align: s.align, first_baseline: -1.0 };
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
    if node_name(L.d, n) == "br" { close_line(L, line, true); return; }
    let s = L.styles[n];
    // A block inside inline content gets lines of its own; its margins and
    // markers wait for block-in-inline splitting.
    let own_lines = is_block_level(L, n);
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
        // No break between this run and the text before it without a space.
        let glued = i == 0 && line.content && !line.space;
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
        i = j;
    }
    if piece >= 0 { emit_text(L, line, run, s, piece, run.len, piece_x, raise); }
}

// How far above its line's baseline text node n sits: the shifts of the
// superscripts and subscripts it is in, up to its block.
fn raise_of(L: Layout, n: i32) -> f32 {
    var raise: f32 = 0.0;
    var e = L.d.nodes[n].parent;
    while e >= 0 && L.d.nodes[e].kind == NODE_ELEMENT && !is_block_level(L, e) {
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
                guard at >= 0 && L.d.nodes[at].kind == NODE_ELEMENT && !is_block_level(L, at) && !ends_unit(L, at) else { return -1; }
            }
            at = L.d.nodes[at].next;
        }
        let node = L.d.nodes[at];
        if node.kind == NODE_TEXT { return at; }
        enter = node.kind == NODE_ELEMENT && L.styles[at].display != K_NONE;
        guard !enter || (!is_block_level(L, at) && !ends_unit(L, at) && node_name(L.d, at) != "br") else { return -1; }
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
        let used = line.x - (if line.space { line.trailing } else { 0.0 });
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
        if line.first_baseline < 0.0 { line.first_baseline = baseline; }
        line.y += height;
    }
    line.x = 0.0;
    line.ascent = line.strut_ascent;
    line.descent = line.strut_descent;
    line.first_item = L.items.len;
    line.content = false;
    line.space = false;
    line.trailing = 0.0;
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
    let inline = L.d.nodes[n].kind == NODE_ELEMENT && !is_block_level(L, n) && L.styles[n].display != K_NONE;
    var c = L.d.nodes[n].first;
    while c >= 0 {
        let cb = inline_boxes(L, c);
        if inline { b = first_line(b, cb); }
        c = L.d.nodes[c].next;
    }
    L.boxes[n] = b;
    return b;
}
