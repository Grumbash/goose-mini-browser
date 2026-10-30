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

- `window.html`: the interface's design, its default window (the top bar, a
  page's header, the page, the dev panel, the hand and the rest bay, 1200 ×
  760 points), ported from the design's HTML so that Tusk draws it: lengths in
  points, grid as flex, the oil's sheen one flat colour, the bay's corners as
  borders, and the console's floated sources as flex items. The cards' art
  waits for images. The interface is drawn by Tusk's own engine
  (docs/adr/0010), and this page shows it can: Tusk draws it as WebKit does,
  but for the edges of text.

  ```bash
  ./app/tusk --screenshot window.png --size 1200x760 tests/pages/window.html
  ```

- `linked/`: a page styled by linked sheets. `page.css` imports `base.css`,
  which imports `page.css` back (a cycle, cut); its own `<style>` and
  `later.css` come after; a print sheet, an alternate sheet and a missing
  sheet are left out, the last with an error in the Console. Blue on yellow,
  green, then red, when the cascade's order is right.

  ```bash
  ./app/tusk --screenshot linked.png --dev-tab console tests/pages/linked/index.html
  ```
