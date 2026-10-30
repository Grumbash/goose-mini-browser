// Inline SVG (docs/adr/0010): what is inside an <svg> is drawn as paths.
// Each shape is filled and stroked as its paint says and becomes a Painted
// path: moves, lines, cubic curves and closes in a shared array of path
// data, in points from its corner, which the platform rasterizes as a mask
// and tints, like a glyph. Shapes are placed by the viewBox, transform
// attributes and CSS transforms; a <use> draws a <symbol> or another
// element, whose paint then comes from the <use>.
//
// Not yet: gradients and patterns (a url() paint takes its fallback), clip
// paths, masks, markers, text, images and dashed strokes.

import std;
import math;
import .dom;
import .css;

let PATH_MOVE: f32 = 0.0;    // x y
let PATH_LINE: f32 = 1.0;    // x y
let PATH_CUBIC: f32 = 2.0;   // x1 y1 x2 y2 x y
let PATH_CLOSE: f32 = 3.0;
let PATH_CLIP: f32 = 4.0;    // n, then n corners x y: a convex polygon the path shows inside, last

// How a path is painted, as the platform reads Painted.flags.
let PATH_EVENODD: i32 = 1;
let PATH_CAP_ROUND: i32 = 2;
let PATH_CAP_SQUARE: i32 = 4;
let PATH_JOIN_ROUND: i32 = 8;
let PATH_JOIN_BEVEL: i32 = 16;

// The deepest groups and uses go inside one another.
let SVG_DEPTH_MAX: i32 = 32;

// The most elements one <svg> draws, each drawing of a <use> counted again:
// more than any real drawing has, few enough that <use>s which multiply one
// another can't make it draw billions.
let SVG_ELEMENTS_MAX: i32 = 100000;

// A path to paint: its span of the path data, in points from (x, y); what
// it may cover from there, w × h, its stroke included; its colour, opacity
// applied; its stroke's width in points, 0 to fill it; and its PATH_ flags.
struct Painted { start: i32, len: i32, x: f32, y: f32, w: f32, h: f32, color: u32, stroke: f32, flags: i32 }

// x' = a x + c y + e, y' = b x + d y + f, as CSS's matrix() has it.
struct Affine { a: f32, b: f32, c: f32, d: f32, e: f32, f: f32 }

// What nested viewports leave visible, on the page: a convex polygon of n
// corners, n -1 for no limit and 0 for nothing.
struct Clip { n: i32, x: f32[CLIP_CORNERS], y: f32[CLIP_CORNERS] }

// The most corners a clip keeps: four viewports turned every way.
let CLIP_CORNERS: i64 = 16;

// A clip of n corners, all at (0, 0) for now.
fn clip_of(n: i32) -> Clip {
    let z: f32[CLIP_CORNERS] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    return Clip { n: n, x: z, y: z };
}

fn affine(a: f32, b: f32, c: f32, d: f32, e: f32, f: f32) -> Affine { return Affine { a: a, b: b, c: c, d: d, e: e, f: f }; }
fn shift(x: f32, y: f32) -> Affine { return affine(1.0, 0.0, 0.0, 1.0, x, y); }

// n, then m.
fn times(m: Affine, n: Affine) -> Affine {
    return affine(m.a * n.a + m.c * n.b, m.b * n.a + m.d * n.b, m.a * n.c + m.c * n.d, m.b * n.c + m.d * n.d,
                  m.a * n.e + m.c * n.f + m.e, m.b * n.e + m.d * n.f + m.f);
}

// What a shape inherits, which inside a <use> is the <use>'s rather than its
// own parent's: its paint, its stroke's width, caps and joins, its fill rule
// and the text colour that currentColor is.
struct Inherited { fill: u32, stroke: u32, width: f32, width_pct: i32, cap: i32, join: i32, rule: i32, color: u32,
                   fill_opacity: f32, stroke_opacity: f32 }

fn inherited(s: Style) -> Inherited {
    return Inherited { fill: s.fill, stroke: s.stroke, width: s.stroke_width, width_pct: s.stroke_pct, cap: s.linecap,
                       join: s.linejoin, rule: s.fill_rule, color: s.color, fill_opacity: s.fill_opacity,
                       stroke_opacity: s.stroke_opacity };
}

// What style s's own declarations set, the rest from `up`.
fn paint_of(s: Style, up: Inherited) -> Inherited {
    var p = up;
    if (s.svg_set & SVG_FILL) != 0 { p.fill = s.fill; }
    if (s.svg_set & SVG_STROKE) != 0 { p.stroke = s.stroke; }
    if (s.svg_set & SVG_STROKE_WIDTH) != 0 { p.width = s.stroke_width; p.width_pct = s.stroke_pct; }
    if (s.svg_set & SVG_LINECAP) != 0 { p.cap = s.linecap; }
    if (s.svg_set & SVG_LINEJOIN) != 0 { p.join = s.linejoin; }
    if (s.svg_set & SVG_FILL_RULE) != 0 { p.rule = s.fill_rule; }
    if (s.svg_set & SVG_COLOR) != 0 { p.color = s.color; }
    if (s.svg_set & SVG_FILL_OPACITY) != 0 { p.fill_opacity = s.fill_opacity; }
    if (s.svg_set & SVG_STROKE_OPACITY) != 0 { p.stroke_opacity = s.stroke_opacity; }
    return p;
}

// What drawing one <svg>'s content works with: its document, the styles and
// the table of ids (index_ids); the <use>s being drawn, innermost last; how
// many more elements it may draw; and the path data and paths it adds to.
struct Drawing { d: Doc, styles: Style[>..]&, ids: i32[>..]&, uses: i32[>..<]&, left: i32,
                 paths: f32[>..<]&, out: Painted[>..<]& }

// The content of <svg> n, whose content box is w × h at (x, y) on the page,
// as paths into `out`, their data into `paths`.
fn draw_svg(d: Doc, styles: Style[>..]&, ids: i32[>..]&, n: i32, x: f32, y: f32, w: f32, h: f32,
            paths: f32[>..<]&, out: Painted[>..<]&) {
    guard w > 0.0 && h > 0.0;
    var uses: i32[>..<] = [];
    var V = Drawing { d: d, styles: styles, ids: ids, uses: uses, left: SVG_ELEMENTS_MAX, paths: paths, out: out };
    let vw, vh = view_size(d, n, w, h);
    // Its own box clips through layout; what is inside, here.
    draw_children(V, n, times(shift(x, y), fit_view(d, n, w, h)), inherited(styles[n]), 1.0, vw, vh, clip_of(-1), 0);
}

recursive fn draw_children(V: Drawing&, n: i32, m: Affine, up: Inherited, alpha: f32, vw: f32, vh: f32, clip: Clip,
                           depth: i32) {
    var c = V.d.nodes[n].first;
    while c >= 0 {
        if V.d.nodes[c].kind == NODE_ELEMENT { draw_node(V, c, m, up, alpha, vw, vh, clip, depth); }
        c = V.d.nodes[c].next;
    }
}

// Element e, its user space taken to the page by m: a group's children, a
// nested <svg>'s in its viewport, what a <use> refers to, or a shape.
// vw × vh is the viewport that percentages count in.
recursive fn draw_node(V: Drawing&, e: i32, m: Affine, up: Inherited, alpha: f32, vw: f32, vh: f32, clip: Clip,
                       depth: i32) {
    let s = V.styles[e];
    guard s.display != K_NONE && depth < SVG_DEPTH_MAX && V.left > 0;
    V.left -= 1;
    let a = alpha * s.opacity;
    guard a > 0.0;
    let p = paint_of(s, up);
    let own = times(m, local_transform(V, e, vw, vh, depth));
    let name = node_name(V.d, e);
    if name == "g" || name == "a" || name == "switch" {
        draw_children(V, e, own, p, a, vw, vh, clip, depth + 1);
    } else if name == "svg" {
        // A viewport of its own: x, y, width and height, then its viewBox.
        let at, iw, ih, ok = viewport(V.d, e, own, -1.0, -1.0, vw, vh);
        guard ok;
        draw_children(V, e, at, p, a, iw, ih, viewport_clip(V, e, own, -1.0, -1.0, vw, vh, clip), depth + 1);
    } else if name == "use" {
        let t = use_target(V, e);
        guard t > 0;
        let at = times(own, shift(length_attr(V.d, e, "x", vw, 0.0), length_attr(V.d, e, "y", vh, 0.0)));
        let tname = node_name(V.d, t);
        V.uses.push(e);
        if tname == "symbol" || tname == "svg" {
            // Its viewBox fits the <use>'s width and height, or its own, or
            // all of the viewport.
            let inner, iw, ih, ok = viewport(V.d, t, at, length_attr(V.d, e, "width", vw, -1.0),
                                             length_attr(V.d, e, "height", vh, -1.0), vw, vh);
            let uw = length_attr(V.d, e, "width", vw, -1.0);
            let uh = length_attr(V.d, e, "height", vh, -1.0);
            if ok { draw_children(V, t, inner, paint_of(V.styles[t], p), a, iw, ih, viewport_clip(V, t, at, uw, uh, vw, vh, clip), depth + 1); }
        } else {
            draw_node(V, t, at, p, a, vw, vh, clip, depth + 1);
        }
        V.uses.pop();
    } else {
        draw_shape(V, e, name, own, p, a, vw, vh, clip);
    }
}

// What takes the content of viewport element e, a nested <svg> or a
// <symbol> that a <use> draws, onto the page, its parent's user space
// taken there by m: its x and y, then its width and height (w and h when
// they aren't below 0, else its own, else the parent viewport's, pw × ph)
// fitted by its viewBox. Also the size of its user space, and whether it
// has any.
fn viewport(d: Doc, e: i32, m: Affine, w: f32, h: f32, pw: f32, ph: f32) -> Affine, f32, f32, bool {
    let nx, ny, nw, nh = viewport_box(d, e, w, h, pw, ph);
    guard nw > 0.0 && nh > 0.0 else { return m, 0.0, 0.0, false; }
    let iw, ih = view_size(d, e, nw, nh);
    return times(m, times(shift(nx, ny), fit_view(d, e, nw, nh))), iw, ih, true;
}

// Viewport element e's box in its parent's user space: x, y, width and
// height, as viewport() takes them.
fn viewport_box(d: Doc, e: i32, w: f32, h: f32, pw: f32, ph: f32) -> f32, f32, f32, f32 {
    let nx = length_attr(d, e, "x", pw, 0.0);
    let ny = length_attr(d, e, "y", ph, 0.0);
    let nw = if w >= 0.0 { w } else { length_attr(d, e, "width", pw, pw) };
    let nh = if h >= 0.0 { h } else { length_attr(d, e, "height", ph, ph) };
    return nx, ny, nw, nh;
}

// What is visible inside viewport element e as well as `clip`: its box, which
// m takes to the page, unless its overflow shows.
fn viewport_clip(V: Drawing&, e: i32, m: Affine, w: f32, h: f32, pw: f32, ph: f32, clip: Clip) -> Clip {
    guard V.styles[e].clips != 0 else { return clip; }
    let x, y, bw, bh = viewport_box(V.d, e, w, h, pw, ph);
    var box = clip_of(4);
    let xs: f32[4] = [x, x + bw, x + bw, x];
    let ys: f32[4] = [y, y, y + bh, y + bh];
    for k in 4 {
        box.x[k] = m.a * xs[k] + m.c * ys[k] + m.e;
        box.y[k] = m.b * xs[k] + m.d * ys[k] + m.f;
    }
    return cut(clip, box);
}

// The part of convex polygon a inside convex polygon b (Sutherland and
// Hodgman), where a limit of -1 corners is none.
fn cut(a: Clip, b: Clip) -> Clip {
    guard a.n >= 0 else { return b; }
    guard b.n >= 0 else { return a; }
    var out = a;
    // Which side of b's edges its inside is on, as its corners turn.
    var area: f32 = 0.0;
    for i in b.n { let j = (i + 1) % b.n; area += b.x[i] * b.y[j] - b.x[j] * b.y[i]; }
    let turn: f32 = if area < 0.0 { -1.0 } else { 1.0 };
    for i in b.n {
        guard out.n > 0 else { return out; }
        let j = (i + 1) % b.n;
        let ex = b.x[j] - b.x[i];
        let ey = b.y[j] - b.y[i];
        var next = clip_of(0);
        for k in out.n {
            let l = (k + 1) % out.n;
            let sk = turn * (ex * (out.y[k] - b.y[i]) - ey * (out.x[k] - b.x[i]));
            let sl = turn * (ex * (out.y[l] - b.y[i]) - ey * (out.x[l] - b.x[i]));
            if sk >= 0.0 && next.n < CLIP_CORNERS {
                next.x[next.n] = out.x[k];
                next.y[next.n] = out.y[k];
                next.n += 1;
            }
            if (sk >= 0.0) != (sl >= 0.0) && next.n < CLIP_CORNERS {
                // Where the edge from corner k to corner l crosses b's.
                let t = sk / (sk - sl);
                next.x[next.n] = out.x[k] + t * (out.x[l] - out.x[k]);
                next.y[next.n] = out.y[k] + t * (out.y[l] - out.y[k]);
                next.n += 1;
            }
        }
        out = next;
    }
    return out;
}

// Whether point (x, y) is inside convex polygon c, its edges included.
fn in_clip(c: Clip, x: f32, y: f32) -> bool {
    var area: f32 = 0.0;
    for i in c.n { let j = (i + 1) % c.n; area += c.x[i] * c.y[j] - c.x[j] * c.y[i]; }
    let turn: f32 = if area < 0.0 { -1.0 } else { 1.0 };
    for i in c.n {
        let j = (i + 1) % c.n;
        guard turn * ((c.x[j] - c.x[i]) * (y - c.y[i]) - (c.y[j] - c.y[i]) * (x - c.x[i])) >= -0.001 else { return false; }
    }
    return true;
}

// What <use> e draws: the element its href names, unless that holds e or a
// <use> being drawn, so that it would draw itself (SVG 2 §5.6.1); else -1.
fn use_target(V: Drawing&, e: i32) -> i32 {
    let href1, has1 = attr_value(V.d, e, "href");
    let href2, has2 = attr_value(V.d, e, "xlink:href");
    let href = if has1 { href1 } else { href2 };
    guard (has1 || has2) && href.len > 1 && href[0] == '#' else { return -1; }
    let t = element_by_id(V.d, V.ids[..], href[1..]);
    guard t > 0 && !holds(V.d, t, e) else { return -1; }
    for u in V.uses { if holds(V.d, t, u) { return -1; } }
    return t;
}

// Whether element t is node n or one of its ancestors.
fn holds(d: Doc, t: i32, n: i32) -> bool {
    var k = n;
    while k >= 0 {
        if k == t { return true; }
        k = d.nodes[k].parent;
    }
    return false;
}

// Shape e, with its points taken to the page by m: filled, then stroked.
fn draw_shape(V: Drawing&, e: i32, name: const u8[:], m: Affine, p: Inherited, alpha: f32, vw: f32, vh: f32, clip: Clip) {
    guard clip.n != 0;
    let start = V.paths.len;
    add_shape(V.d, e, name, m, vw, vh, V.paths);
    guard V.paths.len > start;
    let fill = faded(if p.fill == CURRENT_COLOR { p.color } else { p.fill }, alpha * p.fill_opacity);
    let stroke = faded(if p.stroke == CURRENT_COLOR { p.color } else { p.stroke }, alpha * p.stroke_opacity);
    // A stroke's width in user units, a percentage of the viewport's
    // diagonal over the square root of 2; on the page, scaled as the shape
    // is, on average.
    let width = if p.width_pct != 0 { p.width / 100.0 * sqrt((vw * vw + vh * vh) / 2.0) } else { p.width };
    let sw = if (stroke >> 24) != 0 { width * sqrt(abs(m.a * m.d - m.b * m.c)) } else { 0.0 };
    // A line has no inside to fill (SVG 2 §10.6).
    let fills = (fill >> 24) != 0 && name != "line";
    if !fills && sw <= 0.0 { V.paths.resize(start); return; }
    // What a stroke may reach past the points: half its width, four times
    // that at a sharp miter.
    let reach = if sw > 0.0 { sw * (if p.join == K_MITER { 2.0 } else { 1.0 }) } else { 0.0 };
    let px0, py0, px1, py1 = path_bounds(V.paths[..], start);
    var ox = px0 - reach;
    var oy = py0 - reach;
    var ex = px1 + reach;
    var ey = py1 + reach;
    if clip.n > 0 {
        // Cut where it leaves what nested viewports show; nothing at all
        // when it is all outside them.
        var cx0: f32 = clip.x[0];
        var cy0: f32 = clip.y[0];
        var cx1: f32 = clip.x[0];
        var cy1: f32 = clip.y[0];
        for k in clip.n {
            cx0 = min(cx0, clip.x[k]);
            cy0 = min(cy0, clip.y[k]);
            cx1 = max(cx1, clip.x[k]);
            cy1 = max(cy1, clip.y[k]);
        }
        if ex <= cx0 || ox >= cx1 || ey <= cy0 || oy >= cy1 { V.paths.resize(start); return; }
        if !(in_clip(clip, ox, oy) && in_clip(clip, ex, oy) && in_clip(clip, ex, ey) && in_clip(clip, ox, ey)) {
            V.paths.push(PATH_CLIP);
            V.paths.push(clip.n);
            for k in clip.n {
                V.paths.push(clip.x[k]);
                V.paths.push(clip.y[k]);
            }
            ox = max(ox, cx0);
            oy = max(oy, cy0);
            ex = min(ex, cx1);
            ey = min(ey, cy1);
        }
    }
    move_path(V.paths[..], start, -ox, -oy);
    let span = (V.paths.len - start) as i32;
    if fills {
        V.out.push(Painted { start: start as i32, len: span, x: ox, y: oy, w: ex - ox, h: ey - oy,
                             color: fill, stroke: 0.0, flags: if p.rule == K_EVENODD { PATH_EVENODD } else { 0 } });
    }
    if sw > 0.0 {
        var flags: i32 = 0;
        if p.cap == K_ROUND { flags = flags | PATH_CAP_ROUND; } else if p.cap == K_SQUARE { flags = flags | PATH_CAP_SQUARE; }
        if p.join == K_ROUND { flags = flags | PATH_JOIN_ROUND; } else if p.join == K_BEVEL { flags = flags | PATH_JOIN_BEVEL; }
        V.out.push(Painted { start: start as i32, len: span, x: ox, y: oy, w: ex - ox, h: ey - oy,
                             color: stroke, stroke: sw, flags: flags });
    }
}

fn faded(c: u32, a: f32) -> u32 {
    guard a < 1.0 else { return c; }
    let alpha = ((c >> 24) * a + 0.5) as u32;
    return (c & 0xFFFFFF) | (alpha << 24);
}

// ------------------------------------------------------------------ geometry

// Shape e's outline, its points through m, as path data: a path, rect,
// circle, ellipse, line, polyline or polygon. Lengths are user units; a
// percentage counts in the viewport, vw × vh. Anything else adds nothing.
fn add_shape(d: Doc, e: i32, name: const u8[:], m: Affine, vw: f32, vh: f32, paths: f32[>..<]&) {
    if name == "path" {
        let data, has = attr_value(d, e, "d");
        if has { add_path_data(data, m, paths); }
    } else if name == "rect" {
        let x = length_attr(d, e, "x", vw, 0.0);
        let y = length_attr(d, e, "y", vh, 0.0);
        let w = length_attr(d, e, "width", vw, 0.0);
        let h = length_attr(d, e, "height", vh, 0.0);
        guard w > 0.0 && h > 0.0;
        // A radius left out is the other one; both are at most half a side,
        // and with either 0 the corners are square.
        var rx = length_attr(d, e, "rx", vw, -1.0);
        var ry = length_attr(d, e, "ry", vh, -1.0);
        if rx < 0.0 { rx = ry; }
        if ry < 0.0 { ry = rx; }
        rx = clamp(rx, 0.0, w / 2.0);
        ry = clamp(ry, 0.0, h / 2.0);
        if rx == 0.0 || ry == 0.0 {
            rx = 0.0;
            ry = 0.0;
        }
        add_point(paths, PATH_MOVE, m, x + rx, y);
        add_point(paths, PATH_LINE, m, x + w - rx, y);
        if rx > 0.0 && ry > 0.0 { add_quarter(paths, m, x + w - rx, y, x + w, y + ry, 1.0, 0.0); }
        add_point(paths, PATH_LINE, m, x + w, y + h - ry);
        if rx > 0.0 && ry > 0.0 { add_quarter(paths, m, x + w, y + h - ry, x + w - rx, y + h, 0.0, 1.0); }
        add_point(paths, PATH_LINE, m, x + rx, y + h);
        if rx > 0.0 && ry > 0.0 { add_quarter(paths, m, x + rx, y + h, x, y + h - ry, -1.0, 0.0); }
        add_point(paths, PATH_LINE, m, x, y + ry);
        if rx > 0.0 && ry > 0.0 { add_quarter(paths, m, x, y + ry, x + rx, y, 0.0, -1.0); }
        paths.push(PATH_CLOSE);
    } else if name == "circle" || name == "ellipse" {
        let cx = length_attr(d, e, "cx", vw, 0.0);
        let cy = length_attr(d, e, "cy", vh, 0.0);
        var rx: f32 = 0.0;
        var ry: f32 = 0.0;
        if name == "circle" {
            rx = length_attr(d, e, "r", sqrt((vw * vw + vh * vh) / 2.0), 0.0);
            ry = rx;
        } else {
            rx = length_attr(d, e, "rx", vw, -1.0);
            ry = length_attr(d, e, "ry", vh, -1.0);
            if rx < 0.0 { rx = ry; }
            if ry < 0.0 { ry = rx; }
        }
        guard rx > 0.0 && ry > 0.0;
        add_point(paths, PATH_MOVE, m, cx + rx, cy);
        add_quarter(paths, m, cx + rx, cy, cx, cy + ry, 0.0, 1.0);
        add_quarter(paths, m, cx, cy + ry, cx - rx, cy, -1.0, 0.0);
        add_quarter(paths, m, cx - rx, cy, cx, cy - ry, 0.0, -1.0);
        add_quarter(paths, m, cx, cy - ry, cx + rx, cy, 1.0, 0.0);
        paths.push(PATH_CLOSE);
    } else if name == "line" {
        add_point(paths, PATH_MOVE, m, length_attr(d, e, "x1", vw, 0.0), length_attr(d, e, "y1", vh, 0.0));
        add_point(paths, PATH_LINE, m, length_attr(d, e, "x2", vw, 0.0), length_attr(d, e, "y2", vh, 0.0));
    } else if name == "polyline" || name == "polygon" {
        let pts, has = attr_value(d, e, "points");
        guard has;
        var i: i64 = 0;
        var first = true;
        loop {
            let x, ix, okx = scan_number(pts, i);
            let y, iy, oky = scan_number(pts, ix);
            guard okx && oky else { break; }
            add_point(paths, if first { PATH_MOVE } else { PATH_LINE }, m, x, y);
            first = false;
            i = iy;
        }
        if !first && name == "polygon" { paths.push(PATH_CLOSE); }
    }
}

fn add_point(paths: f32[>..<]&, op: f32, m: Affine, x: f32, y: f32) {
    paths.push(op);
    paths.push(m.a * x + m.c * y + m.e);
    paths.push(m.b * x + m.d * y + m.f);
}

fn add_cubic(paths: f32[>..<]&, m: Affine, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
    paths.push(PATH_CUBIC);
    for v in [x1, y1, x2, y2, x, y] { paths.push(v); }
    let k = paths.len - 6;
    for j in 3 {
        let px = paths[k + 2 * j];
        let py = paths[k + 2 * j + 1];
        paths[k + 2 * j] = m.a * px + m.c * py + m.e;
        paths[k + 2 * j + 1] = m.b * px + m.d * py + m.f;
    }
}

// A quarter of an ellipse from (x0, y0) to (x1, y1), leaving the first along
// (dx, dy), as one cubic curve.
fn add_quarter(paths: f32[>..<]&, m: Affine, x0: f32, y0: f32, x1: f32, y1: f32, dx: f32, dy: f32) {
    let k: f32 = 0.5522847498;
    // The first control point goes along (dx, dy); the second comes into the
    // end at right angles to it.
    let ax = x1 - x0;
    let ay = y1 - y0;
    let c1x = x0 + dx * abs(ax) * k;
    let c1y = y0 + dy * abs(ay) * k;
    let c2x = x1 - (if dx != 0.0 { 0.0 } else { ax * k });
    let c2y = y1 - (if dy != 0.0 { 0.0 } else { ay * k });
    add_cubic(paths, m, c1x, c1y, c2x, c2y, x1, y1);
}

// Path data (SVG 2 §9.3), each point taken through m, onto `paths`. Moves,
// lines, curves and arcs, absolute and relative, become moves, lines,
// cubic curves and closes; at the first error it stops, keeping what came
// before, as browsers do.
fn add_path_data(src: const u8[:], m: Affine, paths: f32[>..<]&) {
    var i: i64 = 0;
    var cmd: u8 = 0;
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    var sx: f32 = 0.0;        // where the subpath started
    var sy: f32 = 0.0;
    var qx: f32 = 0.0;        // the last curve's last control point, for S and T
    var qy: f32 = 0.0;
    var last: u8 = 0;         // the last command, upper case
    loop {
        // A number takes the white space and one comma after it; a command
        // only white space, so a comma after a command letter is an error.
        while i < src.len && is_ws(src[i]) { i += 1; }
        guard i < src.len else { return; }
        let c = src[i];
        if is_path_command(c) {
            cmd = c;
            i += 1;
        } else if cmd == 0 || cmd == 'Z' || cmd == 'z' {
            return;
        }
        let up = cmd & 0xDF;
        let rel = cmd != up;
        guard last != 0 || up == 'M' else { return; }
        let bx: f32 = if rel { x } else { 0.0 };
        let by: f32 = if rel { y } else { 0.0 };
        if up == 'Z' {
            paths.push(PATH_CLOSE);
            x = sx;
            y = sy;
            last = 'Z';
            continue;
        }
        if up == 'M' || up == 'L' || up == 'T' {
            let nx, i1, ok1 = scan_number(src, i);
            let ny, i2, ok2 = scan_number(src, i1);
            guard ok1 && ok2 else { return; }
            i = i2;
            let px = bx + nx;
            let py = by + ny;
            if up == 'M' {
                add_point(paths, PATH_MOVE, m, px, py);
                sx = px;
                sy = py;
                // More pairs after a move are lines.
                cmd = if rel { 'l' } else { 'L' };
            } else if up == 'L' {
                add_point(paths, PATH_LINE, m, px, py);
            } else {
                // A smooth quadratic: its control point the last one's reflection.
                let cx = if last == 'Q' || last == 'T' { 2.0 * x - qx } else { x };
                let cy = if last == 'Q' || last == 'T' { 2.0 * y - qy } else { y };
                add_quad(paths, m, x, y, cx, cy, px, py);
                qx = cx;
                qy = cy;
            }
            x = px;
            y = py;
        } else if up == 'H' || up == 'V' {
            let v, i1, ok = scan_number(src, i);
            guard ok else { return; }
            i = i1;
            if up == 'H' { x = bx + v; } else { y = by + v; }
            add_point(paths, PATH_LINE, m, x, y);
        } else if up == 'C' || up == 'S' || up == 'Q' {
            let count = if up == 'C' { 6 } else { 4 };
            var v: f32[6];
            var k: i64 = i;
            for j in count {
                let n, nk, ok = scan_number(src, k);
                guard ok else { return; }
                v[j] = n + (if j % 2 == 0 { bx } else { by });
                k = nk;
            }
            i = k;
            if up == 'C' {
                add_cubic(paths, m, v[0], v[1], v[2], v[3], v[4], v[5]);
                qx = v[2];
                qy = v[3];
                x = v[4];
                y = v[5];
            } else if up == 'S' {
                let cx = if last == 'C' || last == 'S' { 2.0 * x - qx } else { x };
                let cy = if last == 'C' || last == 'S' { 2.0 * y - qy } else { y };
                add_cubic(paths, m, cx, cy, v[0], v[1], v[2], v[3]);
                qx = v[0];
                qy = v[1];
                x = v[2];
                y = v[3];
            } else {
                add_quad(paths, m, x, y, v[0], v[1], v[2], v[3]);
                qx = v[0];
                qy = v[1];
                x = v[2];
                y = v[3];
            }
        } else if up == 'A' {
            let rx, i1, ok1 = scan_number(src, i);
            let ry, i2, ok2 = scan_number(src, i1);
            let rot, i3, ok3 = scan_number(src, i2);
            let large, i4, ok4 = scan_flag(src, i3);
            let sweep, i5, ok5 = scan_flag(src, i4);
            let ex, i6, ok6 = scan_number(src, i5);
            let ey, i7, ok7 = scan_number(src, i6);
            guard ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 else { return; }
            i = i7;
            add_arc(paths, m, x, y, rx, ry, rot, large, sweep, bx + ex, by + ey);
            x = bx + ex;
            y = by + ey;
        } else {
            return;
        }
        last = up;
    }
}

fn is_path_command(c: u8) -> bool {
    let u = c & 0xDF;
    return (c >= 'A' && c <= 'z') && (u == 'M' || u == 'L' || u == 'H' || u == 'V' || u == 'C' || u == 'S' || u == 'Q'
                                      || u == 'T' || u == 'A' || u == 'Z');
}

// A quadratic curve from (x0, y0) through control point (cx, cy) to (x, y),
// as the cubic curve it is.
fn add_quad(paths: f32[>..<]&, m: Affine, x0: f32, y0: f32, cx: f32, cy: f32, x: f32, y: f32) {
    add_cubic(paths, m, x0 + 2.0 / 3.0 * (cx - x0), y0 + 2.0 / 3.0 * (cy - y0),
              x + 2.0 / 3.0 * (cx - x), y + 2.0 / 3.0 * (cy - y), x, y);
}

// An elliptical arc from (x1, y1) to (x2, y2) (SVG 2 §9.5.1, its center found
// as in Appendix B.2.4), as cubic curves of at most a quarter turn each.
fn add_arc(paths: f32[>..<]&, m: Affine, x1: f32, y1: f32, rx0: f32, ry0: f32, degrees: f32, large: bool, sweep: bool,
           x2: f32, y2: f32) {
    guard x1 != x2 || y1 != y2;
    var rx = abs(rx0);
    var ry = abs(ry0);
    if rx == 0.0 || ry == 0.0 {
        add_point(paths, PATH_LINE, m, x2, y2);
        return;
    }
    let phi = radians(degrees);
    let cp = cos(phi);
    let sp = sin(phi);
    let hx = (x1 - x2) / 2.0;
    let hy = (y1 - y2) / 2.0;
    let x1p = cp * hx + sp * hy;
    let y1p = -sp * hx + cp * hy;
    // Radii too small to reach are scaled up until they do.
    let reach = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
    if reach > 1.0 {
        rx = rx * sqrt(reach);
        ry = ry * sqrt(reach);
    }
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co = if den > 0.0 { sqrt(max(num / den, 0.0)) } else { 0.0 };
    if large == sweep { co = -co; }
    let cxp = co * rx * y1p / ry;
    let cyp = -co * ry * x1p / rx;
    let cx = cp * cxp - sp * cyp + (x1 + x2) / 2.0;
    let cy = sp * cxp + cp * cyp + (y1 + y2) / 2.0;
    let ux = (x1p - cxp) / rx;
    let uy = (y1p - cyp) / ry;
    let vx = (-x1p - cxp) / rx;
    let vy = (-y1p - cyp) / ry;
    let t1 = atan2(uy, ux);
    var dt = atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if !sweep && dt > 0.0 { dt = dt - 6.2831853; } else if sweep && dt < 0.0 { dt = dt + 6.2831853; }
    let n = max(ceil(abs(dt) / 1.5707964 - 0.001) as i64, 1);
    let step = dt / n;
    let k = 4.0 / 3.0 * tan(step / 4.0);
    var t = t1;
    for j in n {
        let c1 = cos(t);
        let s1 = sin(t);
        let c2 = cos(t + step);
        let s2 = sin(t + step);
        // The unit circle's arc from t to t + step, then stretched, turned and
        // moved onto the ellipse; it ends exactly where the arc does.
        let ax1, ay1 = on_ellipse(cx, cy, rx, ry, cp, sp, c1 - k * s1, s1 + k * c1);
        let ax2, ay2 = on_ellipse(cx, cy, rx, ry, cp, sp, c2 + k * s2, s2 - k * c2);
        let px, py = on_ellipse(cx, cy, rx, ry, cp, sp, c2, s2);
        let last = j == n - 1;
        add_cubic(paths, m, ax1, ay1, ax2, ay2, if last { x2 } else { px }, if last { y2 } else { py });
        t = t + step;
    }
}

fn on_ellipse(cx: f32, cy: f32, rx: f32, ry: f32, cp: f32, sp: f32, ux: f32, uy: f32) -> f32, f32 {
    return cx + rx * ux * cp - ry * uy * sp, cy + rx * ux * sp + ry * uy * cp;
}

// The number at s[i], white space before it skipped: its value, where the
// white space and at most one comma after it end, and whether there was
// one. 1.5.5 is two numbers; 1. is none, a point needing a digit after it.
fn scan_number(s: const u8[:], i: i64) -> f32, i64, bool {
    var k = i;
    while k < s.len && is_ws(s[k]) { k += 1; }
    let st = k;
    if k < s.len && (s[k] == '+' || s[k] == '-') { k += 1; }
    var digits = false;
    while k < s.len && s[k] >= '0' && s[k] <= '9' { k += 1; digits = true; }
    if k < s.len && s[k] == '.' {
        guard k + 1 < s.len && s[k + 1] >= '0' && s[k + 1] <= '9' else { return 0.0, i, false; }
        k += 1;
        while k < s.len && s[k] >= '0' && s[k] <= '9' { k += 1; digits = true; }
    }
    guard digits else { return 0.0, i, false; }
    if k < s.len && (s[k] == 'e' || s[k] == 'E') {
        var j = k + 1;
        if j < s.len && (s[j] == '+' || s[j] == '-') { j += 1; }
        if j < s.len && s[j] >= '0' && s[j] <= '9' {
            while j < s.len && s[j] >= '0' && s[j] <= '9' { j += 1; }
            k = j;
        }
    }
    let v, ok = parse_flt(s[st..k]);
    guard ok && v > -3.0e38 && v < 3.0e38 else { return 0.0, i, false; }
    return v as f32, past_separator(s, k), true;
}

// An arc's flag, 0 or 1, which may run into the number after it, as
// scan_number reads a number.
fn scan_flag(s: const u8[:], i: i64) -> bool, i64, bool {
    var k = i;
    while k < s.len && is_ws(s[k]) { k += 1; }
    guard k < s.len && (s[k] == '0' || s[k] == '1') else { return false, i, false; }
    return s[k] == '1', past_separator(s, k + 1), true;
}

// Past white space with at most one comma in it, from s[i].
fn past_separator(s: const u8[:], i: i64) -> i64 {
    var k = i;
    while k < s.len && is_ws(s[k]) { k += 1; }
    if k < s.len && s[k] == ',' {
        k += 1;
        while k < s.len && is_ws(s[k]) { k += 1; }
    }
    return k;
}

// Attribute `name` of e as a length in user units: a number, px, or a
// percentage of `base`; `def` when it is missing or isn't one.
fn length_attr(d: Doc, e: i32, name: const u8[:], base: f32, def: f32) -> f32 {
    let v, has = attr_value(d, e, name);
    guard has else { return def; }
    let n, k, ok = scan_number(v, 0);
    guard ok else { return def; }
    let unit = trim(v[k..]);
    if unit.len == 0 || unit == "px" { return n; }
    if unit == "%" { return n / 100.0 * base; }
    if unit == "pt" { return n * 4.0 / 3.0; }
    return def;
}

// The bounds of the path data from `start` on: its points, and how far its
// curves reach between them.
fn path_bounds(paths: const f32[:], start: i64) -> f32, f32, f32, f32 {
    var x0: f32 = 1000000000.0;
    var y0: f32 = 1000000000.0;
    var x1: f32 = -1000000000.0;
    var y1: f32 = -1000000000.0;
    var px: f32 = 0.0;        // the current point
    var py: f32 = 0.0;
    var sx: f32 = 0.0;        // where the subpath started
    var sy: f32 = 0.0;
    var k = start;
    while k < paths.len {
        let op = paths[k];
        if op == PATH_CLIP { break; }
        if op == PATH_CLOSE {
            px = sx;
            py = sy;
            k += 1;
            continue;
        }
        // Where it ends, and for a curve where it turns along each axis.
        let n: i64 = if op == PATH_CUBIC { 5 } else { 1 };
        let ex = paths[k + n];
        let ey = paths[k + n + 1];
        if op == PATH_CUBIC {
            let ax = paths[k + 1];
            let ay = paths[k + 2];
            let bx = paths[k + 3];
            let by = paths[k + 4];
            let tx1, tx2 = turns(px, ax, bx, ex);
            let ty1, ty2 = turns(py, ay, by, ey);
            for t in [tx1, tx2, ty1, ty2] {
                guard t >= 0.0 else { continue; }
                let cx = bezier(px, ax, bx, ex, t);
                let cy = bezier(py, ay, by, ey, t);
                x0 = min(x0, cx);
                y0 = min(y0, cy);
                x1 = max(x1, cx);
                y1 = max(y1, cy);
            }
        }
        x0 = min(x0, ex);
        y0 = min(y0, ey);
        x1 = max(x1, ex);
        y1 = max(y1, ey);
        if op == PATH_MOVE {
            sx = ex;
            sy = ey;
        }
        px = ex;
        py = ey;
        k += if op == PATH_CUBIC { 7 } else { 3 };
    }
    if x1 < x0 { return 0.0, 0.0, 0.0, 0.0; }
    return x0, y0, x1, y1;
}

// Where a cubic curve from a through b and c to d turns along one axis: up
// to two parameters between 0 and 1, -1 for none.
fn turns(a: f32, b: f32, c: f32, d: f32) -> f32, f32 {
    // Its slope over 3 is (b - a)(1 - t)² + 2(c - b)(1 - t)t + (d - c)t².
    let p = b - a;
    let q = c - b;
    let r = d - c;
    let qa = p - 2.0 * q + r;
    let qb = 2.0 * (q - p);
    if abs(qa) < 0.000001 {
        guard abs(qb) > 0.000001 else { return -1.0, -1.0; }
        return between(-p / qb), -1.0;
    }
    let disc = qb * qb - 4.0 * qa * p;
    guard disc >= 0.0 else { return -1.0, -1.0; }
    let root = sqrt(disc);
    return between((-qb + root) / (2.0 * qa)), between((-qb - root) / (2.0 * qa));
}

fn between(t: f32) -> f32 { return if t > 0.0 && t < 1.0 { t } else { -1.0 }; }

// A cubic curve from a through b and c to d, along one axis, at t.
fn bezier(a: f32, b: f32, c: f32, d: f32, t: f32) -> f32 {
    let u = 1.0 - t;
    return u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d;
}

// Moves the points of the path data from `start` on by (dx, dy), a clip's
// corners too.
fn move_path(paths: f32[:], start: i64, dx: f32, dy: f32) {
    var k = start;
    while k < paths.len {
        // A clip's corners come after its count.
        let clip = paths[k] == PATH_CLIP;
        let n: i64 = if clip { paths[k + 1] as i64 } else if paths[k] == PATH_CUBIC { 3 } else if paths[k] == PATH_CLOSE { 0 } else { 1 };
        let at: i64 = if clip { k + 2 } else { k + 1 };
        for j in n {
            paths[at + 2 * j] += dx;
            paths[at + 1 + 2 * j] += dy;
        }
        k = at + 2 * n;
    }
}

// ------------------------------------------------------------------ viewports and transforms

// A viewBox: its x, y, width and height, and whether it is one.
fn view_box(d: Doc, e: i32) -> f32, f32, f32, f32, bool {
    let v, has = attr_value(d, e, "viewbox");
    guard has else { return 0.0, 0.0, 0.0, 0.0, false; }
    let x, i1, ok1 = scan_number(v, 0);
    let y, i2, ok2 = scan_number(v, i1);
    let w, i3, ok3 = scan_number(v, i2);
    let h, i4, ok4 = scan_number(v, i3);
    guard ok1 && ok2 && ok3 && ok4 && w > 0.0 && h > 0.0 else { return 0.0, 0.0, 0.0, 0.0, false; }
    return x, y, w, h, true;
}

// An element's viewBox height over width, or -1 without one.
fn view_ratio(d: Doc, e: i32) -> f32 {
    let x, y, w, h, ok = view_box(d, e);
    return if ok { h / w } else { -1.0 };
}

// The size of the user space inside element e's viewport, w × h: its
// viewBox's, else the viewport's.
fn view_size(d: Doc, e: i32, w: f32, h: f32) -> f32, f32 {
    let x, y, bw, bh, ok = view_box(d, e);
    return if ok { bw } else { w }, if ok { bh } else { h };
}

// What takes element e's user space into its viewport, w × h at (0, 0): its
// viewBox scaled and aligned as preserveAspectRatio says (xMidYMid meet,
// unless it says otherwise), or nothing without one.
fn fit_view(d: Doc, e: i32, w: f32, h: f32) -> Affine {
    let vx, vy, vw, vh, ok = view_box(d, e);
    guard ok else { return shift(0.0, 0.0); }
    var sx = w / vw;
    var sy = h / vh;
    let par, has = attr_value(d, e, "preserveaspectratio");
    var align: u8[>..] = [];
    var slice = false;
    if has {
        each_word(par) {
            if it == "slice" { slice = true; }
            else if it != "meet" { align.clear(); for ch in it { align.push(lower(ch)); } }
        };
    }
    if align[..] == "none" { return affine(sx, 0.0, 0.0, sy, -vx * sx, -vy * sy); }
    let s = if slice { max(sx, sy) } else { min(sx, sy) };
    // xMinYMin to xMaxYMax: where the content sits along each axis.
    let ax: f32 = if align.len == 8 && align[1..4] == "min" { 0.0 } else if align.len == 8 && align[1..4] == "max" { 1.0 } else { 0.5 };
    let ay: f32 = if align.len == 8 && align[5..8] == "min" { 0.0 } else if align.len == 8 && align[5..8] == "max" { 1.0 } else { 0.5 };
    sx = s;
    sy = s;
    return affine(sx, 0.0, 0.0, sy, (w - vw * sx) * ax - vx * sx, (h - vh * sy) * ay - vy * sy);
}

// Element e's own transform, taking its user space into its parent's: its CSS
// transform, else its transform attribute, about its transform-origin. The
// origin counts in its viewport (vw × vh), or for transform-box: fill-box and
// stroke-box in the bounds of its own geometry, without and with half its
// stroke's width all round.
recursive fn local_transform(V: Drawing&, e: i32, vw: f32, vh: f32, depth: i32) -> Affine {
    let s = V.styles[e];
    let attr = s.xf_count == 0;
    let t = if attr { transform_attr(V.d, e) } else { shift(0.0, 0.0) };
    if attr {
        // An origin only matters when there is a transform to turn about it.
        let none = t.a == 1.0 && t.b == 0.0 && t.c == 0.0 && t.d == 1.0 && t.e == 0.0 && t.f == 0.0;
        let at_zero = s.transform_box == K_VIEW_BOX && s.origin_pct == 0 && s.origin_x == 0.0 && s.origin_y == 0.0;
        if none || at_zero { return t; }
    }
    var bx: f32 = 0.0;
    var by: f32 = 0.0;
    var bw = vw;
    var bh = vh;
    if s.transform_box == K_FILL_BOX || s.transform_box == K_STROKE_BOX {
        let mark = V.paths.len;
        add_geometry(V, e, shift(0.0, 0.0), vw, vh, depth + 1);
        let x0, y0, x1, y1 = path_bounds(V.paths[..], mark);
        V.paths.resize(mark);
        let width = if s.stroke_pct != 0 { s.stroke_width / 100.0 * sqrt((vw * vw + vh * vh) / 2.0) } else { s.stroke_width };
        let half: f32 = if s.transform_box == K_STROKE_BOX && s.stroke != 0 { width / 2.0 } else { 0.0 };
        bx = x0 - half;
        by = y0 - half;
        bw = x1 - x0 + 2.0 * half;
        bh = y1 - y0 + 2.0 * half;
    }
    let ox = bx + (if (s.origin_pct & 1) != 0 { s.origin_x / 100.0 * bw } else { s.origin_x });
    let oy = by + (if (s.origin_pct & 2) != 0 { s.origin_y / 100.0 * bh } else { s.origin_y });
    var m = times(shift(ox, oy), t);
    var k: i32 = 0;
    while k < s.xf_count {
        let f = s.xf[k];
        if f.kind == XF_TRANSLATE {
            m = times(m, shift(if (f.pct & 1) != 0 { f.x / 100.0 * bw } else { f.x }, if (f.pct & 2) != 0 { f.y / 100.0 * bh } else { f.y }));
        } else if f.kind == XF_SCALE {
            m = times(m, affine(f.x, 0.0, 0.0, f.y, 0.0, 0.0));
        } else if f.kind == XF_ROTATE {
            m = times(m, affine(cos(f.x), sin(f.x), -sin(f.x), cos(f.x), 0.0, 0.0));
        } else if f.kind == XF_MATRIX && k + 2 < s.xf_count {
            m = times(m, affine(f.x, f.y, s.xf[k + 1].x, s.xf[k + 1].y, s.xf[k + 2].x, s.xf[k + 2].y));
            k += 2;
        }
        k += 1;
    }
    return times(m, shift(-ox, -oy));
}

// Element e's shapes and its children's, through m and their own
// transforms, as path data with no paint: what fill-box measures.
recursive fn add_geometry(V: Drawing&, e: i32, m: Affine, vw: f32, vh: f32, depth: i32) {
    guard depth < SVG_DEPTH_MAX && V.styles[e].display != K_NONE && V.left > 0;
    V.left -= 1;
    let name = node_name(V.d, e);
    if name == "g" || name == "a" || name == "switch" {
        add_children_geometry(V, e, m, vw, vh, depth + 1);
    } else if name == "svg" {
        let at, iw, ih, ok = viewport(V.d, e, m, vw, vh, vw, vh);
        if ok { add_children_geometry(V, e, at, iw, ih, depth + 1); }
    } else if name == "use" {
        // What it draws, where it draws it.
        let t = use_target(V, e);
        guard t > 0;
        let at = times(m, shift(length_attr(V.d, e, "x", vw, 0.0), length_attr(V.d, e, "y", vh, 0.0)));
        let tname = node_name(V.d, t);
        V.uses.push(e);
        if tname == "symbol" || tname == "svg" {
            let inner, iw, ih, ok = viewport(V.d, t, at, length_attr(V.d, e, "width", vw, -1.0),
                                             length_attr(V.d, e, "height", vh, -1.0), vw, vh);
            if ok { add_children_geometry(V, t, inner, iw, ih, depth + 1); }
        } else {
            add_geometry(V, t, times(at, local_transform(V, t, vw, vh, depth + 1)), vw, vh, depth + 1);
        }
        V.uses.pop();
    } else {
        add_shape(V.d, e, name, m, vw, vh, V.paths);
    }
}

recursive fn add_children_geometry(V: Drawing&, e: i32, m: Affine, vw: f32, vh: f32, depth: i32) {
    var c = V.d.nodes[e].first;
    while c >= 0 {
        if V.d.nodes[c].kind == NODE_ELEMENT {
            add_geometry(V, c, times(m, local_transform(V, c, vw, vh, depth)), vw, vh, depth);
        }
        c = V.d.nodes[c].next;
    }
}

// The transform attribute (SVG 1.1 §7.6): matrix, translate, scale, rotate
// (about a point), skewX and skewY, in order; numbers are user units and
// degrees. One it can't read is none.
fn transform_attr(d: Doc, e: i32) -> Affine {
    var m = shift(0.0, 0.0);
    let v, has = attr_value(d, e, "transform");
    guard has else { return m; }
    var i: i64 = 0;
    loop {
        while i < v.len && (is_ws(v[i]) || v[i] == ',') { i += 1; }
        guard i < v.len else { return m; }
        let st = i;
        while i < v.len && v[i] != '(' { i += 1; }
        guard i < v.len else { return shift(0.0, 0.0); }
        let name = trim(v[st..i]);
        i += 1;
        var a: f32[6];
        var n: i64 = 0;
        loop {
            let x, k, ok = scan_number(v, i);
            if !ok || n >= 6 { break; }
            a[n] = x;
            n += 1;
            i = k;
        }
        while i < v.len && is_ws(v[i]) { i += 1; }
        guard i < v.len && v[i] == ')' else { return shift(0.0, 0.0); }
        i += 1;
        if name == "matrix" && n == 6 { m = times(m, affine(a[0], a[1], a[2], a[3], a[4], a[5])); }
        else if name == "translate" && (n == 1 || n == 2) { m = times(m, shift(a[0], if n == 2 { a[1] } else { 0.0 })); }
        else if name == "scale" && (n == 1 || n == 2) { m = times(m, affine(a[0], 0.0, 0.0, if n == 2 { a[1] } else { a[0] }, 0.0, 0.0)); }
        else if name == "rotate" && (n == 1 || n == 3) {
            let t = radians(a[0]);
            let r = affine(cos(t), sin(t), -sin(t), cos(t), 0.0, 0.0);
            m = if n == 3 { times(m, times(shift(a[1], a[2]), times(r, shift(-a[1], -a[2])))) } else { times(m, r) };
        }
        else if name == "skewX" && n == 1 { m = times(m, affine(1.0, 0.0, tan(radians(a[0])), 1.0, 0.0, 0.0)); }
        else if name == "skewY" && n == 1 { m = times(m, affine(1.0, tan(radians(a[0])), 0.0, 1.0, 0.0, 0.0)); }
        else { return shift(0.0, 0.0); }
    }
}

// ------------------------------------------------------------------ ids

// A table of the elements with an id, by id, into `ids`: open addressing in
// a power of two of slots, at least twice as many as ids, each an element
// or -1. Elements go in in document order, so the first with an id is
// found first, as getElementById finds it.
fn index_ids(d: Doc, ids: i32[>..]&) {
    var count: i64 = 0;
    for n, i in d.nodes {
        guard n.kind == NODE_ELEMENT else { continue; }
        let v, has = attr_value(d, i as i32, "id");
        if has && v.len > 0 { count += 1; }
    }
    var size: i64 = 1;
    while size < count * 2 { size *= 2; }
    for k in size { ids.push(-1); }
    for n, i in d.nodes {
        guard n.kind == NODE_ELEMENT else { continue; }
        let v, has = attr_value(d, i as i32, "id");
        guard has && v.len > 0 else { continue; }
        var h = id_hash(v) & (size - 1);
        while ids[h] >= 0 { h = (h + 1) & (size - 1); }
        ids[h] = i as i32;
    }
}

// The first element whose id is `id`, through index_ids's table, or -1.
fn element_by_id(d: Doc, ids: const i32[:], id: const u8[:]) -> i32 {
    guard ids.len > 0 && id.len > 0 else { return -1; }
    var h = id_hash(id) & (ids.len - 1);
    while ids[h] >= 0 {
        let v, has = attr_value(d, ids[h], "id");
        if v == id { return ids[h]; }
        h = (h + 1) & (ids.len - 1);
    }
    return -1;
}

// FNV-1a.
fn id_hash(s: const u8[:]) -> i64 {
    var h: i64 = 2166136261;
    for c in s { h = ((h ^ c) * 16777619) & 0xFFFFFFFF; }
    return h;
}
