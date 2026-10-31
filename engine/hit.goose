// What is under the pointer (docs/adr/0010): the topmost thing a page paints
// at a point, found in the display list layout made, and the link it is in.
// A hover's cursor and a click's target come from here.

import std;
import .dom;
import .layout;

// Where each item can be under the pointer, for node_at: four floats per item
// (left, top, right, bottom on the page), around where its transform takes
// it and inside its square clip; empty for one that never is. Made once per
// layout, so that a hit test passes over an item by reading 16 bytes of it,
// not its 184: on a page of 120,000 items that is 2 MB a test, not 22.
fn hit_bounds(items: const DItem[:], fonts: const FontInfo[:], bounds: f32[>..<]&) {
    bounds.resize(0);
    for it in items {
        let boxy = it.kind == ITEM_RECT || it.kind == ITEM_BOX;
        if it.node < 0 || it.kind == ITEM_NONE || (boxy && (it.font & BOX_SHADOW) != 0) {
            bounds.push(1.0); bounds.push(1.0); bounds.push(0.0); bounds.push(0.0);
            continue;
        }
        var top = it.y;
        var bottom = it.y + it.h;
        if it.kind == ITEM_TEXT {
            let ascent, descent = extent(fonts, it.font, it.size);
            top = it.y - ascent;
            bottom = it.y + descent;
        }
        var x0 = it.x;
        var y0 = top;
        var x1 = it.x + it.w;
        var y1 = bottom;
        if it.m_a != 0.0 || it.m_b != 0.0 || it.m_c != 0.0 || it.m_d != 0.0 {
            // Around its corners where they land, a little wide for rounding.
            let xs: f32[4] = [it.x, x1, it.x, x1];
            let ys: f32[4] = [top, top, bottom, bottom];
            x0 = 1000000000.0;
            y0 = 1000000000.0;
            x1 = -1000000000.0;
            y1 = -1000000000.0;
            for cx, c in xs {
                let lx = it.m_a * cx + it.m_c * ys[c] + it.m_e;
                let ly = it.m_b * cx + it.m_d * ys[c] + it.m_f;
                x0 = min(x0, lx - 0.01);
                y0 = min(y0, ly - 0.01);
                x1 = max(x1, lx + 0.01);
                y1 = max(y1, ly + 0.01);
            }
        }
        if it.oclip_w > 0.0 {
            x0 = max(x0, it.oclip_x);
            y0 = max(y0, it.oclip_y);
            x1 = min(x1, it.oclip_x + it.oclip_w);
            y1 = min(y1, it.oclip_y + it.oclip_h);
        }
        bounds.push(x0); bounds.push(y0); bounds.push(x1); bounds.push(y1);
    }
}

// The node whose item is topmost at page point (x, y), or -1, by the items'
// `bounds` (hit_bounds). Items paint in order, so the last one there wins. A
// box is there in all of its border box, its corners rounded, through its
// background or its hit item; its shadows aren't. One that its clips cut away
// there, or that its transform has moved elsewhere, isn't there. A text item
// reaches from its font's ascent above its baseline to its descent below, a
// path item over its whole rectangle. One pass back over the bounds, looking
// closer only at an item whose bounds hold the point.
fn node_at(items: const DItem[:], fonts: const FontInfo[:], bounds: const f32[:], x: f32, y: f32) -> i32 {
    guard bounds.len == items.len * 4 else { return -1; }
    var k = items.len - 1;
    while k >= 0 {
        let b = k * 4;
        k -= 1;
        guard x >= bounds[b] && y >= bounds[b + 1] && x <= bounds[b + 2] && y <= bounds[b + 3] else { continue; }
        let it = items[k + 1];
        // The second clip is square on the page.
        guard it.oclip_w <= 0.0 || (x >= it.oclip_x && x < it.oclip_x + it.oclip_w && y >= it.oclip_y && y < it.oclip_y + it.oclip_h)
            else { continue; }
        // The point in the item's own space, where its transform came from.
        var px = x;
        var py = y;
        if it.m_a != 0.0 || it.m_b != 0.0 || it.m_c != 0.0 || it.m_d != 0.0 {
            let det = it.m_a * it.m_d - it.m_b * it.m_c;
            guard det != 0.0 else { continue; }
            let dx = x - it.m_e;
            let dy = y - it.m_f;
            px = (it.m_d * dx - it.m_c * dy) / det;
            py = (it.m_a * dy - it.m_b * dx) / det;
        }
        guard px >= it.x && px < it.x + it.w else { continue; }
        var top = it.y;
        var bottom = it.y + it.h;
        if it.kind == ITEM_TEXT {
            let ascent, descent = extent(fonts, it.font, it.size);
            top = it.y - ascent;
            bottom = it.y + descent;
        }
        guard py >= top && py < bottom else { continue; }
        if it.kind == ITEM_BOX || it.kind == ITEM_HIT {
            guard in_corners(px - it.x, py - it.y, it.w, it.h, it.rad_tl, it.rad_tr, it.rad_br, it.rad_bl) else { continue; }
        }
        if it.clip_w > 0.0 {
            // The clip is in the item's space, or where its own matrix takes it.
            var cx = px;
            var cy = py;
            if it.c_a != 0.0 || it.c_b != 0.0 || it.c_c != 0.0 || it.c_d != 0.0 {
                cx = it.c_a * px + it.c_c * py + it.c_e;
                cy = it.c_b * px + it.c_d * py + it.c_f;
            }
            guard cx >= it.clip_x && cx < it.clip_x + it.clip_w && cy >= it.clip_y && cy < it.clip_y + it.clip_h
                else { continue; }
            guard in_corners(cx - it.clip_x, cy - it.clip_y, it.clip_w, it.clip_h, it.clip_tl, it.clip_tr, it.clip_br, it.clip_bl)
                else { continue; }
        }
        return it.node;
    }
    return -1;
}

// Whether point (x, y), in a w × h rectangle from its corner, is inside its
// corners rounded by tl, tr, br and bl: each corner's arc counts wherever the
// point is in its square, as the compositor draws it.
fn in_corners(x: f32, y: f32, w: f32, h: f32, tl: f32, tr: f32, br: f32, bl: f32) -> bool {
    if x < tl && y < tl && beyond(tl - x, tl - y, tl) { return false; }
    if x > w - tr && y < tr && beyond(x - (w - tr), tr - y, tr) { return false; }
    if x > w - br && y > h - br && beyond(x - (w - br), y - (h - br), br) { return false; }
    if x < bl && y > h - bl && beyond(bl - x, y - (h - bl), bl) { return false; }
    return true;
}

fn beyond(dx: f32, dy: f32, r: f32) -> bool { return dx * dx + dy * dy > r * r; }

// How far font `font` at `size` reaches above and below its baseline, as
// layout measured it.
fn extent(fonts: const FontInfo[:], font: i32, size: f32) -> f32, f32 {
    for f in fonts {
        if f.font == font && f.size == size { return f.m.ascent, f.m.descent; }
    }
    return size * 0.8, size * 0.2;
}

// The link node n is in: the nearest <a> with an href around it, n itself
// included, or -1.
fn link_at(d: Doc, n: i32) -> i32 {
    var k = n;
    while k >= 0 {
        if d.nodes[k].kind == NODE_ELEMENT && node_name(d, k) == "a" {
            let href, has = attr_value(d, k, "href");
            if has { return k; }
        }
        k = d.nodes[k].parent;
    }
    return -1;
}
