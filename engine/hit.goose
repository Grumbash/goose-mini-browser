// What is under the pointer (docs/adr/0010): the topmost thing a page paints
// at a point, found in the display list layout made, and the link it is in.
// A hover's cursor and a click's target come from here.

import std;
import .dom;
import .layout;

// The node whose item is topmost at page point (x, y), or -1. Items paint in
// order, so the last one there wins. One that its clips cut away there, or
// that its transform has moved elsewhere, isn't there. A text item reaches
// from its font's ascent above its baseline to its descent below. One pass
// back over the list, stopping at the first item there.
fn node_at(items: const DItem[:], fonts: const FontInfo[:], x: f32, y: f32) -> i32 {
    var k = items.len - 1;
    while k >= 0 {
        let it = items[k];
        k -= 1;
        guard it.node >= 0 && it.kind != ITEM_NONE else { continue; }
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
        }
        var top = it.y;
        var bottom = it.y + it.h;
        if it.kind == ITEM_TEXT {
            let ascent, descent = extent(fonts, it.font, it.size);
            top = it.y - ascent;
            bottom = it.y + descent;
        }
        if px >= it.x && px < it.x + it.w && py >= top && py < bottom { return it.node; }
    }
    return -1;
}

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
