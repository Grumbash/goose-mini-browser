//! Text on Core Text (docs/adr/0001): fonts by family, weight, style and size;
//! shaping, with Core Text's fallback fonts for characters a font lacks; the pen
//! position before every byte, which Goose breaks lines with; and the glyph
//! atlas the compositor draws text from.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ptr::null;
use std::sync::Mutex;

use crate::cg::*;
use crate::{ERR_ARGUMENT, GSlice, guarded};

// Font ids, as Goose writes them: the family in the low four bits, the weight
// over 100 in the next four (0 is 400, normal), whether it is italic, and
// whether its optional ligatures are off, for letter-spaced text.
pub const FAMILY_SANS: i32 = 0;
pub const FAMILY_SERIF: i32 = 1;
pub const FAMILY_MONO: i32 = 2;
pub const FAMILY_CONDENSED: i32 = 3; // Barlow Condensed, bundled
pub const FAMILY_CODE: i32 = 4; // JetBrains Mono, bundled
pub const FONT_WEIGHT_SHIFT: i32 = 4;
pub const FONT_BOLD: i32 = 7 << FONT_WEIGHT_SHIFT;
pub const FONT_ITALIC: i32 = 1 << 8;
pub const FONT_NO_LIGATURES: i32 = 1 << 9;

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

/// The font for id `id` at `size` points: its family's face for its weight
/// and style, with optional ligatures off when the id says so.
fn create_font(id: i32, size: f64) -> Option<Cf> {
    if !(size > 0.0 && size < 10_000.0) {
        return None;
    }
    let weight = match (id >> FONT_WEIGHT_SHIFT) & 0xF {
        0 => 400,
        w => w * 100,
    };
    let font = face(id & 0xF, weight, id & FONT_ITALIC != 0, size)?;
    if id & FONT_NO_LIGATURES != 0 {
        return without_ligatures(&font).or(Some(font));
    }
    Some(font)
}

/// Generic families map to fonts every Mac has: the system font for
/// sans-serif, matched to the weight trait, as it has every weight; Georgia
/// for serif and Menlo for monospace, which have a regular and a bold face,
/// bold from 600 on as CSS matches faces (Fonts 4 §5.2). The bundled families
/// (tp_register_fonts) are Barlow Condensed, by its nearest face, and
/// JetBrains Mono, by its variable weight axis; neither has italics, and
/// without them the system font and Menlo stand in.
fn face(family: i32, weight: i32, italic: bool, size: f64) -> Option<Cf> {
    let named =
        |name: &str| Cf::take(unsafe { CTFontCreateWithName(cf_str(name)?.get(), size, null()) });
    let system =
        || Cf::take(unsafe { CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, null()) });
    let (base, two_faces) = match family {
        FAMILY_SERIF => (named("Georgia")?, true),
        FAMILY_MONO => (named("Menlo")?, true),
        FAMILY_CONDENSED => {
            register_bundled();
            // Medium is the lightest face bundled, Black the heaviest.
            let face = match weight {
                ..=550 => "BarlowCondensed-Medium",
                551..=650 => "BarlowCondensed-SemiBold",
                651..=750 => "BarlowCondensed-Bold",
                751..=850 => "BarlowCondensed-ExtraBold",
                _ => "BarlowCondensed-Black",
            };
            match registered(face, "Barlow Condensed", size) {
                Some(font) => return Some(font),
                None => (system()?, false),
            }
        }
        FAMILY_CODE => {
            register_bundled();
            match registered("JetBrainsMono-Regular", "JetBrains Mono", size) {
                Some(font) => {
                    return Some(at_weight(&font, weight.clamp(100, 800)).unwrap_or(font));
                }
                None => (named("Menlo")?, true),
            }
        }
        _ => (system()?, false),
    };
    if weight == 400 && !italic {
        return Some(base);
    }
    if two_faces {
        return bold_or_italic(&base, weight >= 600, italic).or(Some(base));
    }
    styled(&base, size, weight, italic).or(Some(base))
}

/// `base` in its bold or italic face, or both.
fn bold_or_italic(base: &Cf, bold: bool, italic: bool) -> Option<Cf> {
    let mut traits = 0;
    if bold {
        traits |= kCTFontTraitBold;
    }
    if italic {
        traits |= kCTFontTraitItalic;
    }
    if traits == 0 {
        return None;
    }
    // A size of 0 keeps the base font's size.
    Cf::take(unsafe { CTFontCreateCopyWithSymbolicTraits(base.get(), 0.0, null(), traits, traits) })
}

/// `font` with its optional ligatures and contextual alternates (liga, clig,
/// calt) off, as CSS has for letter-spaced text (Text 3 §9.2).
fn without_ligatures(font: &Cf) -> Option<Cf> {
    let off = integer(0)?;
    let mut settings = Vec::new();
    for tag in ["liga", "clig", "calt"] {
        let tag = cf_str(tag)?;
        settings.push(dictionary(
            &[unsafe { kCTFontOpenTypeFeatureTag }, unsafe {
                kCTFontOpenTypeFeatureValue
            }],
            &[tag.get(), off.get()],
        )?);
    }
    let values: Vec<CFTypeRef> = settings.iter().map(|s| s.get()).collect();
    let list = Cf::take(unsafe {
        CFArrayCreate(
            null(),
            values.as_ptr(),
            values.len() as CFIndex,
            &kCFTypeArrayCallBacks,
        )
    })?;
    let attributes = dictionary(&[unsafe { kCTFontFeatureSettingsAttribute }], &[list.get()])?;
    let descriptor = Cf::take(unsafe { CTFontDescriptorCreateWithAttributes(attributes.get()) })?;
    // A size of 0 keeps the font's size.
    Cf::take(unsafe { CTFontCreateCopyWithAttributes(font.get(), 0.0, null(), descriptor.get()) })
}

/// Font `name` at `size`, only when it is of family `family`: Core Text gives
/// another font for a name it doesn't know, before the bundled ones are
/// registered.
fn registered(name: &str, family: &str, size: f64) -> Option<Cf> {
    let font = Cf::take(unsafe { CTFontCreateWithName(cf_str(name)?.get(), size, null()) })?;
    let got = Cf::take(unsafe { CTFontCopyFamilyName(font.get()) })?;
    (unsafe { CFEqual(got.get(), cf_str(family)?.get()) } != 0).then_some(font)
}

/// A variable font with its weight axis set to `weight`.
fn at_weight(font: &Cf, weight: i32) -> Option<Cf> {
    let axis = integer(0x7767_6874)?; // 'wght'
    let value = number(weight as f64)?;
    let variation = dictionary(&[axis.get()], &[value.get()])?;
    let attributes = dictionary(&[unsafe { kCTFontVariationAttribute }], &[variation.get()])?;
    let descriptor = Cf::take(unsafe { CTFontDescriptorCreateWithAttributes(attributes.get()) })?;
    // A size of 0 keeps the font's size.
    Cf::take(unsafe { CTFontCreateCopyWithAttributes(font.get(), 0.0, null(), descriptor.get()) })
}

/// `base`'s family at CSS weight `weight` (100 to 1000), italic if asked: the
/// face Core Text matches to the weight trait.
fn styled(base: &Cf, size: f64, weight: i32, italic: bool) -> Option<Cf> {
    let family = Cf::take(unsafe { CTFontCopyFamilyName(base.get()) })?;
    let mut symbolic = if italic { kCTFontTraitItalic } else { 0 };
    if weight >= 600 {
        symbolic |= kCTFontTraitBold;
    }
    let trait_weight = number(trait_of(weight))?;
    let trait_symbolic = integer(symbolic as i32)?;
    let traits = dictionary(
        &[unsafe { kCTFontWeightTrait }, unsafe {
            kCTFontSymbolicTrait
        }],
        &[trait_weight.get(), trait_symbolic.get()],
    )?;
    let attributes = dictionary(
        &[unsafe { kCTFontFamilyNameAttribute }, unsafe {
            kCTFontTraitsAttribute
        }],
        &[family.get(), traits.get()],
    )?;
    let descriptor = Cf::take(unsafe { CTFontDescriptorCreateWithAttributes(attributes.get()) })?;
    Cf::take(unsafe { CTFontCreateWithFontDescriptor(descriptor.get(), size, null()) })
}

/// A CSS weight as Core Text's weight trait, from -1 (thinnest) to 1 (heaviest).
fn trait_of(weight: i32) -> f64 {
    match weight {
        ..=100 => -0.8,
        101..=200 => -0.6,
        201..=300 => -0.4,
        301..=400 => 0.0,
        401..=500 => 0.23,
        501..=600 => 0.3,
        601..=700 => 0.4,
        701..=800 => 0.56,
        _ => 0.62,
    }
}

fn number(v: f64) -> Option<Cf> {
    Cf::take(unsafe { CFNumberCreate(null(), kCFNumberFloat64Type, (&v as *const f64).cast()) })
}

fn integer(v: i32) -> Option<Cf> {
    Cf::take(unsafe { CFNumberCreate(null(), kCFNumberSInt32Type, (&v as *const i32).cast()) })
}

fn dictionary(keys: &[CFTypeRef], values: &[CFTypeRef]) -> Option<Cf> {
    Cf::take(unsafe {
        CFDictionaryCreate(
            null(),
            keys.as_ptr(),
            values.as_ptr(),
            keys.len() as CFIndex,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    })
}

/// The bundled fonts: the files tp_register_fonts found, registered for the
/// process the first time a bundled family is asked for.
struct Bundled {
    files: Vec<std::path::PathBuf>,
    registered: bool,
}

static BUNDLED: Mutex<Bundled> = Mutex::new(Bundled {
    files: Vec::new(),
    registered: false,
});

/// Names directory `dir` as where the bundled fonts are (its .ttf and .otf
/// files). They are registered when first needed, so a page that doesn't use
/// them doesn't pay for them. Returns how many there are.
#[unsafe(no_mangle)]
pub extern "C" fn tp_register_fonts(dir: GSlice<u8>) -> i32 {
    guarded(|| {
        let dir = unsafe { dir.as_slice() }.ok_or(ERR_ARGUMENT)?;
        let dir = std::str::from_utf8(dir).map_err(|_| ERR_ARGUMENT)?;
        let entries = std::fs::read_dir(dir).map_err(|_| ERR_ARGUMENT)?;
        let mut files: Vec<_> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
                ext.eq_ignore_ascii_case("ttf") || ext.eq_ignore_ascii_case("otf")
            })
            .collect();
        files.sort();
        let count = files.len() as i32;
        let mut bundled = BUNDLED.lock().map_err(|_| ERR_ARGUMENT)?;
        if !bundled.registered {
            bundled.files = files;
        }
        Ok(count)
    })
}

/// Registers the bundled fonts for this process, once.
fn register_bundled() {
    let Ok(mut bundled) = BUNDLED.lock() else {
        return;
    };
    if bundled.registered || bundled.files.is_empty() {
        return;
    }
    for path in &bundled.files {
        let bytes = path.as_os_str().as_encoded_bytes();
        let Some(url) = Cf::take(unsafe {
            CFURLCreateFromFileSystemRepresentation(
                null(),
                bytes.as_ptr(),
                bytes.len() as CFIndex,
                0,
            )
        }) else {
            continue;
        };
        unsafe {
            CTFontManagerRegisterFontsForURL(
                url.get(),
                kCTFontManagerScopeProcess,
                std::ptr::null_mut(),
            )
        };
    }
    bundled.registered = true;
}

/// Where each typographic character unit of `text` starts (CSS Text 3 §9.2),
/// one flag per byte: a letter with its marks, spacing ones too, an emoji with
/// its modifiers, as Core Foundation finds composed character sequences. A
/// zero-width character (a soft hyphen, a zero-width space or joiner, a word
/// joiner, a byte-order mark) starts none, so letter-spacing gives it no room.
/// Text that isn't UTF-8 has one per character.
pub fn unit_starts(text: &[u8], out: &mut Vec<u8>) {
    out.clear();
    out.extend(text.iter().map(|&b| u8::from(b & 0xC0 != 0x80)));
    let Some(s) = Cf::take(unsafe {
        CFStringCreateWithBytes(
            null(),
            text.as_ptr(),
            text.len() as CFIndex,
            kCFStringEncodingUTF8,
            0,
        )
    }) else {
        return;
    };
    // Each UTF-16 unit's character, as a byte offset: two for one past U+FFFF.
    let mut byte_at = Vec::with_capacity(text.len() + 1);
    let mut k = 0;
    while k < text.len() {
        let n = match text[k] {
            0xF0.. => 4,
            0xE0.. => 3,
            0xC0.. => 2,
            _ => 1,
        };
        byte_at.push(k);
        if n == 4 {
            byte_at.push(k);
        }
        k += n;
    }
    let len = unsafe { CFStringGetLength(s.get()) } as usize;
    if len != byte_at.len() {
        return;
    }
    out.fill(0);
    let mut i = 0;
    while i < len {
        let r = unsafe {
            CFStringGetRangeOfCharacterClusterAtIndex(
                s.get(),
                i as CFIndex,
                kCFStringComposedCharacterCluster,
            )
        };
        let start = byte_at[r.location as usize];
        if !zero_width(&text[start..]) {
            out[start] = 1;
        }
        i = ((r.location + r.length) as usize).max(i + 1);
    }
}

/// Whether `text` starts with a character that takes no room: U+00AD,
/// U+200B to U+200F, U+2060 to U+2064 or U+FEFF.
fn zero_width(text: &[u8]) -> bool {
    matches!(
        text,
        [0xC2, 0xAD, ..]
            | [0xE2, 0x80, 0x8B..=0x8F, ..]
            | [0xE2, 0x81, 0xA0..=0xA4, ..]
            | [0xEF, 0xBB, 0xBF, ..]
    )
}

/// Fills `units`, as long as `text`, with 1 where a typographic character
/// unit of it starts and 0 elsewhere (see unit_starts), for letter-spacing.
#[unsafe(no_mangle)]
pub extern "C" fn tp_text_units(text: GSlice<u8>, units: GSlice<u8>) -> i32 {
    guarded(|| {
        let text = unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?;
        if units.count() != Some(text.len()) {
            return Err(ERR_ARGUMENT);
        }
        let mut out = Vec::new();
        unit_starts(text, &mut out);
        for (i, &u) in out.iter().enumerate() {
            unsafe { units.set(i, u) };
        }
        Ok(0)
    })
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
/// A glyph with nothing to draw, such as a space, has zero size. A path's mask
/// too big for its sheet is `div` times smaller than it draws (0 or 1: not).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AtlasEntry {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
    pub left: i16,
    pub top: i16,
    pub div: u8,
}

struct Shelf {
    y: u32,
    h: u32,
    x: u32,
}

/// Masks of one kind for one texture, one byte per device pixel, packed on
/// shelves of similar height. It grows downwards when full, up to its most
/// rows, so rows already uploaded never move until it is cleared.
pub struct Sheet {
    pub width: u32,
    pub height: u32,
    max_height: u32,
    pub pixels: Vec<u8>,
    /// Rows written since the compositor last uploaded, as [first, end).
    pub dirty: Option<(u32, u32)>,
    shelves: Vec<Shelf>,
    /// Whether a mask found no room since it was last cleared.
    pub full: bool,
    /// Whether a path's mask that finds no room is drawn smaller instead:
    /// once the sheet has been cleared and still can't hold what is drawn.
    pub tight: bool,
}

impl Sheet {
    fn new(width: u32, max_height: u32) -> Self {
        let height = 256.min(max_height);
        Sheet {
            width,
            height,
            max_height,
            pixels: vec![0; (width * height) as usize],
            dirty: None,
            shelves: Vec::new(),
            full: false,
            tight: false,
        }
    }

    /// A free w × h place: on a shelf of about that height, or on a new shelf
    /// below the last one, growing the sheet when it runs out of rows. None
    /// when there is no room.
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
        // A new shelf is an eighth taller than what opens it, so that masks
        // a little taller share it rather than each opening its own.
        let y = self.shelves.last().map_or(0, |s| s.y + s.h + 1);
        let shelf_h = (h + h / 8 + 3) & !3;
        while y + shelf_h > self.height {
            if self.height * 2 > self.max_height {
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

    /// Copies mask `mask`, w × h with its first row its top, to (x, y).
    fn put(&mut self, x: u32, y: u32, w: u32, h: u32, mask: &[u8]) {
        for row in 0..h {
            let from = (row * w) as usize;
            let to = ((y + row) * self.width + x) as usize;
            self.pixels[to..to + w as usize].copy_from_slice(&mask[from..from + w as usize]);
        }
        self.dirty = Some(match self.dirty {
            Some((a, b)) => (a.min(y), b.max(y + h)),
            None => (y, y + h),
        });
    }

    /// Empties it, to draw the masks in use again; all of it is uploaded.
    pub fn clear(&mut self) {
        self.shelves.clear();
        self.pixels.fill(0);
        self.full = false;
        self.dirty = Some((0, self.height));
    }
}

/// The coverage masks drawn so far at one backing scale: glyphs in one sheet
/// and SVG's paths in another, so that big paths never take the glyphs' room.
pub struct Atlas {
    pub scale: f64,
    pub glyphs: Sheet,
    pub paths: Sheet,
    entries: HashMap<(u32, u16, u8), AtlasEntry>,
    path_entries: HashMap<u64, AtlasEntry>, // by path_key
    raster_fonts: HashMap<u32, Cf>,         // font index -> that font at size × scale
}

/// The glyphs' sheet: 1024 pixels wide, up to 16 MB.
const GLYPHS_WIDTH: u32 = 1024;
const GLYPHS_MAX_HEIGHT: u32 = 16384;
/// The paths' sheet: wide enough for a path 2048 points across at 2x, up to
/// 16 MB.
const PATHS_WIDTH: u32 = 4096;
const PATHS_MAX_HEIGHT: u32 = 4096;

impl Atlas {
    pub fn new(scale: f64) -> Self {
        Atlas {
            scale,
            glyphs: Sheet::new(GLYPHS_WIDTH, GLYPHS_MAX_HEIGHT),
            paths: Sheet::new(PATHS_WIDTH, PATHS_MAX_HEIGHT),
            entries: HashMap::new(),
            path_entries: HashMap::new(),
            raster_fonts: HashMap::new(),
        }
    }

    /// Empties the glyphs' sheet, and forgets the glyphs that were in it.
    pub fn clear_glyphs(&mut self) {
        self.glyphs.clear();
        self.entries.clear();
    }

    /// Empties the paths' sheet, and forgets the paths that were in it.
    pub fn clear_paths(&mut self) {
        self.paths.clear();
        self.path_entries.clear();
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
        if w > self.glyphs.width || h > 2048 {
            return None;
        }
        let Some((ax, ay)) = self.glyphs.place(w, h) else {
            self.glyphs.full = true;
            return None;
        };

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
        self.glyphs.put(ax, ay, w, h, &mask);
        Some(AtlasEntry {
            x: ax as u16,
            y: ay as u16,
            w: w as u16,
            h: h as u16,
            left: x0 as i16,
            top: y1 as i16,
            div: 0,
        })
    }

    /// The atlas entry for an SVG path (see Goose's vector.goose), rasterized
    /// on first use: its data `data` in points from the item's corner, filled,
    /// or stroked `stroke` points wide, as `flags` say, from (`phase_x`,
    /// `phase_y`) in 1/PHASES of a device pixel past a pixel's corner. Its
    /// `left` and `top` are where its mask's corner is from that pixel, in
    /// device pixels. One bigger than its sheet is drawn smaller. With
    /// `seen`, the part of the device pixels from that pixel that can show,
    /// as x0, y0, x1, y1, its mask covers no more than that.
    pub fn path(
        &mut self,
        data: &[f32],
        stroke: f32,
        flags: i32,
        phase_x: u8,
        phase_y: u8,
        seen: Option<[i32; 4]>,
    ) -> AtlasEntry {
        let key = path_key(data, stroke, flags, phase_x, phase_y, seen);
        if let Some(e) = self.path_entries.get(&key) {
            return *e;
        }
        let entry = self
            .rasterize_path(data, stroke, flags, phase_x, phase_y, seen)
            .unwrap_or_default();
        self.path_entries.insert(key, entry);
        entry
    }

    fn rasterize_path(
        &mut self,
        data: &[f32],
        stroke: f32,
        flags: i32,
        phase_x: u8,
        phase_y: u8,
        seen: Option<[i32; 4]>,
    ) -> Option<AtlasEntry> {
        let (own, clip) = split_clip(data);
        let (dx, dy) = (
            phase_x as f64 / PHASES as f64,
            phase_y as f64 / PHASES as f64,
        );
        let path = device_path(own, self.scale, dx, dy)?;
        let clip = match clip {
            Some(corners) => Some(device_polygon(corners, self.scale, dx, dy)?),
            None => None,
        };
        let outline = if stroke > 0.0 {
            let cap = if flags & PATH_CAP_ROUND != 0 {
                1
            } else if flags & PATH_CAP_SQUARE != 0 {
                2
            } else {
                0
            };
            let join = if flags & PATH_JOIN_ROUND != 0 {
                1
            } else if flags & PATH_JOIN_BEVEL != 0 {
                2
            } else {
                0
            };
            Cf::take(unsafe {
                CGPathCreateCopyByStrokingPath(
                    path.get(),
                    null(),
                    stroke as f64 * self.scale,
                    cap,
                    join,
                    4.0,
                )
            })?
        } else {
            path
        };
        let mut r = unsafe { CGPathGetPathBoundingBox(outline.get()) };
        if let Some(c) = &clip {
            // Only what the clip shows needs a mask.
            let b = unsafe { CGPathGetPathBoundingBox(c.get()) };
            let x0 = r.origin.x.max(b.origin.x);
            let y0 = r.origin.y.max(b.origin.y);
            let x1 = (r.origin.x + r.size.width).min(b.origin.x + b.size.width);
            let y1 = (r.origin.y + r.size.height).min(b.origin.y + b.size.height);
            r.origin.x = x0;
            r.origin.y = y0;
            r.size.width = x1 - x0;
            r.size.height = y1 - y0;
        }
        if let Some([sx0, sy0, sx1, sy1]) = seen {
            let x0 = r.origin.x.max(sx0 as f64);
            let y0 = r.origin.y.max(sy0 as f64);
            let x1 = (r.origin.x + r.size.width).min(sx1 as f64);
            let y1 = (r.origin.y + r.size.height).min(sy1 as f64);
            r.origin.x = x0;
            r.origin.y = y0;
            r.size.width = x1 - x0;
            r.size.height = y1 - y0;
        }
        if !(r.size.width > 0.0 && r.size.height > 0.0) {
            return None;
        }
        // A pixel of margin all round keeps antialiased edges whole.
        let x0 = r.origin.x.floor() as i32 - 1;
        let x1 = (r.origin.x + r.size.width).ceil() as i32 + 1;
        let y0 = r.origin.y.floor() as i32 - 1;
        let y1 = (r.origin.y + r.size.height).ceil() as i32 + 1;
        if !(i16::MIN as i32..=i16::MAX as i32).contains(&x0)
            || !(i16::MIN as i32..=i16::MAX as i32).contains(&y0)
        {
            return None;
        }
        // A mask too big for the sheet is drawn smaller, by a power of two,
        // and stretched back: its edges soften a little, at a size where that
        // doesn't show.
        let (w, h) = ((x1 - x0) as u32, (y1 - y0) as u32);
        let mut div = 1;
        while w.div_ceil(div) > self.paths.width || h.div_ceil(div) > self.paths.max_height {
            div *= 2;
        }
        // When the sheet can't hold what the layers draw, a big mask (over a
        // 64th of the sheet) is drawn at half the size, and any that still
        // finds no room smaller again, rather than not at all.
        if self.paths.tight
            && w.div_ceil(div) * h.div_ceil(div) > self.paths.width * self.paths.max_height / 64
        {
            div *= 2;
        }
        let (mw, mh, ax, ay) = loop {
            let (mw, mh) = (w.div_ceil(div), h.div_ceil(div));
            if let Some((ax, ay)) = self.paths.place(mw, mh) {
                break (mw, mh, ax, ay);
            }
            if !self.paths.tight || div >= 16 {
                self.paths.full = true;
                return None;
            }
            div *= 2;
        };
        let mut mask = vec![0u8; (mw * mh) as usize];
        {
            let context = Cf::take(unsafe {
                CGBitmapContextCreate(
                    mask.as_mut_ptr().cast(),
                    mw as usize,
                    mh as usize,
                    8,
                    mw as usize,
                    null(),
                    kCGImageAlphaOnly,
                )
            })?;
            let c = context.get();
            unsafe {
                CGContextSetAllowsAntialiasing(c, true);
                CGContextSetShouldAntialias(c, true);
                CGContextSetGrayFillColor(c, 1.0, 1.0);
                // Device pixels have y down; the bitmap's first row is its top.
                CGContextScaleCTM(c, 1.0 / div as f64, 1.0 / div as f64);
                CGContextTranslateCTM(c, -x0 as f64, y1 as f64);
                CGContextScaleCTM(c, 1.0, -1.0);
                if let Some(clip) = &clip {
                    CGContextAddPath(c, clip.get());
                    CGContextClip(c);
                }
                CGContextAddPath(c, outline.get());
                if stroke <= 0.0 && flags & PATH_EVENODD != 0 {
                    CGContextEOFillPath(c);
                } else {
                    CGContextFillPath(c);
                }
            }
        }
        self.paths.put(ax, ay, mw, mh, &mask);
        Some(AtlasEntry {
            x: ax as u16,
            y: ay as u16,
            w: mw as u16,
            h: mh as u16,
            left: x0 as i16,
            top: y0 as i16,
            div: div as u8,
        })
    }
}

// How an SVG path is painted, as Goose's vector.goose writes Painted.flags.
pub const PATH_EVENODD: i32 = 1;
pub const PATH_CAP_ROUND: i32 = 2;
pub const PATH_CAP_SQUARE: i32 = 4;
pub const PATH_JOIN_ROUND: i32 = 8;
pub const PATH_JOIN_BEVEL: i32 = 16;

/// Path data (moves 0 and lines 1 with a point, cubic curves 2 with three,
/// closes 3) as a Core Graphics path in device pixels, from (dx, dy). Data
/// that ends early ends the path there.
fn device_path(data: &[f32], scale: f64, dx: f64, dy: f64) -> Option<Cf> {
    let path = Cf::take(unsafe { CGPathCreateMutable() })?;
    let p = path.get();
    let at = |i: usize| (data[i] as f64 * scale + dx, data[i + 1] as f64 * scale + dy);
    let mut k = 0;
    let mut open = false;
    while k < data.len() {
        let op = data[k];
        if op == 3.0 {
            if open {
                unsafe { CGPathCloseSubpath(p) };
            }
            k += 1;
        } else if (op == 0.0 || op == 1.0) && k + 2 < data.len() {
            let (x, y) = at(k + 1);
            if op == 0.0 || !open {
                unsafe { CGPathMoveToPoint(p, null(), x, y) };
                open = true;
            } else {
                unsafe { CGPathAddLineToPoint(p, null(), x, y) };
            }
            k += 3;
        } else if op == 2.0 && k + 6 < data.len() && open {
            let ((ax, ay), (bx, by), (x, y)) = (at(k + 1), at(k + 3), at(k + 5));
            unsafe { CGPathAddCurveToPoint(p, null(), ax, ay, bx, by, x, y) };
            k += 7;
        } else {
            break;
        }
    }
    if unsafe { CGPathIsEmpty(p) } {
        return None;
    }
    Some(path)
}

/// Path data's own part, and the corners of the polygon it shows inside when
/// it ends with a clip (4, then a count of corners and each one's x y).
fn split_clip(data: &[f32]) -> (&[f32], Option<&[f32]>) {
    let mut k = 0;
    while k < data.len() {
        let op = data[k];
        if op == 4.0 {
            let corners = data.get(k + 1).map_or(0, |&n| n.max(0.0) as usize);
            let end = (k + 2 + 2 * corners).min(data.len());
            return (&data[..k], Some(&data[(k + 2).min(end)..end]));
        }
        k += if op == 2.0 {
            7
        } else if op == 3.0 {
            1
        } else {
            3
        };
    }
    (data, None)
}

/// A clip's corners as a closed Core Graphics polygon in device pixels, from
/// (dx, dy), as device_path places points.
fn device_polygon(corners: &[f32], scale: f64, dx: f64, dy: f64) -> Option<Cf> {
    if corners.len() < 6 {
        return None;
    }
    let path = Cf::take(unsafe { CGPathCreateMutable() })?;
    let p = path.get();
    for (i, &[x, y]) in corners.as_chunks::<2>().0.iter().enumerate() {
        let (x, y) = (x as f64 * scale + dx, y as f64 * scale + dy);
        unsafe {
            if i == 0 {
                CGPathMoveToPoint(p, null(), x, y);
            } else {
                CGPathAddLineToPoint(p, null(), x, y);
            }
        }
    }
    unsafe { CGPathCloseSubpath(p) };
    Some(path)
}

/// What tells two path masks apart: the path's points to a 64th of a point,
/// its stroke, flags and phases, and what of it can show.
fn path_key(
    data: &[f32],
    stroke: f32,
    flags: i32,
    phase_x: u8,
    phase_y: u8,
    seen: Option<[i32; 4]>,
) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for &v in data {
        ((v * 64.0).round() as i32).hash(&mut h);
    }
    stroke.to_bits().hash(&mut h);
    (flags, phase_x, phase_y, seen).hash(&mut h);
    h.finish()
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

    /// The PostScript name of the font Goose's id `id` gets at 20 points.
    fn face_of(id: i32) -> String {
        let font = create_font(id, 20.0).unwrap();
        let name = Cf::take(unsafe { CTFontCopyPostScriptName(font.get()) }).unwrap();
        let mut buf = [0u8; 128];
        let ok =
            unsafe { CFStringGetCString(name.get(), buf.as_mut_ptr(), 128, kCFStringEncodingUTF8) };
        assert!(ok);
        let end = buf.iter().position(|&b| b == 0).unwrap();
        String::from_utf8_lossy(&buf[..end]).into_owned()
    }

    #[test]
    fn bundled_families_have_their_weights() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../app/fonts");
        let dir = GSlice::<u8> {
            data: dir.as_ptr() as *mut u8,
            len: dir.len() as i64,
        };
        assert_eq!(tp_register_fonts(dir), 6);
        let w = |weight: i32| (weight / 100) << FONT_WEIGHT_SHIFT;
        assert_eq!(face_of(FAMILY_CONDENSED | w(500)), "BarlowCondensed-Medium");
        assert_eq!(face_of(FAMILY_CONDENSED | w(700)), "BarlowCondensed-Bold");
        assert_eq!(face_of(FAMILY_CONDENSED | w(900)), "BarlowCondensed-Black");
        assert!(face_of(FAMILY_CODE).starts_with("JetBrainsMono"));
        assert_ne!(face_of(FAMILY_CODE | w(700)), face_of(FAMILY_CODE));
        // The system font gets wider as it gets heavier.
        let wide = |id: i32| *carets_of(id, 17.0, b"Focaccia bread").last().unwrap();
        assert!(wide(FAMILY_SANS) < wide(FAMILY_SANS | w(600)));
        assert!(wide(FAMILY_SANS | w(600)) < wide(FAMILY_SANS | w(900)));
        // Georgia and Menlo have a regular and a bold face: bold from 600 on.
        assert_eq!(face_of(FAMILY_SERIF | w(500)), "Georgia");
        assert_eq!(face_of(FAMILY_SERIF | w(600)), "Georgia-Bold");
        assert_eq!(
            face_of(FAMILY_SERIF | w(500) | FONT_ITALIC),
            "Georgia-Italic"
        );
        assert_eq!(face_of(FAMILY_MONO | w(500)), "Menlo-Regular");
        assert_eq!(face_of(FAMILY_MONO | w(800)), "Menlo-Bold");
    }

    #[test]
    fn spaced_text_has_no_optional_ligatures() {
        // Barlow Condensed draws "ffi" as one glyph, unless the text is spaced.
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../app/fonts");
        let dir = GSlice::<u8> {
            data: dir.as_ptr() as *mut u8,
            len: dir.len() as i64,
        };
        assert_eq!(tp_register_fonts(dir), 6);
        let glyphs = |id: i32| {
            with_text(|t| {
                let f = t.fonts.get(id, 20.0).unwrap();
                let mut out = Vec::new();
                t.shaper.shape(&mut t.fonts, f, b"ffi", &mut out).unwrap();
                out.len()
            })
        };
        assert_eq!(glyphs(FAMILY_CONDENSED), 1);
        assert_eq!(glyphs(FAMILY_CONDENSED | FONT_NO_LIGATURES), 3);
    }

    #[test]
    fn units_are_letters_with_their_marks() {
        let units = |s: &str| {
            let mut out = Vec::new();
            unit_starts(s.as_bytes(), &mut out);
            out
        };
        // x with a combining circumflex; a zero-width space between two letters;
        // a thumbs up with its skin tone; the Devanagari सविता as स, वि and ता.
        assert_eq!(units("x\u{302}b"), [1, 0, 0, 1]);
        assert_eq!(units("a\u{200B}b"), [1, 0, 0, 0, 1]);
        assert_eq!(units("\u{1F44D}\u{1F3FD}"), [1, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(
            units("सविता"),
            [1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]
        );
        // Bytes that aren't UTF-8: one per character still.
        assert_eq!(units_of(&[b'a', 0xFF, b'b']), [1, 1, 1]);
    }

    fn units_of(text: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        unit_starts(text, &mut out);
        out
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
                    let start = ((e.y + r) as u32 * t.atlas.glyphs.width + e.x as u32) as usize;
                    t.atlas.glyphs.pixels[start..start + e.w as usize]
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

    #[test]
    fn a_clip_cuts_a_path_mask() {
        let mut atlas = Atlas::new(1.0);
        // A 20 × 20 square, then the same shown only left of x = 10.
        let square = [
            0.0, 0.0, 0.0, 1.0, 20.0, 0.0, 1.0, 20.0, 20.0, 1.0, 0.0, 20.0, 3.0,
        ];
        let mut half = square.to_vec();
        half.extend_from_slice(&[4.0, 4.0, 0.0, 0.0, 10.0, 0.0, 10.0, 20.0, 0.0, 20.0]);
        let a = atlas.path(&square, 0.0, 0, 0, 0, None);
        let b = atlas.path(&half, 0.0, 0, 0, 0, None);
        let at = |e: AtlasEntry, x: i32, y: i32| {
            let (mx, my) = ((x - e.left as i32) as u32, (y - e.top as i32) as u32);
            atlas.paths.pixels[((e.y as u32 + my) * atlas.paths.width + e.x as u32 + mx) as usize]
        };
        assert!(a.w >= 20 && b.w < a.w && b.h == a.h, "{a:?} {b:?}");
        assert_eq!(at(a, 15, 10), 255);
        assert_eq!(at(b, 5, 10), 255);
        // Its mask stops a pixel past the clip, though the square goes on.
        assert!(b.left as i32 + b.w as i32 <= 12, "{b:?}");
    }

    #[test]
    fn a_turned_clip_cuts_inside_its_bounds() {
        let mut atlas = Atlas::new(1.0);
        // The square shown only above its diagonal.
        let mut corner = vec![
            0.0, 0.0, 0.0, 1.0, 20.0, 0.0, 1.0, 20.0, 20.0, 1.0, 0.0, 20.0, 3.0,
        ];
        corner.extend_from_slice(&[4.0, 3.0, 0.0, 0.0, 20.0, 0.0, 0.0, 20.0]);
        let e = atlas.path(&corner, 0.0, 0, 0, 0, None);
        let at = |x: i32, y: i32| {
            let (mx, my) = ((x - e.left as i32) as u32, (y - e.top as i32) as u32);
            atlas.paths.pixels[((e.y as u32 + my) * atlas.paths.width + e.x as u32 + mx) as usize]
        };
        assert_eq!(at(4, 4), 255);
        assert_eq!(at(15, 15), 0);
    }

    #[test]
    fn a_path_mask_is_drawn_at_its_phase() {
        let mut atlas = Atlas::new(1.0);
        let triangle = [0.0, 0.0, 0.0, 1.0, 9.5, 0.0, 1.0, 0.0, 9.5, 3.0];
        let a = atlas.path(&triangle, 0.0, 0, 0, 0, None);
        let b = atlas.path(&triangle, 0.0, 0, 2, 0, None);
        assert_ne!(a, b);
        assert_eq!(atlas.path(&triangle, 0.0, 0, 0, 0, None), a);
    }

    /// A square path `side` points wide, as path data.
    fn square(side: f32) -> Vec<f32> {
        vec![
            0.0, 0.0, 0.0, 1.0, side, 0.0, 1.0, side, side, 1.0, 0.0, side, 3.0,
        ]
    }

    #[test]
    fn a_path_too_big_for_its_sheet_is_drawn_smaller() {
        let mut atlas = Atlas::new(1.0);
        let wide = [
            0.0, 0.0, 0.0, 1.0, 6000.0, 0.0, 1.0, 6000.0, 20.0, 1.0, 0.0, 20.0, 3.0,
        ];
        let e = atlas.path(&wide, 0.0, 0, 0, 0, None);
        assert_eq!(e.div, 2, "{e:?}");
        assert!(
            e.w as u32 <= atlas.paths.width && e.w as u32 * 2 >= 6000,
            "{e:?}"
        );
        let row = (e.y as u32 + e.h as u32 / 2) * atlas.paths.width;
        assert_eq!(
            atlas.paths.pixels[(row + e.x as u32 + e.w as u32 / 2) as usize],
            255
        );
        // One that fits is drawn at its size.
        assert!(atlas.path(&square(100.0), 0.0, 0, 0, 0, None).div <= 1);
    }

    #[test]
    fn a_sheet_with_no_room_says_so_until_cleared() {
        let mut atlas = Atlas::new(1.0);
        let mut side = 1000.0;
        while atlas.path(&square(side), 0.0, 0, 0, 0, None).w > 0 {
            assert!(!atlas.paths.full);
            side += 1.0;
        }
        assert!(atlas.paths.full && !atlas.glyphs.full);
        atlas.clear_paths();
        assert!(!atlas.paths.full);
        assert!(atlas.path(&square(side), 0.0, 0, 0, 0, None).w > 0);
    }

    #[test]
    fn a_tight_sheet_draws_masks_smaller_rather_than_not_at_all() {
        let mut atlas = Atlas::new(1.0);
        atlas.paths.tight = true;
        let entries: Vec<AtlasEntry> = (0..24)
            .map(|k| atlas.path(&square(1000.0 + k as f32), 0.0, 0, 0, 0, None))
            .collect();
        // Twenty-four squares 1000 wide, where sixteen fill the sheet: all
        // drawn, at half the size.
        assert!(entries.iter().all(|e| e.w > 0 && e.div == 2), "{entries:?}");
        assert!(!atlas.paths.full);
        // A small one keeps its size.
        assert!(atlas.path(&square(100.0), 0.0, 0, 0, 0, None).div <= 1);
    }

    #[test]
    fn a_tight_sheet_draws_smaller_any_mask_with_no_room() {
        let mut atlas = Atlas::new(1.0);
        atlas.paths.tight = true;
        // A hundred and twenty squares 400 wide, where a hundred fill the
        // sheet: the last ones drawn as much smaller as the room left needs.
        let entries: Vec<AtlasEntry> = (0..120)
            .map(|k| atlas.path(&square(400.0 + k as f32 / 8.0), 0.0, 0, 0, 0, None))
            .collect();
        assert!(entries.iter().all(|e| e.w > 0));
        assert!(
            entries[0].div <= 1 && entries[119].div >= 2,
            "{:?}",
            entries[119]
        );
    }

    #[test]
    fn masks_a_little_taller_share_a_shelf() {
        let mut atlas = Atlas::new(1.0);
        // Eight 100 wide, each a point taller than the one before: one shelf.
        let ys: Vec<u16> = (0..8)
            .map(|k| {
                let h = 100.0 + k as f32;
                let d = [
                    0.0, 0.0, 0.0, 1.0, 100.0, 0.0, 1.0, 100.0, h, 1.0, 0.0, h, 3.0,
                ];
                atlas.path(&d, 0.0, 0, 0, 0, None).y
            })
            .collect();
        assert!(ys.iter().all(|&y| y == ys[0]), "{ys:?}");
    }

    #[test]
    fn a_mask_covers_no_more_than_can_show() {
        let mut atlas = Atlas::new(1.0);
        // A bar 10000 points long, of which 200 show.
        let bar = [
            0.0, 0.0, 0.0, 1.0, 10000.0, 0.0, 1.0, 10000.0, 4.0, 1.0, 0.0, 4.0, 3.0,
        ];
        let e = atlas.path(&bar, 0.0, 0, 0, 0, Some([0, 0, 200, 20]));
        assert!(e.w <= 202 && e.div <= 1, "{e:?}");
        // What shows is another mask than the whole bar's.
        assert_ne!(atlas.path(&bar, 0.0, 0, 0, 0, None), e);
    }
}
