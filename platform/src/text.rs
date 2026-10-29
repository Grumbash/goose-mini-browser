//! Text on Core Text (docs/adr/0001): fonts by family, weight, style and size;
//! shaping, with Core Text's fallback fonts for characters a font lacks; the pen
//! position before every byte, which Goose breaks lines with; and the glyph
//! atlas the compositor draws text from.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ptr::null;

use crate::cg::*;
use crate::{ERR_ARGUMENT, GSlice, guarded};

// Font ids, as Goose writes them: the family in the low bits, then the face.
pub const FAMILY_SANS: i32 = 0;
pub const FAMILY_SERIF: i32 = 1;
pub const FAMILY_MONO: i32 = 2;
pub const FONT_BOLD: i32 = 1 << 4;
pub const FONT_ITALIC: i32 = 1 << 5;

/// Horizontal subpixel positions a glyph is rasterized at, per device pixel.
pub const PHASES: u32 = 4;

/// The fonts in use: those Goose asks for by id and size, and the fallback
/// fonts Core Text picks for characters they lack. A glyph names its font by
/// its index here.
#[derive(Default)]
pub struct Fonts {
    fonts: Vec<Cf>,
    attributes: Vec<Cf>, // per font: { kCTFontAttributeName: font }, for shaping
    by_id: HashMap<(i32, u32), u32>,
}

impl Fonts {
    /// The index of font `id` at `size` points, created on first use.
    pub fn get(&mut self, id: i32, size: f32) -> Option<u32> {
        if let Some(&i) = self.by_id.get(&(id, size.to_bits())) {
            return Some(i);
        }
        let font = create_font(id, size as f64)?;
        let i = self.add(font)?;
        self.by_id.insert((id, size.to_bits()), i);
        Some(i)
    }

    /// The index of a font Core Text chose, such as a fallback for emoji.
    fn index_of(&mut self, font: CFTypeRef) -> Option<u32> {
        if let Some(i) = self
            .fonts
            .iter()
            .position(|f| unsafe { CFEqual(f.get(), font) } != 0)
        {
            return Some(i as u32);
        }
        self.add(Cf::retain(font)?)
    }

    fn add(&mut self, font: Cf) -> Option<u32> {
        let keys = [unsafe { kCTFontAttributeName }];
        let values = [font.get()];
        let attributes = Cf::take(unsafe {
            CFDictionaryCreate(
                null(),
                keys.as_ptr(),
                values.as_ptr(),
                1,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks,
            )
        })?;
        self.fonts.push(font);
        self.attributes.push(attributes);
        Some((self.fonts.len() - 1) as u32)
    }

    pub fn ct(&self, index: u32) -> CFTypeRef {
        self.fonts[index as usize].get()
    }
}

/// Generic families map to fonts every Mac has: the system font for sans-serif,
/// Georgia for serif, Menlo for monospace. A family without a bold or italic
/// face keeps its regular one.
fn create_font(id: i32, size: f64) -> Option<Cf> {
    if !(size > 0.0 && size < 10_000.0) {
        return None;
    }
    let base = match id & 0xF {
        FAMILY_SERIF => {
            Cf::take(unsafe { CTFontCreateWithName(cf_str("Georgia")?.get(), size, null()) })?
        }
        FAMILY_MONO => {
            Cf::take(unsafe { CTFontCreateWithName(cf_str("Menlo")?.get(), size, null()) })?
        }
        _ => Cf::take(unsafe { CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, null()) })?,
    };
    let mut traits = 0;
    if id & FONT_BOLD != 0 {
        traits |= kCTFontTraitBold;
    }
    if id & FONT_ITALIC != 0 {
        traits |= kCTFontTraitItalic;
    }
    if traits == 0 {
        return Some(base);
    }
    // A size of 0 keeps the base font's size.
    Cf::take(unsafe { CTFontCreateCopyWithSymbolicTraits(base.get(), 0.0, null(), traits, traits) })
        .or(Some(base))
}

/// One glyph of a shaped run.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Glyph {
    pub font: u32, // index into Fonts
    pub id: u16,
    pub x: f32, // pen position from the start of the run, in points
    pub y: f32,
    pub byte: u32, // the first byte of the character it came from
}

/// Shapes UTF-8 text with Core Text. Holds scratch space reused across calls.
#[derive(Default)]
pub struct Shaper {
    units: Vec<u16>,     // the text as UTF-16, which Core Text indexes by
    unit_byte: Vec<u32>, // for each unit, the first byte of its character
    glyph_buf: Vec<CGGlyph>,
    position_buf: Vec<CGPoint>,
    index_buf: Vec<CFIndex>,
    glyphs: Vec<Glyph>,
}

impl Shaper {
    /// Shapes `text` in font `font` and appends its glyphs to `out`, left to
    /// right. Returns the run's advance in points. Invalid UTF-8 shows as
    /// U+FFFD, one per bad byte; right-to-left scripts are not ordered yet.
    pub fn shape(
        &mut self,
        fonts: &mut Fonts,
        font: u32,
        text: &[u8],
        out: &mut Vec<Glyph>,
    ) -> Option<f32> {
        if text.is_empty() {
            return Some(0.0);
        }
        decode(text, &mut self.units, &mut self.unit_byte);
        let string = Cf::take(unsafe {
            CFStringCreateWithCharacters(null(), self.units.as_ptr(), self.units.len() as CFIndex)
        })?;
        let attributed = Cf::take(unsafe {
            CFAttributedStringCreate(null(), string.get(), fonts.attributes[font as usize].get())
        })?;
        let line = Cf::take(unsafe { CTLineCreateWithAttributedString(attributed.get()) })?;
        let width = unsafe {
            CTLineGetTypographicBounds(
                line.get(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };

        let runs = unsafe { CTLineGetGlyphRuns(line.get()) }; // owned by the line
        let all = CFRange {
            location: 0,
            length: 0,
        };
        for r in 0..unsafe { CFArrayGetCount(runs) } {
            let run = unsafe { CFArrayGetValueAtIndex(runs, r) };
            let n = unsafe { CTRunGetGlyphCount(run) };
            if n <= 0 {
                continue;
            }
            let run_font =
                unsafe { CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName) };
            let run_font = if run_font.is_null() {
                font
            } else {
                fonts.index_of(run_font).unwrap_or(font)
            };
            let n = n as usize;
            self.glyph_buf.resize(n, 0);
            self.position_buf.resize(n, CGPoint::default());
            self.index_buf.resize(n, 0);
            unsafe {
                CTRunGetGlyphs(run, all, self.glyph_buf.as_mut_ptr());
                CTRunGetPositions(run, all, self.position_buf.as_mut_ptr());
                CTRunGetStringIndices(run, all, self.index_buf.as_mut_ptr());
            }
            for k in 0..n {
                let unit = (self.index_buf[k].max(0) as usize).min(self.unit_byte.len() - 1);
                out.push(Glyph {
                    font: run_font,
                    id: self.glyph_buf[k],
                    x: self.position_buf[k].x as f32,
                    y: self.position_buf[k].y as f32,
                    byte: self.unit_byte[unit],
                });
            }
        }
        Some(width as f32)
    }

    /// Writes the pen position before each byte of `text` to `carets`, and the
    /// run's advance to `carets[text.len()]`. Bytes inside a character, a
    /// ligature or a cluster share the position of the byte before them, so the
    /// positions never decrease.
    pub fn carets(
        &mut self,
        fonts: &mut Fonts,
        font: u32,
        text: &[u8],
        carets: &mut [f32],
    ) -> Option<f32> {
        if carets.len() != text.len() + 1 {
            return None;
        }
        let mut glyphs = std::mem::take(&mut self.glyphs);
        glyphs.clear();
        let width = self.shape(fonts, font, text, &mut glyphs);
        carets.fill(f32::NAN);
        for g in &glyphs {
            let c = &mut carets[g.byte as usize];
            if c.is_nan() || g.x < *c {
                *c = g.x;
            }
        }
        self.glyphs = glyphs;
        let width = width?;
        let mut last = 0.0f32;
        for c in carets[..text.len()].iter_mut() {
            last = if c.is_nan() { last } else { c.max(last) };
            *c = last;
        }
        carets[text.len()] = width.max(last);
        Some(width)
    }
}

/// UTF-8 to UTF-16, remembering for each unit the first byte of its character.
fn decode(text: &[u8], units: &mut Vec<u16>, unit_byte: &mut Vec<u32>) {
    units.clear();
    unit_byte.clear();
    let mut i = 0;
    while i < text.len() {
        let (ch, n) = next_char(&text[i..]);
        let mut buf = [0u16; 2];
        for u in ch.encode_utf16(&mut buf) {
            units.push(*u);
            unit_byte.push(i as u32);
        }
        i += n;
    }
}

/// The character at the start of `s` and its length in bytes. A byte that
/// doesn't start a valid sequence is one U+FFFD.
fn next_char(s: &[u8]) -> (char, usize) {
    let b = s[0];
    let n = match b {
        0x00..=0x7F => return (b as char, 1),
        0xC2..=0xDF => 2,
        0xE0..=0xEF => 3,
        0xF0..=0xF4 => 4,
        _ => return ('\u{FFFD}', 1),
    };
    match s.get(..n).map(std::str::from_utf8) {
        Some(Ok(t)) => (t.chars().next().unwrap_or('\u{FFFD}'), n),
        _ => ('\u{FFFD}', 1),
    }
}

/// Where a glyph's bitmap is in the atlas, and where its top-left corner sits
/// from the glyph's pen position on the baseline, in device pixels with y down.
/// A glyph with nothing to draw, such as a space, has zero size.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AtlasEntry {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
    pub left: i16,
    pub top: i16,
}

struct Shelf {
    y: u32,
    h: u32,
    x: u32,
}

/// Coverage masks of every glyph drawn so far, one byte per device pixel, at
/// one backing scale. Glyphs are packed on shelves of similar height; the atlas
/// grows downwards when full, so rows already uploaded never move.
pub struct Atlas {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
    pub scale: f64,
    /// Rows written since the compositor last uploaded, as [first, end).
    pub dirty: Option<(u32, u32)>,
    entries: HashMap<(u32, u16, u8), AtlasEntry>,
    shelves: Vec<Shelf>,
    raster_fonts: HashMap<u32, Cf>, // font index -> that font at size × scale
}

const ATLAS_WIDTH: u32 = 1024;
const ATLAS_MAX_HEIGHT: u32 = 16384;

impl Atlas {
    pub fn new(scale: f64) -> Self {
        Atlas {
            width: ATLAS_WIDTH,
            height: 256,
            pixels: vec![0; (ATLAS_WIDTH * 256) as usize],
            scale,
            dirty: None,
            entries: HashMap::new(),
            shelves: Vec::new(),
            raster_fonts: HashMap::new(),
        }
    }

    /// The atlas entry for glyph `id` of font `font`, rasterized at subpixel
    /// phase `phase` (in 1/PHASES of a device pixel) on first use.
    pub fn glyph(&mut self, fonts: &Fonts, font: u32, id: u16, phase: u8) -> AtlasEntry {
        if let Some(e) = self.entries.get(&(font, id, phase)) {
            return *e;
        }
        let entry = self.rasterize(fonts, font, id, phase).unwrap_or_default();
        self.entries.insert((font, id, phase), entry);
        entry
    }

    fn rasterize(&mut self, fonts: &Fonts, font: u32, id: u16, phase: u8) -> Option<AtlasEntry> {
        let raster = match self.raster_fonts.get(&font) {
            Some(f) => f.get(),
            None => {
                let f = raster_font(fonts.ct(font), self.scale)?;
                let p = f.get();
                self.raster_fonts.insert(font, f);
                p
            }
        };
        let mut rect = CGRect::default();
        unsafe {
            CTFontGetBoundingRectsForGlyphs(raster, kCTFontOrientationDefault, &id, &mut rect, 1)
        };
        if !(rect.size.width > 0.0 && rect.size.height > 0.0) {
            return None;
        }
        // A pixel of margin all round keeps antialiased edges whole.
        let dx = phase as f64 / PHASES as f64;
        let x0 = (rect.origin.x + dx).floor() as i32 - 1;
        let x1 = (rect.origin.x + rect.size.width + dx).ceil() as i32 + 1;
        let y0 = rect.origin.y.floor() as i32 - 1;
        let y1 = (rect.origin.y + rect.size.height).ceil() as i32 + 1;
        let (w, h) = ((x1 - x0) as u32, (y1 - y0) as u32);
        if w > self.width || h > 2048 {
            return None;
        }
        let (ax, ay) = self.place(w, h)?;

        let mut mask = vec![0u8; (w * h) as usize];
        {
            let context = Cf::take(unsafe {
                CGBitmapContextCreate(
                    mask.as_mut_ptr().cast(),
                    w as usize,
                    h as usize,
                    8,
                    w as usize,
                    null(),
                    kCGImageAlphaOnly,
                )
            })?;
            let c = context.get();
            unsafe {
                CGContextSetAllowsAntialiasing(c, true);
                CGContextSetShouldAntialias(c, true);
                CGContextSetAllowsFontSmoothing(c, false);
                CGContextSetShouldSmoothFonts(c, false);
                CGContextSetAllowsFontSubpixelPositioning(c, true);
                CGContextSetShouldSubpixelPositionFonts(c, true);
                CGContextSetAllowsFontSubpixelQuantization(c, false);
                CGContextSetShouldSubpixelQuantizeFonts(c, false);
                CGContextSetGrayFillColor(c, 1.0, 1.0);
                let origin = CGPoint {
                    x: dx - x0 as f64,
                    y: -(y0 as f64),
                };
                CTFontDrawGlyphs(raster, &id, &origin, 1, c);
            }
        }
        // The bitmap's first row is its top.
        for row in 0..h {
            let from = (row * w) as usize;
            let to = ((ay + row) * self.width + ax) as usize;
            self.pixels[to..to + w as usize].copy_from_slice(&mask[from..from + w as usize]);
        }
        self.dirty = Some(match self.dirty {
            Some((a, b)) => (a.min(ay), b.max(ay + h)),
            None => (ay, ay + h),
        });
        Some(AtlasEntry {
            x: ax as u16,
            y: ay as u16,
            w: w as u16,
            h: h as u16,
            left: x0 as i16,
            top: y1 as i16,
        })
    }

    /// A free w × h place: on a shelf of about that height, or on a new shelf
    /// below the last one, growing the atlas when it runs out of rows.
    fn place(&mut self, w: u32, h: u32) -> Option<(u32, u32)> {
        let width = self.width;
        if let Some(s) = self
            .shelves
            .iter_mut()
            .find(|s| h <= s.h && s.h <= h + h / 4 + 2 && s.x + w <= width)
        {
            let x = s.x;
            s.x += w + 1;
            return Some((x, s.y));
        }
        let y = self.shelves.last().map_or(0, |s| s.y + s.h + 1);
        let shelf_h = (h + 3) & !3;
        while y + shelf_h > self.height {
            if self.height * 2 > ATLAS_MAX_HEIGHT {
                return None;
            }
            self.height *= 2;
            self.pixels.resize((self.width * self.height) as usize, 0);
        }
        self.shelves.push(Shelf {
            y,
            h: shelf_h,
            x: w + 1,
        });
        Some((0, y))
    }
}

/// `font` scaled to device pixels. The scale goes through the font's matrix,
/// not its size: the system font is variable, and at twice the size it would
/// switch to its larger optical design, with thinner, differently spaced
/// glyphs than the ones Goose measured.
fn raster_font(font: CFTypeRef, scale: f64) -> Option<Cf> {
    let m = CGAffineTransform {
        a: scale,
        b: 0.0,
        c: 0.0,
        d: scale,
        tx: 0.0,
        ty: 0.0,
    };
    // A size of 0 keeps the font's size.
    Cf::take(unsafe { CTFontCreateCopyWithAttributes(font, 0.0, &m, null()) })
}

/// Everything text keeps between calls. AppKit's thread calls in, so it lives
/// in a thread-local, like the window.
pub struct Text {
    pub fonts: Fonts,
    pub shaper: Shaper,
    pub atlas: Atlas,
    carets: Vec<f32>,
}

thread_local! {
    static TEXT: RefCell<Text> = RefCell::new(Text {
        fonts: Fonts::default(),
        shaper: Shaper::default(),
        atlas: Atlas::new(2.0),
        carets: Vec::new(),
    });
}

pub fn with_text<R>(f: impl FnOnce(&mut Text) -> R) -> R {
    TEXT.with(|t| f(&mut t.borrow_mut()))
}

/// A font's vertical metrics in points, laid out as Goose's `struct Metrics`.
/// `underline_position` is measured from the baseline, up positive, as Core
/// Text gives it, so it is usually negative.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct GpMetrics {
    pub ascent: f32,
    pub descent: f32,
    pub leading: f32,
    pub x_height: f32,
    pub underline_position: f32,
    pub underline_thickness: f32,
}

fn valid_size(size: f32) -> bool {
    size > 0.0 && size < 10_000.0
}

/// Writes the metrics of font `font` at `size` points to `out`.
#[unsafe(no_mangle)]
pub extern "C" fn tp_font_metrics(font: i32, size: f32, out: *mut GpMetrics) -> i32 {
    guarded(|| {
        if out.is_null() || !valid_size(size) {
            return Err(ERR_ARGUMENT);
        }
        with_text(|t| {
            let index = t.fonts.get(font, size).ok_or(ERR_ARGUMENT)?;
            let ct = t.fonts.ct(index);
            let m = unsafe {
                GpMetrics {
                    ascent: CTFontGetAscent(ct) as f32,
                    descent: CTFontGetDescent(ct) as f32,
                    leading: CTFontGetLeading(ct) as f32,
                    x_height: CTFontGetXHeight(ct) as f32,
                    underline_position: CTFontGetUnderlinePosition(ct) as f32,
                    underline_thickness: CTFontGetUnderlineThickness(ct) as f32,
                }
            };
            unsafe { out.write_unaligned(m) };
            Ok(0)
        })
    })
}

/// Shapes `text` in font `font` at `size` points and writes the pen position
/// before each byte to `carets`, which holds `text.len + 1` numbers: the last is
/// the advance of the whole text. Goose breaks lines with these: a word's width
/// is the difference of two positions, so each text is shaped once however
/// often the window's width changes.
#[unsafe(no_mangle)]
pub extern "C" fn tp_text_carets(
    font: i32,
    size: f32,
    text: GSlice<u8>,
    carets: GSlice<f32>,
) -> i32 {
    guarded(|| {
        let text = unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?;
        if !valid_size(size) || carets.count() != Some(text.len() + 1) {
            return Err(ERR_ARGUMENT);
        }
        with_text(|t| {
            let f = t.fonts.get(font, size).ok_or(ERR_ARGUMENT)?;
            let mut out = std::mem::take(&mut t.carets);
            out.resize(text.len() + 1, 0.0);
            let shaped = t.shaper.carets(&mut t.fonts, f, text, &mut out);
            if shaped.is_some() {
                for (i, &c) in out.iter().enumerate() {
                    unsafe { carets.set(i, c) };
                }
            }
            t.carets = out;
            shaped.map(|_| 0).ok_or(ERR_ARGUMENT)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn carets_of(font: i32, size: f32, s: &[u8]) -> Vec<f32> {
        let mut c = vec![0.0; s.len() + 1];
        with_text(|t| {
            let f = t.fonts.get(font, size).unwrap();
            t.shaper.carets(&mut t.fonts, f, s, &mut c).unwrap();
        });
        c
    }

    #[test]
    fn positions_rise_through_the_text_and_bold_is_wider() {
        let c = carets_of(FAMILY_SANS, 17.0, b"Focaccia bread");
        assert_eq!(c[0], 0.0);
        assert!(c.windows(2).all(|w| w[1] >= w[0]), "{c:?}");
        let width = *c.last().unwrap();
        assert!(width > 60.0 && width < 200.0, "width {width}");
        let bold = *carets_of(FAMILY_SANS | FONT_BOLD, 17.0, b"Focaccia bread")
            .last()
            .unwrap();
        assert!(bold > width, "bold {bold} regular {width}");
    }

    #[test]
    fn bytes_of_one_character_share_its_position() {
        let s = "café au lait".as_bytes(); // é is bytes 3 and 4
        let c = carets_of(FAMILY_SERIF, 17.0, s);
        assert_eq!(c[3], c[4]);
        assert!(c[5] > c[3]);
    }

    #[test]
    fn invalid_utf8_is_drawn_not_refused() {
        let c = carets_of(FAMILY_MONO, 13.0, &[b'a', 0xFF, b'b']);
        assert!(c[1] > 0.0 && c[2] > c[1] && c[3] > c[2], "{c:?}");
    }

    #[test]
    fn other_scripts_fall_back_to_other_fonts() {
        with_text(|t| {
            let georgia = t.fonts.get(FAMILY_SERIF, 17.0).unwrap();
            let mut glyphs = Vec::new();
            t.shaper
                .shape(&mut t.fonts, georgia, "日本".as_bytes(), &mut glyphs)
                .unwrap();
            assert_eq!(glyphs.len(), 2);
            assert!(
                glyphs.iter().all(|g| g.font != georgia && g.id != 0),
                "{glyphs:?}"
            );
            assert_eq!(glyphs[1].byte, 3);
        });
    }

    #[test]
    fn metrics_are_those_of_the_font() {
        let mut m = GpMetrics::default();
        assert_eq!(tp_font_metrics(FAMILY_SANS, 17.0, &mut m), 0);
        assert!(
            m.ascent > m.descent && m.descent > 0.0 && m.ascent < 25.0,
            "{m:?}"
        );
        assert!(
            m.underline_position < 0.0 && m.underline_thickness > 0.0,
            "{m:?}"
        );
    }

    #[test]
    fn glyphs_are_rasterized_upright_once() {
        with_text(|t| {
            let f = t.fonts.get(FAMILY_SANS, 40.0).unwrap();
            let mut glyphs = Vec::new();
            t.shaper.shape(&mut t.fonts, f, b"T", &mut glyphs).unwrap();
            let e = t.atlas.glyph(&t.fonts, f, glyphs[0].id, 0);
            assert!(e.w > 10 && e.h > 10 && e.top > 0, "{e:?}");
            // T's bar is at the top: the upper rows carry more ink.
            let ink = |rows: std::ops::Range<u16>| -> u32 {
                rows.map(|r| {
                    let start = ((e.y + r) as u32 * t.atlas.width + e.x as u32) as usize;
                    t.atlas.pixels[start..start + e.w as usize]
                        .iter()
                        .map(|&p| p as u32)
                        .sum::<u32>()
                })
                .sum()
            };
            let third = e.h / 3;
            assert!(ink(0..third) > 2 * ink(e.h - third..e.h));
            assert_eq!(t.atlas.glyph(&t.fonts, f, glyphs[0].id, 0), e);
        });
    }

    #[test]
    fn glyphs_keep_their_design_at_twice_the_size() {
        with_text(|t| {
            let f = t.fonts.get(FAMILY_SANS, 17.0).unwrap();
            let mut glyphs = Vec::new();
            t.shaper.shape(&mut t.fonts, f, b"r", &mut glyphs).unwrap();
            let id = glyphs[0].id;
            let width = |font: CFTypeRef| {
                let mut r = CGRect::default();
                unsafe {
                    CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &id, &mut r, 1)
                };
                r.size.width
            };
            let at_1x = width(t.fonts.ct(f));
            let raster = raster_font(t.fonts.ct(f), 2.0).unwrap();
            let at_2x = width(raster.get());
            assert!((at_2x - 2.0 * at_1x).abs() < 0.01, "1x {at_1x}, 2x {at_2x}");
        });
    }

    #[test]
    fn bad_arguments_are_refused() {
        let text = b"ab";
        let mut carets = [0.0f32; 3];
        let t = GSlice {
            data: text.as_ptr() as *mut u8,
            len: 2,
        };
        let short = GSlice {
            data: carets.as_mut_ptr(),
            len: 2,
        }; // needs 3
        assert_eq!(tp_text_carets(FAMILY_SANS, 17.0, t, short), ERR_ARGUMENT);
        let c = GSlice {
            data: carets.as_mut_ptr(),
            len: 3,
        };
        assert_eq!(tp_text_carets(FAMILY_SANS, f32::NAN, t, c), ERR_ARGUMENT);
        assert_eq!(tp_text_carets(FAMILY_SANS, 17.0, t, c), 0);
        assert!(carets[2] > carets[1] && carets[1] > 0.0);
        assert_eq!(
            tp_font_metrics(FAMILY_SANS, 17.0, std::ptr::null_mut()),
            ERR_ARGUMENT
        );
    }
}
