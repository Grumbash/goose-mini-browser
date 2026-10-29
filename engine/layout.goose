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

// One item of the display list, laid out as the compositor's DItem: positions
// in points from the page's top-left; a text item's y is its baseline and its
// text a span of the layout's text.
struct DItem {
    kind: i32,
    x: f32, y: f32, w: f32, h: f32,
    color: u32,              // 0xAARRGGBB
    font: i32, size: f32,    // text: the font id (see font_of) and size in points
    text: i32, text_len: i32,
    node: i32,               // the node it paints
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
    guard s.display == K_BLOCK && s.bt == 0.0 && s.pt == 0.0 && s.pb == 0.0 && s.bb == 0.0 else { return false; }
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
    var w = avail - s.ml - s.mr - s.pl - s.pr;
    if s.width >= 0.0 { w = s.width; }
    else if s.width_pct >= 0.0 { w = avail * s.width_pct / 100.0; }
    var limit: f32 = -1.0;
    if s.max_width >= 0.0 { limit = s.max_width; }
    else if s.max_width_pct >= 0.0 { limit = avail * s.max_width_pct / 100.0; }
    if limit >= 0.0 && w > limit { w = limit; }
    if w < 0.0 { w = 0.0; }
    var ml = s.ml;
    let room = avail - w - s.pl - s.pr;
    if s.auto_ml != 0 && s.auto_mr != 0 { ml = max(room / 2.0, 0.0); }
    else if s.auto_ml != 0 { ml = max(room - s.mr, 0.0); }
    let bx = x + ml;
    let bw = w + s.pl + s.pr;

    var bg: i64 = -1;
    if (s.bg >> 24) != 0 {
        bg = L.items.len;
        L.items.push(rect_item(n, bx, y, bw, 0.0, s.bg));
    }
    let root = L.d.nodes[n].parent == 0;
    let absorb_bottom = !root && s.bb == 0.0 && s.pb == 0.0;
    let inner, first, trailing = layout_children(L, n, bx + s.pl, y + s.bt + s.pt, w, !root && s.bt == 0.0 && s.pt == 0.0);
    var ch = inner;
    var mb = s.mb;
    if absorb_bottom { mb = collapse(mb, trailing); } else { ch += trailing; }
    let h = s.bt + s.pt + ch + s.pb + s.bb;
    if bg >= 0 { L.items[bg].h = h; }
    let top = border_color(s.bt_color, s);
    let bottom = border_color(s.bb_color, s);
    if s.bt > 0.0 && (top >> 24) != 0 { L.items.push(rect_item(n, bx, y, bw, s.bt, top)); }
    if s.bb > 0.0 && (bottom >> 24) != 0 { L.items.push(rect_item(n, bx, y + h - s.bb, bw, s.bb, bottom)); }
    if s.display == K_LIST_ITEM { paint_marker(L, n, bx + s.pl, first); }
    L.boxes[n] = Rect { x: bx, y: y, w: bw, h: h };
    return h, first, mb;
}

// currentColor, a border's colour unless it has its own, is the text's.
fn border_color(c: u32, s: Style) -> u32 { return if c == CURRENT_COLOR { s.color } else { c }; }

fn rect_item(n: i32, x: f32, y: f32, w: f32, h: f32, color: u32) -> DItem {
    return DItem { kind: ITEM_RECT, x: x, y: y, w: w, h: h, color: color, font: 0, size: 0.0, text: 0, text_len: 0, node: n };
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
    L.items.push(DItem { kind: ITEM_TEXT, x: line.left + x, y: -raise, w: L.carets[c + to] - L.carets[c + from], h: 0.0,
                         color: s.color, font: font_of(s), size: s.font_size,
                         text: run.start + from, text_len: to - from, node: run.node });
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
    L.items.push(DItem { kind: ITEM_TEXT, x: content_x - w - s.font_size * 0.45, y: baseline, w: w, h: 0.0,
                         color: s.color, font: font_of(s), size: s.font_size,
                         text: run.start, text_len: run.len, node: li });
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
