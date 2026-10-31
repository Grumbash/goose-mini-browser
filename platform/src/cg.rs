//! The C functions of Core Foundation, Core Graphics, Core Text and ImageIO that
//! text and screenshots need. A few dozen stable calls, declared here rather
//! than through another binding crate, and one owner type that releases them.
#![allow(non_upper_case_globals, non_snake_case, dead_code)]

use std::ffi::c_void;

pub type CFTypeRef = *const c_void;
pub type CFIndex = isize;
pub type CGGlyph = u16;

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct CGPoint {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct CGSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CGAffineTransform {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub tx: f64,
    pub ty: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CFRange {
    pub location: CFIndex,
    pub length: CFIndex,
}

#[repr(C)]
pub struct CFDictionaryKeyCallBacks {
    version: CFIndex,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
    hash: *const c_void,
}

#[repr(C)]
pub struct CFDictionaryValueCallBacks {
    version: CFIndex,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}

#[repr(C)]
pub struct CFArrayCallBacks {
    version: CFIndex,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}

pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;
pub const kCFNumberSInt32Type: CFIndex = 3;
pub const kCFStringComposedCharacterCluster: CFIndex = 2;
pub const kCFNumberFloat64Type: CFIndex = 6;
pub const kCTFontManagerScopeProcess: u32 = 1;
pub const kCTFontUIFontSystem: u32 = 2;
pub const kCTFontTraitItalic: u32 = 1 << 0;
pub const kCTFontTraitBold: u32 = 1 << 1;
pub const kCTFontOrientationDefault: u32 = 0;
pub const kCTRunStatusRightToLeft: u32 = 1 << 0;
pub const kCGImageAlphaOnly: u32 = 7;
pub const kCGImageAlphaPremultipliedFirst: u32 = 2;
pub const kCGImageByteOrder32Little: u32 = 2 << 12;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    pub static kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
    pub static kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
    pub static kCFTypeArrayCallBacks: CFArrayCallBacks;
    pub fn CFArrayCreate(
        alloc: CFTypeRef,
        values: *const CFTypeRef,
        n: CFIndex,
        callbacks: *const CFArrayCallBacks,
    ) -> CFTypeRef;
    pub fn CFStringGetLength(s: CFTypeRef) -> CFIndex;
    pub fn CFStringGetRangeOfCharacterClusterAtIndex(
        s: CFTypeRef,
        index: CFIndex,
        kind: CFIndex,
    ) -> CFRange;
    pub fn CFRelease(cf: CFTypeRef);
    pub fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    pub fn CFEqual(a: CFTypeRef, b: CFTypeRef) -> u8;
    pub fn CFStringCreateWithCharacters(
        alloc: CFTypeRef,
        chars: *const u16,
        n: CFIndex,
    ) -> CFTypeRef;
    pub fn CFStringCreateWithBytes(
        alloc: CFTypeRef,
        bytes: *const u8,
        n: CFIndex,
        encoding: u32,
        external: u8,
    ) -> CFTypeRef;
    pub fn CFDictionaryCreate(
        alloc: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        n: CFIndex,
        key_callbacks: *const CFDictionaryKeyCallBacks,
        value_callbacks: *const CFDictionaryValueCallBacks,
    ) -> CFTypeRef;
    pub fn CFDictionaryGetValue(dict: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    pub fn CFAttributedStringCreate(
        alloc: CFTypeRef,
        s: CFTypeRef,
        attributes: CFTypeRef,
    ) -> CFTypeRef;
    pub fn CFArrayGetCount(array: CFTypeRef) -> CFIndex;
    pub fn CFArrayGetValueAtIndex(array: CFTypeRef, i: CFIndex) -> CFTypeRef;
    pub fn CFNumberCreate(alloc: CFTypeRef, kind: CFIndex, value: *const c_void) -> CFTypeRef;
    pub fn CFStringGetCString(s: CFTypeRef, buf: *mut u8, size: CFIndex, encoding: u32) -> bool;
    pub fn CFURLCreateFromFileSystemRepresentation(
        alloc: CFTypeRef,
        path: *const u8,
        len: CFIndex,
        is_directory: u8,
    ) -> CFTypeRef;
}

#[link(name = "CoreText", kind = "framework")]
unsafe extern "C" {
    pub static kCTFontAttributeName: CFTypeRef;
    pub static kCTFontFamilyNameAttribute: CFTypeRef;
    pub static kCTFontTraitsAttribute: CFTypeRef;
    pub static kCTFontWeightTrait: CFTypeRef;
    pub static kCTFontSymbolicTrait: CFTypeRef;
    pub static kCTFontVariationAttribute: CFTypeRef;
    pub static kCTFontFeatureSettingsAttribute: CFTypeRef;
    pub static kCTFontOpenTypeFeatureTag: CFTypeRef;
    pub static kCTFontOpenTypeFeatureValue: CFTypeRef;
    pub fn CTFontDescriptorCreateWithAttributes(attributes: CFTypeRef) -> CFTypeRef;
    pub fn CTFontCreateWithFontDescriptor(
        descriptor: CFTypeRef,
        size: f64,
        matrix: *const c_void,
    ) -> CFTypeRef;
    pub fn CTFontCopyFamilyName(font: CFTypeRef) -> CFTypeRef;
    pub fn CTFontCopyPostScriptName(font: CFTypeRef) -> CFTypeRef;
    pub fn CTFontManagerRegisterFontsForURL(
        url: CFTypeRef,
        scope: u32,
        error: *mut CFTypeRef,
    ) -> bool;
    pub fn CTFontCreateWithName(name: CFTypeRef, size: f64, matrix: *const c_void) -> CFTypeRef;
    pub fn CTFontCreateUIFontForLanguage(kind: u32, size: f64, language: CFTypeRef) -> CFTypeRef;
    pub fn CTFontCreateCopyWithSymbolicTraits(
        font: CFTypeRef,
        size: f64,
        matrix: *const c_void,
        value: u32,
        mask: u32,
    ) -> CFTypeRef;
    pub fn CTFontCreateCopyWithAttributes(
        font: CFTypeRef,
        size: f64,
        matrix: *const CGAffineTransform,
        attributes: CFTypeRef,
    ) -> CFTypeRef;
    pub fn CTFontGetSize(font: CFTypeRef) -> f64;
    pub fn CTFontGetAscent(font: CFTypeRef) -> f64;
    pub fn CTFontGetDescent(font: CFTypeRef) -> f64;
    pub fn CTFontGetLeading(font: CFTypeRef) -> f64;
    pub fn CTFontGetXHeight(font: CFTypeRef) -> f64;
    pub fn CTFontGetUnderlinePosition(font: CFTypeRef) -> f64;
    pub fn CTFontGetUnderlineThickness(font: CFTypeRef) -> f64;
    pub fn CTFontGetBoundingRectsForGlyphs(
        font: CFTypeRef,
        orientation: u32,
        glyphs: *const CGGlyph,
        rects: *mut CGRect,
        count: CFIndex,
    ) -> CGRect;
    pub fn CTFontDrawGlyphs(
        font: CFTypeRef,
        glyphs: *const CGGlyph,
        positions: *const CGPoint,
        count: usize,
        context: CFTypeRef,
    );
    pub fn CTLineCreateWithAttributedString(s: CFTypeRef) -> CFTypeRef;
    pub fn CTLineGetGlyphRuns(line: CFTypeRef) -> CFTypeRef;
    pub fn CTLineGetTypographicBounds(
        line: CFTypeRef,
        ascent: *mut f64,
        descent: *mut f64,
        leading: *mut f64,
    ) -> f64;
    pub fn CTRunGetGlyphCount(run: CFTypeRef) -> CFIndex;
    pub fn CTRunGetAttributes(run: CFTypeRef) -> CFTypeRef;
    pub fn CTRunGetStatus(run: CFTypeRef) -> u32;
    pub fn CTRunGetGlyphs(run: CFTypeRef, range: CFRange, out: *mut CGGlyph);
    pub fn CTRunGetPositions(run: CFTypeRef, range: CFRange, out: *mut CGPoint);
    pub fn CTRunGetStringIndices(run: CFTypeRef, range: CFRange, out: *mut CFIndex);
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    pub static kCGColorSpaceSRGB: CFTypeRef;
    pub fn CGColorSpaceCreateWithName(name: CFTypeRef) -> CFTypeRef;
    pub fn CGBitmapContextCreate(
        data: *mut c_void,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        space: CFTypeRef,
        info: u32,
    ) -> CFTypeRef;
    pub fn CGBitmapContextCreateImage(context: CFTypeRef) -> CFTypeRef;
    pub fn CGContextSetGrayFillColor(context: CFTypeRef, gray: f64, alpha: f64);
    pub fn CGContextTranslateCTM(context: CFTypeRef, tx: f64, ty: f64);
    pub fn CGContextScaleCTM(context: CFTypeRef, sx: f64, sy: f64);
    pub fn CGContextAddPath(context: CFTypeRef, path: CFTypeRef);
    pub fn CGContextFillPath(context: CFTypeRef);
    pub fn CGContextEOFillPath(context: CFTypeRef);
    pub fn CGContextClip(context: CFTypeRef);
    pub fn CGPathCreateMutable() -> CFTypeRef;
    pub fn CGPathMoveToPoint(path: CFTypeRef, m: *const c_void, x: f64, y: f64);
    pub fn CGPathAddLineToPoint(path: CFTypeRef, m: *const c_void, x: f64, y: f64);
    #[allow(clippy::too_many_arguments)]
    pub fn CGPathAddCurveToPoint(
        path: CFTypeRef,
        m: *const c_void,
        c1x: f64,
        c1y: f64,
        c2x: f64,
        c2y: f64,
        x: f64,
        y: f64,
    );
    pub fn CGPathCloseSubpath(path: CFTypeRef);
    pub fn CGPathIsEmpty(path: CFTypeRef) -> bool;
    pub fn CGPathGetPathBoundingBox(path: CFTypeRef) -> CGRect;
    pub fn CGPathCreateCopyByStrokingPath(
        path: CFTypeRef,
        m: *const c_void,
        width: f64,
        cap: i32,
        join: i32,
        miter_limit: f64,
    ) -> CFTypeRef;
    pub fn CGContextSetAllowsAntialiasing(context: CFTypeRef, allows: bool);
    pub fn CGContextSetShouldAntialias(context: CFTypeRef, should: bool);
    pub fn CGContextSetAllowsFontSmoothing(context: CFTypeRef, allows: bool);
    pub fn CGContextSetShouldSmoothFonts(context: CFTypeRef, should: bool);
    pub fn CGContextSetAllowsFontSubpixelPositioning(context: CFTypeRef, allows: bool);
    pub fn CGContextSetShouldSubpixelPositionFonts(context: CFTypeRef, should: bool);
    pub fn CGContextSetAllowsFontSubpixelQuantization(context: CFTypeRef, allows: bool);
    pub fn CGContextSetShouldSubpixelQuantizeFonts(context: CFTypeRef, should: bool);
}

#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    pub fn CGImageDestinationCreateWithURL(
        url: CFTypeRef,
        kind: CFTypeRef,
        count: usize,
        options: CFTypeRef,
    ) -> CFTypeRef;
    pub fn CGImageDestinationAddImage(dest: CFTypeRef, image: CFTypeRef, properties: CFTypeRef);
    pub fn CGImageDestinationFinalize(dest: CFTypeRef) -> bool;
}

/// Owns one Core Foundation reference (Core Graphics and Core Text objects are
/// CF types too) and releases it when dropped.
pub struct Cf(CFTypeRef);

impl Cf {
    /// Takes a reference the caller owns (from a Create or Copy function).
    /// `None` when the function returned null.
    pub fn take(p: CFTypeRef) -> Option<Cf> {
        if p.is_null() { None } else { Some(Cf(p)) }
    }

    /// Keeps a reference the caller was lent (from a Get function).
    pub fn retain(p: CFTypeRef) -> Option<Cf> {
        if p.is_null() {
            None
        } else {
            Some(Cf(unsafe { CFRetain(p) }))
        }
    }

    pub fn get(&self) -> CFTypeRef {
        self.0
    }
}

impl Drop for Cf {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

/// A CFString from UTF-8 that the caller knows is valid (names and types).
pub fn cf_str(s: &str) -> Option<Cf> {
    Cf::take(unsafe {
        CFStringCreateWithBytes(
            std::ptr::null(),
            s.as_ptr(),
            s.len() as CFIndex,
            kCFStringEncodingUTF8,
            0,
        )
    })
}
