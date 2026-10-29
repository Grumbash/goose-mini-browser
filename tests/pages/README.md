# Test pages

- `focaccia.html`: the English Wikipedia article
  [Focaccia](https://en.wikipedia.org/wiki/Focaccia), revision 1375681898
  (19 September 2026), as returned by `action=render`, inside a minimal document
  with its title. The text is by Wikipedia's contributors under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). It is the M1
  page (docs/adr/0004): the article Tusk must scroll without a dropped frame.

  ```bash
  curl -A "TuskBrowserTest/0.1" "https://en.wikipedia.org/w/index.php?title=Focaccia&action=render"
  ```
