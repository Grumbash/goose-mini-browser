// Checks for the engine: run with `goose tests/engine_test.goose`. Prints each
// failure and exits non-zero if any check failed.

import std;
import os;
import engine from "../engine";
import engine.dom;
import engine.html;

var failures = 0;

fn check(what: const u8[:], got: const u8[:], want: const u8[:]) {
    if got == want { return; }
    failures += 1;
    print("FAIL ", what, "\n--- want\n", want, "--- got\n", got);
}

fn tree_of(src: const u8[:]) -> u8[>..] {
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    let doc = parse_html(src, d);
    var out: u8[>..] = [];
    dump_tree(d, doc, 0, out);
    return out;
}

fn test_html() {
    check("implied structure and an unclosed p",
          tree_of("<title>T</title><p>One<p>Two &amp; <b>three</b>"),
          "#document\n  html\n    head\n      title\n        \"T\"\n    body\n      p\n        \"One\"\n      p\n        \"Two & \"\n        b\n          \"three\"\n");
    check("list items close each other; void elements don't nest",
          tree_of("<ul><li>a<li>b<br>c</ul>"),
          "#document\n  html\n    head\n    body\n      ul\n        li\n          \"a\"\n        li\n          \"b\"\n          br\n          \"c\"\n");
    check("attributes, entities and a comment",
          tree_of("<div id=x class='a b' data-n=1>caf&eacute; <!-- no --> &#x263A;&#9731;</div>"),
          "#document\n  html\n    head\n    body\n      div id=\"x\" class=\"a b\" data-n=\"1\"\n        \"café  ☺☃\"\n");
    check("scripts are skipped, styles kept, stray end tags ignored",
          tree_of("<p>x</span><script>if (a < b) { x() }</script><style>p { color: red }</style></p>"),
          "#document\n  html\n    head\n    body\n      p\n        \"x\"\n        script\n        style\n          \"p { color: red }\"\n");
    check("a heading closes the paragraph before it",
          tree_of("<P>Intro<H2 class=c>Heading</H2>after"),
          "#document\n  html\n    head\n    body\n      p\n        \"Intro\"\n      h2 class=\"c\"\n        \"Heading\"\n      \"after\"\n");
}

// The M1 page parses into the tree a browser would build: its title, and
// thousands of nodes from Wikipedia's real markup.
fn test_page() {
    var src: u8[>..] = [];
    guard read_file("tests/pages/focaccia.html", src) else { check("read tests/pages/focaccia.html", "missing", "present"); return; }
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(src[..], d);
    var title: u8[>..] = [];
    var headings = 0;
    for n, i in nodes {
        if n.kind != NODE_ELEMENT { continue; }
        let name = node_name(d, i as i32);
        if name == "title" && n.first >= 0 { title.append(node_text(d, n.first)); }
        if name == "h2" { headings += 1; }
    }
    check("the page's title", title[..], "Focaccia – Wikipedia");
    check("the page has its sections", if headings >= 5 { "yes" } else { "no" }, "yes");
    let size: u8[>..] = if nodes.len > 4000 { "over 4000" } else { str(nodes.len) };
    check("the page's size in nodes", size[..], "over 4000");
}

fn main() {
    test_html();
    test_page();
    if failures > 0 {
        print(failures, " check(s) failed");
        exit(1);
    }
    print("engine: all checks passed");
}
