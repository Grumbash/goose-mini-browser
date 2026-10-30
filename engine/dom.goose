// The document (docs/adr/0001): every node in one grow-only array, linked by
// index, and every byte of text, tag name and attribute in one shared buffer,
// addressed by spans. Nothing is allocated per node, and the whole document is
// freed at once when the scope that owns the arrays ends.

import std;

let NODE_DOCUMENT: i32 = 0;
let NODE_ELEMENT: i32 = 1;
let NODE_TEXT: i32 = 2;

struct Node {
    kind: i32,
    parent: i32,         // -1 for the document
    first: i32,          // first child, -1 if none
    last: i32,           // last child, -1 if none
    next: i32,           // next sibling, -1 if none
    name: i32,           // elements: the lowercase tag name, as a span into Doc.bytes
    name_len: i32,
    text: i32,           // text nodes: their text, as a span into Doc.bytes
    text_len: i32,
    attr: i32,           // elements: the first attribute in Doc.attrs
    attr_count: i32,
}

// An attribute's lowercase name and its decoded value, as spans into Doc.bytes.
struct Attr { name: i32, name_len: i32, value: i32, value_len: i32 }

// The three arrays a document lives in, owned by the caller and passed around
// by reference (the context pattern: a struct may hold one growable array at
// most, so it holds references to three instead).
struct Doc {
    nodes: Node[>..]&,
    attrs: Attr[>..]&,
    bytes: u8[>..]&,
}

fn new_node(kind: i32) -> Node {
    return Node { kind: kind, parent: -1, first: -1, last: -1, next: -1, name: 0, name_len: 0,
                  text: 0, text_len: 0, attr: 0, attr_count: 0 };
}

// Appends a node as the last child of `parent` (or as a root when -1) and
// returns its index.
fn append_node(d: Doc, kind: i32, parent: i32) -> i32 {
    let id = d.nodes.len as i32;
    var n = new_node(kind);
    n.parent = parent;
    d.nodes.push(n);
    if parent >= 0 {
        let p .= d.nodes[parent];
        if p.last >= 0 { d.nodes[p.last].next = id; } else { p.first = id; }
        p.last = id;
    }
    return id;
}

// Inserts a node as the first child of `parent` and returns its index. The
// node goes at the end of the array like any other; only the links put it
// first.
fn prepend_node(d: Doc, kind: i32, parent: i32) -> i32 {
    let id = d.nodes.len as i32;
    var n = new_node(kind);
    n.parent = parent;
    n.next = d.nodes[parent].first;
    d.nodes.push(n);
    let p .= d.nodes[parent];
    p.first = id;
    if p.last < 0 { p.last = id; }
    return id;
}

// An element named `name` (lowercase already) as the last child of `parent`,
// or the first when `first`; returns its index.
fn add_element(d: Doc, name: const u8[:], parent: i32, first: bool) -> i32 {
    let id = if first { prepend_node(d, NODE_ELEMENT, parent) } else { append_node(d, NODE_ELEMENT, parent) };
    d.nodes[id].name = d.bytes.len as i32;
    d.nodes[id].name_len = name.len as i32;
    d.bytes.append(name);
    return id;
}

// A text node holding `text`, as the last child of `parent`; returns its index.
fn add_text(d: Doc, text: const u8[:], parent: i32) -> i32 {
    let id = append_node(d, NODE_TEXT, parent);
    d.nodes[id].text = d.bytes.len as i32;
    d.nodes[id].text_len = text.len as i32;
    d.bytes.append(text);
    return id;
}

// Whether element n is a ::before or ::after that the cascade made
// (css.goose). No element the parser makes has a name starting with ':'.
fn is_generated(d: Doc, n: i32) -> bool {
    let node = d.nodes[n];
    return node.kind == NODE_ELEMENT && node.name_len > 2 && d.bytes[node.name as i64] == ':';
}

fn span(d: Doc, start: i32, len: i32) -> const u8[:] {
    let a: i64 = start;
    let b: i64 = start + len;
    return d.bytes[a..b];
}

fn node_name(d: Doc, n: i32) -> const u8[:] {
    let node = d.nodes[n];
    return span(d, node.name, node.name_len);
}

fn node_text(d: Doc, n: i32) -> const u8[:] {
    let node = d.nodes[n];
    return span(d, node.text, node.text_len);
}

fn is_element(d: Doc, n: i32, name: const u8[:]) -> bool {
    return d.nodes[n].kind == NODE_ELEMENT && node_name(d, n) == name;
}

// The value of attribute `name` on element `n`, and whether it is there.
fn attr_value(d: Doc, n: i32, name: const u8[:]) -> const u8[:], bool {
    let node = d.nodes[n];
    for i in node.attr..node.attr + node.attr_count {
        let a = d.attrs[i];
        if span(d, a.name, a.name_len) == name { return span(d, a.value, a.value_len), true; }
    }
    return d.bytes[0..0], false;
}

// Whether `cls` is one of the space-separated words of the element's class.
fn has_class(d: Doc, n: i32, cls: const u8[:]) -> bool {
    let v, ok = attr_value(d, n, "class");
    return ok && has_word(v, cls);
}

// Whether `w` is one of the words of `v`, split on HTML whitespace.
fn has_word(v: const u8[:], w: const u8[:]) -> bool {
    var i = 0;
    while i < v.len {
        while i < v.len && is_ws(v[i]) { i += 1; }
        let start = i;
        while i < v.len && !is_ws(v[i]) { i += 1; }
        if i > start && v[start..i] == w { return true; }
    }
    return false;
}

// HTML whitespace: std is_space plus the form feed.
fn is_ws(c: u8) -> bool { return c == 32 || c == 10 || c == 9 || c == 13 || c == 12; }

fn lower(c: u8) -> u8 { return if c >= 'A' && c <= 'Z' { c + 32 } else { c }; }

// Writes the tree under `n` as indented lines: elements by name, text quoted.
// For tests and debugging.
recursive fn dump_tree(d: Doc, n: i32, depth: i64, out: u8[>..]&) {
    let node = d.nodes[n];
    for i in depth { out.append("  "); }
    if node.kind == NODE_ELEMENT {
        out.append(node_name(d, n));
        for i in node.attr..node.attr + node.attr_count {
            let a = d.attrs[i];
            format(out, " ", span(d, a.name, a.name_len), "=\"", span(d, a.value, a.value_len), "\"");
        }
    } else if node.kind == NODE_TEXT {
        format(out, "\"", node_text(d, n), "\"");
    } else {
        out.append("#document");
    }
    out.push('\n');
    var c = node.first;
    while c >= 0 {
        dump_tree(d, c, depth + 1, out);
        c = d.nodes[c].next;
    }
}
