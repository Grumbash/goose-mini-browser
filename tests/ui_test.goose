// Checks of Tusk's interface document (app/ui.goose) and of what a page's
// worker hands it (app/tab.goose), with no window: what a page puts in the
// interface is escaped and cut short, and the document marks where the page
// goes and where the window is dragged.
//
//   goose tests/ui_test.goose   (from the repository)

import std;
import os;
import engine from "../engine";
import engine.dom;
import engine.html;
import engine.layout;
import app from "../app";
import app.tab;
import app.ui;
import app.net;

var failures = 0;

fn check(what: const u8[:], got: const u8[:], want: const u8[:]) {
    if got == want { return; }
    failures += 1;
    print("FAIL ", what, "\n--- want\n", want, "--- got\n", got);
}

fn yes(what: const u8[:], ok: bool) { check(what, if ok { "yes" } else { "no" }, "yes"); }

fn test_one_line() {
    var out: u8[>..] = [];
    one_line(out, "  A   title\n\twith  breaks  ", 256);
    check("white space as one space, none at the ends", out[..], "A title with breaks");
    out.resize(0);
    one_line(out, "Focaccia – Wikipedia", 12);
    check("cut before a character that doesn't fit", out[..], "Focaccia –");
    out.resize(0);
    one_line(out, "Focaccia – Wikipedia", 11);
    check("a character is kept whole or not at all (– is 3 bytes)", out[..], "Focaccia");
    out.resize(0);
    one_line(out, "  \n ", 256);
    check("a title of white space is none", out[..], "");
    out.resize(0);
    var stray: u8[>..] = [];
    for k in 1000 { stray.push(0x80); }
    one_line(out, stray[..], 80);
    check("bytes that start no character are cut too", str(out.len), "80");
}

fn test_elements() {
    var big: u8[>..] = [];
    big.append("<body><div id=\"");
    for k in 500 { big.append("x"); }
    big.append("\" class=\"a\tb\"><p>t</p></div>");
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html(big[..], d);
    var out: u8[>..] = [];
    elements_of(d, out);
    var want: u8[>..] = [];
    want.append("0\tbody\t\t\n1\tdiv\t");
    for k in NAME_MAX { want.push('x'); }
    want.append("\ta b\n2\tp\t\t\n");
    check("elements: depth, name, id and class, each cut to a line", out[..], want[..]);
}

// The interface's document for one tab whose page's title is `title`, at `path`.
fn doc_for(title: const u8[:], path: const u8[:], w: f32, out: u8[>..]&) {
    var css: u8[>..] = [];
    var sprite: u8[>..] = [];
    var rest: u8[>..] = [];
    var run: u8[>..] = [];
    let F = UiFiles { css: css, sprite: sprite, rest: rest, run: run };
    var notes: u8[>..] = [];
    notes.append(path);
    notes.append(title);
    let T = UiText { notes: notes };
    let info = FrameInfo { height: 100.0, background: 0xFFFFFFFF, nodes: 10, bytes: 2000, parse: 1.0, style: 1.0,
                           measure: 1.0, layout: 1.0, scale: 2.0, read: 1.0 };
    var tabs: Tab[>..] = [];
    tabs.push(Tab { worker: 0, ready: true, failed: false, info: info, paint: 1.0, waiting: false, scroll: 0.0,
                    opened: 0, load_ms: 4.0, status: 0, loc_at: 0, loc_len: path.len, title_at: path.len,
                    title_len: title.len, why_at: 0, why_len: 0, log_at: 0, log_len: 0, elems_at: 0, elems_len: 0 });
    let U = Ui { w: w, h: 760.0, lights: 0.0, cur: 0, dev: true, dev_tab: DEV_CONSOLE, oil: 50.0, mac_used: 12288.0, mac_total: 24576.0, cpu: 1.0, mac_cpu: 12.0, fps: 0,
                 running: false };
    ui_html(F, U, tabs, T, [], 0, 1.0, out);
}

fn test_document() {
    var html: u8[>..] = [];
    doc_for("</b><script>x</script>\"&", "/pages/<i>a&b.html", 1200.0, html);
    yes("so is its file's name", find(html[..], "&lt;i&gt;a&amp;b.html") >= 0 && find(html[..], "<i>a&b") < 0);
    yes("a page's title is escaped", find(html[..], "&lt;/b&gt;&lt;script&gt;x&lt;/script&gt;&quot;&amp;") >= 0);
    yes("and nothing of it is markup", find(html[..], "<script>") < 0);
    yes("the page's slot is marked", find(html[..], "data-slot=\"0\"") >= 0);
    yes("the bar drags the window", find(html[..], "class=\"bar\" data-drag") >= 0);
    var holes = 0;
    var at: i64 = 0;
    loop {
        let k = find(html[at..], "data-nodrag");
        guard k >= 0 else { break; }
        holes += 1;
        at += k + 1;
    }
    check("and its four controls don't", str(holes), "4");
    // A long path loses its start, from a folder on; its file's name shows.
    var long: u8[>..] = [];
    for k in 30 { long.append("/folder"); }
    long.append("/page.html");
    var wide: u8[>..] = [];
    doc_for("", long[..], 1200.0, wide);
    yes("a long path is cut at its start, at a folder", find(wide[..], "…/folder/folder/") >= 0);
    yes("not at its end", find(wide[..], "/folder/<b>page.html</b>") >= 0);
    var narrow: u8[>..] = [];
    doc_for("", long[..], 700.0, narrow);
    yes("where only its file's name fits, that shows", find(narrow[..], "…/<b>page.html</b>") >= 0);
    yes("an empty title is the file's name", find(narrow[..], "<b>page.html</b><span class=\"host\">") >= 0);
    yes("the badge says FILE, and the scheme isn't said again", find(narrow[..], "FILE</span><span class=\"u\">…/") >= 0
        && find(narrow[..], "file://") < 0);
    var web: u8[>..] = [];
    doc_for("", "https://en.wikipedia.org/wiki/Focaccia", 1200.0, web);
    yes("a web page: its scheme in the badge, its host in bold, then its path",
        find(web[..], "<span class=\"env\">HTTPS</span><span class=\"u\"><b>en.wikipedia.org</b>/wiki/Focaccia</span>") >= 0);
    var local: u8[>..] = [];
    doc_for("", "http://localhost:5173/", 1200.0, local);
    yes("one on this Mac says LOCAL, then its scheme",
        find(local[..], "LOCAL</span><span class=\"u\"><i>http://</i><b>localhost</b><em>:5173</em>/</span>") >= 0);
}

fn test_urls() {
    var out: u8[>..] = [];
    yes("a relative href resolves against the page", resolve_url("https://a.org/b/c?q#f", "../d", out));
    check("to an absolute URL", out[..], "https://a.org/d");
    var none: u8[>..] = [];
    yes("one that can't be doesn't", !resolve_url("https://a.org/", "https://exa mple.com/", none));
    check("and adds nothing", str(none.len), "0");
    var nodes: Node[>..] = [];
    var attrs: Attr[>..] = [];
    var bytes: u8[>..] = [];
    let d = Doc { nodes: nodes, attrs: attrs, bytes: bytes };
    parse_html("<base href='/docs/'><a href=x>x</a>", d);
    var base: u8[>..] = [];
    doc_base(d, "https://a.org/one/page.html", base);
    check("<base href> moves where a page's URLs resolve", base[..], "https://a.org/docs/");
    var plain_nodes: Node[>..] = [];
    var plain_attrs: Attr[>..] = [];
    var plain_bytes: u8[>..] = [];
    let plain = Doc { nodes: plain_nodes, attrs: plain_attrs, bytes: plain_bytes };
    parse_html("<p>x", plain);
    var page: u8[>..] = [];
    doc_base(plain, "https://a.org/one/page.html", page);
    check("without one, they resolve against the page's URL", page[..], "https://a.org/one/page.html");
}

fn main() {
    test_urls();
    test_one_line();
    test_elements();
    test_document();
    if failures > 0 {
        print(failures, " check(s) failed");
        exit(1);
    }
    print("interface: all checks passed");
}
