// HTML parsing (docs/adr/0004): a tokenizer and tree builder for the part of
// the WHATWG algorithm that documents use. It recovers the way browsers do in
// the common cases: an unclosed <p>, <li> or cell, a stray end tag, void
// elements, the implied <html>, <head> and <body>. Scripts are skipped, never
// run, and tables nest as written.

import std;
import .dom;

struct Parser {
    d: Doc,
    open: i32[>..<]&,   // the stack of open elements, below <body>
    src: const u8[:],
    pos: i64,
    head: i32,
    body: i32,
    in_body: bool,      // false until the first content that belongs in <body>
}

// Parses `src` into `d` and returns the document node.
fn parse_html(src: const u8[:], d: Doc) -> i32 {
    var open: i32[>..<] = [];
    let doc = append_node(d, NODE_DOCUMENT, -1);
    let html = make_element(d, "html", doc);
    let head = make_element(d, "head", html);
    let body = make_element(d, "body", html);
    var p = Parser { d: d, open: open, src: src, pos: 0, head: head, body: body, in_body: false };
    run(p);
    return doc;
}

fn make_element(d: Doc, name: const u8[:], parent: i32) -> i32 {
    let id = append_node(d, NODE_ELEMENT, parent);
    d.nodes[id].name = d.bytes.len as i32;
    d.nodes[id].name_len = name.len as i32;
    d.bytes.append(name);
    return id;
}

fn current_parent(p: Parser&) -> i32 {
    return if p.open.len > 0 { p.open[p.open.len - 1] } else { p.body };
}

fn run(p: Parser&) {
    let s = p.src;
    var text_start: i64 = -1;      // where the current run of text starts in d.bytes
    while p.pos < s.len {
        let c = s[p.pos];
        if c == '<' && p.pos + 1 < s.len {
            let n = s[p.pos + 1];
            if is_alpha(n) || n == '/' || n == '!' || n == '?' {
                flush_text(p, text_start);
                text_start = -1;
                if n == '!' { skip_declaration(p); }
                else if n == '?' { skip_past(p, ">"); }
                else if n == '/' { end_tag(p); }
                else { start_tag(p); }
                continue;
            }
        }
        if text_start < 0 { text_start = p.d.bytes.len; }
        if c == '&' {
            p.pos = decode_ref(s, p.pos, s.len, p.d.bytes);
        } else {
            p.d.bytes.push(c);
            p.pos += 1;
        }
    }
    flush_text(p, text_start);
}

// Turns the bytes appended since `start` into a text node.
fn flush_text(p: Parser&, start: i64) {
    guard start >= 0 && p.d.bytes.len > start;
    let len = p.d.bytes.len - start;
    if !p.in_body {
        var blank = true;
        for i in start..p.d.bytes.len { if !is_ws(p.d.bytes[i]) { blank = false; break; } }
        guard !blank;                // whitespace before <body> content belongs nowhere
        p.in_body = true;
    }
    let parent = current_parent(p);
    let prev = p.d.nodes[parent].last;
    // Adjacent text (split by a comment, say) joins the node before it.
    if prev >= 0 && p.d.nodes[prev].kind == NODE_TEXT && p.d.nodes[prev].text + p.d.nodes[prev].text_len == start {
        p.d.nodes[prev].text_len += len as i32;
        return;
    }
    let t = append_node(p.d, NODE_TEXT, parent);
    p.d.nodes[t].text = start as i32;
    p.d.nodes[t].text_len = len as i32;
}

fn start_tag(p: Parser&) {
    let s = p.src;
    p.pos += 1;
    let name_start = p.d.bytes.len;
    while p.pos < s.len && !is_ws(s[p.pos]) && s[p.pos] != '>' && s[p.pos] != '/' {
        p.d.bytes.push(lower(s[p.pos]));
        p.pos += 1;
    }
    let name_len = p.d.bytes.len - name_start;
    let attr_start = p.d.attrs.len;
    read_attributes(p);
    let name = p.d.bytes[name_start..name_start + name_len];

    if name == "html" || name == "body" {
        let target = if name == "html" { p.d.nodes[p.head].parent } else { p.body };
        if p.d.nodes[target].attr_count == 0 {
            p.d.nodes[target].attr = attr_start as i32;
            p.d.nodes[target].attr_count = (p.d.attrs.len - attr_start) as i32;
        }
        if name == "body" { p.in_body = true; }
        return;
    }
    if name == "head" { return; }

    var parent = p.head;
    if p.in_body || !is_head_element(name) {
        p.in_body = true;
        close_implied(p, name);
        parent = current_parent(p);
    }
    let id = append_node(p.d, NODE_ELEMENT, parent);
    p.d.nodes[id].name = name_start as i32;
    p.d.nodes[id].name_len = name_len as i32;
    p.d.nodes[id].attr = attr_start as i32;
    p.d.nodes[id].attr_count = (p.d.attrs.len - attr_start) as i32;

    if is_raw_text(name) {
        read_raw_text(p, id, name_start, name_len);
    } else if !is_void(name) {
        if parent != p.head { p.open.push(id); }
    }
}

// Reads attributes up to and past the closing '>'. A '/' before it is ignored:
// HTML elements are void or not by name, whatever the tag says.
fn read_attributes(p: Parser&) {
    let s = p.src;
    loop {
        while p.pos < s.len && (is_ws(s[p.pos]) || s[p.pos] == '/') { p.pos += 1; }
        guard p.pos < s.len else { return; }
        if s[p.pos] == '>' { p.pos += 1; return; }
        let an = p.d.bytes.len;
        while p.pos < s.len && !is_ws(s[p.pos]) && s[p.pos] != '=' && s[p.pos] != '>' && s[p.pos] != '/' {
            p.d.bytes.push(lower(s[p.pos]));
            p.pos += 1;
        }
        let an_len = p.d.bytes.len - an;
        while p.pos < s.len && is_ws(s[p.pos]) { p.pos += 1; }
        var av = p.d.bytes.len;
        if p.pos < s.len && s[p.pos] == '=' {
            p.pos += 1;
            while p.pos < s.len && is_ws(s[p.pos]) { p.pos += 1; }
            av = p.d.bytes.len;
            if p.pos < s.len && (s[p.pos] == '"' || s[p.pos] == '\'') {
                let q = s[p.pos];
                var end = p.pos + 1;
                while end < s.len && s[end] != q { end += 1; }
                decode_into(s, p.pos + 1, end, p.d.bytes);
                p.pos = min(end + 1, s.len);
            } else {
                var end = p.pos;
                while end < s.len && !is_ws(s[end]) && s[end] != '>' { end += 1; }
                decode_into(s, p.pos, end, p.d.bytes);
                p.pos = end;
            }
        }
        if an_len > 0 {
            p.d.attrs.push(Attr { name: an as i32, name_len: an_len as i32, value: av as i32,
                                  value_len: (p.d.bytes.len - av) as i32 });
        }
    }
}

// <script>, <style>, <title> and their kind hold text, not markup, up to their
// own end tag. Style and title text is kept; script text is dropped.
fn read_raw_text(p: Parser&, id: i32, name_start: i64, name_len: i64) {
    let s = p.src;
    var name: u8[>..] = [];
    name.append(p.d.bytes[name_start..name_start + name_len]);
    var end = p.pos;
    while end < s.len {
        if s[end] == '<' && end + 1 < s.len && s[end + 1] == '/' && ends_tag(s, end + 2, name[..]) { break; }
        end += 1;
    }
    if name[..] == "style" || name[..] == "title" || name[..] == "textarea" {
        let t = append_node(p.d, NODE_TEXT, id);
        p.d.nodes[t].text = p.d.bytes.len as i32;
        if name[..] == "style" {
            p.d.bytes.append(s[p.pos..end]);
        } else {
            decode_into(s, p.pos, end, p.d.bytes);
        }
        p.d.nodes[t].text_len = p.d.bytes.len as i32 - p.d.nodes[t].text;
    }
    p.pos = end;
    if p.pos < s.len { skip_past(p, ">"); }
}

// Whether s[i..] starts with `name` (any case) followed by the end of a tag name.
fn ends_tag(s: const u8[:], i: i64, name: const u8[:]) -> bool {
    guard i + name.len <= s.len else { return false; }
    for k in name.len { if lower(s[i + k]) != name[k] { return false; } }
    let after = i + name.len;
    return after >= s.len || is_ws(s[after]) || s[after] == '>' || s[after] == '/';
}

fn end_tag(p: Parser&) {
    let s = p.src;
    p.pos += 2;
    var name: u8[>..] = [];
    while p.pos < s.len && !is_ws(s[p.pos]) && s[p.pos] != '>' { name.push(lower(s[p.pos])); p.pos += 1; }
    skip_past(p, ">");
    if name[..] == "html" || name[..] == "body" || name[..] == "head" { return; }
    if name[..] == "br" {                    // browsers read a stray </br> as <br>
        p.in_body = true;
        let br = make_element(p.d, "br", current_parent(p));
        return;
    }
    let k = if is_table_part(name[..]) { find_open_in_table(p, name[..]) } else { find_open(p, name[..], "") };
    if k >= 0 { pop_to(p, k); }
}

fn is_table_part(n: const u8[:]) -> bool {
    return n == "table" || n == "caption" || n == "tbody" || n == "thead" || n == "tfoot" || n == "tr" || n == "td" || n == "th";
}

// Like find_open for the end tags of a table's parts, which reach through the
// cells and rows still open (the table scope of the WHATWG algorithm): </table>
// closes them all, </tr> the cell open in its row.
fn find_open_in_table(p: Parser&, name: const u8[:]) -> i64 {
    var k = p.open.len - 1;
    while k >= 0 {
        let n = node_name(p.d, p.open[k]);
        if n == name { return k; }
        if n == "table" || n == "template" { return -1; }
        k -= 1;
    }
    return -1;
}

// The index in the open stack of the nearest element called `name`, searching
// down from the top but not past an element called `wall` or a table cell
// boundary, which close tags do not reach through. -1 if there is none.
fn find_open(p: Parser&, name: const u8[:], wall: const u8[:]) -> i64 {
    var k = p.open.len - 1;
    while k >= 0 {
        let n = node_name(p.d, p.open[k]);
        if n == name { return k; }
        if wall.len > 0 && n == wall { return -1; }
        if n == "table" || n == "td" || n == "th" || n == "caption" || n == "template" || n == "object" { return -1; }
        k -= 1;
    }
    return -1;
}

fn pop_to(p: Parser&, k: i64) {
    while p.open.len > k { p.open.pop(); }
}

// The implied end tags that a new start tag brings: a block closes an open
// <p>, a new <li> closes the open one, a new cell closes the open cell, and so on.
fn close_implied(p: Parser&, name: const u8[:]) {
    if closes_p(name) {
        let k = find_open(p, "p", "");
        if k >= 0 { pop_to(p, k); }
    }
    if name == "li" {
        let k = find_open(p, "li", "ul");
        if k >= 0 { pop_to(p, k); } else {
            let j = find_open(p, "li", "ol");
            if j >= 0 { pop_to(p, j); }
        }
    } else if name == "dd" || name == "dt" {
        var k = find_open(p, "dd", "dl");
        if k < 0 { k = find_open(p, "dt", "dl"); }
        if k >= 0 { pop_to(p, k); }
    } else if is_heading(name) {
        if p.open.len > 0 && is_heading(node_name(p.d, p.open[p.open.len - 1])) { p.open.pop(); }
    } else if name == "tr" {
        close_cells(p);
        let k = find_open_row(p);
        if k >= 0 { pop_to(p, k); }
    } else if name == "td" || name == "th" {
        close_cells(p);
    } else if name == "option" {
        if p.open.len > 0 && node_name(p.d, p.open[p.open.len - 1]) == "option" { p.open.pop(); }
    } else if name == "a" {
        let k = find_open(p, "a", "");
        if k >= 0 { pop_to(p, k); }
    }
}

fn close_cells(p: Parser&) {
    var k = p.open.len - 1;
    while k >= 0 {
        let n = node_name(p.d, p.open[k]);
        if n == "td" || n == "th" { pop_to(p, k); return; }
        if n == "tr" || n == "table" { return; }
        k -= 1;
    }
}

fn find_open_row(p: Parser&) -> i64 {
    var k = p.open.len - 1;
    while k >= 0 {
        let n = node_name(p.d, p.open[k]);
        if n == "tr" { return k; }
        if n == "table" || n == "tbody" || n == "thead" || n == "tfoot" { return -1; }
        k -= 1;
    }
    return -1;
}

// <!-- comments -->, <!DOCTYPE ...> and <![CDATA[ ... ]]> leave no node.
fn skip_declaration(p: Parser&) {
    let s = p.src;
    if p.pos + 3 < s.len && s[p.pos + 2] == '-' && s[p.pos + 3] == '-' {
        p.pos += 4;
        skip_past(p, "-->");
    } else if starts_with(s[p.pos..], "<![CDATA[") {
        skip_past(p, "]]>");
    } else {
        skip_past(p, ">");
    }
}

fn skip_past(p: Parser&, marker: const u8[:]) {
    let k = find(p.src[p.pos..], marker);
    p.pos = if k < 0 { p.src.len } else { p.pos + k + marker.len };
}

// Appends s[i..end] to `out` with character references decoded.
fn decode_into(s: const u8[:], i: i64, end: i64, out: u8[>..]&) {
    var j = i;
    while j < end {
        if s[j] == '&' { j = decode_ref(s, j, end, out); }
        else { out.push(s[j]); j += 1; }
    }
}

// Decodes the character reference at s[i] == '&' into `out` and returns the
// index after it. Not a reference: appends the '&' itself.
fn decode_ref(s: const u8[:], i: i64, end: i64, out: u8[>..]&) -> i64 {
    var j = i + 1;
    if j < end && s[j] == '#' {
        j += 1;
        let hex = j < end && (s[j] == 'x' || s[j] == 'X');
        if hex { j += 1; }
        let ds = j;
        while j < end && (if hex { is_hex(s[j]) } else { is_digit(s[j]) }) && j - ds < 8 { j += 1; }
        if j > ds {
            let code, ok = parse_int(s[ds..j], if hex { 16 } else { 10 });
            if j < end && s[j] == ';' { j += 1; }
            push_utf8(out, if ok && code > 0 && code <= 0x10FFFF { code } else { 0xFFFD });
            return j;
        }
    } else {
        let ns = j;
        while j < end && j - ns < 32 && (is_alpha(s[j]) || is_digit(s[j])) { j += 1; }
        if j < end && s[j] == ';' && j > ns {
            let cp = named_entity(s[ns..j]);
            if cp >= 0 { push_utf8(out, cp); return j + 1; }
        }
    }
    out.push('&');
    return i + 1;
}

// The named references documents actually use. The full table has over two
// thousand; anything not here stays as written.
fn named_entity(n: const u8[:]) -> i64 {
    if n == "amp" { return '&'; } if n == "lt" { return '<'; } if n == "gt" { return '>'; }
    if n == "quot" { return '"'; } if n == "apos" { return '\''; } if n == "nbsp" { return 0xA0; }
    if n == "ndash" { return 0x2013; } if n == "mdash" { return 0x2014; } if n == "hellip" { return 0x2026; }
    if n == "lsquo" { return 0x2018; } if n == "rsquo" { return 0x2019; } if n == "ldquo" { return 0x201C; }
    if n == "rdquo" { return 0x201D; } if n == "laquo" { return 0xAB; } if n == "raquo" { return 0xBB; }
    if n == "bull" { return 0x2022; } if n == "middot" { return 0xB7; } if n == "copy" { return 0xA9; }
    if n == "reg" { return 0xAE; } if n == "trade" { return 0x2122; } if n == "deg" { return 0xB0; }
    if n == "times" { return 0xD7; } if n == "divide" { return 0xF7; } if n == "minus" { return 0x2212; }
    if n == "plusmn" { return 0xB1; } if n == "frac12" { return 0xBD; } if n == "frac14" { return 0xBC; }
    if n == "frac34" { return 0xBE; } if n == "para" { return 0xB6; } if n == "sect" { return 0xA7; }
    if n == "euro" { return 0x20AC; } if n == "pound" { return 0xA3; } if n == "yen" { return 0xA5; }
    if n == "cent" { return 0xA2; } if n == "shy" { return 0xAD; } if n == "thinsp" { return 0x2009; }
    if n == "ensp" { return 0x2002; } if n == "emsp" { return 0x2003; } if n == "zwj" { return 0x200D; }
    if n == "zwnj" { return 0x200C; } if n == "larr" { return 0x2190; } if n == "rarr" { return 0x2192; }
    if n == "uarr" { return 0x2191; } if n == "darr" { return 0x2193; } if n == "harr" { return 0x2194; }
    if n == "prime" { return 0x2032; } if n == "Prime" { return 0x2033; } if n == "iexcl" { return 0xA1; }
    if n == "iquest" { return 0xBF; } if n == "szlig" { return 0xDF; } if n == "aelig" { return 0xE6; }
    if n == "oslash" { return 0xF8; } if n == "ccedil" { return 0xE7; } if n == "Ccedil" { return 0xC7; }
    if n == "ntilde" { return 0xF1; } if n == "Ntilde" { return 0xD1; }
    // Acute, grave, circumflex and diaeresis vowels, both cases.
    let vowels = "aeiouAEIOU";
    let acute: i64[10] = [0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xC1, 0xC9, 0xCD, 0xD3, 0xDA];
    let grave: i64[10] = [0xE0, 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9];
    let circ: i64[10] = [0xE2, 0xEA, 0xEE, 0xF4, 0xFB, 0xC2, 0xCA, 0xCE, 0xD4, 0xDB];
    let uml: i64[10] = [0xE4, 0xEB, 0xEF, 0xF6, 0xFC, 0xC4, 0xCB, 0xCF, 0xD6, 0xDC];
    if n.len > 1 {
        let v = position(vowels, n[0]);
        if v >= 0 {
            let rest = n[1..];
            if rest == "acute" { return acute[v]; }
            if rest == "grave" { return grave[v]; }
            if rest == "circ" { return circ[v]; }
            if rest == "uml" { return uml[v]; }
        }
    }
    return -1;
}

fn is_alpha(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
fn is_digit(c: u8) -> bool { return c >= '0' && c <= '9'; }
fn is_hex(c: u8) -> bool { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

fn is_void(n: const u8[:]) -> bool {
    return n == "br" || n == "img" || n == "hr" || n == "meta" || n == "link" || n == "input" || n == "wbr"
        || n == "area" || n == "base" || n == "col" || n == "embed" || n == "source" || n == "track" || n == "param";
}

fn is_raw_text(n: const u8[:]) -> bool {
    return n == "script" || n == "style" || n == "title" || n == "textarea" || n == "xmp" || n == "iframe"
        || n == "noembed" || n == "noframes" || n == "noscript";
}

fn is_head_element(n: const u8[:]) -> bool {
    return n == "title" || n == "style" || n == "meta" || n == "link" || n == "base" || n == "script" || n == "noscript";
}

fn is_heading(n: const u8[:]) -> bool {
    return n.len == 2 && n[0] == 'h' && n[1] >= '1' && n[1] <= '6';
}

// Start tags that close an open <p> first.
fn closes_p(n: const u8[:]) -> bool {
    return n == "p" || n == "div" || n == "ul" || n == "ol" || n == "dl" || n == "li" || n == "dd" || n == "dt"
        || n == "blockquote" || n == "pre" || n == "table" || n == "section" || n == "article" || n == "aside"
        || n == "header" || n == "footer" || n == "nav" || n == "main" || n == "figure" || n == "figcaption"
        || n == "form" || n == "fieldset" || n == "address" || n == "details" || n == "summary" || n == "hr"
        || n == "menu" || n == "center" || n == "hgroup" || n == "dialog" || is_heading(n);
}
