// CSS (docs/adr/0004): a parser for the part of CSS documents use, selector
// matching, the cascade and computed style. Selectors: type, class, id,
// universal, descendant and child, :first-child and :last-child. A selector
// with anything else (attributes, siblings, :not, pseudo-elements) is dropped,
// as is every at-rule. Values compute to pixels at style time, except the
// percentages of widths, which layout resolves.

import std;
import .dom;

// Properties.
let P_DISPLAY: i32 = 0;
let P_COLOR: i32 = 1;
let P_BG: i32 = 2;
let P_FONT_SIZE: i32 = 3;
let P_FONT_WEIGHT: i32 = 4;
let P_FONT_STYLE: i32 = 5;
let P_FONT_FAMILY: i32 = 6;
let P_LINE_HEIGHT: i32 = 7;
let P_TEXT_ALIGN: i32 = 8;
let P_WHITE_SPACE: i32 = 9;
let P_MT: i32 = 10;
let P_MR: i32 = 11;
let P_MB: i32 = 12;
let P_ML: i32 = 13;
let P_PT: i32 = 14;
let P_PR: i32 = 15;
let P_PB: i32 = 16;
let P_PL: i32 = 17;
let P_WIDTH: i32 = 18;
let P_MAX_WIDTH: i32 = 19;
let P_LIST: i32 = 20;
let P_DECO: i32 = 21;
let P_VALIGN: i32 = 22;
let P_BT_WIDTH: i32 = 23;
let P_BB_WIDTH: i32 = 24;
let P_BT_COLOR: i32 = 25;
let P_BB_COLOR: i32 = 26;
let P_TEXT_INDENT: i32 = 27;
let NPROPS: i64 = 28;

// Kinds of value.
let V_KEYWORD: i32 = 1;   // Decl.num holds a K_* id
let V_LENGTH: i32 = 2;    // Decl.num in Decl.unit
let V_NUMBER: i32 = 3;
let V_COLOR: i32 = 4;
let V_INHERIT: i32 = 5;

// Units.
let U_PX: i32 = 0;
let U_EM: i32 = 1;
let U_REM: i32 = 2;
let U_PCT: i32 = 3;

// Keywords.
let K_NONE: i32 = 0;
let K_BLOCK: i32 = 1;
let K_INLINE: i32 = 2;
let K_LIST_ITEM: i32 = 3;
let K_NORMAL: i32 = 4;
let K_BOLD: i32 = 5;
let K_ITALIC: i32 = 6;
let K_LEFT: i32 = 7;
let K_RIGHT: i32 = 8;
let K_CENTER: i32 = 9;
let K_PRE: i32 = 10;
let K_NOWRAP: i32 = 11;
let K_PRE_WRAP: i32 = 12;
let K_DISC: i32 = 13;
let K_CIRCLE: i32 = 14;
let K_SQUARE: i32 = 15;
let K_DECIMAL: i32 = 16;
let K_LOWER_ALPHA: i32 = 17;
let K_UPPER_ALPHA: i32 = 18;
let K_UNDERLINE: i32 = 19;
let K_LINE_THROUGH: i32 = 20;
let K_SUPER: i32 = 21;
let K_SUB: i32 = 22;
let K_BASELINE: i32 = 23;
let K_AUTO: i32 = 24;
let K_SANS: i32 = 25;
let K_SERIF: i32 = 26;
let K_MONO: i32 = 27;
let K_LOWER_ROMAN: i32 = 28;
let K_UPPER_ROMAN: i32 = 29;
let K_TRANSPARENT: i32 = 30;

// Font families, as the platform layer's text functions number them.
let FAMILY_SANS: i32 = 0;
let FAMILY_SERIF: i32 = 1;
let FAMILY_MONO: i32 = 2;

// Origins, lowest first.
let ORIGIN_UA: i32 = 0;
let ORIGIN_AUTHOR: i32 = 1;
let ORIGIN_INLINE: i32 = 2;

// One compound selector, e.g. `div.note#x`, and how it joins the one to its
// left: 0 for the first, 1 descendant, 2 child.
struct Compound {
    join: i32,
    tag: i32, tag_len: i32,            // a span into Sheet.bytes; 0 length for none or *
    id: i32, id_len: i32,
    cls: i32, cls_count: i32,          // classes, in Sheet.classes
    first_child: i32, last_child: i32,
    link: i32,                         // 1 for :link and :any-link, 2 for :visited
}

struct Span { start: i32, len: i32 }

// One selector of a rule with its declarations. A group `a, b { }` becomes
// two rules sharing their declarations.
struct Rule {
    comp: i32, comp_count: i32,
    decl: i32, decl_count: i32,
    spec: i32,                         // specificity, packed as ids << 16 | classes << 8 | types
    order: i32,
    origin: i32,
}

struct Decl { prop: i32, kind: i32, num: f32, unit: i32, color: u32, important: i32 }

struct Sheet {
    rules: Rule[>..]&,
    comps: Compound[>..]&,
    classes: Span[>..]&,
    decls: Decl[>..]&,
    bytes: u8[>..]&,
}

// Computed style for one element; text nodes use their parent's.
struct Style {
    display: i32,
    color: u32, bg: u32,                 // 0xAARRGGBB; a background with alpha 0 is none
    font_size: f32, bold: i32, italic: i32, family: i32,
    lh_mult: f32, lh_px: f32,            // line-height: a multiple of the font size, or pixels when lh_mult is 0
    align: i32, ws: i32, list: i32, deco: i32, valign: i32,
    mt: f32, mr: f32, mb: f32, ml: f32,
    auto_ml: i32, auto_mr: i32,
    pt: f32, pr: f32, pb: f32, pl: f32,
    width: f32, width_pct: f32,          // -1 when not set
    max_width: f32, max_width_pct: f32,  // -1 when not set
    bt: f32, bb: f32, bt_color: u32, bb_color: u32,   // a colour of CURRENT_COLOR is the text's
    indent: f32,
    root_size: f32,                      // the root element's font size, which rem counts in
}

// currentColor until layout paints with the text's colour. Its alpha is 0 and
// no colour name or #rrggbb parses to it.
let CURRENT_COLOR: u32 = 2;

fn line_height(s: Style) -> f32 {
    return if s.lh_mult >= 0.0 { s.lh_mult * s.font_size } else { s.lh_px };
}

fn root_style() -> Style {
    return Style { display: K_BLOCK, color: 0xFF000000, bg: 0, font_size: 16.0, bold: 0, italic: 0, family: FAMILY_SANS,
                   lh_mult: 1.2, lh_px: 0.0, align: K_LEFT, ws: K_NORMAL, list: K_DISC, deco: K_NONE, valign: K_BASELINE,
                   mt: 0.0, mr: 0.0, mb: 0.0, ml: 0.0, auto_ml: 0, auto_mr: 0, pt: 0.0, pr: 0.0, pb: 0.0, pl: 0.0,
                   width: -1.0, width_pct: -1.0, max_width: -1.0, max_width_pct: -1.0,
                   bt: 0.0, bb: 0.0, bt_color: CURRENT_COLOR, bb_color: CURRENT_COLOR, indent: 0.0, root_size: 16.0 };
}

// ------------------------------------------------------------------ parsing

struct Lexer { src: const u8[:], pos: i64 }

fn skip_ws_comments(l: Lexer&) {
    let s = l.src;
    loop {
        while l.pos < s.len && is_ws(s[l.pos]) { l.pos += 1; }
        if l.pos + 1 < s.len && s[l.pos] == '/' && s[l.pos + 1] == '*' {
            let k = find(s[l.pos + 2..], "*/");
            l.pos = if k < 0 { s.len } else { l.pos + 2 + k + 2 };
            continue;
        }
        return;
    }
}

// Skips a {...} block, nested blocks included; l.pos is at the '{'.
fn skip_block(l: Lexer&) {
    let s = l.src;
    var depth = 0;
    while l.pos < s.len {
        let c = s[l.pos];
        if c == '{' { depth += 1; }
        else if c == '}' { depth -= 1; if depth == 0 { l.pos += 1; return; } }
        else if c == '"' || c == '\'' { l.pos = skip_string(s, l.pos); continue; }
        else if at_comment(s, l.pos) { l.pos = skip_comment(s, l.pos); continue; }
        l.pos += 1;
    }
}

fn at_comment(s: const u8[:], i: i64) -> bool { return i + 1 < s.len && s[i] == '/' && s[i + 1] == '*'; }

// The index after the comment that starts at i.
fn skip_comment(s: const u8[:], i: i64) -> i64 {
    let k = find(s[i + 2..], "*/");
    return if k < 0 { s.len } else { i + 2 + k + 2 };
}

// s without its comments, each replaced by a space, appended to `out`;
// strings are copied whole.
fn without_comments(s: const u8[:], out: u8[>..]&) {
    var i: i64 = 0;
    while i < s.len {
        if at_comment(s, i) { i = skip_comment(s, i); out.push(' '); continue; }
        if s[i] == '"' || s[i] == '\'' {
            let end = skip_string(s, i);
            out.append(s[i..end]);
            i = end;
            continue;
        }
        out.push(s[i]);
        i += 1;
    }
}

fn skip_string(s: const u8[:], i: i64) -> i64 {
    let q = s[i];
    var j = i + 1;
    while j < s.len && s[j] != q { if s[j] == '\\' { j += 1; } j += 1; }
    return min(j + 1, s.len);
}

// Parses a whole style sheet into `sh`. `order` numbers rules across sheets so
// later ones win ties; returns the next free number.
fn parse_sheet(src: const u8[:], sh: Sheet, origin: i32, order: i32) -> i32 {
    var l = Lexer { src: src, pos: 0 };
    var next = order;
    loop {
        skip_ws_comments(l);
        guard l.pos < src.len else { break; }
        // The <!-- and --> that old pages wrap style sheets in are skipped.
        if starts_with(src[l.pos..], "<!--") { l.pos += 4; continue; }
        if starts_with(src[l.pos..], "-->") { l.pos += 3; continue; }
        if src[l.pos] == '@' {                  // at-rules: skipped, with any block they open
            while l.pos < src.len && src[l.pos] != ';' && src[l.pos] != '{' { l.pos += 1; }
            if l.pos < src.len && src[l.pos] == '{' { skip_block(l); } else { l.pos += 1; }
            continue;
        }
        if src[l.pos] == '}' { l.pos += 1; continue; }
        let pstart = l.pos;
        while l.pos < src.len && src[l.pos] != '{' {
            if at_comment(src, l.pos) { l.pos = skip_comment(src, l.pos); continue; }
            l.pos += 1;
        }
        guard l.pos < src.len else { break; }
        let prelude = src[pstart..l.pos];
        l.pos += 1;
        let bstart = l.pos;
        while l.pos < src.len && src[l.pos] != '}' {
            if src[l.pos] == '"' || src[l.pos] == '\'' { l.pos = skip_string(src, l.pos); continue; }
            if at_comment(src, l.pos) { l.pos = skip_comment(src, l.pos); continue; }
            l.pos += 1;
        }
        var body_text: u8[>..] = [];
        without_comments(src[bstart..min(l.pos, src.len)], body_text);
        l.pos = min(l.pos + 1, src.len);
        let decl_start = sh.decls.len as i32;
        parse_declarations(body_text[..], sh.decls);
        let decl_count = sh.decls.len as i32 - decl_start;
        guard decl_count > 0 else { continue; }
        each_split(prelude, ',') {
            if parse_selector(trim(it), sh, decl_start, decl_count, origin, next) { next += 1; }
        };
    }
    return next;
}

// One complex selector; false (and nothing added) when it uses what we don't support.
fn parse_selector(sel: const u8[:], sh: Sheet, decl: i32, decl_count: i32, origin: i32, order: i32) -> bool {
    guard sel.len > 0 && selector_supported(sel) else { return false; }
    let comp_start = sh.comps.len;
    let cls_start = sh.classes.len;
    var ids = 0;
    var classes = 0;
    var types = 0;
    var i: i64 = 0;
    var join: i32 = 0;
    var ok = true;
    while i < sel.len && ok {
        var c = Compound { join: join, tag: 0, tag_len: 0, id: 0, id_len: 0, cls: sh.classes.len as i32, cls_count: 0,
                           first_child: 0, last_child: 0, link: 0 };
        var any = false;
        while i < sel.len && !is_ws(sel[i]) && sel[i] != '>' {
            let ch = sel[i];
            if ch == '*' { i += 1; any = true; continue; }
            if ch == '#' || ch == '.' {
                i += 1;
                let st = i;
                while i < sel.len && is_ident(sel[i]) { i += 1; }
                guard i > st else { ok = false; break; }
                let at = sh.bytes.len as i32;
                sh.bytes.append(sel[st..i]);
                if ch == '#' { c.id = at; c.id_len = (i - st) as i32; ids += 1; }
                else { sh.classes.push(Span { start: at, len: (i - st) as i32 }); c.cls_count += 1; classes += 1; }
                any = true;
                continue;
            }
            if ch == ':' {
                i += 1;
                let st = i;
                while i < sel.len && (is_ident(sel[i]) || sel[i] == ':') { i += 1; }
                let pc = sel[st..i];
                if pc == "first-child" { c.first_child = 1; classes += 1; }
                else if pc == "last-child" { c.last_child = 1; classes += 1; }
                else if pc == "link" || pc == "any-link" { c.link = 1; classes += 1; }
                else if pc == "visited" { c.link = 2; classes += 1; }
                else { ok = false; break; }
                any = true;
                continue;
            }
            if is_ident(ch) {
                let st = i;
                while i < sel.len && is_ident(sel[i]) { i += 1; }
                let at = sh.bytes.len as i32;
                for k in st..i { sh.bytes.push(lower(sel[k])); }
                c.tag = at;
                c.tag_len = (i - st) as i32;
                types += 1;
                any = true;
                continue;
            }
            ok = false;                     // [attr], +, ~, ( ... ) and the rest
            break;
        }
        guard ok && any else { ok = false; break; }
        sh.comps.push(c);
        // The combinator to the next compound.
        var saw_ws = false;
        while i < sel.len && is_ws(sel[i]) { i += 1; saw_ws = true; }
        if i < sel.len && sel[i] == '>' {
            i += 1;
            while i < sel.len && is_ws(sel[i]) { i += 1; }
            join = 2;
        } else if saw_ws {
            join = 1;
        }
        if i < sel.len && (sel[i] == '+' || sel[i] == '~') { ok = false; }
    }
    guard ok && sh.comps.len > comp_start else { return false; }
    let spec = (min(ids, 255) << 16) | (min(classes, 255) << 8) | min(types, 255);
    sh.rules.push(Rule { comp: comp_start as i32, comp_count: (sh.comps.len - comp_start) as i32, decl: decl, decl_count: decl_count,
                         spec: spec as i32, order: order, origin: origin });
    return true;
}

// Whether a selector uses only what parse_selector handles, so it can be
// written into the sheet in one pass with nothing to take back.
fn selector_supported(sel: const u8[:]) -> bool {
    var i: i64 = 0;
    var parts = 0;
    while i < sel.len {
        let ch = sel[i];
        if is_ws(ch) || ch == '>' || ch == '*' { i += 1; continue; }
        if ch == '#' || ch == '.' {
            i += 1;
            let st = i;
            while i < sel.len && is_ident(sel[i]) { i += 1; }
            guard i > st else { return false; }
            parts += 1;
            continue;
        }
        if ch == ':' {
            i += 1;
            let st = i;
            while i < sel.len && (is_ident(sel[i]) || sel[i] == ':') { i += 1; }
            let pc = sel[st..i];
            guard pc == "first-child" || pc == "last-child" || pc == "link" || pc == "visited" || pc == "any-link" else { return false; }
            continue;
        }
        if is_ident(ch) {
            while i < sel.len && is_ident(sel[i]) { i += 1; }
            parts += 1;
            continue;
        }
        return false;
    }
    return parts > 0 || find(sel, "*") >= 0;
}

fn is_ident(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 128;
}

// Declarations `prop: value; ...`, shorthands expanded, unknown ones skipped.
fn parse_declarations(body: const u8[:], out: Decl[>..]&) {
    var i: i64 = 0;
    while i < body.len {
        // One declaration runs to the next ';' outside quotes and brackets.
        let st = i;
        var depth = 0;
        while i < body.len {
            let c = body[i];
            if c == '"' || c == '\'' { i = skip_string(body, i); continue; }
            if c == '(' { depth += 1; } else if c == ')' { depth -= 1; }
            else if c == ';' && depth <= 0 { break; }
            i += 1;
        }
        let one = body[st..i];
        i += 1;
        let colon = find(one, ":");
        if colon <= 0 { continue; }
        var name: u8[>..] = [];
        name.append(trim(one[..colon]));
        to_lower(name[..]);
        var value = trim(one[colon + 1..]);
        var important: i32 = 0;
        let bang = find(value, "!");
        if bang >= 0 {
            if trim(value[bang + 1..]) == "important" { important = 1; }
            value = trim(value[..bang]);
        }
        add_declaration(name[..], value, important, out);
    }
}

fn add_declaration(name: const u8[:], value: const u8[:], important: i32, out: Decl[>..]&) {
    if name == "margin" || name == "padding" {
        let base = if name == "margin" { P_MT } else { P_PT };
        let parts = words(value);
        guard parts.len >= 1 && parts.len <= 4;
        // top right bottom left, with CSS's rules for one to three values.
        let n = parts.len;
        let t = parts[0];
        let r = if n >= 2 { parts[1] } else { parts[0] };
        let b = if n >= 3 { parts[2] } else { parts[0] };
        let lft = if n == 4 { parts[3] } else { r };
        add_value(base, t, important, out);
        add_value(base + 1, r, important, out);
        add_value(base + 2, b, important, out);
        add_value(base + 3, lft, important, out);
        return;
    }
    if name == "border-top" || name == "border-bottom" || name == "border" {
        // width, style and colour in any order; a style of none removes the line.
        var width: f32 = 0.0;
        var color: u32 = CURRENT_COLOR;
        var none = false;
        each_word(value) {
            let w = it;
            let k = keyword(w);
            if w == "none" || w == "hidden" { none = true; }
            else if w == "thin" { width = 1.0; }
            else if w == "medium" { width = 3.0; }
            else if w == "thick" { width = 5.0; }
            else if w.len > 0 && (w[0] >= '0' && w[0] <= '9' || w[0] == '.') {
                let n, u, ok = parse_length(w);
                if ok && u == U_PX { width = n; }
            } else if k < 0 {
                let col, cok = parse_color(w);
                if cok { color = col; }
            }
        };
        if none { width = 0.0; }
        if name == "border-top" || name == "border" {
            push_decl(out, Decl { prop: P_BT_WIDTH, kind: V_LENGTH, num: width, unit: U_PX, color: 0, important: important });
            push_decl(out, Decl { prop: P_BT_COLOR, kind: V_COLOR, num: 0.0, unit: 0, color: color, important: important });
        }
        if name == "border-bottom" || name == "border" {
            push_decl(out, Decl { prop: P_BB_WIDTH, kind: V_LENGTH, num: width, unit: U_PX, color: 0, important: important });
            push_decl(out, Decl { prop: P_BB_COLOR, kind: V_COLOR, num: 0.0, unit: 0, color: color, important: important });
        }
        return;
    }
    if name == "background" {
        each_word(value) {
            let col, ok = parse_color(it);
            if ok { push_decl(out, Decl { prop: P_BG, kind: V_COLOR, num: 0.0, unit: 0, color: col, important: important }); }
        };
        return;
    }
    if name == "list-style" {
        each_word(value) {
            let k = keyword(it);
            if k == K_NONE || (k >= K_DISC && k <= K_UPPER_ALPHA) || k == K_LOWER_ROMAN || k == K_UPPER_ROMAN {
                push_decl(out, Decl { prop: P_LIST, kind: V_KEYWORD, num: k as f32, unit: 0, color: 0, important: important });
            }
        };
        return;
    }
    if name == "text-decoration" || name == "text-decoration-line" {
        var k = K_NONE;
        each_word(value) { let w = keyword(it); if w == K_UNDERLINE || w == K_LINE_THROUGH { k = w; } };
        push_decl(out, Decl { prop: P_DECO, kind: V_KEYWORD, num: k, unit: 0, color: 0, important: important });
        return;
    }
    let prop = property_id(name);
    guard prop >= 0;
    add_value(prop, value, important, out);
}

fn push_decl(out: Decl[>..]&, d: Decl) { out.push(d); }

fn add_value(prop: i32, value: const u8[:], important: i32, out: Decl[>..]&) {
    var d = Decl { prop: prop, kind: 0, num: 0.0, unit: 0, color: 0, important: important };
    if value == "inherit" { d.kind = V_INHERIT; push_decl(out, d); return; }
    if prop == P_COLOR || prop == P_BG || prop == P_BT_COLOR || prop == P_BB_COLOR {
        let c, ok = parse_color(value);
        guard ok;
        d.kind = V_COLOR;
        d.color = c;
        push_decl(out, d);
        return;
    }
    if prop == P_FONT_FAMILY {
        d.kind = V_KEYWORD;
        d.num = family_of(value);
        push_decl(out, d);
        return;
    }
    if prop == P_FONT_WEIGHT {
        let n, ok = parse_int(value);
        if ok { d.kind = V_KEYWORD; d.num = (if n >= 600 { K_BOLD } else { K_NORMAL }) as f32; push_decl(out, d); return; }
        let k = keyword(value);
        guard k == K_BOLD || k == K_NORMAL || value == "bolder" || value == "lighter";
        d.kind = V_KEYWORD;
        d.num = (if k == K_BOLD || value == "bolder" { K_BOLD } else { K_NORMAL }) as f32;
        push_decl(out, d);
        return;
    }
    if prop == P_FONT_SIZE {
        // Keywords, as multiples of the 16 px medium or of the parent.
        let scale: f32 = if value == "xx-small" { 0.6 } else if value == "x-small" { 0.75 } else if value == "small" { 0.89 }
            else if value == "medium" { 1.0 } else if value == "large" { 1.2 } else if value == "x-large" { 1.5 }
            else if value == "xx-large" { 2.0 } else { 0.0 };
        if scale > 0.0 { d.kind = V_LENGTH; d.num = 16.0 * scale; d.unit = U_PX; push_decl(out, d); return; }
        if value == "smaller" || value == "larger" {
            d.kind = V_LENGTH; d.num = if value == "smaller" { 0.83 } else { 1.2 }; d.unit = U_EM; push_decl(out, d); return;
        }
    }
    if prop == P_LINE_HEIGHT {
        if value == "normal" { d.kind = V_NUMBER; d.num = 1.2; push_decl(out, d); return; }
        let n, ok = parse_flt(value);
        if ok { d.kind = V_NUMBER; d.num = n as f32; push_decl(out, d); return; }
    }
    let k = keyword(value);
    if k >= 0 {
        d.kind = V_KEYWORD;
        d.num = k;
        push_decl(out, d);
        return;
    }
    let n, u, ok = parse_length(value);
    guard ok;
    d.kind = V_LENGTH;
    d.num = n;
    d.unit = u;
    push_decl(out, d);
}

fn property_id(n: const u8[:]) -> i32 {
    if n == "display" { return P_DISPLAY; } if n == "color" { return P_COLOR; }
    if n == "background-color" { return P_BG; } if n == "font-size" { return P_FONT_SIZE; }
    if n == "font-weight" { return P_FONT_WEIGHT; } if n == "font-style" { return P_FONT_STYLE; }
    if n == "font-family" { return P_FONT_FAMILY; } if n == "line-height" { return P_LINE_HEIGHT; }
    if n == "text-align" { return P_TEXT_ALIGN; } if n == "white-space" { return P_WHITE_SPACE; }
    if n == "margin-top" { return P_MT; } if n == "margin-right" { return P_MR; }
    if n == "margin-bottom" { return P_MB; } if n == "margin-left" { return P_ML; }
    if n == "padding-top" { return P_PT; } if n == "padding-right" { return P_PR; }
    if n == "padding-bottom" { return P_PB; } if n == "padding-left" { return P_PL; }
    if n == "width" { return P_WIDTH; } if n == "max-width" { return P_MAX_WIDTH; }
    if n == "list-style-type" { return P_LIST; } if n == "vertical-align" { return P_VALIGN; }
    if n == "border-top-width" { return P_BT_WIDTH; } if n == "border-bottom-width" { return P_BB_WIDTH; }
    if n == "border-top-color" { return P_BT_COLOR; } if n == "border-bottom-color" { return P_BB_COLOR; }
    if n == "text-indent" { return P_TEXT_INDENT; }
    return -1;
}

fn keyword(v: const u8[:]) -> i32 {
    if v == "none" { return K_NONE; } if v == "block" { return K_BLOCK; } if v == "inline" { return K_INLINE; }
    if v == "list-item" { return K_LIST_ITEM; } if v == "normal" { return K_NORMAL; } if v == "bold" { return K_BOLD; }
    if v == "italic" || v == "oblique" { return K_ITALIC; } if v == "left" || v == "start" { return K_LEFT; }
    if v == "right" || v == "end" { return K_RIGHT; } if v == "center" { return K_CENTER; }
    if v == "justify" { return K_LEFT; } if v == "pre" { return K_PRE; } if v == "nowrap" { return K_NOWRAP; }
    if v == "pre-wrap" || v == "pre-line" || v == "break-spaces" { return K_PRE_WRAP; }
    if v == "disc" { return K_DISC; } if v == "circle" { return K_CIRCLE; } if v == "square" { return K_SQUARE; }
    if v == "decimal" { return K_DECIMAL; } if v == "lower-alpha" || v == "lower-latin" { return K_LOWER_ALPHA; }
    if v == "upper-alpha" || v == "upper-latin" { return K_UPPER_ALPHA; }
    if v == "lower-roman" { return K_LOWER_ROMAN; } if v == "upper-roman" { return K_UPPER_ROMAN; }
    if v == "underline" { return K_UNDERLINE; } if v == "line-through" { return K_LINE_THROUGH; }
    if v == "super" { return K_SUPER; } if v == "sub" { return K_SUB; } if v == "baseline" { return K_BASELINE; }
    if v == "auto" { return K_AUTO; } if v == "transparent" { return K_TRANSPARENT; }
    // Display values we lay out as one of the three we know.
    if v == "inline-block" || v == "inline-flex" || v == "inline-grid" || v == "inline-table" || v == "table-cell" { return K_INLINE; }
    if v == "flex" || v == "grid" || v == "table" || v == "table-row" || v == "table-row-group" || v == "table-header-group"
        || v == "table-footer-group" || v == "table-caption" || v == "flow-root" || v == "contents" { return K_BLOCK; }
    return -1;
}

// A family list maps to the first generic family it names or implies.
fn family_of(v: const u8[:]) -> i32 {
    var family: i32 = -1;
    each_split(v, ',') {
        if family < 0 {
            var f: u8[>..] = [];
            for c in trim(it) { if c != '"' && c != '\'' { f.push(lower(c)); } }
            let s = trim(f[..]);
            if s == "monospace" || find(s, "mono") >= 0 || find(s, "courier") >= 0 || find(s, "menlo") >= 0 || find(s, "consolas") >= 0 {
                family = FAMILY_MONO;
            } else if s == "serif" || find(s, "georgia") >= 0 || find(s, "times") >= 0 || find(s, "palatino") >= 0
                || find(s, "garamond") >= 0 || find(s, "baskerville") >= 0 || find(s, "linux libertine") >= 0 {
                family = FAMILY_SERIF;
            } else if s == "sans-serif" || s == "system-ui" || s == "-apple-system" || find(s, "helvetica") >= 0
                || find(s, "arial") >= 0 || find(s, "verdana") >= 0 || find(s, "inter") >= 0 {
                family = FAMILY_SANS;
            }
        }
    };
    return if family >= 0 { family } else { FAMILY_SANS };
}

// A number and its unit; false when it isn't one. Unitless zero is pixels.
fn parse_length(v: const u8[:]) -> f32, i32, bool {
    var i: i64 = 0;
    while i < v.len && (v[i] == '-' || v[i] == '+' || v[i] == '.' || (v[i] >= '0' && v[i] <= '9')) { i += 1; }
    guard i > 0 else { return 0.0, 0, false; }
    let n, ok = parse_flt(v[..i]);
    guard ok && n > -100000.0 && n < 100000.0 else { return 0.0, 0, false; }
    let unit = v[i..];
    let x = n as f32;
    if unit == "px" { return x, U_PX, true; }
    if unit == "em" { return x, U_EM, true; }
    if unit == "rem" { return x, U_REM, true; }
    if unit == "%" { return x, U_PCT, true; }
    if unit == "pt" { return x * 4.0 / 3.0, U_PX, true; }
    if unit == "ex" || unit == "ch" { return x * 0.5, U_EM, true; }
    if unit.len == 0 && x == 0.0 { return 0.0, U_PX, true; }
    return 0.0, 0, false;
}

fn parse_color(v: const u8[:]) -> u32, bool {
    guard v.len > 0 else { return 0, false; }
    if v[0] == '#' {
        let h = v[1..];
        let n, ok = parse_int(h, 16);
        guard ok else { return 0, false; }
        let x = n as u32;
        if h.len == 6 { return 0xFF000000 | x, true; }
        if h.len == 3 {
            let r = (x >> 8) & 15;
            let g = (x >> 4) & 15;
            let b = x & 15;
            return 0xFF000000 | (r * 17) << 16 | (g * 17) << 8 | b * 17, true;
        }
        if h.len == 8 { return ((x & 255) << 24) | (x >> 8), true; }
        if h.len == 4 {
            let r = (x >> 12) & 15;
            let g = (x >> 8) & 15;
            let b = (x >> 4) & 15;
            let a = x & 15;
            return (a * 17) << 24 | (r * 17) << 16 | (g * 17) << 8 | b * 17, true;
        }
        return 0, false;
    }
    if starts_with(v, "rgb") {
        let open = find(v, "(");
        let close = find(v, ")");
        guard open > 0 && close > open else { return 0, false; }
        var parts: f64[4] = [0.0, 0.0, 0.0, 1.0];
        var count = 0;
        var inner: u8[>..] = [];
        for c in v[open + 1..close] { inner.push(if c == ',' || c == '/' { ' ' } else { c }); }
        each_word(inner[..]) {
            if count < 4 {
                let pct = it.len > 0 && it[it.len - 1] == '%';
                let x, ok = parse_flt(if pct { it[..it.len - 1] } else { it });
                if ok { parts[count] = if pct { if count < 3 { x * 2.55 } else { x / 100.0 } } else { x }; }
                count += 1;
            }
        };
        guard count >= 3 else { return 0, false; }
        let r = clamp(parts[0], 0.0, 255.0) as u32;
        let g = clamp(parts[1], 0.0, 255.0) as u32;
        let b = clamp(parts[2], 0.0, 255.0) as u32;
        let a = (clamp(parts[3], 0.0, 1.0) * 255.0) as u32;
        return a << 24 | r << 16 | g << 8 | b, true;
    }
    var n: u8[>..] = [];
    n.append(v);
    to_lower(n[..]);
    let c = named_color(n[..]);
    if c == 1 { return 0, false; }
    return c, true;
}

// Named colours; 1 (never a real colour, its alpha is 0) when unknown.
fn named_color(n: const u8[:]) -> u32 {
    if n == "black" { return 0xFF000000; } if n == "white" { return 0xFFFFFFFF; } if n == "red" { return 0xFFFF0000; }
    if n == "green" { return 0xFF008000; } if n == "blue" { return 0xFF0000FF; } if n == "gray" || n == "grey" { return 0xFF808080; }
    if n == "silver" { return 0xFFC0C0C0; } if n == "maroon" { return 0xFF800000; } if n == "navy" { return 0xFF000080; }
    if n == "purple" { return 0xFF800080; } if n == "teal" { return 0xFF008080; } if n == "olive" { return 0xFF808000; }
    if n == "lime" { return 0xFF00FF00; } if n == "aqua" || n == "cyan" { return 0xFF00FFFF; }
    if n == "fuchsia" || n == "magenta" { return 0xFFFF00FF; } if n == "yellow" { return 0xFFFFFF00; }
    if n == "orange" { return 0xFFFFA500; } if n == "brown" { return 0xFFA52A2A; } if n == "pink" { return 0xFFFFC0CB; }
    if n == "darkgray" || n == "darkgrey" { return 0xFFA9A9A9; } if n == "lightgray" || n == "lightgrey" { return 0xFFD3D3D3; }
    if n == "whitesmoke" { return 0xFFF5F5F5; } if n == "gainsboro" { return 0xFFDCDCDC; } if n == "transparent" { return 0; }
    if n == "currentcolor" { return CURRENT_COLOR; }
    if n == "darkred" { return 0xFF8B0000; } if n == "darkgreen" { return 0xFF006400; } if n == "darkblue" { return 0xFF00008B; }
    return 1;
}

// ------------------------------------------------------------------ the cascade

// Whether element `e` matches rule `r`, compounds checked right to left.
fn rule_matches(sh: Sheet, d: Doc, r: Rule, e: i32) -> bool {
    return matches_from(sh, d, r, r.comp + r.comp_count - 1, e);
}

// Whether compound k of rule r matches element e, and the compounds to its
// left match e's ancestors as their combinators say. A descendant combinator
// tries every ancestor in turn, not just the nearest that matches.
recursive fn matches_from(sh: Sheet, d: Doc, r: Rule, k: i32, e: i32) -> bool {
    guard compound_matches(sh, d, sh.comps[k], e) else { return false; }
    guard k > r.comp else { return true; }
    let join = sh.comps[k].join;
    var at = d.nodes[e].parent;
    while at >= 0 && d.nodes[at].kind == NODE_ELEMENT {
        if matches_from(sh, d, r, k - 1, at) { return true; }
        if join == 2 { return false; }      // a child combinator allows the parent only
        at = d.nodes[at].parent;
    }
    return false;
}

fn compound_matches(sh: Sheet, d: Doc, c: Compound, e: i32) -> bool {
    let n = d.nodes[e];
    if c.tag_len > 0 && span_of(sh, c.tag, c.tag_len) != node_name(d, e) { return false; }
    if c.id_len > 0 {
        let v, ok = attr_value(d, e, "id");
        guard ok && v == span_of(sh, c.id, c.id_len) else { return false; }
    }
    for k in c.cls..c.cls + c.cls_count {
        let s = sh.classes[k];
        guard has_class(d, e, span_of(sh, s.start, s.len)) else { return false; }
    }
    if c.first_child == 1 && first_element_child(d, n.parent) != e { return false; }
    if c.last_child == 1 && last_element_child(d, n.parent) != e { return false; }
    // Tusk keeps no history, and :visited mustn't reveal it anyway.
    if c.link == 2 { return false; }
    if c.link == 1 {
        let name = node_name(d, e);
        let href, has = attr_value(d, e, "href");
        guard has && (name == "a" || name == "area") else { return false; }
    }
    return true;
}

fn span_of(sh: Sheet, start: i32, len: i32) -> const u8[:] {
    let a: i64 = start;
    let b: i64 = start + len;
    return sh.bytes[a..b];
}

fn first_element_child(d: Doc, p: i32) -> i32 {
    guard p >= 0 else { return -1; }
    var c = d.nodes[p].first;
    while c >= 0 && d.nodes[c].kind != NODE_ELEMENT { c = d.nodes[c].next; }
    return c;
}

fn last_element_child(d: Doc, p: i32) -> i32 {
    guard p >= 0 else { return -1; }
    var last: i32 = -1;
    var c = d.nodes[p].first;
    while c >= 0 { if d.nodes[c].kind == NODE_ELEMENT { last = c; } c = d.nodes[c].next; }
    return last;
}

// Computes the style of every element into `styles`, indexed like d.nodes.
// `sh` holds the user-agent sheet and the document's own sheets; the style
// attributes are parsed here, one element at a time, into `scratch`.
fn compute_styles(d: Doc, sh: Sheet, styles: Style[>..]&) {
    while styles.len < d.nodes.len { styles.push(root_style()); }
    compute_subtree(d, sh, styles, 0, root_style());
}

recursive fn compute_subtree(d: Doc, sh: Sheet, styles: Style[>..]&, n: i32, parent: Style) {
    var s = parent;
    if d.nodes[n].kind == NODE_ELEMENT {
        s = cascade(d, sh, n, parent);
    }
    styles[n] = s;
    var c = d.nodes[n].first;
    while c >= 0 {
        if d.nodes[c].kind == NODE_ELEMENT { compute_subtree(d, sh, styles, c, s); }
        else { styles[c] = s; }
        c = d.nodes[c].next;
    }
}

// The cascade for one element: for each property the declaration with the
// highest (importance, origin, specificity, order) wins.
fn cascade(d: Doc, sh: Sheet, e: i32, parent: Style) -> Style {
    var win_prio: i64[28];
    var win: Decl[28];
    fill(win_prio[..], -1);
    for r in sh.rules {
        guard rule_matches(sh, d, r, e) else { continue; }
        for k in r.decl..r.decl + r.decl_count {
            let dc = sh.decls[k];
            let prio = (dc.important as i64) << 62 | (r.origin as i64) << 56 | (r.spec as i64) << 32 | r.order;
            if prio >= win_prio[dc.prop] { win_prio[dc.prop] = prio; win[dc.prop] = dc; }
        }
    }
    // The style attribute beats every sheet, at its own importance.
    let style_attr, has_style = attr_value(d, e, "style");
    if has_style {
        var inline: Decl[>..] = [];
        var text: u8[>..] = [];
        without_comments(style_attr, text);
        parse_declarations(text[..], inline);
        for dc in inline {
            let prio = (dc.important as i64) << 62 | (ORIGIN_INLINE as i64) << 56;
            if prio >= win_prio[dc.prop] { win_prio[dc.prop] = prio; win[dc.prop] = dc; }
        }
    }

    var s = inherit(parent);
    // Font size first: em lengths everywhere else depend on it.
    if win_prio[P_FONT_SIZE] >= 0 { apply(s, parent, win[P_FONT_SIZE]); }
    for p in NPROPS {
        if p == P_FONT_SIZE || win_prio[p] < 0 { continue; }
        apply(s, parent, win[p]);
    }
    let hidden, is_hidden = attr_value(d, e, "hidden");
    if is_hidden { s.display = K_NONE; }
    // rem counts in the root element's font size, from its children on.
    let up = d.nodes[e].parent;
    if up >= 0 && d.nodes[up].kind == NODE_DOCUMENT { s.root_size = s.font_size; }
    return s;
}

// What an element starts from: the inherited properties of its parent, the
// initial values of the rest.
fn inherit(p: Style) -> Style {
    var s = root_style();
    s.color = p.color; s.font_size = p.font_size; s.bold = p.bold; s.italic = p.italic; s.family = p.family;
    s.lh_mult = p.lh_mult; s.lh_px = p.lh_px; s.align = p.align; s.ws = p.ws; s.list = p.list; s.deco = p.deco;
    s.indent = p.indent; s.root_size = p.root_size;
    s.display = K_INLINE;
    return s;
}

fn px(dc: Decl, s: Style, parent: Style) -> f32 {
    if dc.unit == U_EM { return dc.num * s.font_size; }
    if dc.unit == U_REM { return dc.num * s.root_size; }
    if dc.unit == U_PCT { return 0.0; }       // percentages of margins and padding aren't supported yet
    return dc.num;
}

fn apply(s: Style&, parent: Style, dc: Decl) {
    let p = dc.prop;
    if dc.kind == V_INHERIT {
        if p == P_BG { s.bg = parent.bg; }
        else if p == P_DISPLAY { s.display = parent.display; }
        return;
    }
    let k = dc.num as i32;
    if p == P_DISPLAY { if dc.kind == V_KEYWORD && (k == K_NONE || k == K_BLOCK || k == K_INLINE || k == K_LIST_ITEM) { s.display = k; } }
    else if p == P_COLOR { s.color = if dc.color == CURRENT_COLOR { parent.color } else { dc.color }; }
    else if p == P_BG { s.bg = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_FONT_SIZE {
        if dc.kind == V_LENGTH {
            s.font_size = if dc.unit == U_EM { dc.num * parent.font_size } else if dc.unit == U_PCT { dc.num / 100.0 * parent.font_size }
                          else if dc.unit == U_REM { dc.num * s.root_size } else { dc.num };
        }
    }
    else if p == P_FONT_WEIGHT { s.bold = if k == K_BOLD { 1 } else { 0 }; }
    else if p == P_FONT_STYLE { s.italic = if k == K_ITALIC { 1 } else { 0 }; }
    else if p == P_FONT_FAMILY { s.family = k; }
    else if p == P_LINE_HEIGHT {
        // A number is inherited as a number; a length or percentage as the
        // length it comes to here (lh_mult -1).
        if dc.kind == V_NUMBER { s.lh_mult = max(dc.num, 0.0); }
        else if dc.kind == V_LENGTH {
            s.lh_mult = -1.0;
            s.lh_px = max(if dc.unit == U_PCT { dc.num / 100.0 * s.font_size } else { px(dc, s, parent) }, 0.0);
        }
    }
    else if p == P_TEXT_ALIGN { if k == K_LEFT || k == K_RIGHT || k == K_CENTER { s.align = k; } }
    else if p == P_WHITE_SPACE { s.ws = k; }
    else if p == P_LIST { s.list = k; }
    else if p == P_DECO { s.deco = k; }
    else if p == P_VALIGN { s.valign = if dc.kind == V_KEYWORD && (k == K_SUPER || k == K_SUB) { k } else { K_BASELINE }; }
    else if p >= P_MT && p <= P_ML {
        let auto = dc.kind == V_KEYWORD && k == K_AUTO;
        let v = if dc.kind == V_LENGTH { px(dc, s, parent) } else { 0.0 };
        if p == P_MT { s.mt = v; } else if p == P_MB { s.mb = v; }
        else if p == P_ML { s.ml = v; s.auto_ml = if auto { 1 } else { 0 }; }
        else { s.mr = v; s.auto_mr = if auto { 1 } else { 0 }; }
    }
    else if p >= P_PT && p <= P_PL {
        let v = if dc.kind == V_LENGTH { max(px(dc, s, parent), 0.0) } else { 0.0 };
        if p == P_PT { s.pt = v; } else if p == P_PR { s.pr = v; } else if p == P_PB { s.pb = v; } else { s.pl = v; }
    }
    else if p == P_WIDTH || p == P_MAX_WIDTH {
        var v: f32 = -1.0;
        var pct: f32 = -1.0;
        if dc.kind == V_LENGTH { if dc.unit == U_PCT { pct = dc.num; } else { v = px(dc, s, parent); } }
        if p == P_WIDTH { s.width = v; s.width_pct = pct; } else { s.max_width = v; s.max_width_pct = pct; }
    }
    else if p == P_BT_WIDTH { s.bt = if dc.kind == V_LENGTH { px(dc, s, parent) } else { 0.0 }; }
    else if p == P_BB_WIDTH { s.bb = if dc.kind == V_LENGTH { px(dc, s, parent) } else { 0.0 }; }
    else if p == P_BT_COLOR { s.bt_color = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_BB_COLOR { s.bb_color = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_TEXT_INDENT { if dc.kind == V_LENGTH { s.indent = px(dc, s, parent); } }
}

// ------------------------------------------------------------------ Tusk's own style sheet

// The user-agent sheet: HTML's defaults, tuned for reading. Until the network
// stack lands (M2), pages' linked style sheets don't load, so these defaults are
// what most documents look like.
let UA_CSS = """
    html, body, div, p, h1, h2, h3, h4, h5, h6, ul, ol, dl, dt, dd, blockquote, pre, figure, figcaption, section,
    article, main, header, footer, nav, aside, address, hr, form, fieldset, details, summary, center, menu, dir,
    table, caption, thead, tbody, tfoot, tr, legend, hgroup { display: block }
    li { display: list-item }
    head, title, style, script, link, meta, base, noscript, template, iframe, object, embed, video, audio, img, svg,
    math, input, button, select, textarea, map, area, canvas, picture, source, track, param { display: none }
    html { color: #1c1c1c; font-family: sans-serif; font-size: 17px; line-height: 1.6 }
    body { max-width: 720px; margin: 0 auto; padding: 40px 32px 120px }
    h1 { font-size: 2em; font-weight: bold; line-height: 1.2; margin: 0.4em 0 0.6em }
    h2 { font-size: 1.45em; font-weight: bold; line-height: 1.25; margin: 1.3em 0 0.5em; padding-bottom: 0.15em;
         border-bottom: 1px solid #dcdcdc }
    h3 { font-size: 1.2em; font-weight: bold; line-height: 1.3; margin: 1.1em 0 0.4em }
    h4, h5, h6 { font-size: 1em; font-weight: bold; margin: 1em 0 0.3em }
    p { margin: 0 0 1em }
    ul, ol { margin: 0 0 1em; padding-left: 1.6em }
    ul { list-style-type: disc }
    ol { list-style-type: decimal }
    li { margin: 0 0 0.3em }
    dl { margin: 0 0 1em }
    dt { font-weight: bold }
    dd { margin: 0 0 0.5em 1.6em }
    blockquote { margin: 1em 0; padding-left: 1.2em; color: #4a4a4a }
    pre { font-family: monospace; white-space: pre; font-size: 0.88em; line-height: 1.45; margin: 0 0 1em;
          padding: 12px 14px; background-color: #f4f2ee }
    code, kbd, samp, tt { font-family: monospace; font-size: 0.88em }
    b, strong, th { font-weight: bold }
    i, em, cite, var, dfn { font-style: italic }
    a { color: #1a5fb4; text-decoration: underline }
    sup { vertical-align: super; font-size: 0.75em; line-height: 1 }
    sub { vertical-align: sub; font-size: 0.75em; line-height: 1 }
    small { font-size: 0.85em }
    hr { border-top: 1px solid #d0d0d0; margin: 1.2em 0 }
    figure { margin: 1em 0 }
    figcaption, caption { font-size: 0.9em; color: #555555 }
    table { margin: 0 0 1em }
    tr { margin: 0 0 0.2em }
    th, td { padding-right: 1em }
    center { text-align: center }
    """;

// Builds the document's sheets into `sh`: Tusk's own, then each <style> in
// document order. Linked sheets wait for the network stack (M2).
fn load_sheets(d: Doc, sh: Sheet) {
    var order = parse_sheet(UA_CSS, sh, ORIGIN_UA, 0);
    for n, i in d.nodes {
        guard n.kind == NODE_ELEMENT && n.first >= 0 && node_name(d, i as i32) == "style" else { continue; }
        // A sheet for print or speech only isn't for the screen.
        let media, has = attr_value(d, i as i32, "media");
        if has && !for_screen(media) { continue; }
        order = parse_sheet(node_text(d, n.first), sh, ORIGIN_AUTHOR, order);
    }
}

// Whether a media attribute includes the screen: "screen", "all", or a
// query that doesn't name another type.
fn for_screen(media: const u8[:]) -> bool {
    var m: u8[>..] = [];
    m.append(media);
    to_lower(m[..]);
    let t = trim(m[..]);
    return t.len == 0 || find(t, "screen") >= 0 || find(t, "all") >= 0 || (find(t, "print") < 0 && find(t, "speech") < 0);
}
