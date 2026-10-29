# Line-for-line port of resolve() in browser/mini_browser.goose (lines 229-237)
def resolve(base, href):
    if href.startswith("http://") or href.startswith("https://"):
        return href
    slash = -1
    for i, ch in enumerate(base):
        if ch == "/":
            slash = i
    return (base[: slash + 1] if slash >= 0 else "") + href

cases = [
    ("https://developer.mozilla.org/en-US/docs/Web", "/en-US/docs/Web/CSS"),   # root-relative
    ("https://example.com", "about.html"),                                      # base with no path
    ("https://news.ycombinator.com/news", "item?id=1"),                         # query-only relative
    ("https://a.example/docs/guide/", "../api/"),                               # parent dir
    ("https://a.example/page", "#section"),                                     # fragment
    ("https://a.example/page", "//cdn.example/x.html"),                         # protocol-relative
    ("https://a.example/page", "mailto:hi@a.example"),                          # other scheme
]
for base, href in cases:
    print(f"{href:24} on {base:48} -> {resolve(base, href)}")
