// A tab's history: tusk.goose keeps one list of places for every tab. Going
// to another page adds a place after where the tab is, and drops those that
// came after it.

import std;
import .tab;
import .sheets;

// A place in a tab's history: the tab, the places before and after it (-1:
// none), where it is (a span of the notes) and how far it was scrolled when
// left.
struct Entry { tab: i64, prev: i64, next: i64, loc_at: i64, loc_len: i64, scroll: f32 }

// Where a link leads, as a tab is: a file URL as its path, or the URL.
fn as_loc(url: const u8[:], out: u8[>..]&) {
    if starts_with(url, "file://") && percent_decoded(url[7..], out) { return; }
    out.append(url);
}

// `loc` up to its fragment: the document it names.
fn doc_part(loc: const u8[:]) -> const u8[:] {
    let hash = find(loc, "#");
    return if hash >= 0 { loc[..hash] } else { loc };
}

// Tab k goes to where the span `at`, `len` of the notes says, after the
// place it is in its history, which keeps how far it was scrolled; the
// places after it are dropped. Returns the new place.
fn push_entry(tabs: Tab[>..]&, k: i64, entries: Entry[>..]&, at: i64, len: i64) -> i64 {
    let cur = tabs[k].entry;
    if cur >= 0 { entries[cur].scroll = tabs[k].scroll; }
    entries.push(Entry { tab: k, prev: cur, next: -1, loc_at: at, loc_len: len, scroll: 0.0 });
    let j = entries.len - 1;
    if cur >= 0 { entries[cur].next = j; }
    tabs[k].entry = j;
    return j;
}
