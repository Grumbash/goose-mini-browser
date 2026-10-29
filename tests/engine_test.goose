// Checks for the engine: run with `goose tests/engine_test.goose`. Prints each
// failure and exits non-zero if any check failed.

import std;
import os;
import engine from "../engine";
import engine.dom;
import engine.html;
import engine.css;
import engine.layout;

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
    check("a nested list stays nested",
          tree_of("<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>"),
          "#document\n  html\n    head\n    body\n      ul\n        li\n          \"a\"\n          ul\n            li\n              \"b\"\n        li\n          \"c\"\n");
    check("a newline right after <pre> isn't content; </template> closes its open cells",
          tree_of("<pre>\nx</pre><template><table><tr><td>row</template><p>after"),
          "#document\n  html\n    head\n    body\n      pre\n        \"x\"\n      template\n        table\n          tr\n            td\n              \"row\"\n      p\n        \"after\"\n");
    var deep: u8[>..] = [];
    for k in 600 { deep.append("<div>"); }
    deep.append("x");
    var dn: Node[>..] = [];
    var da: Attr[>..] = [];
    var db: u8[>..] = [];
    let dd = Doc { nodes: dn, attrs: da, bytes: db };
    parse_html(deep[..], dd);
    var depth = 0;
    var at: i32 = (dn.len - 1) as i32;       // the text, made last
    while at >= 0 { depth += 1; at = dn[at].parent; }
    check("nesting stops at 512 open elements", if depth == 516 { "512 deep" } else { "not capped" }, "512 deep");
    check("list items close each other; void elements don't nest",
          tree_of("<ul><li>a<li>b<br>c</ul>"),
          "#document\n  html\n    head\n    body\n      ul\n        li\n          \"a\"\n        li\n          \"b\"\n          br\n          \"c\"\n");
    check("attributes, entities and a comment",
          tree_of("<div id=x class='a b' data-n=1>caf&eacute; <!-- no --> &#x263A;&#9731;</div>"),
          "#document\n  html\n    head\n    body\n      div id=\"x\" class=\"a b\" data-n=\"1\"\n        \"café  ☺☃\"\n");
    check("scripts are skipped, styles kept, stray end tags ignored",
          tree_of("<p>x</span><script>if (a < b) { x() }</script><style>p { color: red }</style></p>"),
          "#document\n  html\n    head\n    body\n      p\n        \"x\"\n        script\n        style\n          \"p { color: red }\"\n");
    check("</table> closes the cells and rows still open",
          tree_of("<table><tr><td>a<td>b</table><p>after"),
          "#document\n  html\n    head\n    body\n      table\n        tr\n          td\n            \"a\"\n          td\n            \"b\"\n      p\n        \"after\"\n");
    check("a heading closes the paragraph before it",
          tree_of("<P>Intro<H2 class=c>Heading</H2>after"),
          "#document\n  html\n    head\n    body\n      p\n        \"Intro\"\n      h2 class=\"c\"\n        \"Heading\"\n      \"after\"\n");
}

// The computed style of the first element called `name`, as text.
fn style_of(src: const u8[:], name: const u8[:]) -> u8[>..] {
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(src, d);
    var rules: Rule[>..] = [];
    var comps: Compound[>..] = [];
    var classes: Span[>..] = [];
    var decls: Decl[>..] = [];
    var sbytes: u8[>..] = [];
    let sh = Sheet { rules: rules, comps: comps, classes: classes, decls: decls, bytes: sbytes };
    load_sheets(d, sh);
    var styles: Style[>..] = [];
    compute_styles(d, sh, styles);
    var out: u8[>..] = [];
    for n, i in nodes {
        if n.kind == NODE_ELEMENT && node_name(d, i as i32) == name {
            let st = styles[i];
            format(out, "display=", st.display, " size=");
            format_flt(out, st.font_size, 1);
            format(out, " bold=", st.bold, " italic=", st.italic, " color=");
            format_uint(out, st.color, 16, 8, '0');
            out.append(" mt=");
            format_flt(out, st.mt, 1);
            out.append(" ml=");
            format_flt(out, st.ml, 1);
            format(out, " auto_ml=", st.auto_ml);
            return out;
        }
    }
    return out;
}

fn test_css() {
    let page = """
        <style>p.note { color: #c00; font-size: 2em } #x > em { font-weight: 700 } .a .b { margin: 4px 8px }
        div:first-child { font-style: italic } p { color: blue !important }</style>
        <div><p class=note>n <i>e</i></p></div><p id=x><em>direct</em></p><div class=a><span class=b>s</span></div>
        <script>x</script><section style='color: red; margin-left: auto'>inline</section>
        """;
    check("a class rule and its em size; !important beats specificity",
          style_of(page, "p"), "display=1 size=34.0 bold=0 italic=1 color=ff0000ff mt=0.0 ml=0.0 auto_ml=0");
    check("a child selector", style_of(page, "em"), "display=2 size=17.0 bold=1 italic=1 color=ff0000ff mt=0.0 ml=0.0 auto_ml=0");
    check("a descendant selector and the margin shorthand",
          style_of(page, "span"), "display=2 size=17.0 bold=0 italic=0 color=ff1c1c1c mt=4.0 ml=8.0 auto_ml=0");
    check("Tusk's sheet hides scripts", style_of(page, "script"), "display=0 size=17.0 bold=0 italic=0 color=ff1c1c1c mt=0.0 ml=0.0 auto_ml=0");
    check("a style attribute, with an auto margin",
          style_of(page, "section"), "display=1 size=17.0 bold=0 italic=0 color=ffff0000 mt=0.0 ml=0.0 auto_ml=1");
    // Comments anywhere, <!-- -->, rem, :link and :visited, a selector that
    // needs its descendant step to try a further ancestor, and a print sheet.
    let more = """
        <style><!-- p { /* a comment; with: a colon */ color: red; /* don't */ margin-left: 5px }
        h1 { color: green } -->
        html { font-size: 20px } h1 { font-size: 2rem }
        a:link { color: #00f } a:visited { color: #0f0 } div > section em { font-weight: bold }</style>
        <style media=print>p { color: #ccc }</style>
        <h1>t</h1><p>p</p><a href=x>link</a><div><section><section><em>deep</em></section></section></div>
        """;
    check("comments inside rules, and a print sheet left out",
          style_of(more, "p"), "display=1 size=20.0 bold=0 italic=0 color=ffff0000 mt=0.0 ml=5.0 auto_ml=0");
    check("rem counts in the root's font size; an apostrophe in a comment",
          style_of(more, "h1"), "display=1 size=40.0 bold=1 italic=0 color=ff008000 mt=16.0 ml=0.0 auto_ml=0");
    check(":link matches a link with an href; :visited matches nothing",
          style_of(more, "a"), "display=2 size=20.0 bold=0 italic=0 color=ff0000ff mt=0.0 ml=0.0 auto_ml=0");
    check("a descendant step tries every ancestor",
          style_of(more, "em"), "display=2 size=20.0 bold=1 italic=1 color=ff1c1c1c mt=0.0 ml=0.0 auto_ml=0");
    check("headings", style_of("<h2>T</h2>", "h2"), "display=1 size=24.7 bold=1 italic=0 color=ff1c1c1c mt=32.0 ml=0.0 auto_ml=0");
}

// ------------------------------------------------------------------ layout

let PROBE_TEXT: i32 = 1;    // each text item: its text, its line, and where it starts: the
                            // x of a line's first item, then left or right of that
let PROBE_BOXES: i32 = 2;   // each element's box, top and height
let PROBE_FIT: i32 = 3;     // whether every text item's ink stays in the column

// Lays `src` out `width` points wide and describes the result as `probe` asks.
fn layout_probe(src: const u8[:], width: f32, probe: i32) -> u8[>..] {
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(src, d);
    var rules: Rule[>..] = [];
    var comps: Compound[>..] = [];
    var classes: Span[>..] = [];
    var decls: Decl[>..] = [];
    var sbytes: u8[>..] = [];
    let sh = Sheet { rules: rules, comps: comps, classes: classes, decls: decls, bytes: sbytes };
    load_sheets(d, sh);
    var styles: Style[>..] = [];
    compute_styles(d, sh, styles);
    var text: u8[>..] = [];
    var carets: f32[>..] = [];
    var runs: Run[>..] = [];
    var run_of: i32[>..] = [];
    var fonts: FontInfo[>..] = [];
    var boxes: Rect[>..] = [];
    var items: DItem[>..] = [];
    let L = Layout { d: d, styles: styles, text: text, carets: carets, runs: runs, run_of: run_of,
                     fonts: fonts, boxes: boxes, items: items };
    measure(L);
    layout_page(L, width);

    var out: u8[>..] = [];
    if probe == PROBE_TEXT {
        // Widths depend on the system's fonts; where lines start doesn't.
        var line = 0;
        var last_y: f32 = -1.0;
        var start: f32 = 0.0;
        for it in items {
            guard it.kind == ITEM_TEXT else { continue; }
            format(out, "\"", text[it.text..it.text + it.text_len], "\" line ");
            if it.y != last_y {
                line += 1;
                last_y = it.y;
                start = it.x;
                format(out, line, " x ");
                format_flt(out, it.x, 0);
            } else {
                format(out, line, if it.x > start { " right" } else { " left" });
            }
            out.push('\n');
        }
    } else if probe == PROBE_BOXES {
        for n, i in nodes {
            guard n.kind == NODE_ELEMENT && boxes[i].h > 0.0 else { continue; }
            format(out, node_name(d, i as i32), " y ");
            format_flt(out, boxes[i].y, 1);
            out.append(" h ");
            format_flt(out, boxes[i].h, 1);
            out.push('\n');
        }
    } else if probe == PROBE_FIT {
        // The body's column: from its padding to the right edge of its content.
        let right = width - 32.0;
        for it in items {
            guard it.kind == ITEM_TEXT else { continue; }
            var ink = it.text + it.text_len;
            while ink > it.text && text[ink - 1] == ' ' { ink -= 1; }
            let r = runs[run_of[it.node]];
            let w = carets[r.caret + ink - r.start] - carets[r.caret + it.text - r.start];
            if it.x < 31.99 || it.x + w > right + 0.01 { format(out, "outside: \"", text[it.text..it.text + it.text_len], "\"\n"); }
        }
        if out.len == 0 { out.append("fits"); }
    }
    return out;
}

fn test_layout() {
    check("a paragraph sits on the body's padding",
          layout_probe("<p>Hello world</p>", 400.0, PROBE_TEXT), "\"Hello world\" line 1 x 32\n");
    check("a hidden paragraph paints nothing; inline elements share a line",
          layout_probe("<p hidden>gone</p><p>kept <b>bold</b> and <i>it</i></p>", 400.0, PROBE_TEXT),
          "\"kept \" line 1 x 32\n\"bold\" line 1 right\n\" and \" line 1 right\n\"it\" line 1 right\n");
    let words = "<p>Focaccia is a flat leavened oven-baked Italian bread, similar in style, texture and height to pizza dough. It may be topped with herbs or other ingredients.</p>";
    check("lines break at spaces and stay in the column", layout_probe(words, 300.0, PROBE_FIT), "fits");
    check("a word longer than the line breaks between characters",
          layout_probe("<p>Pneumonoultramicroscopicsilicovolcanoconiosis</p>", 140.0, PROBE_FIT), "fits");
    check("pre keeps spaces and line breaks",
          layout_probe("<pre>a  b\nc</pre>", 400.0, PROBE_TEXT), "\"a  b\" line 1 x 46\n\"c\" line 2 x 46\n");
    // The heading's top margin (1.3em of 24.65px) collapses through the div
    // with the paragraph's 1em rather than adding to it: 67.2 + 32.0 = 99.2.
    // Line heights come from CSS, so these numbers don't depend on fonts.
    check("margins collapse between siblings and through a parent",
          layout_probe("<p>a</p><div><h2>b</h2></div>", 400.0, PROBE_BOXES),
          "html y 0.0 h 267.1\nbody y 0.0 h 267.1\np y 40.0 h 27.2\ndiv y 99.2 h 35.5\nh2 y 99.2 h 35.5\n");
    check("list items get markers left of their content",
          layout_probe("<ul><li>one<li>two</ul><ol start=3><li>three</ol>", 400.0, PROBE_TEXT),
          "\"one\" line 1 x 59\n\"•\" line 1 left\n\"two\" line 2 x 59\n\"•\" line 2 left\n\"three\" line 3 x 59\n\"3.\" line 3 left\n");
}

// The M1 page parses into the tree a browser would build: its title, and
// thousands of nodes from Wikipedia's real markup.
fn test_page() {
    var src: u8[>..] = [];
    let path = str(resource_dir(), "pages/focaccia.html");
    guard read_file(path[..], src) else { check("read tests/pages/focaccia.html", "missing", "present"); return; }
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
    test_css();
    test_layout();
    test_page();
    if failures > 0 {
        print(failures, " check(s) failed");
        exit(1);
    }
    print("engine: all checks passed");
}
