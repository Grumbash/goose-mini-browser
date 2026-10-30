// The address bar as it is typed in (tusk.goose keeps its text, caret and
// whether all of it is selected): where the caret moves and what editing
// makes of the text, and where typed text leads.

import std;
import os;
import .net;
import .history;

// Where the character before byte i of UTF-8 text `s` starts.
fn char_before(s: const u8[:], i: i64) -> i64 {
    var j = min(i, s.len) - 1;
    while j > 0 && (s[j] & 0xC0) == 0x80 { j -= 1; }
    return max(j, 0);
}

// Where the character after the one at byte i of UTF-8 text `s` starts.
fn char_after(s: const u8[:], i: i64) -> i64 {
    var j = i + 1;
    while j < s.len && (s[j] & 0xC0) == 0x80 { j += 1; }
    return min(j, s.len);
}

// `s` with its bytes from..to replaced by `with`.
fn spliced(s: const u8[:], from: i64, to: i64, with: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(s[..from]);
    out.append(with);
    out.append(s[to..]);
    return out;
}

// Pasted text as one line: its line breaks and tabs as spaces.
fn one_line_of(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in s { out.push(if c == '\n' || c == '\r' || c == '\t' { ' ' } else { c }); }
    return out;
}

// Where text typed in the address bar leads, onto `out`; false for nothing.
// An http or https URL is itself; a file URL, a path from / or from ~ is a
// file; something with no spaces and a dot, or localhost, is a host (http
// for this Mac, https for the rest); anything else is a search, on
// DuckDuckGo's page that needs no JavaScript.
fn typed_loc(input: const u8[:], out: u8[>..]&) -> bool {
    let t = trim(input);
    guard t.len > 0 else { return false; }
    if is_web(t) { return resolve_url(t, t, out); }
    if starts_with(t, "file://") {
        as_loc(t, out);
        return true;
    }
    if t[0] == '/' {
        out.append(t);
        return true;
    }
    if t[0] == '~' && (t.len == 1 || t[1] == '/') {
        var home: u8[>..] = [];
        guard env("HOME", home) && home.len > 0 else { return false; }
        out.append(home);
        out.append(t[1..]);
        return true;
    }
    let spaced = find(t, " ") >= 0;
    let local = starts_with(t, "localhost") || starts_with(t, "127.0.0.1") || starts_with(t, "[::1]");
    if !spaced && (local || find(t, ".") > 0) {
        var url: u8[>..] = [];
        url.append(if local { "http://" } else { "https://" });
        url.append(t);
        if resolve_url(url[..], url[..], out) { return true; }
    }
    // A search: letters, digits and -._~ as they are, spaces as +, the rest
    // as %XX (application/x-www-form-urlencoded).
    let digits = "0123456789ABCDEF";
    out.append("https://html.duckduckgo.com/html/?q=");
    for c in t {
        let plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.'
                    || c == '_' || c == '~';
        if plain { out.push(c); }
        else if c == ' ' { out.push('+'); }
        else {
            out.push('%');
            out.push(digits[c >> 4]);
            out.push(digits[c & 15]);
        }
    }
    return true;
}
