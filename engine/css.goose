// CSS (docs/adr/0004): a parser for the part of CSS that documents and Tusk's
// own interface (docs/adr/0010) use, selector matching, the cascade and
// computed style. Selectors: type, class, id, universal, attributes,
// descendant and child, :root, :first-child, :last-child, :nth-child, :link,
// and ::before and ::after. A selector with anything else (siblings, :not,
// :hover) is dropped, as is every at-rule. Custom properties inherit, and the
// cascade substitutes var() for each element. Values compute to pixels at
// style time, except the percentages of widths, which layout resolves.

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
let P_CONTENT: i32 = 28;
let P_HEIGHT: i32 = 29;
let P_MIN_WIDTH: i32 = 30;
let P_MIN_HEIGHT: i32 = 31;
let P_MAX_HEIGHT: i32 = 32;
let P_BOX_SIZING: i32 = 33;
let P_BL_WIDTH: i32 = 34;
let P_BR_WIDTH: i32 = 35;
let P_BL_COLOR: i32 = 36;
let P_BR_COLOR: i32 = 37;
let P_BT_STYLE: i32 = 38;
let P_BR_STYLE: i32 = 39;
let P_BB_STYLE: i32 = 40;
let P_BL_STYLE: i32 = 41;
let P_RAD_TL: i32 = 42;
let P_RAD_TR: i32 = 43;
let P_RAD_BR: i32 = 44;
let P_RAD_BL: i32 = 45;
let P_BOX_SHADOW: i32 = 46;
let P_OPACITY: i32 = 47;
let P_POSITION: i32 = 48;
let P_TOP: i32 = 49;
let P_RIGHT: i32 = 50;
let P_BOTTOM: i32 = 51;
let P_LEFT: i32 = 52;
let P_Z_INDEX: i32 = 53;
let P_OVERFLOW_X: i32 = 54;
let P_OVERFLOW_Y: i32 = 55;
let P_TEXT_OVERFLOW: i32 = 56;
let P_FLEX_DIRECTION: i32 = 57;
let P_FLEX_WRAP: i32 = 58;
let P_JUSTIFY_CONTENT: i32 = 59;
let P_ALIGN_ITEMS: i32 = 60;
let P_ALIGN_SELF: i32 = 61;
let P_ALIGN_CONTENT: i32 = 62;
let P_FLEX_GROW: i32 = 63;
let P_FLEX_SHRINK: i32 = 64;
let P_FLEX_BASIS: i32 = 65;
let P_ORDER: i32 = 66;
let P_ROW_GAP: i32 = 67;
let P_COLUMN_GAP: i32 = 68;
let P_TRANSFORM: i32 = 69;
let P_TRANSFORM_ORIGIN: i32 = 70;
let P_LETTER_SPACING: i32 = 71;
let P_TEXT_TRANSFORM: i32 = 72;
let NPROPS: i64 = 73;
let P_CUSTOM: i32 = -2;   // a custom property, --name, which the cascade keeps apart

// Kinds of value.
let V_KEYWORD: i32 = 1;   // Decl.num holds a K_* id
let V_LENGTH: i32 = 2;    // Decl.num in Decl.unit
let V_NUMBER: i32 = 3;
let V_COLOR: i32 = 4;
let V_INHERIT: i32 = 5;
let V_VAR: i32 = 6;       // has var() in it, so it waits as Decl.text until the cascade
let V_STRING: i32 = 7;    // a string, in Decl.text

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
let K_SOLID: i32 = 31;          // border styles: double, groove and the like draw solid,
let K_DASHED: i32 = 32;         // and dotted draws dashed
let K_BORDER_BOX: i32 = 33;
let K_CONTENT_BOX: i32 = 34;
let K_STATIC: i32 = 35;
let K_RELATIVE: i32 = 36;       // sticky too, for now
let K_ABSOLUTE: i32 = 37;
let K_FIXED: i32 = 38;
let K_VISIBLE: i32 = 39;
let K_HIDDEN: i32 = 40;         // overflow: clip, auto and scroll too, since nothing scrolls inside a page yet
let K_ELLIPSIS: i32 = 41;
let K_FLEX: i32 = 42;
let K_ROW: i32 = 43;
let K_ROW_REVERSE: i32 = 44;
let K_COLUMN: i32 = 45;
let K_COLUMN_REVERSE: i32 = 46;
let K_WRAP: i32 = 47;
let K_WRAP_REVERSE: i32 = 48;
let K_FLEX_START: i32 = 49;     // start and self-start too
let K_FLEX_END: i32 = 50;       // end and self-end too
let K_SPACE_BETWEEN: i32 = 51;
let K_SPACE_AROUND: i32 = 52;
let K_SPACE_EVENLY: i32 = 53;
let K_STRETCH: i32 = 54;
let K_CONTENT: i32 = 55;
let K_INLINE_BLOCK: i32 = 56;
let K_INLINE_FLEX: i32 = 57;
let K_UPPERCASE: i32 = 58;
let K_LOWERCASE: i32 = 59;
let K_CAPITALIZE: i32 = 60;
let K_BOLDER: i32 = 61;
let K_LIGHTER: i32 = 62;

// Font families, as the platform layer's text functions number them.
let FAMILY_SANS: i32 = 0;
let FAMILY_SERIF: i32 = 1;
let FAMILY_MONO: i32 = 2;
let FAMILY_CONDENSED: i32 = 3;  // Barlow Condensed, bundled (app/fonts)
let FAMILY_CODE: i32 = 4;       // JetBrains Mono, bundled

// Origins, lowest first.
let ORIGIN_UA: i32 = 0;
let ORIGIN_AUTHOR: i32 = 1;
let ORIGIN_INLINE: i32 = 2;

// One compound selector, e.g. `li.note[data-a]:nth-child(2n)`, and how it
// joins the one to its left: 0 for the first, 1 descendant, 2 child.
struct Compound {
    join: i32,
    tag: i32, tag_len: i32,            // a span into Sheet.bytes; 0 length for none or *
    id: i32, id_len: i32,
    cls: i32, cls_count: i32,          // classes, in Sheet.classes
    attr: i32, attr_count: i32,        // attribute selectors, in Sheet.attrs
    first_child: i32, last_child: i32,
    nth: i32, nth_a: i32, nth_b: i32,  // :nth-child(an+b) when nth is 1
    root: i32,                         // 1 for :root
    link: i32,                         // 1 for :link and :any-link, 2 for :visited
    pseudo: i32,                       // the last compound only: 1 for ::before, 2 for ::after
}

struct Span { start: i32, len: i32 }

// An attribute selector, [name] or [name op value], as spans into Sheet.bytes.
struct AttrSel { name: i32, name_len: i32, value: i32, value_len: i32, op: i32 }

// Attribute selector operators.
let A_HAS: i32 = 0;       // [name]
let A_EQ: i32 = 1;        // =
let A_WORD: i32 = 2;      // ~=, one of the space-separated words
let A_PREFIX: i32 = 3;    // ^=
let A_SUFFIX: i32 = 4;    // $=
let A_SUB: i32 = 5;       // *=
let A_DASH: i32 = 6;      // |=, the value or the value and a hyphen

// One selector of a rule with its declarations. A group `a, b { }` becomes
// two rules sharing their declarations.
struct Rule {
    comp: i32, comp_count: i32,
    decl: i32, decl_count: i32,
    spec: i32,                         // specificity, packed as ids << 16 | classes << 8 | types
    order: i32,
    origin: i32,
    pseudo: i32,                       // its last compound's: 1 for ::before, 2 for ::after
}

// One declaration. Custom properties, values that wait on var() and strings
// keep their text, as spans into Sheet.bytes: `text` is the value, and `name`
// the custom property's name or, for var(), the property or shorthand it was
// written as.
struct Decl { prop: i32, kind: i32, num: f32, unit: i32, color: u32, important: i32,
              text: i32, text_len: i32, name: i32, name_len: i32 }

struct Sheet {
    rules: Rule[>..]&,
    comps: Compound[>..]&,
    classes: Span[>..]&,
    attrs: AttrSel[>..]&,
    decls: Decl[>..]&,
    bytes: u8[>..]&,
    vars: Var[>..]&,          // every element's own custom properties, see Var
    var_bytes: u8[>..]&,      // their values, substituted
}

// One custom property of one element, in a chain: an element's own come
// first, and `next` leads on to its parent's. The name is a span into
// Sheet.bytes, where its declaration keeps it, and the value one into
// Sheet.var_bytes. A value_len of -1 is a value that is invalid (initial, a
// cycle, past a cap, or a var() with no value and no fallback): var() treats
// it as missing.
struct Var { name: i32, name_len: i32, value: i32, value_len: i32, next: i32 }

// Computed style for one element; text nodes use their parent's.
struct Style {
    display: i32,
    color: u32, bg: u32,                 // 0xAARRGGBB; a background with alpha 0 is none
    font_size: f32, italic: i32, family: i32,
    weight: i32,                         // font-weight, 1 to 1000
    spacing: f32,                        // letter-spacing, in points
    text_case: i32,                      // text-transform: K_NONE, K_UPPERCASE, K_LOWERCASE or K_CAPITALIZE
    lh_mult: f32, lh_px: f32,            // line-height: a multiple of the font size, or pixels when lh_mult is 0
    align: i32, ws: i32, list: i32, deco: i32, valign: i32,
    mt: f32, mr: f32, mb: f32, ml: f32,
    auto_ml: i32, auto_mr: i32, auto_mt: i32, auto_mb: i32,
    pt: f32, pr: f32, pb: f32, pl: f32,
    width: f32, width_pct: f32,          // -1 when not set
    max_width: f32, max_width_pct: f32,  // -1 when not set
    bt: f32, bb: f32, bt_color: u32, bb_color: u32,   // a colour of CURRENT_COLOR is the text's
    indent: f32,
    root_size: f32,                      // the root element's font size, which rem counts in
    vars: i32,                           // the head of the element's custom properties in Sheet.vars; -1 for none
    content: i32, content_len: i32,      // ::before and ::after: the content, a span into Sheet.bytes; -1 length for none
    height: f32, height_pct: f32,        // -1 when not set (auto)
    min_width: f32, min_width_pct: f32,  // 0 and -1 when not set
    min_height: f32, min_height_pct: f32,
    max_height: f32, max_height_pct: f32,   // -1 when not set (none)
    border_box: i32,                     // box-sizing: 1 for border-box, where width and height include padding and border
    bl: f32, br: f32, bl_color: u32, br_color: u32,
    bt_style: i32, br_style: i32, bb_style: i32, bl_style: i32,   // K_NONE, K_SOLID or K_DASHED
    rad_tl: f32, rad_tr: f32, rad_br: f32, rad_bl: f32,           // corner radii, top left first, clockwise
    rad_pct: i32,                        // bit k set: corner k's radius is a percentage of the box
    shadows: Shadow[2], shadow_count: i32,
    opacity: f32,                        // the element's own
    alpha: f32,                          // what its paint is multiplied by: its opacity times its parent's alpha
    position: i32,                       // K_STATIC, K_RELATIVE, K_ABSOLUTE or K_FIXED
    top: f32, right: f32, bottom: f32, left: f32,   // insets, in points or percentages (see inset_pct)
    inset_auto: i32, inset_pct: i32,     // bit k (top, right, bottom, left): that inset is auto, or a percentage
    z: i32, z_auto: i32,                 // z-index, and whether it is auto
    clips: i32,                          // bit 0 overflow-x, bit 1 overflow-y isn't visible; either cuts its content at its padding box
    ellipsis: i32,                       // text-overflow: ellipsis
    // Flex containers: direction, wrap, and how they align their items along and across lines.
    flex_dir: i32, flex_wrap: i32, justify: i32, align_items: i32, align_content: i32,
    row_gap: f32, col_gap: f32, gap_pct: i32, // gap_pct: bit 0 row, bit 1 column, percentages
    // Flex items: align-self, flex-grow, flex-shrink, order, and flex-basis:
    // basis_kind K_AUTO, K_CONTENT, or 1 for a length, 2 for a percentage.
    align_self: i32, grow: f32, shrink: f32, order: i32, basis: f32, basis_kind: i32,
    min_w_auto: i32, min_h_auto: i32,    // min-width and min-height are auto, which a flex item turns into its content's
    xf: XForm[6], xf_count: i32,         // transform, its functions in order
    origin_x: f32, origin_y: f32, origin_pct: i32, // transform-origin; origin_pct bit 1 x, 2 y: percentages
}

// One box-shadow. Blurred ones aren't drawn (docs/adr/0010: the interface's
// shadows are rings and bars, which have none).
struct Shadow { ox: f32, oy: f32, blur: f32, spread: f32, color: u32, inset: i32 }

// One transform function: translate (x and y lengths, `pct` bit 1 or 2 when
// x or y is a percentage of the border box), scale (x, y), rotate (x, in
// radians), or matrix(a, b, c, d, e, f), whose a and b are here and c, d and
// e, f in the next two.
struct XForm { kind: i32, x: f32, y: f32, pct: i32 }
let XF_TRANSLATE: i32 = 1;
let XF_SCALE: i32 = 2;
let XF_ROTATE: i32 = 3;
let XF_MATRIX: i32 = 4;

fn no_xform() -> XForm { return XForm { kind: 0, x: 0.0, y: 0.0, pct: 0 }; }

// currentColor until layout paints with the text's colour. Its alpha is 0 and
// no colour name or #rrggbb parses to it.
let CURRENT_COLOR: u32 = 2;

fn line_height(s: Style) -> f32 {
    return if s.lh_mult >= 0.0 { s.lh_mult * s.font_size } else { s.lh_px };
}

fn no_shadow() -> Shadow { return Shadow { ox: 0.0, oy: 0.0, blur: 0.0, spread: 0.0, color: 0, inset: 0 }; }

fn root_style() -> Style {
    return Style { display: K_BLOCK, color: 0xFF000000, bg: 0, font_size: 16.0, italic: 0, family: FAMILY_SANS,
                   weight: 400, spacing: 0.0, text_case: K_NONE,
                   lh_mult: 1.2, lh_px: 0.0, align: K_LEFT, ws: K_NORMAL, list: K_DISC, deco: K_NONE, valign: K_BASELINE,
                   mt: 0.0, mr: 0.0, mb: 0.0, ml: 0.0, auto_ml: 0, auto_mr: 0, auto_mt: 0, auto_mb: 0, pt: 0.0, pr: 0.0, pb: 0.0, pl: 0.0,
                   width: -1.0, width_pct: -1.0, max_width: -1.0, max_width_pct: -1.0,
                   bt: 3.0, bb: 3.0, bt_color: CURRENT_COLOR, bb_color: CURRENT_COLOR, indent: 0.0, root_size: 16.0,
                   vars: -1, content: 0, content_len: -1,
                   height: -1.0, height_pct: -1.0, min_width: 0.0, min_width_pct: -1.0, min_height: 0.0, min_height_pct: -1.0,
                   max_height: -1.0, max_height_pct: -1.0, border_box: 0,
                   bl: 3.0, br: 3.0, bl_color: CURRENT_COLOR, br_color: CURRENT_COLOR,
                   bt_style: K_NONE, br_style: K_NONE, bb_style: K_NONE, bl_style: K_NONE,
                   rad_tl: 0.0, rad_tr: 0.0, rad_br: 0.0, rad_bl: 0.0, rad_pct: 0,
                   shadows: [no_shadow(), no_shadow()], shadow_count: 0, opacity: 1.0, alpha: 1.0,
                   position: K_STATIC, top: 0.0, right: 0.0, bottom: 0.0, left: 0.0, inset_auto: 15, inset_pct: 0,
                   z: 0, z_auto: 1, clips: 0, ellipsis: 0,
                   flex_dir: K_ROW, flex_wrap: K_NOWRAP, justify: K_NORMAL, align_items: K_NORMAL, align_content: K_NORMAL,
                   row_gap: 0.0, col_gap: 0.0, gap_pct: 0,
                   align_self: K_AUTO, grow: 0.0, shrink: 1.0, order: 0, basis: 0.0, basis_kind: K_AUTO,
                   min_w_auto: 1, min_h_auto: 1,
                   xf: [no_xform(), no_xform(), no_xform(), no_xform(), no_xform(), no_xform()], xf_count: 0,
                   origin_x: 50.0, origin_y: 50.0, origin_pct: 3 };
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
        parse_declarations(body_text[..], sh.decls, sh.bytes);
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
    var ids = 0;
    var classes = 0;
    var types = 0;
    var i: i64 = 0;
    var join: i32 = 0;
    var ok = true;
    while i < sel.len && ok {
        var c = Compound { join: join, tag: 0, tag_len: 0, id: 0, id_len: 0, cls: sh.classes.len as i32, cls_count: 0,
                           attr: sh.attrs.len as i32, attr_count: 0, first_child: 0, last_child: 0,
                           nth: 0, nth_a: 0, nth_b: 0, root: 0, link: 0, pseudo: 0 };
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
            if ch == '[' {
                let a = scan_attr(sel, i);
                guard a.ok else { ok = false; break; }
                var at = AttrSel { name: sh.bytes.len as i32, name_len: (a.name_end - a.name_start) as i32,
                                   value: 0, value_len: (a.value_end - a.value_start) as i32, op: a.op };
                for k in a.name_start..a.name_end { sh.bytes.push(lower(sel[k])); }
                at.value = sh.bytes.len as i32;
                sh.bytes.append(sel[a.value_start..a.value_end]);
                sh.attrs.push(at);
                c.attr_count += 1;
                classes += 1;
                i = a.end;
                any = true;
                continue;
            }
            if ch == ':' {
                let p = scan_pseudo(sel, i);
                guard p.ok else { ok = false; break; }
                if p.kind == PS_FIRST { c.first_child = 1; classes += 1; }
                else if p.kind == PS_LAST { c.last_child = 1; classes += 1; }
                else if p.kind == PS_LINK { c.link = 1; classes += 1; }
                else if p.kind == PS_VISITED { c.link = 2; classes += 1; }
                else if p.kind == PS_ROOT { c.root = 1; classes += 1; }
                else if p.kind == PS_NTH { c.nth = 1; c.nth_a = p.a; c.nth_b = p.b; classes += 1; }
                else { c.pseudo = if p.kind == PS_BEFORE { 1 } else { 2 }; types += 1; }
                i = p.end;
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
    let pseudo = sh.comps[sh.comps.len - 1].pseudo;
    sh.rules.push(Rule { comp: comp_start as i32, comp_count: (sh.comps.len - comp_start) as i32, decl: decl, decl_count: decl_count,
                         spec: spec as i32, order: order, origin: origin, pseudo: pseudo });
    return true;
}

// Whether a selector uses only what parse_selector handles, so it can be
// written into the sheet in one pass with nothing to take back. A '>' needs
// a compound on each side, and a pseudo-element may only come last.
fn selector_supported(sel: const u8[:]) -> bool {
    var i: i64 = 0;
    var last: i32 = 0;              // what came last: 0 nothing, 1 a simple selector, 2 a '>'
    var ended = false;
    while i < sel.len {
        let ch = sel[i];
        if is_ws(ch) { i += 1; continue; }
        guard !ended else { return false; }
        if ch == '>' {
            guard last == 1 else { return false; }
            last = 2;
            i += 1;
            continue;
        }
        if ch == '*' { i += 1; }
        else if ch == '#' || ch == '.' {
            i += 1;
            let st = i;
            while i < sel.len && is_ident(sel[i]) { i += 1; }
            guard i > st else { return false; }
        } else if ch == '[' {
            let a = scan_attr(sel, i);
            guard a.ok else { return false; }
            i = a.end;
        } else if ch == ':' {
            let p = scan_pseudo(sel, i);
            guard p.ok else { return false; }
            if p.kind == PS_BEFORE || p.kind == PS_AFTER { ended = true; }
            i = p.end;
        } else if is_ident(ch) {
            while i < sel.len && is_ident(sel[i]) { i += 1; }
        } else {
            return false;
        }
        last = 1;
    }
    return last == 1;
}

// What scan_pseudo found.
let PS_FIRST: i32 = 1;
let PS_LAST: i32 = 2;
let PS_LINK: i32 = 3;
let PS_VISITED: i32 = 4;
let PS_ROOT: i32 = 5;
let PS_NTH: i32 = 6;
let PS_BEFORE: i32 = 7;
let PS_AFTER: i32 = 8;

struct Pseudo { ok: bool, kind: i32, a: i32, b: i32, end: i64 }

// The pseudo-class or pseudo-element at sel[i], a ':', and the index after it.
fn scan_pseudo(sel: const u8[:], i: i64) -> Pseudo {
    var r = Pseudo { ok: false, kind: 0, a: 0, b: 0, end: i };
    var j = i + 1;
    let element = j < sel.len && sel[j] == ':';
    if element { j += 1; }
    let st = j;
    while j < sel.len && is_ident(sel[j]) { j += 1; }
    var name: u8[>..] = [];
    for k in st..j { name.push(lower(sel[k])); }
    let n = name[..];
    r.end = j;
    // ::before and ::after, or the old single-colon spelling.
    if n == "before" || n == "after" {
        r.kind = if n == "before" { PS_BEFORE } else { PS_AFTER };
        r.ok = true;
        return r;
    }
    guard !element else { return r; }
    if n == "nth-child" {
        guard j < sel.len && sel[j] == '(' else { return r; }
        let close = find(sel[j..], ")");
        guard close > 0 else { return r; }
        let a, b, ok = parse_nth(sel[j + 1..j + close]);
        guard ok else { return r; }
        r.kind = PS_NTH;
        r.a = a;
        r.b = b;
        r.end = j + close + 1;
        r.ok = true;
        return r;
    }
    if n == "first-child" { r.kind = PS_FIRST; }
    else if n == "last-child" { r.kind = PS_LAST; }
    else if n == "link" || n == "any-link" { r.kind = PS_LINK; }
    else if n == "visited" { r.kind = PS_VISITED; }
    else if n == "root" { r.kind = PS_ROOT; }
    else { return r; }
    r.ok = true;
    return r;
}

// The a and b of :nth-child(an+b) as CSS writes them: "odd", "even", "3",
// "n", "-n+3", "2n+1", "2n - 1". A sign sticks to what follows it; only the
// sign before b may stand apart. Numbers over a billion count as a billion.
fn parse_nth(args: const u8[:]) -> i32, i32, bool {
    var t: u8[>..] = [];
    for c in trim(args) { t.push(lower(c)); }
    let s = t[..];
    if s == "odd" { return 2, 1, true; }
    if s == "even" { return 2, 0, true; }
    var i: i64 = 0;
    var sign: i64 = 1;
    if i < s.len && (s[i] == '+' || s[i] == '-') {
        if s[i] == '-' { sign = -1; }
        i += 1;
    }
    let st = i;
    let x, after = nth_digits(s, i);
    i = after;
    if i == s.len {
        guard i > st else { return 0, 0, false; }
        return 0, (sign * x) as i32, true;
    }
    guard s[i] == 'n' else { return 0, 0, false; }
    let a = sign * (if i > st { x } else { 1 });
    i += 1;
    while i < s.len && is_ws(s[i]) { i += 1; }
    if i == s.len { return a as i32, 0, true; }
    guard s[i] == '+' || s[i] == '-' else { return 0, 0, false; }
    let bsign: i64 = if s[i] == '-' { -1 } else { 1 };
    i += 1;
    while i < s.len && is_ws(s[i]) { i += 1; }
    let bst = i;
    let y, end = nth_digits(s, i);
    guard end > bst && end == s.len else { return 0, 0, false; }
    return a as i32, (bsign * y) as i32, true;
}

// The digits from s[i] on as a number, a billion at most, and the index after them.
fn nth_digits(s: const u8[:], i: i64) -> i64, i64 {
    var j = i;
    var v: i64 = 0;
    while j < s.len && s[j] >= '0' && s[j] <= '9' {
        v = min(v * 10 + (s[j] - '0'), 1000000000);
        j += 1;
    }
    return v, j;
}

struct AttrScan { ok: bool, name_start: i64, name_end: i64, op: i32, value_start: i64, value_end: i64, end: i64 }

// The attribute selector at sel[i], a '[': [name], [name=value] or
// [name op "value"], and the index after its ']'.
fn scan_attr(sel: const u8[:], i: i64) -> AttrScan {
    var r = AttrScan { ok: false, name_start: 0, name_end: 0, op: A_HAS, value_start: 0, value_end: 0, end: i };
    var j = i + 1;
    while j < sel.len && is_ws(sel[j]) { j += 1; }
    r.name_start = j;
    while j < sel.len && is_ident(sel[j]) { j += 1; }
    r.name_end = j;
    guard r.name_end > r.name_start else { return r; }
    while j < sel.len && is_ws(sel[j]) { j += 1; }
    guard j < sel.len else { return r; }
    if sel[j] != ']' {
        var op: i32 = -1;
        if sel[j] == '=' { op = A_EQ; j += 1; }
        else if j + 1 < sel.len && sel[j + 1] == '=' {
            let o = sel[j];
            op = if o == '~' { A_WORD } else if o == '^' { A_PREFIX } else if o == '$' { A_SUFFIX }
                 else if o == '*' { A_SUB } else if o == '|' { A_DASH } else { -1 };
            j += 2;
        }
        guard op >= 0 else { return r; }
        r.op = op;
        while j < sel.len && is_ws(sel[j]) { j += 1; }
        guard j < sel.len else { return r; }
        if sel[j] == '"' || sel[j] == '\'' {
            let q = sel[j];
            r.value_start = j + 1;
            j += 1;
            while j < sel.len && sel[j] != q { j += 1; }
            guard j < sel.len else { return r; }
            r.value_end = j;
            j += 1;
        } else {
            r.value_start = j;
            while j < sel.len && is_ident(sel[j]) { j += 1; }
            r.value_end = j;
            guard r.value_end > r.value_start else { return r; }
        }
        while j < sel.len && is_ws(sel[j]) { j += 1; }
        guard j < sel.len && sel[j] == ']' else { return r; }
    }
    r.end = j + 1;
    r.ok = true;
    return r;
}

fn is_ident(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 128;
}

// Declarations `prop: value; ...`, shorthands expanded, unknown ones skipped.
// What keeps its text (custom properties, values that wait on var(), strings)
// keeps it in `bytes`.
fn parse_declarations(body: const u8[:], out: Decl[>..]&, bytes: u8[>..]&) {
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
        let raw_name = trim(one[..colon]);
        var value = trim(one[colon + 1..]);
        var important: i32 = 0;
        var bang: i64 = -1;
        for k in value.len { if value[k] == '!' { bang = k; } }
        if bang >= 0 && trim(value[bang + 1..]) == "important" {
            important = 1;
            value = trim(value[..bang]);
        }
        // A custom property keeps the case of its name, and its value as text.
        if starts_with(raw_name, "--") {
            push_decl(out, text_decl(P_CUSTOM, 0, important, value, raw_name, bytes));
            continue;
        }
        var name: u8[>..] = [];
        name.append(raw_name);
        to_lower(name[..]);
        if next_var(value, 0) >= 0 { add_pending(name[..], value, important, out, bytes); continue; }
        add_declaration(name[..], value, important, out, bytes);
    }
}

fn decl(prop: i32, kind: i32, num: f32, unit: i32, color: u32, important: i32) -> Decl {
    return Decl { prop: prop, kind: kind, num: num, unit: unit, color: color, important: important,
                  text: 0, text_len: 0, name: 0, name_len: 0 };
}

// A declaration that keeps `value`, and `name` if it has one, as text in `bytes`.
fn text_decl(prop: i32, kind: i32, important: i32, value: const u8[:], name: const u8[:], bytes: u8[>..]&) -> Decl {
    var dc = decl(prop, kind, 0.0, 0, 0, important);
    dc.text = bytes.len as i32;
    dc.text_len = value.len as i32;
    bytes.append(value);
    dc.name = bytes.len as i32;
    dc.name_len = name.len as i32;
    bytes.append(name);
    return dc;
}

// A declaration with var() in it can't be parsed until the cascade knows the
// variables, so it waits as text: once for its property, or once for each
// longhand of its shorthand.
fn add_pending(name: const u8[:], value: const u8[:], important: i32, out: Decl[>..]&, bytes: u8[>..]&) {
    var props: i32[>..] = [];
    let p = property_id(name);
    if p >= 0 { props.push(p); } else { longhands(name, props); }
    guard props.len > 0;
    let dc = text_decl(0, V_VAR, important, value, name, bytes);
    for lp in props {
        var one = dc;
        one.prop = lp;
        push_decl(out, one);
    }
}

// The longhands a shorthand sets.
fn longhands(name: const u8[:], out: i32[>..]&) {
    if name == "margin" { out.append([P_MT, P_MR, P_MB, P_ML]); }
    else if name == "padding" { out.append([P_PT, P_PR, P_PB, P_PL]); }
    else if name == "border" {
        out.append([P_BT_WIDTH, P_BR_WIDTH, P_BB_WIDTH, P_BL_WIDTH, P_BT_STYLE, P_BR_STYLE, P_BB_STYLE, P_BL_STYLE,
                    P_BT_COLOR, P_BR_COLOR, P_BB_COLOR, P_BL_COLOR]);
    }
    else if name == "border-width" { out.append([P_BT_WIDTH, P_BR_WIDTH, P_BB_WIDTH, P_BL_WIDTH]); }
    else if name == "border-style" { out.append([P_BT_STYLE, P_BR_STYLE, P_BB_STYLE, P_BL_STYLE]); }
    else if name == "border-color" { out.append([P_BT_COLOR, P_BR_COLOR, P_BB_COLOR, P_BL_COLOR]); }
    else if name == "border-top" { out.append([P_BT_WIDTH, P_BT_STYLE, P_BT_COLOR]); }
    else if name == "border-right" { out.append([P_BR_WIDTH, P_BR_STYLE, P_BR_COLOR]); }
    else if name == "border-bottom" { out.append([P_BB_WIDTH, P_BB_STYLE, P_BB_COLOR]); }
    else if name == "border-left" { out.append([P_BL_WIDTH, P_BL_STYLE, P_BL_COLOR]); }
    else if name == "border-radius" { out.append([P_RAD_TL, P_RAD_TR, P_RAD_BR, P_RAD_BL]); }
    else if name == "inset" { out.append([P_TOP, P_RIGHT, P_BOTTOM, P_LEFT]); }
    else if name == "overflow" { out.append([P_OVERFLOW_X, P_OVERFLOW_Y]); }
    else if name == "flex" { out.append([P_FLEX_GROW, P_FLEX_SHRINK, P_FLEX_BASIS]); }
    else if name == "flex-flow" { out.append([P_FLEX_DIRECTION, P_FLEX_WRAP]); }
    else if name == "gap" || name == "grid-gap" { out.append([P_ROW_GAP, P_COLUMN_GAP]); }
    else if name == "background" { out.push(P_BG); }
    else if name == "list-style" { out.push(P_LIST); }
    else if name == "text-decoration" || name == "text-decoration-line" { out.push(P_DECO); }
    else if name == "font" { out.append([P_FONT_STYLE, P_FONT_WEIGHT, P_FONT_SIZE, P_LINE_HEIGHT, P_FONT_FAMILY]); }
}

// content: strings, joined, give ::before or ::after their text, with
// open-quote and close-quote as curly quotes; what follows a '/' is alt text
// for screen readers. none and normal mean there is none. A counter, attr()
// or image isn't supported yet, so a value with one is skipped.
fn add_content(value: const u8[:], important: i32, out: Decl[>..]&, bytes: u8[>..]&) {
    if value == "none" || value == "normal" {
        push_decl(out, decl(P_CONTENT, V_KEYWORD, K_NONE, 0, 0, important));
        return;
    }
    var text: u8[>..] = [];
    var i: i64 = 0;
    while i < value.len {
        let c = value[i];
        if is_ws(c) { i += 1; continue; }
        if c == '/' { break; }
        if c == '"' || c == '\'' {
            let end = skip_string(value, i);
            guard end - 1 > i && value[end - 1] == c else { return; }
            decode_css_string(value[i + 1..end - 1], text);
            i = end;
            continue;
        }
        let st = i;
        while i < value.len && is_ident(value[i]) { i += 1; }
        let w = value[st..i];
        if w == "open-quote" { push_utf8(text, 0x201C); }
        else if w == "close-quote" { push_utf8(text, 0x201D); }
        else if w != "no-open-quote" && w != "no-close-quote" { return; }
    }
    push_decl(out, text_decl(P_CONTENT, V_STRING, important, text[..], "", bytes));
}

// A CSS string's contents with its escapes decoded: a backslash and up to six
// hex digits (and one space after them) is that character, before a newline
// it joins the lines, and before anything else it is that character.
fn decode_css_string(s: const u8[:], out: u8[>..]&) {
    var i: i64 = 0;
    while i < s.len {
        let c = s[i];
        if c != '\\' || i + 1 >= s.len { out.push(c); i += 1; continue; }
        let st = i + 1;
        var j = st;
        while j < s.len && j - st < 6 && is_hex_digit(s[j]) { j += 1; }
        if j > st {
            let cp, ok = parse_int(s[st..j], 16);
            push_utf8(out, if ok && cp > 0 && cp <= 0x10FFFF { cp } else { 0xFFFD });
            if j < s.len && is_ws(s[j]) { j += 1; }
            i = j;
            continue;
        }
        if s[st] != '\n' { out.push(s[st]); }
        i = st + 1;
    }
}

fn is_hex_digit(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

// The font shorthand: [style] [weight] size[/line-height] family. What it
// leaves out goes back to its initial value, as CSS says.
fn add_font(value: const u8[:], important: i32, out: Decl[>..]&) {
    var italic = false;
    var weight: u8[>..] = [];
    var i: i64 = 0;
    var size_start: i64 = -1;
    var size_end: i64 = -1;
    while i < value.len {
        while i < value.len && is_ws(value[i]) { i += 1; }
        let st = i;
        while i < value.len && !is_ws(value[i]) && value[i] != '/' { i += 1; }
        let w = value[st..i];
        guard w.len > 0 else { return; }
        if is_font_size(w) { size_start = st; size_end = i; break; }
        if w == "italic" || w == "oblique" { italic = true; }
        else if w == "bold" || w == "bolder" || w == "lighter" || (w[0] >= '1' && w[0] <= '9') {
            weight.clear();
            weight.append(w);
        }
        else if w != "normal" && w != "small-caps" { return; }
    }
    guard size_start >= 0;
    var lh_start: i64 = -1;
    var lh_end: i64 = -1;
    var j = i;
    while j < value.len && is_ws(value[j]) { j += 1; }
    if j < value.len && value[j] == '/' {
        j += 1;
        while j < value.len && is_ws(value[j]) { j += 1; }
        lh_start = j;
        while j < value.len && !is_ws(value[j]) { j += 1; }
        lh_end = j;
        i = j;
    }
    let family = trim(value[i..]);
    guard family.len > 0;
    add_value(P_FONT_STYLE, if italic { "italic" } else { "normal" }, important, out);
    add_value(P_FONT_WEIGHT, if weight.len > 0 { weight[..] } else { "normal" }, important, out);
    add_value(P_FONT_SIZE, value[size_start..size_end], important, out);
    add_value(P_LINE_HEIGHT, if lh_start >= 0 { value[lh_start..lh_end] } else { "normal" }, important, out);
    add_value(P_FONT_FAMILY, family, important, out);
}

// Whether a word of the font shorthand is its size: a length, or a size keyword.
// The flex shorthand (CSS Flexbox 1 §7.1): none is 0 0 auto, auto 1 1 auto,
// initial 0 1 auto; otherwise a grow and a shrink factor and a basis, any of
// them left out: a number alone means a basis of 0%, which in a column of
// auto height is its content's size, as browsers have it.
fn add_flex(value: const u8[:], important: i32, out: Decl[>..]&) {
    var grow: f64 = 1.0;
    var shrink: f64 = 1.0;
    var basis: u8[>..] = [];
    basis.append("0%");
    if value == "none" || value == "auto" || value == "initial" {
        grow = if value == "auto" { 1.0 } else { 0.0 };
        shrink = if value == "none" { 0.0 } else { 1.0 };
        basis.clear();
        basis.append("auto");
    } else {
        var numbers = 0;
        each_word(value) {
            let n, is_number = parse_flt(it);
            if is_number && numbers < 2 && (it[it.len - 1] < 'a' || it[it.len - 1] > 'z') && it[it.len - 1] != '%' {
                if numbers == 0 { grow = n; } else { shrink = n; }
                numbers += 1;
            } else {
                basis.clear();
                basis.append(it);
            }
        };
    }
    var number: u8[>..] = [];
    format_flt(number, grow, 4);
    add_value(P_FLEX_GROW, number[..], important, out);
    number.clear();
    format_flt(number, shrink, 4);
    add_value(P_FLEX_SHRINK, number[..], important, out);
    add_value(P_FLEX_BASIS, basis[..], important, out);
}

fn is_font_size(w: const u8[:]) -> bool {
    if w == "xx-small" || w == "x-small" || w == "small" || w == "medium" || w == "large" || w == "x-large"
        || w == "xx-large" || w == "smaller" || w == "larger" { return true; }
    let n, u, ok = parse_length(w);
    return ok && (w[w.len - 1] < '0' || w[w.len - 1] > '9');
}

fn add_declaration(name: const u8[:], value: const u8[:], important: i32, out: Decl[>..]&, bytes: u8[>..]&) {
    if name == "font" { add_font(value, important, out); return; }
    if name == "content" { add_content(value, important, out, bytes); return; }
    if name == "margin" || name == "padding" {
        let base = if name == "margin" { P_MT } else { P_PT };
        let parts = values(value);
        guard parts.len >= 1 && parts.len <= 4 else { return; }
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
    if name == "border" || name == "border-top" || name == "border-right" || name == "border-bottom" || name == "border-left" {
        // Width, style and colour in any order. What it leaves out goes back
        // to its initial value: medium, none, currentColor. With no style
        // there is no border, as in CSS. Anything else, a negative width
        // among them, makes the whole declaration invalid.
        var width = decl(0, V_LENGTH, 3.0, U_PX, 0, important);
        var style = K_NONE;
        var color: u32 = CURRENT_COLOR;
        for w in values(value) {
            let st = border_style(w);
            let n, u, is_length = parse_length(w);
            let col, is_color = parse_color(w);
            if st >= 0 { style = st; }
            else if w == "thin" { width.num = 1.0; width.unit = U_PX; }
            else if w == "medium" { width.num = 3.0; width.unit = U_PX; }
            else if w == "thick" { width.num = 5.0; width.unit = U_PX; }
            else if is_length && u != U_PCT && n >= 0.0 { width.num = n; width.unit = u; }
            else if is_color { color = col; }
            else { return; }
        }
        for side in 4 {
            if !border_side(name, side) { continue; }
            push_decl(out, side_decl(width, side, P_BT_WIDTH, P_BR_WIDTH, P_BB_WIDTH, P_BL_WIDTH));
            push_decl(out, side_decl(decl(0, V_KEYWORD, style, 0, 0, important), side, P_BT_STYLE, P_BR_STYLE, P_BB_STYLE, P_BL_STYLE));
            push_decl(out, side_decl(decl(0, V_COLOR, 0.0, 0, color, important), side, P_BT_COLOR, P_BR_COLOR, P_BB_COLOR, P_BL_COLOR));
        }
        return;
    }
    if name == "border-width" || name == "border-style" || name == "border-color" || name == "border-radius" {
        // One to four values: top right bottom left, as for margin. A radius
        // goes top left, top right, bottom right, bottom left, and its
        // elliptical second half, after a slash, is left out.
        let slash = find(value, "/");
        let parts = values(if name == "border-radius" && slash >= 0 { value[..slash] } else { value });
        guard parts.len >= 1 && parts.len <= 4 else { return; }
        for side in 4 {
            let v = parts[side_index(parts.len, side)];
            if name == "border-width" { add_value(side_prop(side, P_BT_WIDTH, P_BR_WIDTH, P_BB_WIDTH, P_BL_WIDTH), v, important, out); }
            else if name == "border-style" { add_value(side_prop(side, P_BT_STYLE, P_BR_STYLE, P_BB_STYLE, P_BL_STYLE), v, important, out); }
            else if name == "border-color" { add_value(side_prop(side, P_BT_COLOR, P_BR_COLOR, P_BB_COLOR, P_BL_COLOR), v, important, out); }
            else { add_value(side_prop(side, P_RAD_TL, P_RAD_TR, P_RAD_BR, P_RAD_BL), v, important, out); }
        }
        return;
    }
    if name == "flex" { add_flex(value, important, out); return; }
    if name == "flex-flow" {
        each_word(value) {
            let k = keyword(it);
            if k == K_ROW || k == K_ROW_REVERSE || k == K_COLUMN || k == K_COLUMN_REVERSE { add_value(P_FLEX_DIRECTION, it, important, out); }
            else if k == K_NOWRAP || k == K_WRAP || k == K_WRAP_REVERSE { add_value(P_FLEX_WRAP, it, important, out); }
        };
        return;
    }
    if name == "gap" || name == "grid-gap" {
        // row, then column; one value is both.
        let parts = words(value);
        guard parts.len >= 1 && parts.len <= 2 else { return; }
        add_value(P_ROW_GAP, parts[0], important, out);
        add_value(P_COLUMN_GAP, parts[parts.len - 1], important, out);
        return;
    }
    if name == "inset" || name == "overflow" {
        // inset: top right bottom left, as for margin; overflow: x then y.
        let parts = words(value);
        guard parts.len >= 1 && parts.len <= (if name == "inset" { 4 } else { 2 });
        if name == "overflow" {
            add_value(P_OVERFLOW_X, parts[0], important, out);
            add_value(P_OVERFLOW_Y, parts[parts.len - 1], important, out);
            return;
        }
        for side in 4 { add_value(side_prop(side, P_TOP, P_RIGHT, P_BOTTOM, P_LEFT), parts[side_index(parts.len, side)], important, out); }
        return;
    }
    if name == "transform" || name == "transform-origin" {
        // Parsed when applied, where em and percentages are known; checked now,
        // so that an invalid one is dropped, as CSS has it.
        let prop = if name == "transform" { P_TRANSFORM } else { P_TRANSFORM_ORIGIN };
        if value == "inherit" { push_decl(out, decl(prop, V_INHERIT, 0.0, 0, 0, important)); return; }
        let initial = value == "initial" || value == "unset";
        if prop == P_TRANSFORM && (initial || value == "none") { push_decl(out, decl(prop, V_KEYWORD, K_NONE, 0, 0, important)); return; }
        var probe = root_style();
        if prop == P_TRANSFORM {
            parse_transform(value, probe);
            if probe.xf_count == 0 { return; }
        } else if !initial && !parse_origin(value, probe) {
            return;
        }
        push_decl(out, text_decl(prop, V_STRING, important, if initial { "50% 50%" } else { value }, "", bytes));
        return;
    }
    if name == "box-shadow" {
        if value == "none" { push_decl(out, decl(P_BOX_SHADOW, V_KEYWORD, K_NONE, 0, 0, important)); }
        else { push_decl(out, text_decl(P_BOX_SHADOW, V_STRING, important, value, "", bytes)); }
        return;
    }
    if name == "background" {
        for w in values(value) {
            let col, ok = parse_color(w);
            if ok { push_decl(out, decl(P_BG, V_COLOR, 0.0, 0, col, important)); }
        }
        return;
    }
    if name == "list-style" {
        each_word(value) {
            let k = keyword(it);
            if k == K_NONE || (k >= K_DISC && k <= K_UPPER_ALPHA) || k == K_LOWER_ROMAN || k == K_UPPER_ROMAN {
                push_decl(out, decl(P_LIST, V_KEYWORD, k as f32, 0, 0, important));
            }
        };
        return;
    }
    if name == "text-decoration" || name == "text-decoration-line" {
        var k = K_NONE;
        each_word(value) { let w = keyword(it); if w == K_UNDERLINE || w == K_LINE_THROUGH { k = w; } };
        push_decl(out, decl(P_DECO, V_KEYWORD, k, 0, 0, important));
        return;
    }
    let prop = property_id(name);
    guard prop >= 0;
    add_value(prop, value, important, out);
}

fn push_decl(out: Decl[>..]&, d: Decl) { out.push(d); }

// Which of one to four values goes to side k (top, right, bottom, left): one
// for all, two for vertical then horizontal, three for top, horizontal and
// bottom.
fn side_index(n: i64, k: i64) -> i64 {
    if n == 1 { return 0; }
    if n == 2 { return if k == 0 || k == 2 { 0 } else { 1 }; }
    if n == 3 { return if k == 0 { 0 } else if k == 2 { 2 } else { 1 }; }
    return k;
}

// Of four properties for the top, right, bottom and left, side k's.
fn side_prop(k: i64, top: i32, right: i32, bottom: i32, left: i32) -> i32 {
    return if k == 0 { top } else if k == 1 { right } else if k == 2 { bottom } else { left };
}

fn side_decl(dc: Decl, k: i64, top: i32, right: i32, bottom: i32, left: i32) -> Decl {
    var one = dc;
    one.prop = side_prop(k, top, right, bottom, left);
    return one;
}

// Whether border shorthand `name` sets side k.
fn border_side(name: const u8[:], k: i64) -> bool {
    return name == "border" || (k == 0 && name == "border-top") || (k == 1 && name == "border-right")
        || (k == 2 && name == "border-bottom") || (k == 3 && name == "border-left");
}

// A border style as Tusk draws it, K_SOLID, K_DASHED or K_NONE; -1 when `w`
// isn't one.
fn border_style(w: const u8[:]) -> i32 {
    if w == "none" || w == "hidden" { return K_NONE; }
    if w == "dashed" || w == "dotted" { return K_DASHED; }
    if w == "solid" || w == "double" || w == "groove" || w == "ridge" || w == "inset" || w == "outset" { return K_SOLID; }
    return -1;
}

// The values in a declaration's text, split at spaces outside brackets and
// quotes, so that rgb(0, 0, 255) is one.
fn values(s: const u8[:]) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    var i: i64 = 0;
    while i < s.len {
        while i < s.len && is_ws(s[i]) { i += 1; }
        let start = i;
        var depth = 0;
        while i < s.len && (depth > 0 || !is_ws(s[i])) {
            let c = s[i];
            if c == '"' || c == '\'' { i = skip_string(s, i); continue; }
            if c == '(' { depth += 1; } else if c == ')' { depth -= 1; }
            i += 1;
        }
        if i > start { out.push(s[start..i]); }
    }
    return out;
}

fn add_value(prop: i32, value: const u8[:], important: i32, out: Decl[>..]&) {
    var d = decl(prop, 0, 0.0, 0, 0, important);
    if value == "inherit" { d.kind = V_INHERIT; push_decl(out, d); return; }
    if prop == P_BT_WIDTH || prop == P_BR_WIDTH || prop == P_BB_WIDTH || prop == P_BL_WIDTH {
        // A keyword, or a length that isn't negative.
        if value == "thin" || value == "medium" || value == "thick" {
            d.kind = V_LENGTH;
            d.num = if value == "thin" { 1.0 } else if value == "medium" { 3.0 } else { 5.0 };
            d.unit = U_PX;
            push_decl(out, d);
            return;
        }
        let n, u, ok = parse_length(value);
        guard !ok || n >= 0.0 else { return; }
    }
    if prop >= P_BT_STYLE && prop <= P_BL_STYLE {
        let st = border_style(value);
        guard st >= 0 else { return; }
        d.kind = V_KEYWORD;
        d.num = st;
        push_decl(out, d);
        return;
    }
    if prop == P_FLEX_GROW || prop == P_FLEX_SHRINK || prop == P_ORDER {
        let n, ok = parse_flt(value);
        guard ok && n >= (if prop == P_ORDER { -1000000.0 } else { 0.0 }) && n <= 1000000.0;
        d.kind = V_NUMBER;
        d.num = n as f32;
        push_decl(out, d);
        return;
    }
    if prop == P_Z_INDEX {
        let n, ok = parse_int(value);
        if ok { d.kind = V_NUMBER; d.num = clamp(n, -1000000000, 1000000000); push_decl(out, d); return; }
    }
    if prop == P_OPACITY {
        let pct = value.len > 0 && value[value.len - 1] == '%';
        let n, ok = parse_flt(if pct { value[..value.len - 1] } else { value });
        guard ok else { return; }
        d.kind = V_NUMBER;
        d.num = (if pct { n / 100.0 } else { n }) as f32;
        push_decl(out, d);
        return;
    }
    if prop == P_COLOR || prop == P_BG || prop == P_BT_COLOR || prop == P_BB_COLOR || prop == P_BL_COLOR || prop == P_BR_COLOR {
        let c, ok = parse_color(value);
        guard ok else { return; }
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
        // A number from 1 to 1000, normal (400) or bold (700) as one, or
        // bolder and lighter, which go from the parent's.
        let n, ok = parse_int(value);
        let k = keyword(value);
        guard (ok && n >= 1 && n <= 1000) || k == K_NORMAL || k == K_BOLD || k == K_BOLDER || k == K_LIGHTER else { return; }
        if k == K_BOLDER || k == K_LIGHTER {
            d.kind = V_KEYWORD;
            d.num = k;
        } else {
            d.kind = V_NUMBER;
            d.num = if ok { n } else if k == K_BOLD { 700 } else { 400 };
        }
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
    if n == "text-indent" { return P_TEXT_INDENT; } if n == "content" { return P_CONTENT; }
    if n == "height" { return P_HEIGHT; } if n == "min-width" { return P_MIN_WIDTH; }
    if n == "min-height" { return P_MIN_HEIGHT; } if n == "max-height" { return P_MAX_HEIGHT; }
    if n == "box-sizing" { return P_BOX_SIZING; } if n == "opacity" { return P_OPACITY; }
    if n == "border-left-width" { return P_BL_WIDTH; } if n == "border-right-width" { return P_BR_WIDTH; }
    if n == "border-left-color" { return P_BL_COLOR; } if n == "border-right-color" { return P_BR_COLOR; }
    if n == "border-top-style" { return P_BT_STYLE; } if n == "border-right-style" { return P_BR_STYLE; }
    if n == "border-bottom-style" { return P_BB_STYLE; } if n == "border-left-style" { return P_BL_STYLE; }
    if n == "border-top-left-radius" { return P_RAD_TL; } if n == "border-top-right-radius" { return P_RAD_TR; }
    if n == "border-bottom-right-radius" { return P_RAD_BR; } if n == "border-bottom-left-radius" { return P_RAD_BL; }
    if n == "box-shadow" { return P_BOX_SHADOW; }
    if n == "position" { return P_POSITION; } if n == "z-index" { return P_Z_INDEX; }
    if n == "top" { return P_TOP; } if n == "right" { return P_RIGHT; }
    if n == "bottom" { return P_BOTTOM; } if n == "left" { return P_LEFT; }
    if n == "overflow-x" { return P_OVERFLOW_X; } if n == "overflow-y" { return P_OVERFLOW_Y; }
    if n == "text-overflow" { return P_TEXT_OVERFLOW; }
    if n == "transform" { return P_TRANSFORM; } if n == "transform-origin" { return P_TRANSFORM_ORIGIN; }
    if n == "letter-spacing" { return P_LETTER_SPACING; } if n == "text-transform" { return P_TEXT_TRANSFORM; }
    if n == "flex-direction" { return P_FLEX_DIRECTION; } if n == "flex-wrap" { return P_FLEX_WRAP; }
    if n == "justify-content" { return P_JUSTIFY_CONTENT; } if n == "align-items" { return P_ALIGN_ITEMS; }
    if n == "align-self" { return P_ALIGN_SELF; } if n == "align-content" { return P_ALIGN_CONTENT; }
    if n == "flex-grow" { return P_FLEX_GROW; } if n == "flex-shrink" { return P_FLEX_SHRINK; }
    if n == "flex-basis" { return P_FLEX_BASIS; } if n == "order" { return P_ORDER; }
    if n == "row-gap" || n == "grid-row-gap" { return P_ROW_GAP; } if n == "column-gap" || n == "grid-column-gap" { return P_COLUMN_GAP; }
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
    if v == "border-box" { return K_BORDER_BOX; } if v == "content-box" { return K_CONTENT_BOX; }
    if v == "static" { return K_STATIC; } if v == "relative" || v == "sticky" { return K_RELATIVE; }
    if v == "absolute" { return K_ABSOLUTE; } if v == "fixed" { return K_FIXED; } if v == "visible" { return K_VISIBLE; }
    if v == "hidden" || v == "clip" || v == "scroll" { return K_HIDDEN; } if v == "ellipsis" { return K_ELLIPSIS; }
    if v == "flex" { return K_FLEX; } if v == "row" { return K_ROW; } if v == "row-reverse" { return K_ROW_REVERSE; }
    if v == "column" { return K_COLUMN; } if v == "column-reverse" { return K_COLUMN_REVERSE; }
    if v == "wrap" { return K_WRAP; } if v == "wrap-reverse" { return K_WRAP_REVERSE; }
    if v == "flex-start" || v == "self-start" { return K_FLEX_START; } if v == "flex-end" || v == "self-end" { return K_FLEX_END; }
    if v == "space-between" { return K_SPACE_BETWEEN; } if v == "space-around" { return K_SPACE_AROUND; }
    if v == "space-evenly" { return K_SPACE_EVENLY; } if v == "stretch" { return K_STRETCH; } if v == "content" { return K_CONTENT; }
    if v == "inline-block" { return K_INLINE_BLOCK; } if v == "inline-flex" { return K_INLINE_FLEX; }
    if v == "uppercase" { return K_UPPERCASE; } if v == "lowercase" { return K_LOWERCASE; }
    if v == "capitalize" { return K_CAPITALIZE; } if v == "bolder" { return K_BOLDER; } if v == "lighter" { return K_LIGHTER; }
    // Display values we lay out as one of those we know.
    if v == "inline-grid" || v == "inline-table" || v == "table-cell" { return K_INLINE; }
    if v == "grid" || v == "table" || v == "table-row" || v == "table-row-group" || v == "table-header-group"
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
            // The bundled families by name, then the generic ones by what
            // their names suggest.
            if s == "barlow condensed" { family = FAMILY_CONDENSED; }
            else if s == "jetbrains mono" { family = FAMILY_CODE; }
            else if s == "monospace" || find(s, "mono") >= 0 || find(s, "courier") >= 0 || find(s, "menlo") >= 0 || find(s, "consolas") >= 0 {
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
    for k in c.attr..c.attr + c.attr_count {
        guard attr_matches(sh, d, sh.attrs[k], e) else { return false; }
    }
    if c.root == 1 && (n.parent < 0 || d.nodes[n.parent].kind != NODE_DOCUMENT) { return false; }
    if c.first_child == 1 && first_element_child(d, n.parent) != e { return false; }
    if c.last_child == 1 && last_element_child(d, n.parent) != e { return false; }
    if c.nth == 1 && !nth_matches(c.nth_a, c.nth_b, element_index(d, e)) { return false; }
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

fn var_span(sh: Sheet, start: i32, len: i32) -> const u8[:] {
    let a: i64 = start;
    let b: i64 = start + len;
    return sh.var_bytes[a..b];
}

fn attr_matches(sh: Sheet, d: Doc, a: AttrSel, e: i32) -> bool {
    let v, has = attr_value(d, e, span_of(sh, a.name, a.name_len));
    guard has else { return false; }
    let want = span_of(sh, a.value, a.value_len);
    if a.op == A_HAS { return true; }
    if a.op == A_EQ { return v == want; }
    if a.op == A_PREFIX { return want.len > 0 && starts_with(v, want); }
    if a.op == A_SUFFIX { return want.len > 0 && v.len >= want.len && v[v.len - want.len..] == want; }
    if a.op == A_SUB { return want.len > 0 && find(v, want) >= 0; }
    if a.op == A_DASH { return v == want || (starts_with(v, want) && v.len > want.len && v[want.len] == '-'); }
    return has_word(v, want);
}

// Whether position i (counting from 1) is a·k + b for some k ≥ 0.
fn nth_matches(a: i32, b: i32, i: i32) -> bool {
    if a == 0 { return i == b; }
    let gap = i - b;
    return gap % a == 0 && gap / a >= 0;
}

// Element e's position among its parent's elements, from 1. The ::before and
// ::after the cascade makes don't count, here or in the two below.
fn element_index(d: Doc, e: i32) -> i32 {
    let p = d.nodes[e].parent;
    guard p >= 0 else { return 1; }
    var i: i32 = 0;
    var c = d.nodes[p].first;
    while c >= 0 {
        if d.nodes[c].kind == NODE_ELEMENT && !is_generated(d, c) {
            i += 1;
            if c == e { return i; }
        }
        c = d.nodes[c].next;
    }
    return i;
}

fn first_element_child(d: Doc, p: i32) -> i32 {
    guard p >= 0 else { return -1; }
    var c = d.nodes[p].first;
    while c >= 0 && (d.nodes[c].kind != NODE_ELEMENT || is_generated(d, c)) { c = d.nodes[c].next; }
    return c;
}

fn last_element_child(d: Doc, p: i32) -> i32 {
    guard p >= 0 else { return -1; }
    var last: i32 = -1;
    var c = d.nodes[p].first;
    while c >= 0 {
        if d.nodes[c].kind == NODE_ELEMENT && !is_generated(d, c) { last = c; }
        c = d.nodes[c].next;
    }
    return last;
}

// What the cascade shares across all elements. The rule index: every rule
// filed under one key of its last compound, in `order`, bucket b's at
// offsets[b] to offsets[b + 1]. And scratch, so that styling makes no arrays
// per element: each call pushes above what is there and takes it back
// before it returns.
struct Work { offsets: i32[>..]&, order: i32[>..]&, customs: Decl[>..<]&, prio: i64[>..<]&, text: u8[>..<]& }

let BUCKETS: i64 = 1024;
let UNIVERSAL: i32 = 1024;      // the bucket of rules with no id, class or tag to file them under

// Computes the style of every element into `styles`, indexed like d.nodes,
// and makes the ::before and ::after that rules give content to.
fn compute_styles(d: Doc, sh: Sheet, styles: Style[>..]&) {
    while styles.len < d.nodes.len { styles.push(root_style()); }
    // The rules that style ::before or ::after. Only an element one of them
    // matches gets the cascade for its pseudo-elements, so that the rest
    // don't pay for looking.
    var pseudo_rules: i32[>..] = [];
    for r, i in sh.rules { if r.pseudo != 0 { pseudo_rules.push(i as i32); } }
    var offsets: i32[>..] = [];
    var order: i32[>..] = [];
    index_rules(sh, offsets, order);
    var customs: Decl[>..<] = [];
    var prio: i64[>..<] = [];
    var text: u8[>..<] = [];
    let w = Work { offsets: offsets, order: order, customs: customs, prio: prio, text: text };
    compute_subtree(d, sh, styles, 0, root_style(), pseudo_rules[..], w);
    viewport_overflow(d, styles);
}

// The root element's overflow belongs to the viewport, or the body's when the
// root's is visible (CSS 2.2 §11.1.1); the element itself is then visible.
// Tusk's page never scrolls sideways, so the viewport needs nothing more.
fn viewport_overflow(d: Doc, styles: Style[>..]&) {
    let html = d.nodes[0].first;
    guard html >= 0 && d.nodes[html].kind == NODE_ELEMENT else { return; }
    if styles[html].clips != 0 {
        styles[html].clips = 0;
        return;
    }
    var c = d.nodes[html].first;
    while c >= 0 {
        if is_element(d, c, "body") {
            styles[c].clips = 0;
            return;
        }
        c = d.nodes[c].next;
    }
}

// Files every rule under one key of its last compound, so that an element
// tries only the rules it could match: those under its id, its classes, its
// tag, and the universal ones.
fn index_rules(sh: Sheet, offsets: i32[>..]&, order: i32[>..]&) {
    var counts: i32[1025];
    fill(counts[..], 0);
    for r in sh.rules { counts[rule_bucket(sh, r)] += 1; }
    offsets.push(0);
    for b in BUCKETS + 1 { offsets.push(offsets[b] + counts[b]); }
    var next: i32[1025];
    for b in BUCKETS + 1 { next[b] = offsets[b]; }
    for r in sh.rules { order.push(0); }
    for r, i in sh.rules {
        let b = rule_bucket(sh, r);
        order[next[b]] = i as i32;
        next[b] += 1;
    }
}

// The bucket a rule is filed under: its last compound's id, else its first
// class, else its tag, else UNIVERSAL.
fn rule_bucket(sh: Sheet, r: Rule) -> i32 {
    let c = sh.comps[r.comp + r.comp_count - 1];
    if c.id_len > 0 { return bucket_of('#', span_of(sh, c.id, c.id_len)); }
    if c.cls_count > 0 {
        let s = sh.classes[c.cls];
        return bucket_of('.', span_of(sh, s.start, s.len));
    }
    if c.tag_len > 0 { return bucket_of('<', span_of(sh, c.tag, c.tag_len)); }
    return UNIVERSAL;
}

// Adds bucket b after the first nb of `buckets`, unless `seen` has it already;
// returns how many there are now.
fn add_bucket(buckets: i32[:], seen: u64[:], nb: i64, b: i32) -> i64 {
    let word: i64 = b >> 6;
    let bit: u64 = 1 << (b & 63);
    guard (seen[word] & bit) == 0 else { return nb; }
    seen[word] = seen[word] | bit;
    buckets[nb] = b;
    return nb + 1;
}

// A key's bucket: FNV-1a over its kind ('#' id, '.' class, '<' tag) and its
// bytes, so that the tag p and the class p land apart.
fn bucket_of(kind: u8, key: const u8[:]) -> i32 {
    var h: u64 = 2166136261;
    h = ((h ^ kind) * 16777619) & 0xFFFFFFFF;
    for c in key { h = ((h ^ c) * 16777619) & 0xFFFFFFFF; }
    return (h & 1023) as i32;               // BUCKETS is 1024
}

recursive fn compute_subtree(d: Doc, sh: Sheet, styles: Style[>..]&, n: i32, parent: Style, pseudo_rules: const i32[:], w: Work) {
    var s = parent;
    let element = d.nodes[n].kind == NODE_ELEMENT;
    if element {
        // A ::before or ::after keeps the style it was made with.
        s = if is_generated(d, n) { styles[n] } else { cascade(d, sh, n, parent, 0, w) };
    }
    styles[n] = s;
    if element && pseudo_rules.len > 0 && s.display != K_NONE && !is_generated(d, n) {
        // Which of its pseudo-elements a rule styles: 1 ::before, 2 ::after.
        var styled: i32 = 0;
        for k in pseudo_rules {
            let r = sh.rules[k];
            if (styled & r.pseudo) == 0 && rule_matches(sh, d, r, n) { styled |= r.pseudo; }
        }
        if (styled & 1) != 0 { generate(d, sh, styles, n, s, 1, w); }
        if (styled & 2) != 0 { generate(d, sh, styles, n, s, 2, w); }
    }
    var c = d.nodes[n].first;
    while c >= 0 {
        if d.nodes[c].kind == NODE_ELEMENT { compute_subtree(d, sh, styles, c, s, pseudo_rules, w); }
        else { styles[c] = s; }
        c = d.nodes[c].next;
    }
}

// Makes element n's ::before (`which` 1) or ::after (2), when the cascade
// gives it content: an element named after it as n's first or last child,
// holding the content as text, with its style already in `styles`.
fn generate(d: Doc, sh: Sheet, styles: Style[>..]&, n: i32, s: Style, which: i32, w: Work) {
    let name = if which == 1 { "::before" } else { "::after" };
    var ps = cascade(d, sh, n, s, which, w);
    // Styled again, a document keeps the ones it has and styles them again
    // (compute_subtree gives their text the same style).
    let edge = if which == 1 { d.nodes[n].first } else { d.nodes[n].last };
    if edge >= 0 && d.nodes[edge].kind == NODE_ELEMENT && node_name(d, edge) == name {
        if ps.content_len < 0 { ps.display = K_NONE; }
        styles[edge] = ps;
        return;
    }
    guard ps.content_len >= 0;
    let g = add_element(d, name, n, which == 1);
    styles.push(ps);
    if ps.content_len > 0 {
        add_text(d, span_of(sh, ps.content, ps.content_len), g);
        styles.push(ps);
    }
}

// The cascade for element e, or for its ::before (`pseudo` 1) or ::after (2):
// for each property the declaration with the highest (importance, origin,
// specificity, order) wins. Custom properties win by name, and var() is
// substituted before a declaration that waits on it applies.
fn cascade(d: Doc, sh: Sheet, e: i32, parent: Style, pseudo: i32, w: Work) -> Style {
    var win_prio: i64[NPROPS];
    var win: Decl[NPROPS];
    fill(win_prio[..], -1);
    let mark = w.customs.len;
    // The buckets this element's rules can be in, each once however many
    // classes it has: the universal one, its tag's, its id's and its classes',
    // split as has_class splits them.
    var buckets: i32[1025];
    var seen: u64[17];
    fill(seen[..], 0);
    var nb = add_bucket(buckets[..], seen[..], 0, UNIVERSAL);
    nb = add_bucket(buckets[..], seen[..], nb, bucket_of('<', node_name(d, e)));
    let id, has_id = attr_value(d, e, "id");
    if has_id && id.len > 0 { nb = add_bucket(buckets[..], seen[..], nb, bucket_of('#', id)); }
    let cls, has_cls = attr_value(d, e, "class");
    var ci: i64 = 0;
    while has_cls && ci < cls.len {
        while ci < cls.len && is_ws(cls[ci]) { ci += 1; }
        let st = ci;
        while ci < cls.len && !is_ws(cls[ci]) { ci += 1; }
        if ci > st { nb = add_bucket(buckets[..], seen[..], nb, bucket_of('.', cls[st..ci])); }
    }
    for bi in nb {
        let b = buckets[bi];
        for k in w.offsets[b]..w.offsets[b + 1] {
            let r = sh.rules[w.order[k]];
            guard r.pseudo == pseudo && rule_matches(sh, d, r, e) else { continue; }
            for j in r.decl..r.decl + r.decl_count {
                let dc = sh.decls[j];
                let prio = (dc.important as i64) << 62 | (r.origin as i64) << 56 | (r.spec as i64) << 32 | r.order;
                if dc.prop == P_CUSTOM { keep_custom(sh, w, mark, dc, prio); continue; }
                if prio >= win_prio[dc.prop] { win_prio[dc.prop] = prio; win[dc.prop] = dc; }
            }
        }
    }
    // The style attribute beats every sheet, at its own importance.
    let style_attr, has_style = attr_value(d, e, "style");
    if has_style && pseudo == 0 {
        var inline: Decl[>..] = [];
        var text: u8[>..] = [];
        without_comments(style_attr, text);
        parse_declarations(text[..], inline, sh.bytes);
        for dc in inline {
            let prio = (dc.important as i64) << 62 | (ORIGIN_INLINE as i64) << 56;
            if dc.prop == P_CUSTOM { keep_custom(sh, w, mark, dc, prio); continue; }
            if prio >= win_prio[dc.prop] { win_prio[dc.prop] = prio; win[dc.prop] = dc; }
        }
    }

    var s = inherit(parent);
    if w.customs.len > mark { s.vars = own_vars(sh, w.customs[mark..], parent.vars, w.text); }
    // Font size first: em lengths everywhere else depend on it.
    if win_prio[P_FONT_SIZE] >= 0 { apply_decl(s, parent, win[P_FONT_SIZE], sh, w.text); }
    for p in NPROPS {
        if p == P_FONT_SIZE || win_prio[p] < 0 { continue; }
        apply_decl(s, parent, win[p], sh, w.text);
    }
    if pseudo == 0 {
        let hidden, is_hidden = attr_value(d, e, "hidden");
        if is_hidden { s.display = K_NONE; }
        // rem counts in the root element's font size, from its children on.
        let up = d.nodes[e].parent;
        if up >= 0 && d.nodes[up].kind == NODE_DOCUMENT { s.root_size = s.font_size; }
    }
    // A border whose style is none has no width (CSS 2.2 §8.5.3).
    if s.bt_style == K_NONE { s.bt = 0.0; }
    if s.br_style == K_NONE { s.br = 0.0; }
    if s.bb_style == K_NONE { s.bb = 0.0; }
    if s.bl_style == K_NONE { s.bl = 0.0; }
    s.alpha = parent.alpha * s.opacity;
    // An absolute or fixed box is a block, whatever its display (CSS 2.2 §9.7),
    // and so is a flex item (CSS Flexbox 1 §4): inline and inline-block
    // become block, inline-flex flex.
    if s.position == K_ABSOLUTE || s.position == K_FIXED || parent.display == K_FLEX || parent.display == K_INLINE_FLEX {
        if s.display == K_INLINE || s.display == K_INLINE_BLOCK { s.display = K_BLOCK; }
        else if s.display == K_INLINE_FLEX { s.display = K_FLEX; }
    }
    w.customs.resize(mark);
    w.prio.resize(mark);
    return s;
}

// Keeps the winning declaration of each custom property, by name, in
// w.customs from `from` on.
fn keep_custom(sh: Sheet, w: Work, from: i64, dc: Decl, p: i64) {
    let name = span_of(sh, dc.name, dc.name_len);
    for i in from..w.customs.len {
        if span_of(sh, w.customs[i].name, w.customs[i].name_len) == name {
            if p >= w.prio[i] { w.customs[i] = dc; w.prio[i] = p; }
            return;
        }
    }
    w.customs.push(dc);
    w.prio.push(p);
}

// What one of an element's own custom properties is while own_vars works
// through them.
struct OwnVar { state: i32, depth: i32, at: i32 }
let OV_TODO: i32 = 0;
let OV_BUSY: i32 = 1;           // being substituted, `depth` down the stack
let OV_DONE: i32 = 2;           // substituted, into sh.vars[at]
let OV_INHERIT: i32 = 3;        // inherit or unset: the parent's shows through
let NO_CYCLE: i32 = 1000000;

// Caps, so that a few lines of variables that each use the one before many
// times can't grow into gigabytes: a substituted value's length, the whole
// document's substituted values, and how deep references and fallbacks nest.
let VAR_MAX: i64 = 65536;
let VAR_BYTES_MAX: i64 = 33554432;
let VAR_DEPTH_MAX: i32 = 64;

// Puts an element's own custom properties in front of the chain its parent's
// start at, each substituted once (it may use the others, or inherited ones),
// and returns the new head. Substituted here, a value is inherited as it came
// out where it was set.
fn own_vars(sh: Sheet, own: const Decl[:], head: i32, scratch: u8[>..<]&) -> i32 {
    var ov: OwnVar[>..<] = [];
    for dc in own {
        let v = trim(span_of(sh, dc.text, dc.text_len));
        let inherits = v == "inherit" || v == "unset" || v == "revert" || v == "revert-layer";
        ov.push(OwnVar { state: if inherits { OV_INHERIT } else { OV_TODO }, depth: 0, at: -1 });
    }
    for i in own.len { if ov[i].state == OV_TODO { resolve_own(sh, own, ov, i, 0, head, scratch); } }
    var at = head;
    for o in ov {
        guard o.state == OV_DONE else { continue; }
        sh.vars[o.at].next = at;
        at = o.at;
    }
    return at;
}

// Substitutes own custom property i and files its value as a Var. initial, a
// cycle through it (CSS makes every property in a cycle invalid) and a value
// past the caps make it invalid. Returns how far down the stack a cycle met on
// the way reaches, when that is below i; else NO_CYCLE.
recursive fn resolve_own(sh: Sheet, own: const Decl[:], ov: OwnVar[>..<]&, i: i64, depth: i32, head: i32, scratch: u8[>..<]&) -> i32 {
    ov[i].state = OV_BUSY;
    ov[i].depth = depth;
    let dc = own[i];
    let text = span_of(sh, dc.text, dc.text_len);
    let mark = scratch.len;
    var ok = trim(text) != "initial";
    var low = NO_CYCLE;
    if ok {
        let done, reach = substitute(sh, text, own, ov, depth, head, mark + VAR_MAX, scratch);
        ok = done && reach > depth && sh.var_bytes.len + (scratch.len - mark) <= VAR_BYTES_MAX;
        low = reach;
    }
    var v = Var { name: dc.name, name_len: dc.name_len, value: sh.var_bytes.len as i32, value_len: -1, next: -1 };
    if ok {
        v.value_len = (scratch.len - mark) as i32;
        sh.var_bytes.append(scratch[mark..]);
    }
    scratch.resize(mark);
    ov[i].state = OV_DONE;
    ov[i].at = sh.vars.len as i32;
    sh.vars.push(v);
    return if low < depth { low } else { NO_CYCLE };
}

// Appends `text` to `out` with each var() replaced by its custom property:
// the element's own (`own`, substituted when first used), else the one
// inherited from `head` on, else the var()'s fallback. False, with `out` as it
// was, when one has none of those, when `out` would grow past `limit`, or when
// references nest VAR_DEPTH_MAX deep. Also returns how far down the stack a
// cycle met on the way reaches (NO_CYCLE when there was none).
recursive fn substitute(sh: Sheet, text: const u8[:], own: const Decl[:], ov: OwnVar[>..<]&, depth: i32, head: i32,
                        limit: i64, out: u8[>..<]&) -> bool, i32 {
    guard depth < VAR_DEPTH_MAX else { return false, NO_CYCLE; }
    let mark = out.len;
    var low = NO_CYCLE;
    var i: i64 = 0;
    while i < text.len {
        let k = next_var(text, i);
        let end = if k < 0 { text.len } else { k };
        if out.len + (end - i) > limit { out.resize(mark); return false, low; }
        out.append(text[i..end]);
        if k < 0 { break; }
        let open = k + 4;
        let close = close_paren(text, open);
        if close < 0 { out.resize(mark); return false, low; }
        let inside = text[open..close];
        let comma = top_comma(inside);
        let found, reach = lookup_var(sh, trim(if comma >= 0 { inside[..comma] } else { inside }), own, ov, depth, head, limit, out);
        low = min(low, reach);
        if !found {
            guard comma >= 0 else { out.resize(mark); return false, low; }
            let fell, back = substitute(sh, trim(inside[comma + 1..]), own, ov, depth + 1, head, limit, out);
            low = min(low, back);
            if !fell { out.resize(mark); return false, low; }
        }
        i = close + 1;
    }
    return true, low;
}

// Appends the value of custom property `name`, found as substitute says;
// false, with `out` as it was, when there is none or it is invalid. Also
// returns how far down the stack a cycle met on the way reaches.
recursive fn lookup_var(sh: Sheet, name: const u8[:], own: const Decl[:], ov: OwnVar[>..<]&, depth: i32, head: i32,
                        limit: i64, out: u8[>..<]&) -> bool, i32 {
    var at = head;
    var low = NO_CYCLE;
    for dc, i in own {
        guard ov[i].state != OV_INHERIT && span_of(sh, dc.name, dc.name_len) == name else { continue; }
        // Still being substituted further up: a cycle, down to there.
        if ov[i].state == OV_BUSY { return false, ov[i].depth; }
        if ov[i].state == OV_TODO { low = resolve_own(sh, own, ov, i, depth + 1, head, out); }
        at = ov[i].at;
        break;
    }
    while at >= 0 {
        let v = sh.vars[at];
        if span_of(sh, v.name, v.name_len) == name {
            guard v.value_len >= 0 && out.len + v.value_len <= limit else { return false, low; }
            out.append(var_span(sh, v.value, v.value_len));
            return true, low;
        }
        at = v.next;
    }
    return false, low;
}

// The index of the next var( in s from i on, outside strings; -1 when there
// is none.
fn next_var(s: const u8[:], i: i64) -> i64 {
    var j = i;
    while j + 4 <= s.len {
        let c = s[j];
        if c == '"' || c == '\'' { j = skip_string(s, j); continue; }
        if lower(c) == 'v' && lower(s[j + 1]) == 'a' && lower(s[j + 2]) == 'r' && s[j + 3] == '(' && (j == 0 || !is_ident(s[j - 1])) {
            return j;
        }
        j += 1;
    }
    return -1;
}

// The index of the ')' that closes a '(' just before s[i], nesting and quotes
// allowed for; -1 when there is none.
fn close_paren(s: const u8[:], i: i64) -> i64 {
    var depth = 1;
    var j = i;
    while j < s.len {
        let c = s[j];
        if c == '"' || c == '\'' { j = skip_string(s, j); continue; }
        if c == '(' { depth += 1; }
        else if c == ')' { depth -= 1; if depth == 0 { return j; } }
        j += 1;
    }
    return -1;
}

// The index of the first comma outside brackets and quotes; -1 when there is none.
fn top_comma(s: const u8[:]) -> i64 {
    var depth = 0;
    var j: i64 = 0;
    while j < s.len {
        let c = s[j];
        if c == '"' || c == '\'' { j = skip_string(s, j); continue; }
        if c == '(' { depth += 1; }
        else if c == ')' { depth -= 1; }
        else if c == ',' && depth == 0 { return j; }
        j += 1;
    }
    return -1;
}

// Applies a declaration, substituting var() first when it waits on one: the
// text is then parsed as the property or shorthand it was written as, and
// this longhand applied. When a variable has no value and its var() no
// fallback, the property stays as it was: inherited, or initial.
fn apply_decl(s: Style&, parent: Style, dc: Decl, sh: Sheet, scratch: u8[>..<]&) {
    if dc.kind != V_VAR { apply_value(s, parent, dc, sh); return; }
    let mark = scratch.len;
    var none: OwnVar[>..<] = [];
    let ok, reach = substitute(sh, span_of(sh, dc.text, dc.text_len), sh.decls[0..0], none, 0, s.vars, mark + VAR_MAX, scratch);
    if ok {
        var name: u8[>..] = [];
        name.append(span_of(sh, dc.name, dc.name_len));
        // Shorthands keep slices of their value (words), so it goes into an array
        // that only grows.
        var value: u8[>..] = [];
        value.append(scratch[mark..]);
        var parsed: Decl[>..] = [];
        add_declaration(name[..], value[..], dc.important, parsed, sh.bytes);
        for one in parsed { if one.prop == dc.prop { apply_value(s, parent, one, sh); } }
    }
    scratch.resize(mark);
}

// apply, and box-shadow, whose list is text in the sheet's bytes.
fn apply_value(s: Style&, parent: Style, dc: Decl, sh: Sheet) {
    if dc.prop == P_BOX_SHADOW && dc.kind == V_STRING { parse_shadows(span_of(sh, dc.text, dc.text_len), s); return; }
    if dc.prop == P_TRANSFORM && dc.kind == V_STRING { parse_transform(span_of(sh, dc.text, dc.text_len), s); return; }
    if dc.prop == P_TRANSFORM_ORIGIN && dc.kind == V_STRING { parse_origin(span_of(sh, dc.text, dc.text_len), s); return; }
    apply(s, parent, dc);
}

// transform: translate(), translateX(), translateY(), scale(), scaleX(),
// scaleY(), rotate() and matrix(), up to six of them, in order. Anything
// else (skew, 3D) makes the whole list none, as an invalid value would.
fn parse_transform(text: const u8[:], s: Style&) {
    s.xf_count = 0;
    var i: i64 = 0;
    while i < text.len {
        while i < text.len && is_ws(text[i]) { i += 1; }
        guard i < text.len else { return; }
        let st = i;
        while i < text.len && text[i] != '(' { i += 1; }
        let close = if i < text.len { close_paren(text, i + 1) } else { -1 };
        guard close > 0 else { s.xf_count = 0; return; }
        var name: u8[>..] = [];
        for c in trim(text[st..i]) { name.push(lower(c)); }
        let f = name[..];
        // Its arguments, split at commas or spaces.
        var v: f32[6];
        var unit: i32[6];
        var count = 0;
        var ok = true;
        var j = i + 1;
        while j < close {
            while j < close && (is_ws(text[j]) || text[j] == ',') { j += 1; }
            let a = j;
            while j < close && !is_ws(text[j]) && text[j] != ',' { j += 1; }
            guard j > a else { continue; }
            let x, u, aok = transform_arg(text[a..j], s);
            if !aok || count >= 6 { ok = false; break; }
            v[count] = x;
            unit[count] = u;
            count += 1;
        }
        i = close + 1;
        var one = no_xform();
        let room: i32 = if f == "matrix" { 3 } else { 1 };
        if !ok || s.xf_count + room > 6 { s.xf_count = 0; return; }
        // Units: 0 a number, 1 a length, 2 a percentage, 3 an angle. A 0 with
        // none is a length or an angle too.
        let len0 = count >= 1 && (unit[0] == 1 || unit[0] == 2 || (unit[0] == 0 && v[0] == 0.0));
        let len1 = count >= 2 && (unit[1] == 1 || unit[1] == 2 || (unit[1] == 0 && v[1] == 0.0));
        if (f == "translate" && len0 && (count == 1 || (count == 2 && len1))) || ((f == "translatex" || f == "translatey") && count == 1 && len0) {
            one.kind = XF_TRANSLATE;
            if f == "translatey" {
                one.y = v[0];
                if unit[0] == 2 { one.pct = 2; }
            } else {
                one.x = v[0];
                if unit[0] == 2 { one.pct = 1; }
                if count == 2 {
                    one.y = v[1];
                    if unit[1] == 2 { one.pct = one.pct | 2; }
                }
            }
        } else if (f == "scale" && (count == 1 || count == 2) && unit[0] == 0 && (count == 1 || unit[1] == 0))
                  || ((f == "scalex" || f == "scaley") && count == 1 && unit[0] == 0) {
            one.kind = XF_SCALE;
            one.x = if f == "scaley" { 1.0 } else { v[0] };
            one.y = if f == "scalex" { 1.0 } else if count == 2 { v[1] } else { v[0] };
        } else if (f == "rotate" || f == "rotatez") && count == 1 && (unit[0] == 3 || (unit[0] == 0 && v[0] == 0.0)) {
            one.kind = XF_ROTATE;
            one.x = v[0];
        } else if f == "matrix" && count == 6 {
            for k in 3 { s.xf[s.xf_count + k] = XForm { kind: XF_MATRIX, x: v[2 * k], y: v[2 * k + 1], pct: 0 }; }
            s.xf_count += 3;
            continue;
        } else {
            s.xf_count = 0;
            return;
        }
        s.xf[s.xf_count] = one;
        s.xf_count += 1;
    }
}

// A transform function's argument: its value and what it is (0 a number, 1
// a length in points, 2 a percentage, 3 an angle in radians).
fn transform_arg(w: const u8[:], s: Style) -> f32, i32, bool {
    var k: i64 = 0;
    while k < w.len && (w[k] == '-' || w[k] == '+' || w[k] == '.' || (w[k] >= '0' && w[k] <= '9') || ((w[k] == 'e' || w[k] == 'E') && k > 0 && k + 1 < w.len && (w[k + 1] == '-' || (w[k + 1] >= '0' && w[k + 1] <= '9')))) { k += 1; }
    guard k > 0 else { return 0.0, 0, false; }
    let n, ok = parse_flt(w[..k]);
    guard ok else { return 0.0, 0, false; }
    let x = n as f32;
    var unit: u8[>..] = [];
    for c in w[k..] { unit.push(lower(c)); }
    let u = unit[..];
    if u.len == 0 { return x, 0, true; }
    if u == "px" { return x, 1, true; }
    if u == "em" { return x * s.font_size, 1, true; }
    if u == "rem" { return x * s.root_size, 1, true; }
    if u == "pt" { return x * 4.0 / 3.0, 1, true; }
    if u == "%" { return x, 2, true; }
    if u == "deg" { return x * 3.14159265 / 180.0, 3, true; }
    if u == "rad" { return x, 3, true; }
    if u == "turn" { return x * 6.28318531, 3, true; }
    if u == "grad" { return x * 3.14159265 / 200.0, 3, true; }
    return 0.0, 0, false;
}

// transform-origin: one or two of left, center, right, top, bottom, lengths
// and percentages; x then y, unless keywords say otherwise. A third value
// (depth) is ignored. Whether it was valid: anything else, or more, isn't.
fn parse_origin(text: const u8[:], s: Style&) -> bool {
    var x: f32 = 50.0;
    var y: f32 = 50.0;
    var pct: i32 = 3;
    var count = 0;
    var x_set = false;
    var y_set = false;
    var ok = true;
    each_word(text) {
        let w = it;
        if count >= 2 {
            let v, u, wok = transform_arg(w, s);
            if count > 2 || !wok || !(u == 1 || (u == 0 && v == 0.0)) { ok = false; }
        } else {
            if w == "left" || w == "right" { x = if w == "left" { 0.0 } else { 100.0 }; pct = pct | 1; x_set = true; }
            else if w == "top" || w == "bottom" { y = if w == "top" { 0.0 } else { 100.0 }; pct = pct | 2; y_set = true; }
            else if w == "center" { }
            else {
                let v, u, wok = transform_arg(w, s);
                if !wok || !(u == 1 || u == 2 || (u == 0 && v == 0.0)) { ok = false; }
                else {
                    let into_x = !x_set && (count == 0 || y_set);
                    if into_x {
                        x = v;
                        pct = if u == 2 { pct | 1 } else { pct & ~1 };
                        x_set = true;
                    } else {
                        y = v;
                        pct = if u == 2 { pct | 2 } else { pct & ~2 };
                        y_set = true;
                    }
                }
            }
        }
        count += 1;
    };
    s.origin_x = x;
    s.origin_y = y;
    s.origin_pct = pct;
    return ok && count > 0;
}

// box-shadow: up to two shadows, separated by commas, each `x y [blur
// [spread]]` with `inset` and a colour anywhere among them; the text's colour
// when there's none. Lengths in em count in the element's font size.
fn parse_shadows(text: const u8[:], s: Style&) {
    s.shadow_count = 0;
    var rest = text;
    while rest.len > 0 && s.shadow_count < 2 {
        let comma = top_comma(rest);
        let one = trim(if comma >= 0 { rest[..comma] } else { rest });
        rest = if comma >= 0 { rest[comma + 1..] } else { rest[rest.len..] };
        var sd = no_shadow();
        sd.color = s.color;
        var lengths: f32[4];
        var count = 0;
        var ok = true;
        var i: i64 = 0;
        while i < one.len {
            while i < one.len && is_ws(one[i]) { i += 1; }
            let st = i;
            var depth = 0;
            while i < one.len && (depth > 0 || !is_ws(one[i])) {
                if one[i] == '(' { depth += 1; } else if one[i] == ')' { depth -= 1; }
                i += 1;
            }
            let w = one[st..i];
            if w.len == 0 { continue; }
            if w == "inset" { sd.inset = 1; continue; }
            let n, u, lok = parse_length(w);
            if lok && u != U_PCT {
                if count < 4 {
                    lengths[count] = if u == U_EM { n * s.font_size } else if u == U_REM { n * s.root_size } else { n };
                    count += 1;
                }
                continue;
            }
            let c, cok = parse_color(w);
            if cok { sd.color = if c == CURRENT_COLOR { s.color } else { c }; continue; }
            ok = false;
        }
        guard ok && count >= 2 else { continue; }
        sd.ox = lengths[0];
        sd.oy = lengths[1];
        if count >= 3 { sd.blur = max(lengths[2], 0.0); }
        if count >= 4 { sd.spread = lengths[3]; }
        s.shadows[s.shadow_count] = sd;
        s.shadow_count += 1;
    }
}

// inherit, for a property that doesn't inherit by itself: the parent's
// value. One that does inherit already has it.
fn inherit_value(s: Style&, parent: Style, p: i32) {
    if p == P_BG { s.bg = parent.bg; }
    else if p == P_DISPLAY { s.display = parent.display; }
    else if p == P_VALIGN { s.valign = parent.valign; }
    else if p == P_MT { s.mt = parent.mt; s.auto_mt = parent.auto_mt; } else if p == P_MB { s.mb = parent.mb; s.auto_mb = parent.auto_mb; }
    else if p == P_ML { s.ml = parent.ml; s.auto_ml = parent.auto_ml; }
    else if p == P_MR { s.mr = parent.mr; s.auto_mr = parent.auto_mr; }
    else if p == P_PT { s.pt = parent.pt; } else if p == P_PR { s.pr = parent.pr; }
    else if p == P_PB { s.pb = parent.pb; } else if p == P_PL { s.pl = parent.pl; }
    else if p == P_WIDTH { s.width = parent.width; s.width_pct = parent.width_pct; }
    else if p == P_MAX_WIDTH { s.max_width = parent.max_width; s.max_width_pct = parent.max_width_pct; }
    else if p == P_HEIGHT { s.height = parent.height; s.height_pct = parent.height_pct; }
    else if p == P_MIN_WIDTH { s.min_width = parent.min_width; s.min_width_pct = parent.min_width_pct; }
    else if p == P_MIN_HEIGHT { s.min_height = parent.min_height; s.min_height_pct = parent.min_height_pct; }
    else if p == P_MAX_HEIGHT { s.max_height = parent.max_height; s.max_height_pct = parent.max_height_pct; }
    else if p == P_BOX_SIZING { s.border_box = parent.border_box; }
    else if p == P_BT_WIDTH { s.bt = parent.bt; } else if p == P_BR_WIDTH { s.br = parent.br; }
    else if p == P_BB_WIDTH { s.bb = parent.bb; } else if p == P_BL_WIDTH { s.bl = parent.bl; }
    else if p == P_BT_COLOR { s.bt_color = parent.bt_color; } else if p == P_BR_COLOR { s.br_color = parent.br_color; }
    else if p == P_BB_COLOR { s.bb_color = parent.bb_color; } else if p == P_BL_COLOR { s.bl_color = parent.bl_color; }
    else if p == P_BT_STYLE { s.bt_style = parent.bt_style; } else if p == P_BR_STYLE { s.br_style = parent.br_style; }
    else if p == P_BB_STYLE { s.bb_style = parent.bb_style; } else if p == P_BL_STYLE { s.bl_style = parent.bl_style; }
    else if p >= P_RAD_TL && p <= P_RAD_BL {
        let bit: i32 = 1 << (p - P_RAD_TL);
        if p == P_RAD_TL { s.rad_tl = parent.rad_tl; } else if p == P_RAD_TR { s.rad_tr = parent.rad_tr; }
        else if p == P_RAD_BR { s.rad_br = parent.rad_br; } else { s.rad_bl = parent.rad_bl; }
        s.rad_pct = (s.rad_pct & ~bit) | (parent.rad_pct & bit);
    }
    else if p == P_BOX_SHADOW { s.shadows = parent.shadows; s.shadow_count = parent.shadow_count; }
    else if p == P_OPACITY { s.opacity = parent.opacity; }
    else if p == P_POSITION { s.position = parent.position; }
    else if p >= P_TOP && p <= P_LEFT {
        let bit: i32 = 1 << (p - P_TOP);
        if p == P_TOP { s.top = parent.top; } else if p == P_RIGHT { s.right = parent.right; }
        else if p == P_BOTTOM { s.bottom = parent.bottom; } else { s.left = parent.left; }
        s.inset_auto = (s.inset_auto & ~bit) | (parent.inset_auto & bit);
        s.inset_pct = (s.inset_pct & ~bit) | (parent.inset_pct & bit);
    }
    else if p == P_Z_INDEX { s.z = parent.z; s.z_auto = parent.z_auto; }
    else if p == P_OVERFLOW_X || p == P_OVERFLOW_Y {
        let bit: i32 = if p == P_OVERFLOW_X { 1 } else { 2 };
        s.clips = (s.clips & ~bit) | (parent.clips & bit);
    }
    else if p == P_TEXT_OVERFLOW { s.ellipsis = parent.ellipsis; }
    else if p == P_FLEX_DIRECTION { s.flex_dir = parent.flex_dir; } else if p == P_FLEX_WRAP { s.flex_wrap = parent.flex_wrap; }
    else if p == P_JUSTIFY_CONTENT { s.justify = parent.justify; } else if p == P_ALIGN_ITEMS { s.align_items = parent.align_items; }
    else if p == P_ALIGN_SELF { s.align_self = parent.align_self; } else if p == P_ALIGN_CONTENT { s.align_content = parent.align_content; }
    else if p == P_FLEX_GROW { s.grow = parent.grow; } else if p == P_FLEX_SHRINK { s.shrink = parent.shrink; }
    else if p == P_FLEX_BASIS { s.basis = parent.basis; s.basis_kind = parent.basis_kind; }
    else if p == P_ORDER { s.order = parent.order; }
    else if p == P_ROW_GAP || p == P_COLUMN_GAP {
        let bit: i32 = if p == P_ROW_GAP { 1 } else { 2 };
        if p == P_ROW_GAP { s.row_gap = parent.row_gap; } else { s.col_gap = parent.col_gap; }
        s.gap_pct = (s.gap_pct & ~bit) | (parent.gap_pct & bit);
    }
    else if p == P_TRANSFORM { s.xf = parent.xf; s.xf_count = parent.xf_count; }
    else if p == P_TRANSFORM_ORIGIN { s.origin_x = parent.origin_x; s.origin_y = parent.origin_y; s.origin_pct = parent.origin_pct; }
}

// What an element starts from: the inherited properties of its parent, the
// initial values of the rest.
fn inherit(p: Style) -> Style {
    var s = root_style();
    s.color = p.color; s.font_size = p.font_size; s.italic = p.italic; s.family = p.family;
    s.weight = p.weight; s.spacing = p.spacing; s.text_case = p.text_case;
    s.lh_mult = p.lh_mult; s.lh_px = p.lh_px; s.align = p.align; s.ws = p.ws; s.list = p.list; s.deco = p.deco;
    s.indent = p.indent; s.root_size = p.root_size; s.vars = p.vars;
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
    if dc.kind == V_INHERIT { inherit_value(s, parent, p); return; }
    let k = dc.num as i32;
    if p == P_DISPLAY {
        if dc.kind == V_KEYWORD && (k == K_NONE || k == K_BLOCK || k == K_INLINE || k == K_LIST_ITEM || k == K_FLEX
                                    || k == K_INLINE_BLOCK || k == K_INLINE_FLEX) { s.display = k; }
    }
    else if p == P_COLOR { s.color = if dc.color == CURRENT_COLOR { parent.color } else { dc.color }; }
    else if p == P_BG { s.bg = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_FONT_SIZE {
        if dc.kind == V_LENGTH {
            s.font_size = if dc.unit == U_EM { dc.num * parent.font_size } else if dc.unit == U_PCT { dc.num / 100.0 * parent.font_size }
                          else if dc.unit == U_REM { dc.num * s.root_size } else { dc.num };
        }
    }
    else if p == P_FONT_WEIGHT {
        // bolder and lighter step from the parent's weight (CSS Fonts 4 §2.2).
        var w = parent.weight;
        if dc.kind == V_NUMBER { w = dc.num as i32; }
        else if k == K_BOLDER { w = if w < 350 { 400 } else if w < 550 { 700 } else if w < 900 { 900 } else { w }; }
        else if k == K_LIGHTER { w = if w < 100 { w } else if w < 550 { 100 } else if w < 750 { 400 } else { 700 }; }
        s.weight = w;
    }
    else if p == P_LETTER_SPACING { s.spacing = if dc.kind == V_LENGTH { px(dc, s, parent) } else { 0.0 }; }
    else if p == P_TEXT_TRANSFORM { if k == K_NONE || k == K_UPPERCASE || k == K_LOWERCASE || k == K_CAPITALIZE { s.text_case = k; } }
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
        if p == P_MT { s.mt = v; s.auto_mt = if auto { 1 } else { 0 }; }
        else if p == P_MB { s.mb = v; s.auto_mb = if auto { 1 } else { 0 }; }
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
    else if p == P_BT_WIDTH { s.bt = if dc.kind == V_LENGTH { max(px(dc, s, parent), 0.0) } else { 0.0 }; }
    else if p == P_BB_WIDTH { s.bb = if dc.kind == V_LENGTH { max(px(dc, s, parent), 0.0) } else { 0.0 }; }
    else if p == P_BT_COLOR { s.bt_color = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_BB_COLOR { s.bb_color = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_TEXT_INDENT { if dc.kind == V_LENGTH { s.indent = px(dc, s, parent); } }
    else if p == P_CONTENT {
        s.content = dc.text;
        s.content_len = if dc.kind == V_STRING { dc.text_len } else { -1 };
    }
    else if p == P_HEIGHT || p == P_MIN_WIDTH || p == P_MIN_HEIGHT || p == P_MAX_HEIGHT {
        // auto and none are -1; a minimum that isn't set is 0.
        var v: f32 = if p == P_MIN_WIDTH || p == P_MIN_HEIGHT { 0.0 } else { -1.0 };
        var pct: f32 = -1.0;
        if dc.kind == V_LENGTH { if dc.unit == U_PCT { pct = dc.num; v = -1.0; } else { v = max(px(dc, s, parent), 0.0); } }
        if p == P_HEIGHT { s.height = v; s.height_pct = pct; }
        else if p == P_MIN_WIDTH { s.min_width = max(v, 0.0); s.min_width_pct = pct; s.min_w_auto = if dc.kind == V_LENGTH { 0 } else { 1 }; }
        else if p == P_MIN_HEIGHT { s.min_height = max(v, 0.0); s.min_height_pct = pct; s.min_h_auto = if dc.kind == V_LENGTH { 0 } else { 1 }; }
        else { s.max_height = v; s.max_height_pct = pct; }
    }
    else if p == P_BOX_SIZING { s.border_box = if k == K_BORDER_BOX { 1 } else { 0 }; }
    else if p == P_BL_WIDTH { s.bl = if dc.kind == V_LENGTH { max(px(dc, s, parent), 0.0) } else { 0.0 }; }
    else if p == P_BR_WIDTH { s.br = if dc.kind == V_LENGTH { max(px(dc, s, parent), 0.0) } else { 0.0 }; }
    else if p == P_BL_COLOR { s.bl_color = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_BR_COLOR { s.br_color = if dc.color == CURRENT_COLOR { s.color } else { dc.color }; }
    else if p == P_BT_STYLE { s.bt_style = k; }
    else if p == P_BR_STYLE { s.br_style = k; }
    else if p == P_BB_STYLE { s.bb_style = k; }
    else if p == P_BL_STYLE { s.bl_style = k; }
    else if p >= P_RAD_TL && p <= P_RAD_BL {
        let corner = p - P_RAD_TL;
        let bit: i32 = 1 << corner;
        var v: f32 = 0.0;
        if dc.kind == V_LENGTH {
            if dc.unit == U_PCT { v = max(dc.num, 0.0); s.rad_pct = s.rad_pct | bit; }
            else { v = max(px(dc, s, parent), 0.0); s.rad_pct = s.rad_pct & ~bit; }
        }
        if corner == 0 { s.rad_tl = v; } else if corner == 1 { s.rad_tr = v; } else if corner == 2 { s.rad_br = v; } else { s.rad_bl = v; }
    }
    else if p == P_BOX_SHADOW { s.shadow_count = 0; }       // none; the shadows themselves come through apply_decl
    else if p == P_TRANSFORM { s.xf_count = 0; }             // none; a list comes through apply_value
    else if p == P_TRANSFORM_ORIGIN { s.origin_x = 50.0; s.origin_y = 50.0; s.origin_pct = 3; }
    else if p == P_OPACITY { s.opacity = clamp(dc.num, 0.0, 1.0); }
    else if p == P_POSITION { if k == K_STATIC || k == K_RELATIVE || k == K_ABSOLUTE || k == K_FIXED { s.position = k; } }
    else if p >= P_TOP && p <= P_LEFT {
        let bit: i32 = 1 << (p - P_TOP);
        var v: f32 = 0.0;
        if dc.kind == V_LENGTH {
            s.inset_auto = s.inset_auto & ~bit;
            if dc.unit == U_PCT { v = dc.num; s.inset_pct = s.inset_pct | bit; }
            else { v = px(dc, s, parent); s.inset_pct = s.inset_pct & ~bit; }
        } else {
            s.inset_auto = s.inset_auto | bit;
        }
        if p == P_TOP { s.top = v; } else if p == P_RIGHT { s.right = v; } else if p == P_BOTTOM { s.bottom = v; } else { s.left = v; }
    }
    else if p == P_Z_INDEX {
        if dc.kind == V_NUMBER { s.z = dc.num as i32; s.z_auto = 0; } else { s.z = 0; s.z_auto = 1; }
    }
    else if p == P_OVERFLOW_X || p == P_OVERFLOW_Y {
        // Either axis that isn't visible clips both, as CSS's visible turns to
        // auto beside it (overflow-x: clip alone would cut only sideways).
        let bit: i32 = if p == P_OVERFLOW_X { 1 } else { 2 };
        s.clips = if k == K_HIDDEN || k == K_AUTO { s.clips | bit } else { s.clips & ~bit };
    }
    else if p == P_TEXT_OVERFLOW { s.ellipsis = if k == K_ELLIPSIS { 1 } else { 0 }; }
    else if p == P_FLEX_DIRECTION { if k == K_ROW || k == K_ROW_REVERSE || k == K_COLUMN || k == K_COLUMN_REVERSE { s.flex_dir = k; } }
    else if p == P_FLEX_WRAP { if k == K_NOWRAP || k == K_WRAP || k == K_WRAP_REVERSE { s.flex_wrap = k; } }
    else if p == P_JUSTIFY_CONTENT || p == P_ALIGN_ITEMS || p == P_ALIGN_SELF || p == P_ALIGN_CONTENT {
        // start and end (which text-align calls left and right) are flex-start and flex-end here.
        let a = if k == K_LEFT { K_FLEX_START } else if k == K_RIGHT { K_FLEX_END } else { k };
        guard dc.kind == V_KEYWORD && (a == K_NORMAL || a == K_FLEX_START || a == K_FLEX_END || a == K_CENTER || a == K_STRETCH
              || a == K_BASELINE || a == K_SPACE_BETWEEN || a == K_SPACE_AROUND || a == K_SPACE_EVENLY || a == K_AUTO) else { return; }
        if p == P_JUSTIFY_CONTENT { s.justify = a; } else if p == P_ALIGN_ITEMS { s.align_items = a; }
        else if p == P_ALIGN_SELF { s.align_self = a; } else { s.align_content = a; }
    }
    else if p == P_FLEX_GROW { s.grow = dc.num; }
    else if p == P_FLEX_SHRINK { s.shrink = dc.num; }
    else if p == P_ORDER { s.order = dc.num as i32; }
    else if p == P_FLEX_BASIS {
        if dc.kind == V_LENGTH {
            s.basis_kind = if dc.unit == U_PCT { 2 } else { 1 };
            s.basis = if dc.unit == U_PCT { dc.num } else { max(px(dc, s, parent), 0.0) };
        } else {
            s.basis_kind = if k == K_CONTENT { K_CONTENT } else { K_AUTO };
        }
    }
    else if p == P_ROW_GAP || p == P_COLUMN_GAP {
        let bit: i32 = if p == P_ROW_GAP { 1 } else { 2 };
        let v = if dc.kind == V_LENGTH { if dc.unit == U_PCT { dc.num } else { max(px(dc, s, parent), 0.0) } } else { 0.0 };
        if p == P_ROW_GAP { s.row_gap = v; } else { s.col_gap = v; }
        s.gap_pct = if dc.kind == V_LENGTH && dc.unit == U_PCT { s.gap_pct | bit } else { s.gap_pct & ~bit };
    }
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
