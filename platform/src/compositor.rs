//! The compositor (docs/adr/0001, 0003). A display list becomes GPU instances
//! once, when Goose hands it over; a frame after that uploads nothing and only
//! moves the scroll offset, so scrolling never waits for the engine. A rect and
//! a glyph are the same instance, a quad that is either solid or a mask from
//! the glyph atlas, so a frame is one draw call per layer: the page, which
//! scrolls, and the overlay above it, which doesn't.

use std::cell::RefCell;
use std::ptr::{NonNull, null};
use std::time::Instant;

use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_foundation::NSString;
use objc2_metal::{
    MTLBlendFactor, MTLBuffer, MTLClearColor, MTLCommandBuffer, MTLCommandBufferStatus,
    MTLCommandEncoder, MTLCommandQueue, MTLCreateSystemDefaultDevice, MTLDevice, MTLLibrary,
    MTLLoadAction, MTLOrigin, MTLPixelFormat, MTLPrimitiveType, MTLRegion, MTLRenderCommandEncoder,
    MTLRenderPassDescriptor, MTLRenderPipelineDescriptor, MTLRenderPipelineState,
    MTLResourceOptions, MTLScissorRect, MTLSize, MTLStorageMode, MTLStoreAction, MTLTexture,
    MTLTextureDescriptor, MTLTextureUsage,
};
use objc2_quartz_core::CAMetalDrawable;

use crate::cg::*;
use crate::text::{Atlas, PHASES, Sheet, Text, unit_starts, with_text};
use crate::{ERR_ARGUMENT, ERR_METAL, ERR_NO_DEVICE, ERR_NOT_MAIN_THREAD, GSlice, guarded};

// Display item kinds; engine/layout.goose mirrors these numbers.
pub const ITEM_RECT: i32 = 1;
pub const ITEM_TEXT: i32 = 2;
pub const ITEM_BOX: i32 = 3;
pub const ITEM_PATH: i32 = 4;
// Kinds that draw nothing: 0 (dropped), and 5, where a box is under the
// pointer, which only hit testing reads.

// A box item's border style.
pub const BORDER_SOLID: i32 = 0;
pub const BORDER_DASHED: i32 = 1;

/// How many layers there may be: the interface, its pages and what moves over
/// them. Goose numbers them.
pub const MAX_LAYERS: usize = 64;

/// One display item, laid out as Goose's `struct DItem`: positions in points,
/// a text item's y on its baseline and its text a span of the text buffer. A
/// box is a rectangle with rounded corners (radii from the top left,
/// clockwise) filled with `color`, and borders inside its edge in one colour
/// and style: `border` points wide at the top, the others as they say. An
/// item with a clip (`clip_w` above 0) shows only inside that rectangle, its
/// corners rounded by `clip_tl`, `clip_tr`, `clip_br` and `clip_bl`. A
/// transformed item has a matrix (`m_a` … `m_f`, as CSS's matrix() takes
/// them, points to points; all 0: none), and its clip one that takes its
/// points to the clip's (`c_a` … `c_f`; all 0: they are the same). A second
/// clip (`oclip_w` above 0) cuts it square on the page, after its transform.
/// A text item's `spacing` goes after each of its characters (letter-spacing).
/// A path item draws `text_len` floats of path data from `text` (see Goose's
/// vector.goose), in points from its corner, filled, or stroked `size` points
/// wide, as its `font` (PATH_ flags) says.
#[repr(C, packed)]
#[derive(Clone, Copy, Default, Debug)]
pub struct DItem {
    pub kind: i32,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub color: u32, // 0xAARRGGBB
    pub font: i32,
    pub size: f32,
    pub text: i32,
    pub text_len: i32,
    pub node: i32,
    pub rad_tl: f32,
    pub rad_tr: f32,
    pub rad_br: f32,
    pub rad_bl: f32,
    pub border: f32,
    pub border_color: u32,
    pub border_style: i32,
    pub border_right: f32,
    pub border_bottom: f32,
    pub border_left: f32,
    pub clip_x: f32,
    pub clip_y: f32,
    pub clip_w: f32,
    pub clip_h: f32,
    pub clip_tl: f32,
    pub clip_tr: f32,
    pub clip_br: f32,
    pub clip_bl: f32,
    pub m_a: f32,
    pub m_b: f32,
    pub m_c: f32,
    pub m_d: f32,
    pub m_e: f32,
    pub m_f: f32,
    pub c_a: f32,
    pub c_b: f32,
    pub c_c: f32,
    pub c_d: f32,
    pub c_e: f32,
    pub c_f: f32,
    pub oclip_x: f32,
    pub oclip_y: f32,
    pub oclip_w: f32,
    pub oclip_h: f32,
    pub spacing: f32,
}

/// One quad, in device pixels: solid when `uv[2]` is 0, otherwise the atlas
/// mask at `uv` (in texels) times `color`, which is premultiplied: a glyph's,
/// or with `border[0]` 1 a path's, sampled between texels when `border[1]` is
/// 1 because it was drawn smaller. A box
/// (`border[2]` 1) is drawn by distance from its rounded edge: `radii` from
/// the top left, clockwise, and borders `widths` wide (top, right, bottom,
/// left) in `border_color`, dashed when `border[1]` is 1, over its fill. Any
/// quad with a `clip` (its width above 0) shows only inside it, its corners
/// rounded by `clip_radii`. A transformed quad (`xt[2]` 1) goes where the
/// matrix `xf` (a, b, c, d) and `xt` (e, f, in device pixels) take it, its
/// edges smoothed and glyphs sampled between texels; its clip is tested
/// where `cxf` and `cxt` take its points, when `cxt[2]` is 1. `oclip` (its
/// width above 0) cuts it square where it lands on the page.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct Instance {
    pub rect: [f32; 4],
    pub uv: [f32; 4],
    pub color: [f32; 4],
    pub radii: [f32; 4],
    pub border: [f32; 4],
    pub border_color: [f32; 4],
    pub widths: [f32; 4],
    pub clip: [f32; 4],
    pub clip_radii: [f32; 4],
    pub xf: [f32; 4],
    pub xt: [f32; 4],
    pub cxf: [f32; 4],
    pub cxt: [f32; 4],
    pub oclip: [f32; 4],
}

/// Where a layer goes, laid out as Goose's `struct Place`, in points: its
/// content's point (`scroll_x`, `scroll_y`) lands on the window's (`x`, `y`),
/// and the matrix `a`, `b`, `c`, `d` (as CSS's matrix() takes them; all 0 for
/// none) turns and scales the layer about there. With `clip_w` 0 or more it
/// shows only inside its clip, a rectangle in its own space measured from that
/// landing point, its corners rounded by `radius` (at most half its shorter
/// side); a clip with no area shows nothing, and `clip_w` below 0 is none.
/// `opacity` fades each thing in the layer, so where two overlap the one
/// below shows through: a layer isn't drawn to a texture of its own yet. It
/// is drawn over the layers of a lower `z`, or of the same `z` and a lower
/// number, and not at all when `shown` is 0. Its points are at most 1e7 from
/// 0, and its matrix's entries at most 1e4.
#[repr(C, packed)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Place {
    pub x: f32,
    pub y: f32,
    pub scroll_x: f32,
    pub scroll_y: f32,
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub clip_x: f32,
    pub clip_y: f32,
    pub clip_w: f32,
    pub clip_h: f32,
    pub radius: f32,
    pub opacity: f32,
    pub z: i32,
    pub shown: i32,
}

impl Default for Place {
    /// At the window's corner, unturned and unclipped, opaque and shown.
    fn default() -> Self {
        Place {
            x: 0.0,
            y: 0.0,
            scroll_x: 0.0,
            scroll_y: 0.0,
            a: 0.0,
            b: 0.0,
            c: 0.0,
            d: 0.0,
            clip_x: 0.0,
            clip_y: 0.0,
            clip_w: -1.0,
            clip_h: 0.0,
            radius: 0.0,
            opacity: 1.0,
            z: 0,
            shown: 1,
        }
    }
}

impl Place {
    /// Whether tp_place_layer takes it: within the bounds the type's comment
    /// gives (so nothing overflows once scaled, and NaN is out), a clip of no
    /// negative height, a radius of 0 or more, opacity from 0 to 1.
    fn valid(&self) -> bool {
        let points = [
            self.x,
            self.y,
            self.scroll_x,
            self.scroll_y,
            self.clip_x,
            self.clip_y,
            self.clip_w,
            self.clip_h,
            self.radius,
        ];
        let matrix = [self.a, self.b, self.c, self.d];
        points.iter().all(|v| v.abs() <= 1e7)
            && matrix.iter().all(|v| v.abs() <= 1e4)
            && (self.clip_w < 0.0 || self.clip_h >= 0.0)
            && self.radius >= 0.0
            && (0.0..=1.0).contains(&{ self.opacity })
    }

    /// Its matrix, or None for none (all 0, or the identity).
    fn matrix(&self) -> Option<[f32; 4]> {
        let m = [self.a, self.b, self.c, self.d];
        (m != [0.0; 4] && m != [1.0, 0.0, 0.0, 1.0]).then_some(m)
    }
}

/// What the shaders know of the layer being drawn, in device pixels: `view`
/// is the viewport's size and where the layer's landing point is; `scroll`
/// its content's point that lands there; `matrix` its turn and scale; `clip`
/// its clip in its own space (width 0: none); `style` the clip's radius, the
/// opacity, and 1 when the layer is turned or scaled.
#[repr(C)]
struct Uniforms {
    view: [f32; 4],
    scroll: [f32; 4],
    matrix: [f32; 4],
    clip: [f32; 4],
    style: [f32; 4],
}

const SHADERS: &str = r#"
#include <metal_stdlib>
using namespace metal;

struct Instance { float4 rect; float4 uv; float4 color; float4 radii; float4 border; float4 border_color; float4 widths; float4 clip; float4 clip_radii;
                  float4 xf; float4 xt; float4 cxf; float4 cxt; float4 oclip; };
struct Uniforms { float4 view; float4 scroll; float4 matrix; float4 clip; float4 style; };
struct Out {
    float4 position [[position]];
    float2 uv; float4 color; float textured;
    float2 local; float2 size; float4 radii; float4 border; float4 border_color; float4 widths; float4 clip; float4 clip_radii;
    float2 clip_pos; float smooth; float4 oclip; float2 page; float2 layer;
};

vertex Out quad_vertex(uint v [[vertex_id]], uint i [[instance_id]],
                       const device Instance* instances [[buffer(0)]],
                       constant Uniforms& u [[buffer(1)]]) {
    Instance q = instances[i];
    float2 corner = float2(v & 1, v >> 1);
    // A transformed box or rectangle, by its own transform or its layer's,
    // reaches a pixel or so further on screen, so that its edges' soft outer
    // half is drawn too.
    float2 lo = float2(0.0);
    float2 hi = q.rect.zw;
    if (max(q.xt.z, u.style.z) > 0.5 && q.uv.z == 0.0) {
        float own = q.xt.z > 0.5 ? min(length(q.xf.xy), length(q.xf.zw)) : 1.0;
        float layer = u.style.z > 0.5 ? min(length(u.matrix.xy), length(u.matrix.zw)) : 1.0;
        float pad = 1.0 / max(own * layer, 0.25);
        lo -= pad;
        hi += pad;
    }
    float2 local = mix(lo, hi, corner);
    // On the page, then where its transform takes it, then scrolled.
    float2 p = q.rect.xy + local;
    float2 t = p;
    if (q.xt.z > 0.5) {
        t = float2(q.xf.x * p.x + q.xf.z * p.y + q.xt.x, q.xf.y * p.x + q.xf.w * p.y + q.xt.y);
    }
    Out o;
    o.page = t;
    // Into the layer's own space, scrolled; then onto the window where its
    // place puts it, turned and scaled about there.
    float2 l = t - u.scroll.xy;
    o.layer = l;
    float2 w = u.view.zw + float2(u.matrix.x * l.x + u.matrix.z * l.y, u.matrix.y * l.x + u.matrix.w * l.y);
    o.position = float4(w.x / u.view.x * 2.0 - 1.0, 1.0 - w.y / u.view.y * 2.0, 0.0, 1.0);
    o.uv = q.uv.xy + corner * q.uv.zw;
    o.color = q.color;
    o.textured = q.uv.z > 0.0 ? 1.0 : 0.0;
    o.local = local;
    o.size = q.rect.zw;
    o.radii = q.radii;
    o.border = q.border;
    o.border_color = q.border_color;
    o.widths = q.widths;
    o.clip = q.clip;
    o.clip_radii = q.clip_radii;
    o.clip_pos = p;
    if (q.cxt.z > 0.5) {
        o.clip_pos = float2(q.cxf.x * p.x + q.cxf.z * p.y + q.cxt.x, q.cxf.y * p.x + q.cxf.w * p.y + q.cxt.y);
    }
    // In a turned or scaled layer, every quad's edges and glyphs are smoothed
    // as a transformed quad's are.
    o.smooth = max(q.xt.z, u.style.z);
    o.oclip = q.oclip;
    return o;
}

// The signed distance from p (from the top left) to the edge of a rectangle
// `size` big with corner radii r (top left, top right, bottom right, bottom
// left): negative inside. Each corner's arc counts wherever p is in its
// square, which may reach past the middle: CSS lets one radius take most of
// a side when the corner next to it is square.
float rounded_rect(float2 p, float2 size, float4 r) {
    float2 q = abs(p - size * 0.5) - size * 0.5;
    float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0));
    float2 far = size - p;
    if (p.x < r.x && p.y < r.x) { d = max(d, length(p - r.x) - r.x); }
    if (far.x < r.y && p.y < r.y) { d = max(d, length(float2(far.x, p.y) - r.y) - r.y); }
    if (far.x < r.z && far.y < r.z) { d = max(d, length(far - r.z) - r.z); }
    if (p.x < r.w && far.y < r.w) { d = max(d, length(float2(p.x, far.y) - r.w) - r.w); }
    return d;
}

fragment float4 quad_fragment(Out in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              texture2d<float> atlas [[texture(0)]], texture2d<float> paths [[texture(1)]]) {
    // Inside the clip, if there is one, blended over its edge's pixel. A
    // transformed quad's distances shrink or grow on screen: dividing by how
    // fast they change per pixel keeps its edges one pixel soft.
    float dc = rounded_rect(in.clip_pos - in.clip.xy, in.clip.zw, in.clip_radii);
    float gc = in.smooth > 0.5 ? max(length(float2(dfdx(dc), dfdy(dc))), 0.0001) : 1.0;
    float cover = in.clip.z > 0.0 ? clamp(0.5 - dc / gc, 0.0, 1.0) : 1.0;
    if (in.oclip.z > 0.0) {
        float2 a = in.page - in.oclip.xy;
        float2 b = in.oclip.xy + in.oclip.zw - in.page;
        cover *= clamp(min(min(a.x, a.y), min(b.x, b.y)) + 0.5, 0.0, 1.0);
    }
    // Inside the layer's clip, its edge blended over a pixel, and faded.
    if (u.clip.z > 0.0) {
        float dl = rounded_rect(in.layer - u.clip.xy, u.clip.zw, float4(u.style.x));
        float gl = in.smooth > 0.5 ? max(length(float2(dfdx(dl), dfdy(dl))), 0.0001) : 1.0;
        cover *= clamp(0.5 - dl / gl, 0.0, 1.0);
    }
    cover *= u.style.y;
    if (in.textured > 0.5) {
        constexpr sampler nearest(coord::pixel, filter::nearest, address::clamp_to_edge);
        constexpr sampler between(coord::pixel, filter::linear, address::clamp_to_edge);
        bool soft = in.smooth > 0.5 || in.border.y > 0.5;
        float a = in.border.x > 0.5 ? (soft ? paths.sample(between, in.uv).r : paths.sample(nearest, in.uv).r)
                                    : (soft ? atlas.sample(between, in.uv).r : atlas.sample(nearest, in.uv).r);
        return in.color * (a * cover);
    }
    // A transformed rectangle's edges are smoothed as a box's are.
    if (in.border.z < 0.5 && in.smooth < 0.5) {
        return in.color * cover;
    }
    // A box: covered inside its rounded edge, its borders between that edge
    // and the padding edge (each side's width in, corners less the wider
    // border), each blended over a pixel.
    float d = rounded_rect(in.local, in.size, in.radii);
    float g = in.smooth > 0.5 ? max(length(float2(dfdx(d), dfdy(d))), 0.0001) : 1.0;
    float outer = clamp(0.5 - d / g, 0.0, 1.0);
    float4 w = in.widths;
    if (max(max(w.x, w.y), max(w.z, w.w)) <= 0.0) {
        return in.color * (outer * cover);
    }
    float2 inner_size = in.size - float2(w.w + w.y, w.x + w.z);
    float4 inner_radii = max(in.radii - float4(max(w.x, w.w), max(w.x, w.y), max(w.z, w.y), max(w.z, w.w)), 0.0);
    float inner = 0.0;
    if (inner_size.x > 0.0 && inner_size.y > 0.0) {
        inner = clamp(0.5 - rounded_rect(in.local - float2(w.w, w.x), inner_size, inner_radii) / g, 0.0, 1.0);
    }
    float ring = max(outer - inner, 0.0);
    float dash = 1.0;
    if (in.border.y > 0.5) {
        // Dashes along the nearest edge, three of its widths long, gaps as long.
        float2 p = in.local;
        bool side = min(p.x, in.size.x - p.x) < min(p.y, in.size.y - p.y);
        float along = side ? p.y : p.x;
        float width = side ? (p.x < in.size.x * 0.5 ? w.w : w.y) : (p.y < in.size.y * 0.5 ? w.x : w.z);
        float len = max(width * 3.0, 4.0);
        dash = fmod(along, len * 2.0) < len ? 1.0 : 0.0;
    }
    // The fill runs under the borders: it shows through a translucent one
    // and between dashes.
    return (in.border_color * (ring * dash) + in.color * (inner + ring * (1.0 - in.border_color.a * dash))) * cover;
}
"#;

/// What frames have cost since the last reset, laid out as Goose's
/// `struct FrameStats`. An interval of n refresh periods (n over 1.5) means the
/// display showed the last frame n times: n - 1 dropped frames.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct GpFrameStats {
    pub frames: i32,
    pub dropped: i32,
    pub refresh_hz: f32,
    pub max_interval_ms: f32,
    pub mean_interval_ms: f32,
    pub max_cpu_ms: f32, // building and submitting one frame
    pub max_gpu_ms: f32,
}

#[derive(Default)]
struct Stats {
    frames: i32,
    dropped: i32,
    intervals: i32,
    interval_sum: f64,
    max_interval: f64,
    max_cpu: f64,
    max_gpu: f64,
    last_present: Option<Instant>,
}

#[derive(Default)]
struct Layer {
    place: Place,
    instances: Vec<Instance>,
    buffer: Option<Retained<ProtocolObject<dyn MTLBuffer>>>,
    // What it was last set to, to build it again when the atlas starts again.
    items: Vec<DItem>,
    text: Vec<u8>,
    paths: Vec<f32>,
}

pub struct Compositor {
    pub device: Retained<ProtocolObject<dyn MTLDevice>>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    pipeline: Retained<ProtocolObject<dyn MTLRenderPipelineState>>,
    atlas: Retained<ProtocolObject<dyn MTLTexture>>, // the glyphs' sheet
    atlas_rows: u32,
    path_atlas: Retained<ProtocolObject<dyn MTLTexture>>, // the paths' sheet
    path_rows: u32,
    layers: Vec<Layer>,
    order: Vec<usize>, // the layers' numbers, in the order they are drawn
    scale: f64,        // device pixels per point, as the layers were last built
    stats: Stats,
    last_frame: Option<Retained<ProtocolObject<dyn MTLCommandBuffer>>>,
}

impl Compositor {
    fn new() -> Result<Self, i32> {
        let device = MTLCreateSystemDefaultDevice().ok_or(ERR_NO_DEVICE)?;
        let queue = device.newCommandQueue().ok_or(ERR_METAL)?;
        let library = device
            .newLibraryWithSource_options_error(&NSString::from_str(SHADERS), None)
            .map_err(|_| ERR_METAL)?;
        let vertex = library
            .newFunctionWithName(&NSString::from_str("quad_vertex"))
            .ok_or(ERR_METAL)?;
        let fragment = library
            .newFunctionWithName(&NSString::from_str("quad_fragment"))
            .ok_or(ERR_METAL)?;
        let desc = MTLRenderPipelineDescriptor::new();
        desc.setVertexFunction(Some(&vertex));
        desc.setFragmentFunction(Some(&fragment));
        let color = unsafe { desc.colorAttachments().objectAtIndexedSubscript(0) };
        color.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
        color.setBlendingEnabled(true);
        color.setSourceRGBBlendFactor(MTLBlendFactor::One);
        color.setSourceAlphaBlendFactor(MTLBlendFactor::One);
        color.setDestinationRGBBlendFactor(MTLBlendFactor::OneMinusSourceAlpha);
        color.setDestinationAlphaBlendFactor(MTLBlendFactor::OneMinusSourceAlpha);
        let pipeline = device
            .newRenderPipelineStateWithDescriptor_error(&desc)
            .map_err(|_| ERR_METAL)?;
        let atlas = new_atlas_texture(&device, 1024, 1)?;
        let path_atlas = new_atlas_texture(&device, 1024, 1)?;
        Ok(Compositor {
            device,
            queue,
            pipeline,
            atlas,
            atlas_rows: 1,
            path_atlas,
            path_rows: 1,
            layers: (0..MAX_LAYERS).map(|_| Layer::default()).collect(),
            order: (0..MAX_LAYERS).collect(),
            scale: 1.0,
            stats: Stats::default(),
            last_frame: None,
        })
    }

    /// Turns a display list into layer `layer`'s instances and uploads them,
    /// with any masks the atlas gained. When a sheet of the atlas runs out of
    /// room, or the backing scale changes, the atlas starts again and every
    /// layer is built again from what it was last set to. A path's mask that
    /// still doesn't fit is drawn smaller; a glyph draws nothing this time.
    fn set_layer(
        &mut self,
        layer: usize,
        items: &[DItem],
        text: &[u8],
        paths: &[f32],
        scale: f64,
    ) -> Result<(), i32> {
        let l = &mut self.layers[layer];
        l.items.clear();
        l.items.extend_from_slice(items);
        l.text.clear();
        l.text.extend_from_slice(text);
        l.paths.clear();
        l.paths.extend_from_slice(paths);
        self.scale = scale;
        let all = with_text(|t| {
            // Masks drawn for another backing scale are of no use now.
            t.atlas.paths.tight = false;
            let mut all = t.atlas.scale != scale;
            if all {
                t.atlas = Atlas::new(scale);
                for l in self.layers.iter_mut() {
                    build_layer(l, scale, t);
                }
            } else {
                build_layer(&mut self.layers[layer], scale, t);
            }
            if t.atlas.glyphs.full || t.atlas.paths.full {
                // A sheet ran out of room: it starts again with the masks the
                // layers draw now.
                if t.atlas.glyphs.full {
                    t.atlas.clear_glyphs();
                }
                if t.atlas.paths.full {
                    t.atlas.clear_paths();
                    t.atlas.paths.tight = true;
                }
                all = true;
                for l in self.layers.iter_mut() {
                    build_layer(l, scale, t);
                }
            }
            upload_sheet(
                &self.device,
                &mut self.atlas,
                &mut self.atlas_rows,
                &mut t.atlas.glyphs,
            )?;
            upload_sheet(
                &self.device,
                &mut self.path_atlas,
                &mut self.path_rows,
                &mut t.atlas.paths,
            )?;
            Ok::<bool, i32>(all)
        })?;
        for (i, l) in self.layers.iter_mut().enumerate() {
            if all || i == layer {
                l.buffer = buffer_of(&self.device, &l.instances)?;
            }
        }
        Ok(())
    }

    /// Puts layer `layer` where `place` says. Its content stays on the GPU as
    /// it is: the next frame sends the place, a few bytes, and nothing is built.
    fn place(&mut self, layer: usize, place: Place) {
        let z_changed = self.layers[layer].place.z != place.z;
        self.layers[layer].place = place;
        if z_changed {
            let layers = &self.layers;
            self.order.sort_by_key(|&i| (layers[i].place.z, i));
        }
    }

    /// Empties layer `layer`: its content, its place and its GPU buffer go.
    fn drop_layer(&mut self, layer: usize) {
        self.layers[layer] = Layer::default();
        let layers = &self.layers;
        self.order.sort_by_key(|&i| (layers[i].place.z, i));
    }

    /// Encodes one frame into `target`: cleared to `background`, then each
    /// layer in z order, where its place puts it.
    fn encode(
        &self,
        target: &ProtocolObject<dyn MTLTexture>,
        background: u32,
    ) -> Result<Retained<ProtocolObject<dyn MTLCommandBuffer>>, i32> {
        let pass = MTLRenderPassDescriptor::renderPassDescriptor();
        let [r, g, b, _] = premultiplied(background | 0xFF00_0000);
        unsafe {
            let color = pass.colorAttachments().objectAtIndexedSubscript(0);
            color.setTexture(Some(target));
            color.setLoadAction(MTLLoadAction::Clear);
            color.setClearColor(MTLClearColor {
                red: r as f64,
                green: g as f64,
                blue: b as f64,
                alpha: 1.0,
            });
            color.setStoreAction(MTLStoreAction::Store);
        }
        let commands = self.queue.commandBuffer().ok_or(ERR_METAL)?;
        let encoder = commands
            .renderCommandEncoderWithDescriptor(&pass)
            .ok_or(ERR_METAL)?;
        encoder.setRenderPipelineState(&self.pipeline);
        unsafe {
            encoder.setFragmentTexture_atIndex(Some(&self.atlas), 0);
            encoder.setFragmentTexture_atIndex(Some(&self.path_atlas), 1);
        }
        let (tw, th) = (target.width(), target.height());
        for &i in &self.order {
            let layer = &self.layers[i];
            let Some(buffer) = &layer.buffer else {
                continue;
            };
            let Some((u, scissor)) = uniforms(&layer.place, self.scale, tw, th) else {
                continue;
            };
            unsafe {
                encoder.setScissorRect(scissor);
                encoder.setVertexBuffer_offset_atIndex(Some(buffer), 0, 0);
                encoder.setVertexBytes_length_atIndex(
                    NonNull::from(&u).cast(),
                    std::mem::size_of::<Uniforms>(),
                    1,
                );
                encoder.setFragmentBytes_length_atIndex(
                    NonNull::from(&u).cast(),
                    std::mem::size_of::<Uniforms>(),
                    0,
                );
                encoder.drawPrimitives_vertexStart_vertexCount_instanceCount(
                    MTLPrimitiveType::TriangleStrip,
                    0,
                    4,
                    layer.instances.len(),
                );
            }
        }
        encoder.endEncoding();
        Ok(commands)
    }

    /// Draws a frame into a window's drawable and presents it, timing it.
    pub fn present(
        &mut self,
        drawable: &ProtocolObject<dyn CAMetalDrawable>,
        background: u32,
        refresh_hz: f64,
    ) -> Result<(), i32> {
        let start = Instant::now();
        if let Some(interval) = self
            .stats
            .last_present
            .map(|t| start.duration_since(t).as_secs_f64())
        {
            let s = &mut self.stats;
            s.intervals += 1;
            s.interval_sum += interval;
            s.max_interval = s.max_interval.max(interval);
            if refresh_hz > 0.0 && interval > 1.5 / refresh_hz {
                // Every refresh the interval spans after the first showed an
                // old frame again.
                s.dropped += ((interval * refresh_hz).round() as i32 - 1).max(1);
            }
        }
        // The frame before this one has finished on the GPU by now, almost
        // always: count its time without waiting for it.
        if let Some(last) = &self.last_frame
            && last.status() == MTLCommandBufferStatus::Completed
        {
            self.stats.max_gpu = self
                .stats
                .max_gpu
                .max(last.GPUEndTime() - last.GPUStartTime());
        }
        let texture = unsafe { drawable.texture() };
        let commands = self.encode(&texture, background)?;
        commands.presentDrawable(ProtocolObject::from_ref(drawable));
        commands.commit();
        self.last_frame = Some(commands);
        self.stats.frames += 1;
        self.stats.max_cpu = self.stats.max_cpu.max(start.elapsed().as_secs_f64());
        self.stats.last_present = Some(start);
        Ok(())
    }

    /// Draws a frame offscreen, `width` × `height` device pixels, and returns
    /// its pixels as BGRA rows.
    fn render_pixels(&self, width: usize, height: usize, background: u32) -> Result<Vec<u8>, i32> {
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                MTLPixelFormat::BGRA8Unorm,
                width,
                height,
                false,
            )
        };
        desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
        desc.setStorageMode(MTLStorageMode::Shared);
        let target = self
            .device
            .newTextureWithDescriptor(&desc)
            .ok_or(ERR_METAL)?;
        let commands = self.encode(&target, background)?;
        commands.commit();
        commands.waitUntilCompleted();
        let mut pixels = vec![0u8; width * height * 4];
        let region = MTLRegion {
            origin: MTLOrigin { x: 0, y: 0, z: 0 },
            size: MTLSize {
                width,
                height,
                depth: 1,
            },
        };
        let ptr = NonNull::new(pixels.as_mut_ptr() as *mut std::ffi::c_void).ok_or(ERR_METAL)?;
        unsafe { target.getBytes_bytesPerRow_fromRegion_mipmapLevel(ptr, width * 4, region, 0) };
        Ok(pixels)
    }
}

/// The uniforms that draw a layer placed at `p`, at `scale` device pixels per
/// point, on a target `tw` × `th`, and the scissor rectangle its clip allows;
/// None when it shows nothing. An unturned layer lands on whole device pixels,
/// so its glyphs stay on the pixel grid they were drawn for.
fn uniforms(p: &Place, scale: f64, tw: usize, th: usize) -> Option<(Uniforms, MTLScissorRect)> {
    if p.shown == 0 || p.opacity <= 0.0 {
        return None;
    }
    let k = scale as f32;
    let m = p.matrix();
    let snap = |v: f32| if m.is_none() { v.round() } else { v };
    let (ox, oy) = (snap(p.x * k), snap(p.y * k));
    let (sx, sy) = (snap(p.scroll_x * k), snap(p.scroll_y * k));
    let [a, b, c, d] = m.unwrap_or([1.0, 0.0, 0.0, 1.0]);
    let clipped = p.clip_w >= 0.0;
    if clipped && (p.clip_w == 0.0 || p.clip_h == 0.0) {
        return None;
    }
    let clip = if clipped {
        [p.clip_x * k, p.clip_y * k, p.clip_w * k, p.clip_h * k]
    } else {
        [0.0; 4]
    };
    // A radius past half the clip's shorter side would bite into its middle:
    // as in CSS, it is that half, a pill.
    let radius = if clipped {
        p.radius.min(p.clip_w.min(p.clip_h) / 2.0)
    } else {
        0.0
    };
    // The scissor: where the clip lands on the target, whole pixels out.
    let (mut x0, mut y0, mut x1, mut y1) = (0.0f32, 0.0f32, tw as f32, th as f32);
    if clipped {
        let corners = [
            (clip[0], clip[1]),
            (clip[0] + clip[2], clip[1]),
            (clip[0], clip[1] + clip[3]),
            (clip[0] + clip[2], clip[1] + clip[3]),
        ];
        let land = |(x, y): (f32, f32)| (ox + a * x + c * y, oy + b * x + d * y);
        let (mut lx0, mut ly0, mut lx1, mut ly1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        for corner in corners {
            let (x, y) = land(corner);
            (lx0, ly0, lx1, ly1) = (lx0.min(x), ly0.min(y), lx1.max(x), ly1.max(y));
        }
        (x0, y0, x1, y1) = (
            x0.max(lx0.floor()),
            y0.max(ly0.floor()),
            x1.min(lx1.ceil()),
            y1.min(ly1.ceil()),
        );
    }
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let u = Uniforms {
        view: [tw as f32, th as f32, ox, oy],
        scroll: [sx, sy, 0.0, 0.0],
        matrix: [a, b, c, d],
        clip,
        style: [
            radius * k,
            p.opacity.min(1.0),
            if m.is_some() { 1.0 } else { 0.0 },
            0.0,
        ],
    };
    let scissor = MTLScissorRect {
        x: x0 as usize,
        y: y0 as usize,
        width: (x1 - x0) as usize,
        height: (y1 - y0) as usize,
    };
    Some((u, scissor))
}

/// Builds a layer's instances again from what it was last set to.
fn build_layer(layer: &mut Layer, scale: f64, t: &mut Text) {
    let mut instances = std::mem::take(&mut layer.instances);
    instances.clear();
    build(
        &layer.items,
        &layer.text,
        &layer.paths,
        scale,
        t,
        &mut instances,
    );
    layer.instances = instances;
}

/// Uploads the rows of `sheet` written since the last upload into `texture`,
/// all of it into a new texture when the sheet has grown; `rows` is how many
/// rows the texture has.
fn upload_sheet(
    device: &ProtocolObject<dyn MTLDevice>,
    texture: &mut Retained<ProtocolObject<dyn MTLTexture>>,
    rows: &mut u32,
    sheet: &mut Sheet,
) -> Result<(), i32> {
    let range = if *rows != sheet.height || texture.width() != sheet.width as usize {
        *texture = new_atlas_texture(device, sheet.width, sheet.height)?;
        *rows = sheet.height;
        Some((0, sheet.height))
    } else {
        sheet.dirty
    };
    sheet.dirty = None;
    let Some((first, end)) = range else {
        return Ok(());
    };
    if end <= first {
        return Ok(());
    }
    let region = MTLRegion {
        origin: MTLOrigin {
            x: 0,
            y: first as usize,
            z: 0,
        },
        size: MTLSize {
            width: sheet.width as usize,
            height: (end - first) as usize,
            depth: 1,
        },
    };
    let start = (first * sheet.width) as usize;
    let ptr =
        NonNull::new(sheet.pixels[start..].as_ptr() as *mut std::ffi::c_void).ok_or(ERR_METAL)?;
    unsafe {
        texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(
            region,
            0,
            ptr,
            sheet.width as usize,
        )
    };
    Ok(())
}

/// A Metal buffer holding `instances`, or None for none.
fn buffer_of(
    device: &ProtocolObject<dyn MTLDevice>,
    instances: &[Instance],
) -> Result<Option<Retained<ProtocolObject<dyn MTLBuffer>>>, i32> {
    if instances.is_empty() {
        return Ok(None);
    }
    let bytes = std::mem::size_of_val(instances);
    let ptr = NonNull::new(instances.as_ptr() as *mut std::ffi::c_void).ok_or(ERR_METAL)?;
    let buffer = unsafe {
        device.newBufferWithBytes_length_options(ptr, bytes, MTLResourceOptions::StorageModeShared)
    };
    buffer.map(Some).ok_or(ERR_METAL)
}

fn new_atlas_texture(
    device: &ProtocolObject<dyn MTLDevice>,
    width: u32,
    height: u32,
) -> Result<Retained<ProtocolObject<dyn MTLTexture>>, i32> {
    let desc = unsafe {
        MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            MTLPixelFormat::R8Unorm,
            width as usize,
            height.max(1) as usize,
            false,
        )
    };
    desc.setUsage(MTLTextureUsage::ShaderRead);
    desc.setStorageMode(MTLStorageMode::Shared);
    device.newTextureWithDescriptor(&desc).ok_or(ERR_METAL)
}

fn premultiplied(c: u32) -> [f32; 4] {
    let a = (c >> 24) as f32 / 255.0;
    let channel = |shift: u32| ((c >> shift) & 0xFF) as f32 / 255.0 * a;
    [channel(16), channel(8), channel(0), a]
}

/// The rectangle of an item at `scale`, in device pixels, its edges on whole
/// pixels; a hairline still shows, never less than one pixel.
fn snapped(x: f32, y: f32, w: f32, h: f32, scale: f64) -> [f32; 4] {
    let x0 = (x as f64 * scale).round();
    let y0 = (y as f64 * scale).round();
    let x1 = ((x + w) as f64 * scale).round().max(x0 + 1.0);
    let y1 = ((y + h) as f64 * scale).round().max(y0 + 1.0);
    [x0 as f32, y0 as f32, (x1 - x0) as f32, (y1 - y0) as f32]
}

/// Turns display items into instances at `scale` device pixels per point. Rect
/// and box edges snap to whole pixels; each glyph goes to the whole pixel left
/// of its pen position, with the rest taken by one of the atlas's subpixel
/// phases. Clips snap like rects.
pub fn build(
    items: &[DItem],
    text: &[u8],
    paths: &[f32],
    scale: f64,
    t: &mut Text,
    out: &mut Vec<Instance>,
) {
    let mut glyphs = Vec::new();
    let mut before = Vec::new(); // per byte of a spaced text, the units done before it
    let mut starts = Vec::new();
    for &item in items {
        if !(ITEM_RECT..=ITEM_PATH).contains(&{ item.kind }) {
            continue;
        }
        let DItem {
            clip_x,
            clip_y,
            clip_w,
            clip_h,
            clip_tl,
            clip_tr,
            clip_br,
            clip_bl,
            ..
        } = item;
        let clip = if clip_w > 0.0 && clip_h > 0.0 {
            snapped(clip_x, clip_y, clip_w, clip_h, scale)
        } else {
            [0.0; 4]
        };
        let k = scale as f32;
        let clip_radii = [clip_tl * k, clip_tr * k, clip_br * k, clip_bl * k];
        let DItem {
            oclip_x,
            oclip_y,
            oclip_w,
            oclip_h,
            ..
        } = item;
        let oclip = if oclip_w > 0.0 && oclip_h > 0.0 {
            snapped(oclip_x, oclip_y, oclip_w, oclip_h, scale)
        } else {
            [0.0; 4]
        };
        // Matrices map points to points; in device pixels only their
        // translations scale.
        let DItem {
            m_a,
            m_b,
            m_c,
            m_d,
            m_e,
            m_f,
            c_a,
            c_b,
            c_c,
            c_d,
            c_e,
            c_f,
            ..
        } = item;
        let transformed = m_a != 0.0 || m_b != 0.0 || m_c != 0.0 || m_d != 0.0;
        let (xf, xt) = if transformed {
            ([m_a, m_b, m_c, m_d], [m_e * k, m_f * k, 1.0, 0.0])
        } else {
            ([0.0; 4], [0.0; 4])
        };
        let (cxf, cxt) = if c_a != 0.0 || c_b != 0.0 || c_c != 0.0 || c_d != 0.0 {
            ([c_a, c_b, c_c, c_d], [c_e * k, c_f * k, 1.0, 0.0])
        } else {
            ([0.0; 4], [0.0; 4])
        };
        // What every quad of the item shares.
        let common = Instance {
            clip,
            clip_radii,
            xf,
            xt,
            cxf,
            cxt,
            oclip,
            ..Default::default()
        };
        let DItem {
            kind,
            x,
            y,
            w,
            h,
            color,
            font,
            size,
            text: start,
            text_len,
            ..
        } = item;
        let color = premultiplied(color);
        if kind == ITEM_RECT {
            if !(w > 0.0 && h > 0.0) {
                continue;
            }
            out.push(Instance {
                rect: snapped(x, y, w, h, scale),
                color,
                // A transformed rect is drawn as a box, so that its edges are smoothed.
                border: [0.0, 0.0, if transformed { 1.0 } else { 0.0 }, 0.0],
                ..common
            });
        } else if kind == ITEM_BOX {
            if !(w > 0.0 && h > 0.0) {
                continue;
            }
            let s = scale as f32;
            let DItem {
                rad_tl,
                rad_tr,
                rad_br,
                rad_bl,
                border,
                border_color,
                border_style,
                border_right,
                border_bottom,
                border_left,
                ..
            } = item;
            // A border thinner than a device pixel still shows, one pixel wide.
            let width = |b: f32| if b > 0.0 { (b * s).max(1.0) } else { 0.0 };
            let dashed = if border_style == BORDER_DASHED {
                1.0
            } else {
                0.0
            };
            out.push(Instance {
                rect: snapped(x, y, w, h, scale),
                uv: [0.0; 4],
                color,
                radii: [rad_tl * s, rad_tr * s, rad_br * s, rad_bl * s],
                border: [0.0, dashed, 1.0, 0.0],
                border_color: premultiplied(border_color),
                widths: [
                    width(border),
                    width(border_right),
                    width(border_bottom),
                    width(border_left),
                ],
                ..common
            });
        } else if kind == ITEM_TEXT {
            let (Ok(start), Ok(len)) = (usize::try_from(start), usize::try_from(text_len)) else {
                continue;
            };
            let Some(span) = text.get(start..start.saturating_add(len)) else {
                continue;
            };
            let Some(f) = t.fonts.get(font, size) else {
                continue;
            };
            glyphs.clear();
            if t.shaper.shape(&mut t.fonts, f, span, &mut glyphs).is_none() {
                continue;
            }
            let spacing = item.spacing;
            if spacing != 0.0 {
                // A unit's spacing comes after it: its own marks don't move.
                unit_starts(span, &mut starts);
                before.clear();
                let mut started = 0u32;
                for &s in &starts {
                    before.push(if s != 0 {
                        started
                    } else {
                        started.saturating_sub(1)
                    });
                    started += u32::from(s);
                }
            }
            let baseline = y as f64 * scale;
            for g in &glyphs {
                let spaced = if spacing != 0.0 {
                    spacing * *before.get(g.byte as usize).unwrap_or(&0) as f32
                } else {
                    0.0
                };
                let pen = (x as f64 + (g.x + spaced) as f64) * scale;
                let by = (baseline - g.y as f64 * scale).round();
                let mut px = pen.floor();
                let mut phase = ((pen - px) * PHASES as f64).round() as u32;
                if phase == PHASES {
                    px += 1.0;
                    phase = 0;
                }
                let e = t.atlas.glyph(&t.fonts, g.font, g.id, phase as u8);
                if e.w == 0 {
                    continue;
                }
                out.push(Instance {
                    rect: [
                        (px + e.left as f64) as f32,
                        (by - e.top as f64) as f32,
                        e.w as f32,
                        e.h as f32,
                    ],
                    uv: [e.x as f32, e.y as f32, e.w as f32, e.h as f32],
                    color,
                    ..common
                });
            }
        } else if kind == ITEM_PATH {
            let (Ok(start), Ok(len)) = (usize::try_from(start), usize::try_from(text_len)) else {
                continue;
            };
            let Some(data) = paths.get(start..start.saturating_add(len)) else {
                continue;
            };
            // Its corner on a whole pixel, the rest as a subpixel phase each way.
            let (ox, oy) = (x as f64 * scale, y as f64 * scale);
            let phase = |v: f64| {
                let p = ((v - v.floor()) * PHASES as f64).round() as u32;
                if p == PHASES {
                    (v.floor() + 1.0, 0)
                } else {
                    (v.floor(), p as u8)
                }
            };
            let ((px, phase_x), (py, phase_y)) = (phase(ox), phase(oy));
            // Unturned, it shows only inside its clips, so its mask needs no
            // more than that: in device pixels from its corner's pixel.
            let mut seen: Option<[i32; 4]> = None;
            if !transformed && cxt[2] == 0.0 {
                for r in [clip, oclip] {
                    if r[2] > 0.0 {
                        let b = [
                            (r[0] as f64 - px).floor() as i32,
                            (r[1] as f64 - py).floor() as i32,
                            (r[0] as f64 + r[2] as f64 - px).ceil() as i32,
                            (r[1] as f64 + r[3] as f64 - py).ceil() as i32,
                        ];
                        seen = Some(match seen {
                            Some(s) => [
                                s[0].max(b[0]),
                                s[1].max(b[1]),
                                s[2].min(b[2]),
                                s[3].min(b[3]),
                            ],
                            None => b,
                        });
                    }
                }
            }
            let e = t.atlas.path(data, size, font, phase_x, phase_y, seen);
            if e.w == 0 {
                continue;
            }
            // A mask drawn smaller is stretched back to its size.
            let div = e.div.max(1) as f32;
            out.push(Instance {
                rect: [
                    (px + e.left as f64) as f32,
                    (py + e.top as f64) as f32,
                    e.w as f32 * div,
                    e.h as f32 * div,
                ],
                uv: [e.x as f32, e.y as f32, e.w as f32, e.h as f32],
                color,
                border: [1.0, if e.div > 1 { 1.0 } else { 0.0 }, 0.0, 0.0],
                ..common
            });
        }
    }
}

thread_local! {
    static COMPOSITOR: RefCell<Option<Compositor>> = const { RefCell::new(None) };
}

/// Runs `f` on the compositor, creating it on first use.
pub fn with_compositor<R>(f: impl FnOnce(&mut Compositor) -> Result<R, i32>) -> Result<R, i32> {
    COMPOSITOR.with(|cell| {
        let mut c = cell.borrow_mut();
        if c.is_none() {
            *c = Some(Compositor::new()?);
        }
        f(c.as_mut().unwrap())
    })
}

/// Metal objects live on the main thread only (docs/adr/0005). Off it, the
/// entry points here refuse rather than set up a second compositor, one the
/// window never shows.
fn on_main_thread() -> Result<(), i32> {
    MainThreadMarker::new()
        .map(|_| ())
        .ok_or(ERR_NOT_MAIN_THREAD)
}

/// Sets Metal up (the device, the shaders and the pipeline) if it isn't yet.
/// `tp_open` does this for a window; without one, call it before drawing, so
/// the setup isn't counted as the first paint. ERR_NO_DEVICE on a Mac without
/// a Metal device.
#[unsafe(no_mangle)]
pub extern "C" fn tp_start_metal() -> i32 {
    guarded(|| {
        on_main_thread()?;
        start_metal()
    })
}

fn start_metal() -> Result<i32, i32> {
    with_compositor(|_| Ok(0))
}

/// Hands layer `layer` (0 to MAX_LAYERS - 1) a new display list. Positions
/// are in points, in the layer's own space (see Place); `scale` is device
/// pixels per point. The lists are copied, so Goose may reuse its arrays at
/// once.
#[unsafe(no_mangle)]
pub extern "C" fn tp_set_layer(
    layer: i32,
    items: GSlice<DItem>,
    text: GSlice<u8>,
    paths: GSlice<f32>,
    scale: f32,
) -> i32 {
    guarded(|| {
        on_main_thread()?;
        let items = unsafe { items.as_slice() }.ok_or(ERR_ARGUMENT)?;
        let text = unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?;
        // Goose's floats needn't be aligned: copied out one by one.
        let n = paths.count().ok_or(ERR_ARGUMENT)?;
        let paths: Vec<f32> = (0..n).map(|i| unsafe { paths.get(i) }).collect();
        if !(0..MAX_LAYERS as i32).contains(&layer) || !(scale > 0.0 && scale <= 8.0) {
            return Err(ERR_ARGUMENT);
        }
        with_compositor(|c| c.set_layer(layer as usize, items, text, &paths, scale as f64))?;
        Ok(0)
    })
}

/// Puts layer `layer` where `place` says (see Place). Its display list stays
/// on the GPU as it is: scrolling a page or moving a card costs no rebuild.
#[unsafe(no_mangle)]
pub extern "C" fn tp_place_layer(layer: i32, place: *const Place) -> i32 {
    guarded(|| {
        on_main_thread()?;
        if place.is_null() || !(0..MAX_LAYERS as i32).contains(&layer) {
            return Err(ERR_ARGUMENT);
        }
        let p = unsafe { place.read_unaligned() };
        if !p.valid() {
            return Err(ERR_ARGUMENT);
        }
        with_compositor(|c| {
            c.place(layer as usize, p);
            Ok(0)
        })
    })
}

/// Empties layer `layer`: its display list, its place and its GPU buffer go.
#[unsafe(no_mangle)]
pub extern "C" fn tp_drop_layer(layer: i32) -> i32 {
    guarded(|| {
        on_main_thread()?;
        if !(0..MAX_LAYERS as i32).contains(&layer) {
            return Err(ERR_ARGUMENT);
        }
        with_compositor(|c| {
            c.drop_layer(layer as usize);
            Ok(0)
        })
    })
}

/// Draws the layers offscreen where they are placed, `width` × `height`
/// points at `scale`, and writes a PNG to `path`. Needs no window.
#[unsafe(no_mangle)]
pub extern "C" fn tp_screenshot(
    path: GSlice<u8>,
    width: f32,
    height: f32,
    scale: f32,
    background: u32,
) -> i32 {
    guarded(|| {
        on_main_thread()?;
        let path = unsafe { path.as_slice() }.ok_or(ERR_ARGUMENT)?;
        let (w, h) = ((width * scale).round(), (height * scale).round());
        if path.is_empty() || !(w >= 1.0 && h >= 1.0 && w <= 16384.0 && h <= 16384.0) {
            return Err(ERR_ARGUMENT);
        }
        let mut pixels = with_compositor(|c| c.render_pixels(w as usize, h as usize, background))?;
        write_png(path, &mut pixels, w as usize, h as usize).ok_or(ERR_ARGUMENT)?;
        Ok(0)
    })
}

/// BGRA rows to a PNG file, through ImageIO.
fn write_png(path: &[u8], pixels: &mut [u8], width: usize, height: usize) -> Option<()> {
    unsafe {
        let space = Cf::take(CGColorSpaceCreateWithName(kCGColorSpaceSRGB))?;
        let context = Cf::take(CGBitmapContextCreate(
            pixels.as_mut_ptr().cast(),
            width,
            height,
            8,
            width * 4,
            space.get(),
            kCGImageAlphaPremultipliedFirst | kCGImageByteOrder32Little,
        ))?;
        let image = Cf::take(CGBitmapContextCreateImage(context.get()))?;
        let url = Cf::take(CFURLCreateFromFileSystemRepresentation(
            null(),
            path.as_ptr(),
            path.len() as CFIndex,
            0,
        ))?;
        let png = cf_str("public.png")?;
        let dest = Cf::take(CGImageDestinationCreateWithURL(
            url.get(),
            png.get(),
            1,
            null(),
        ))?;
        CGImageDestinationAddImage(dest.get(), image.get(), null());
        CGImageDestinationFinalize(dest.get()).then_some(())
    }
}

/// Writes the frame statistics gathered since the last reset to `out`.
#[unsafe(no_mangle)]
pub extern "C" fn tp_frame_stats(out: *mut GpFrameStats, reset: bool) -> i32 {
    guarded(|| {
        on_main_thread()?;
        if out.is_null() {
            return Err(ERR_ARGUMENT);
        }
        let refresh = crate::refresh_hz();
        with_compositor(|c| {
            let s = &c.stats;
            let stats = GpFrameStats {
                frames: s.frames,
                dropped: s.dropped,
                refresh_hz: refresh as f32,
                max_interval_ms: (s.max_interval * 1000.0) as f32,
                mean_interval_ms: if s.intervals > 0 {
                    (s.interval_sum / s.intervals as f64 * 1000.0) as f32
                } else {
                    0.0
                },
                max_cpu_ms: (s.max_cpu * 1000.0) as f32,
                max_gpu_ms: (s.max_gpu * 1000.0) as f32,
            };
            unsafe { out.write_unaligned(stats) };
            if reset {
                c.stats = Stats::default();
                c.last_frame = None; // its GPU time belongs before the reset
            }
            Ok(0)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::{PATH_CAP_ROUND, PATH_EVENODD};

    fn rect(x: f32, y: f32, w: f32, h: f32, color: u32) -> DItem {
        DItem {
            kind: ITEM_RECT,
            x,
            y,
            w,
            h,
            color,
            ..Default::default()
        }
    }

    /// A box: `w` × `h` points at (x, y), every corner rounded by `radius`,
    /// with a border `border` wide.
    #[allow(clippy::too_many_arguments)]
    fn boxed(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: u32,
        radius: f32,
        border: f32,
        border_color: u32,
        style: i32,
    ) -> DItem {
        DItem {
            kind: ITEM_BOX,
            x,
            y,
            w,
            h,
            color,
            rad_tl: radius,
            rad_tr: radius,
            rad_br: radius,
            rad_bl: radius,
            border,
            border_color,
            border_style: style,
            border_right: border,
            border_bottom: border,
            border_left: border,
            ..Default::default()
        }
    }

    #[test]
    fn items_match_the_goose_layout() {
        assert_eq!(std::mem::size_of::<DItem>(), 184);
        assert_eq!(std::mem::align_of::<DItem>(), 1);
        assert_eq!(std::mem::size_of::<GpFrameStats>(), 28);
        // The shader reads instances as fourteen float4s.
        assert_eq!(std::mem::size_of::<Instance>(), 224);
    }

    /// The BGRA pixels of `items` drawn offscreen on white, `w` × `h` at one
    /// pixel a point; None without a Metal device.
    fn drawn(items: &[DItem], w: usize, h: usize) -> Option<Vec<u8>> {
        drawn_at(items, w, h, 0.0)
    }

    /// `items` drawn `w` × `h` on white, the page scrolled down `scroll`.
    fn drawn_at(items: &[DItem], w: usize, h: usize, scroll: f64) -> Option<Vec<u8>> {
        drawn_with(items, &[], w, h, scroll)
    }

    /// `items` drawn `w` × `h` on white, with path data `paths`, the page
    /// scrolled down `scroll`.
    fn drawn_with(
        items: &[DItem],
        paths: &[f32],
        w: usize,
        h: usize,
        scroll: f64,
    ) -> Option<Vec<u8>> {
        MTLCreateSystemDefaultDevice()?;
        let pixels = with_compositor(|c| {
            c.set_layer(0, items, b"", paths, 1.0)?;
            c.place(
                0,
                Place {
                    scroll_y: scroll as f32,
                    ..Place::default()
                },
            );
            c.set_layer(1, &[], b"", &[], 1.0)?;
            c.place(1, Place::default());
            c.render_pixels(w, h, 0xFFFF_FFFF)
        })
        .unwrap();
        Some(pixels)
    }

    /// `items` drawn `w` × `h` on white at a pixel a point, as layer 0 at
    /// `place`, with layer 1 holding `under`, placed at `under_place`.
    fn drawn_placed(
        items: &[DItem],
        place: Place,
        under: &[DItem],
        under_place: Place,
        w: usize,
        h: usize,
    ) -> Option<Vec<u8>> {
        MTLCreateSystemDefaultDevice()?;
        let pixels = with_compositor(|c| {
            c.set_layer(0, items, b"", &[], 1.0)?;
            c.place(0, place);
            c.set_layer(1, under, b"", &[], 1.0)?;
            c.place(1, under_place);
            c.render_pixels(w, h, 0xFFFF_FFFF)
        })
        .unwrap();
        Some(pixels)
    }

    /// Pixel (x, y) of BGRA rows `w` wide.
    fn pixel(p: &[u8], w: usize, x: usize, y: usize) -> [u8; 4] {
        let i = (y * w + x) * 4;
        [p[i], p[i + 1], p[i + 2], p[i + 3]]
    }

    const RED: [u8; 4] = [0, 0, 255, 255];
    const BLUE: [u8; 4] = [255, 0, 0, 255];
    const WHITE: [u8; 4] = [255, 255, 255, 255];

    #[test]
    fn a_layer_lands_where_its_place_says() {
        // A red square 4 wide, its layer landing at (10, 6) with its content
        // scrolled 2 down: the square covers x 10 to 14 and y 4 to 8.
        let square = [rect(0.0, 0.0, 4.0, 4.0, 0xFFFF_0000)];
        let place = Place {
            x: 10.0,
            y: 6.0,
            scroll_y: 2.0,
            ..Place::default()
        };
        let Some(p) = drawn_placed(&square, place, &[], Place::default(), 20, 12) else {
            eprintln!("no Metal device here: layer places aren't checked");
            return;
        };
        assert_eq!(pixel(&p, 20, 11, 4), RED);
        assert_eq!(pixel(&p, 20, 13, 7), RED);
        assert_eq!(pixel(&p, 20, 11, 3), WHITE);
        assert_eq!(pixel(&p, 20, 9, 5), WHITE);
        assert_eq!(pixel(&p, 20, 14, 5), WHITE);
        // Clipped to 2 × 2 from where it lands: the rest of the square goes.
        let clipped = Place {
            clip_w: 2.0,
            clip_h: 2.0,
            ..place
        };
        let p = drawn_placed(&square, clipped, &[], Place::default(), 20, 12).unwrap();
        assert_eq!(pixel(&p, 20, 11, 7), RED);
        assert_eq!(pixel(&p, 20, 12, 7), WHITE);
        assert_eq!(pixel(&p, 20, 11, 5), WHITE);
    }

    #[test]
    fn a_layer_clip_rounds_its_corners() {
        let square = [rect(0.0, 0.0, 20.0, 20.0, 0xFFFF_0000)];
        let place = Place {
            clip_w: 20.0,
            clip_h: 20.0,
            radius: 10.0,
            ..Place::default()
        };
        let Some(p) = drawn_placed(&square, place, &[], Place::default(), 20, 20) else {
            return;
        };
        assert_eq!(pixel(&p, 20, 0, 0), WHITE);
        assert_eq!(pixel(&p, 20, 19, 19), WHITE);
        assert_eq!(pixel(&p, 20, 10, 10), RED);
        assert_eq!(pixel(&p, 20, 10, 2), RED);
    }

    #[test]
    fn a_layer_turns_fades_hides_and_stacks() {
        // A 4 × 2 bar turned a quarter clockwise about (10, 2): it covers x 8
        // to 10 and y 2 to 6 instead of x 10 to 14 and y 2 to 4.
        let bar = [rect(0.0, 0.0, 4.0, 2.0, 0xFFFF_0000)];
        let turned = Place {
            x: 10.0,
            y: 2.0,
            a: 0.0,
            b: 1.0,
            c: -1.0,
            d: 0.0,
            ..Place::default()
        };
        let Some(p) = drawn_placed(&bar, turned, &[], Place::default(), 16, 8) else {
            return;
        };
        assert_eq!(pixel(&p, 16, 9, 4), RED);
        assert_eq!(pixel(&p, 16, 12, 3), WHITE);
        // Half faded over white: half red.
        let square = [rect(0.0, 0.0, 4.0, 4.0, 0xFFFF_0000)];
        let faded = Place {
            opacity: 0.5,
            ..Place::default()
        };
        let p = drawn_placed(&square, faded, &[], Place::default(), 8, 8).unwrap();
        let g = pixel(&p, 8, 1, 1)[1];
        assert!((126..=129).contains(&g), "{g}");
        let hidden = Place {
            shown: 0,
            ..Place::default()
        };
        let p = drawn_placed(&square, hidden, &[], Place::default(), 8, 8).unwrap();
        assert_eq!(pixel(&p, 8, 1, 1), WHITE);
        // A blue square in layer 1: over layer 0 by its number, under it by a
        // lower z.
        let blue = [rect(0.0, 0.0, 4.0, 4.0, 0xFF00_00FF)];
        let p = drawn_placed(&square, Place::default(), &blue, Place::default(), 8, 8).unwrap();
        assert_eq!(pixel(&p, 8, 1, 1), BLUE);
        let below = Place {
            z: -1,
            ..Place::default()
        };
        let p = drawn_placed(&square, Place::default(), &blue, below, 8, 8).unwrap();
        assert_eq!(pixel(&p, 8, 1, 1), RED);
    }

    #[test]
    fn placing_a_layer_builds_nothing() {
        if MTLCreateSystemDefaultDevice().is_none() {
            return;
        }
        let items: Vec<DItem> = (0..100)
            .map(|k| rect(k as f32, 0.0, 1.0, 1.0, 0xFF00_0000))
            .collect();
        let (before, after) = with_compositor(|c| {
            c.set_layer(0, &items, b"", &[], 1.0)?;
            let buffer = |c: &Compositor| c.layers[0].buffer.as_ref().map(Retained::as_ptr);
            let before = buffer(c);
            c.place(
                0,
                Place {
                    scroll_y: 500.0,
                    x: 3.0,
                    ..Place::default()
                },
            );
            Ok((before, buffer(c)))
        })
        .unwrap();
        assert!(before.is_some());
        assert_eq!(before, after);
    }

    /// A path item at (x, y) drawing `len` floats of path data from `start`.
    fn path_item(
        x: f32,
        y: f32,
        start: i32,
        len: i32,
        color: u32,
        stroke: f32,
        flags: i32,
    ) -> DItem {
        DItem {
            kind: ITEM_PATH,
            x,
            y,
            w: 20.0,
            h: 20.0,
            color,
            text: start,
            text_len: len,
            size: stroke,
            font: flags,
            ..Default::default()
        }
    }

    #[test]
    fn paths_fill_and_stroke() {
        // A red triangle at (2, 2), its sides 16 long; a blue line 10 long at
        // (24, 10), stroked 4 wide with round caps.
        let paths = [
            0.0, 0.0, 0.0, 1.0, 16.0, 0.0, 1.0, 0.0, 16.0, 3.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0,
        ];
        let items = [
            path_item(2.0, 2.0, 0, 10, 0xFFFF_0000, 0.0, 0),
            path_item(24.0, 10.0, 10, 6, 0xFF00_00FF, 4.0, PATH_CAP_ROUND),
        ];
        let Some(p) = drawn_with(&items, &paths, 40, 20, 0.0) else {
            eprintln!("no Metal device here: paths aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 40 + x) * 4..(y * 40 + x) * 4 + 4];
        assert_eq!(at(4, 4), [0, 0, 255, 255]); // inside the triangle: red (BGRA)
        assert_eq!(at(16, 16), [255, 255, 255, 255]); // past its long side
        assert_eq!(at(30, 10), [255, 0, 0, 255]); // on the line: blue
        assert_eq!(at(23, 10), [255, 0, 0, 255]); // its round cap, before its start
        assert_eq!(at(30, 14), [255, 255, 255, 255]); // beyond half its width
    }

    #[test]
    fn even_odd_fills_leave_holes() {
        // A square 16 across with a square 8 across in its middle, the same
        // way round: nonzero fills both, evenodd leaves the middle out.
        let square = |x: f32, y: f32, s: f32| {
            vec![
                0.0,
                x,
                y,
                1.0,
                x + s,
                y,
                1.0,
                x + s,
                y + s,
                1.0,
                x,
                y + s,
                3.0,
            ]
        };
        let mut paths = square(0.0, 0.0, 16.0);
        paths.extend(square(4.0, 4.0, 8.0));
        let n = paths.len() as i32;
        let items = [
            path_item(0.0, 0.0, 0, n, 0xFFFF_0000, 0.0, 0),
            path_item(20.0, 0.0, 0, n, 0xFFFF_0000, 0.0, PATH_EVENODD),
        ];
        let Some(p) = drawn_with(&items, &paths, 40, 16, 0.0) else {
            eprintln!("no Metal device here: fill rules aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 40 + x) * 4..(y * 40 + x) * 4 + 4];
        assert_eq!(at(8, 8), [0, 0, 255, 255]);
        assert_eq!(at(28, 8), [255, 255, 255, 255]);
        assert_eq!(at(21, 2), [0, 0, 255, 255]);
    }

    #[test]
    fn one_mask_serves_a_path_everywhere() {
        // The same path twice, a whole pixel apart: one place in the atlas.
        let paths = [0.0, 0.0, 0.0, 1.0, 6.0, 0.0, 1.0, 0.0, 6.0, 3.0];
        let mut out = Vec::new();
        with_text(|t| {
            build(
                &[
                    path_item(1.0, 1.0, 0, 10, 0xFF00_0000, 0.0, 0),
                    path_item(9.0, 3.0, 0, 10, 0xFF00_0000, 0.0, 0),
                ],
                b"",
                &paths,
                2.0,
                t,
                &mut out,
            )
        });
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].uv, out[1].uv);
        assert_eq!(out[1].rect[0] - out[0].rect[0], 16.0);
    }

    #[test]
    fn boxes_round_their_corners_and_draw_their_borders() {
        // A circle 16 across, red, with a blue border 2 wide.
        let item = boxed(
            0.0,
            0.0,
            16.0,
            16.0,
            0xFFFF_0000,
            8.0,
            2.0,
            0xFF00_00FF,
            BORDER_SOLID,
        );
        let Some(p) = drawn(&[item], 16, 16) else {
            eprintln!("no Metal device here: boxes aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 16 + x) * 4..(y * 16 + x) * 4 + 4];
        assert_eq!(at(0, 0), [255, 255, 255, 255]); // outside the circle: the background
        assert_eq!(at(15, 15), [255, 255, 255, 255]);
        assert_eq!(at(8, 8), [0, 0, 255, 255]); // the middle: the fill (BGRA)
        let edge = at(8, 0); // on the top edge: the border
        assert!(edge[0] > 200 && edge[2] < 60, "{edge:?}");
    }

    #[test]
    fn dashed_borders_alternate_along_an_edge() {
        // 40 × 10, no fill, a dashed border 2 wide: dashes 6 long, gaps 6.
        let item = boxed(
            0.0,
            0.0,
            40.0,
            10.0,
            0,
            0.0,
            2.0,
            0xFF00_0000,
            BORDER_DASHED,
        );
        let Some(p) = drawn(&[item], 40, 10) else {
            eprintln!("no Metal device here: dashes aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 40 + x) * 4..(y * 40 + x) * 4 + 4];
        assert_eq!(at(14, 0), [0, 0, 0, 255]); // a dash
        assert_eq!(at(20, 0), [255, 255, 255, 255]); // a gap
        assert_eq!(at(20, 5), [255, 255, 255, 255]); // inside: no fill
    }

    #[test]
    fn dashes_run_along_the_nearest_edge() {
        // 60 × 6, dashed 2 wide: dashes 6 long. Near the end of a long edge the
        // dashes still run along it (x 55 is in a gap), not down the short one.
        let item = boxed(0.0, 0.0, 60.0, 6.0, 0, 0.0, 2.0, 0xFF00_0000, BORDER_DASHED);
        let Some(p) = drawn(&[item], 60, 6) else {
            eprintln!("no Metal device here: dashes aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 60 + x) * 4..(y * 60 + x) * 4 + 4];
        assert_eq!(at(55, 0), [255, 255, 255, 255]); // a gap
        assert_eq!(at(50, 0), [0, 0, 0, 255]); // a dash
        assert_eq!(at(0, 3), [0, 0, 0, 255]); // the short side, a dash
    }

    #[test]
    fn borders_differ_by_side_and_the_fill_runs_under_them() {
        // A tab: red, top corners rounded 8, blue borders 2 wide except along
        // the bottom. Then a square of red under a half-transparent blue border.
        let mut tab = boxed(
            0.0,
            0.0,
            20.0,
            20.0,
            0xFFFF_0000,
            8.0,
            2.0,
            0xFF00_00FF,
            BORDER_SOLID,
        );
        (tab.rad_br, tab.rad_bl, tab.border_bottom) = (0.0, 0.0, 0.0);
        let under = boxed(
            20.0,
            0.0,
            10.0,
            10.0,
            0xFFFF_0000,
            0.0,
            2.0,
            0x8000_00FF,
            BORDER_SOLID,
        );
        let Some(p) = drawn(&[tab, under], 30, 20) else {
            eprintln!("no Metal device here: borders aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 30 + x) * 4..(y * 30 + x) * 4 + 4];
        assert_eq!(at(0, 0), [255, 255, 255, 255]); // the rounded corner, away
        assert_eq!(at(10, 0), [255, 0, 0, 255]); // the top border, blue (BGRA)
        assert_eq!(at(10, 19), [0, 0, 255, 255]); // no bottom border: the fill
        assert_eq!(at(0, 19), [255, 0, 0, 255]); // the left border, square below
        let both = at(20, 5); // red under half blue
        assert!(both[0] > 100 && both[2] > 100 && both[1] < 30, "{both:?}");
    }

    #[test]
    fn clips_cut_what_is_outside_them_and_round_their_corners() {
        // A red square 16 across, cut to its left half; a blue one, cut to a
        // circle.
        let mut half = rect(0.0, 0.0, 16.0, 16.0, 0xFFFF_0000);
        (half.clip_x, half.clip_y, half.clip_w, half.clip_h) = (0.0, 0.0, 8.0, 16.0);
        let mut round = rect(16.0, 0.0, 16.0, 16.0, 0xFF00_00FF);
        (round.clip_x, round.clip_y, round.clip_w, round.clip_h) = (16.0, 0.0, 16.0, 16.0);
        (round.clip_tl, round.clip_tr, round.clip_br, round.clip_bl) = (8.0, 8.0, 8.0, 8.0);
        let Some(p) = drawn(&[half, round], 32, 16) else {
            eprintln!("no Metal device here: clips aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 32 + x) * 4..(y * 32 + x) * 4 + 4];
        assert_eq!(at(4, 8), [0, 0, 255, 255]); // inside the clip: red (BGRA)
        assert_eq!(at(12, 8), [255, 255, 255, 255]); // past it: the background
        assert_eq!(at(24, 8), [255, 0, 0, 255]); // the circle's middle: blue
        assert_eq!(at(16, 0), [255, 255, 255, 255]); // its corner, rounded away
    }

    #[test]
    fn a_corner_rounds_past_the_middle() {
        // A red box 40 × 20 with only its top left corner rounded, by 16: more
        // than half its height. Its arc still curves away below the middle,
        // where the corner below it is square.
        let mut item = boxed(0.0, 0.0, 40.0, 20.0, 0xFFFF_0000, 0.0, 0.0, 0, BORDER_SOLID);
        item.rad_tl = 16.0;
        let Some(p) = drawn(&[item], 40, 20) else {
            eprintln!("no Metal device here: corners aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 40 + x) * 4..(y * 40 + x) * 4 + 4];
        assert!(at(0, 10)[0] > 200, "{:?}", at(0, 10)); // outside the arc, below the middle: the background
        assert_eq!(at(2, 14), [0, 0, 255, 255]); // inside it: red
        assert_eq!(at(0, 19), [0, 0, 255, 255]); // the square corner below
    }

    #[test]
    fn outer_clips_cut_where_items_land() {
        // A red square 16 across at (0, 8), moved 10 right by its matrix, in a
        // second clip 20 wide on the page round it, the page scrolled down 8:
        // it shows from 10 to 20 across, all the way down, not past.
        let mut red = rect(0.0, 8.0, 16.0, 16.0, 0xFFFF_0000);
        (red.m_a, red.m_d, red.m_e) = (1.0, 1.0, 10.0);
        (red.oclip_x, red.oclip_y, red.oclip_w, red.oclip_h) = (0.0, 8.0, 20.0, 16.0);
        let Some(p) = drawn_at(&[red], 32, 16, 8.0) else {
            eprintln!("no Metal device here: outer clips aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 32 + x) * 4..(y * 32 + x) * 4 + 4];
        assert_eq!(at(5, 8), [255, 255, 255, 255]); // where it was: the background
        assert_eq!(at(15, 2), [0, 0, 255, 255]); // inside the clip, at its top: red (BGRA)
        assert_eq!(at(15, 13), [0, 0, 255, 255]); // and at its bottom
        assert_eq!(at(23, 8), [255, 255, 255, 255]); // past the clip: cut
    }

    #[test]
    fn turned_edges_are_soft_on_both_sides() {
        // A black square 20 across turned 20° about its middle: the pixels
        // its edges cross are partly covered outside the edge as well as
        // inside, so some are covered less than half.
        let (s, c) = (20f32.to_radians().sin(), 20f32.to_radians().cos());
        let mut black = rect(10.0, 10.0, 20.0, 20.0, 0xFF00_0000);
        (black.m_a, black.m_b, black.m_c, black.m_d) = (c, s, -s, c);
        (black.m_e, black.m_f) = (20.0 - (c * 20.0 - s * 20.0), 20.0 - (s * 20.0 + c * 20.0));
        let Some(p) = drawn(&[black], 40, 40) else {
            eprintln!("no Metal device here: edges aren't checked");
            return;
        };
        let light = p
            .chunks(4)
            .filter(|px| (0.1..0.45).contains(&(1.0 - px[0] as f32 / 255.0)))
            .count();
        assert!(light > 20, "{light} pixels a little covered");
    }

    #[test]
    fn transforms_turn_quads_and_their_clips_follow() {
        // A red square 10 across at (10, 10), turned 45° about its middle: a
        // diamond. Then the same diamond in blue, cut to the top 10 rows of
        // the screen, which aren't turned: its clip matrix is its own, and
        // only its tip, above where the square was, shows.
        let (c, s) = (
            std::f32::consts::FRAC_1_SQRT_2,
            std::f32::consts::FRAC_1_SQRT_2,
        );
        let turn = |it: &mut DItem| {
            (it.m_a, it.m_b, it.m_c, it.m_d) = (c, s, -s, c);
            (it.m_e, it.m_f) = (15.0 - (c * 15.0 - s * 15.0), 15.0 - (s * 15.0 + c * 15.0));
        };
        let mut red = rect(10.0, 10.0, 10.0, 10.0, 0xFFFF_0000);
        turn(&mut red);
        let mut blue = rect(30.0, 10.0, 10.0, 10.0, 0xFF00_00FF);
        (blue.m_a, blue.m_b, blue.m_c, blue.m_d) = (c, s, -s, c);
        (blue.m_e, blue.m_f) = (35.0 - (c * 35.0 - s * 15.0), 15.0 - (s * 35.0 + c * 15.0));
        (blue.clip_x, blue.clip_y, blue.clip_w, blue.clip_h) = (0.0, 0.0, 50.0, 10.0);
        (blue.c_a, blue.c_b, blue.c_c, blue.c_d, blue.c_e, blue.c_f) =
            (blue.m_a, blue.m_b, blue.m_c, blue.m_d, blue.m_e, blue.m_f);
        let Some(p) = drawn(&[red, blue], 50, 30) else {
            eprintln!("no Metal device here: transforms aren't checked");
            return;
        };
        let at = |x: usize, y: usize| &p[(y * 50 + x) * 4..(y * 50 + x) * 4 + 4];
        assert_eq!(at(15, 9), [0, 0, 255, 255]); // above the square's top: the diamond's tip, red
        assert_eq!(at(10, 10), [255, 255, 255, 255]); // the square's corner, turned away
        assert_eq!(at(35, 9), [255, 0, 0, 255]); // the blue diamond's tip, inside the cut
        assert_eq!(at(35, 15), [255, 255, 255, 255]); // its middle, cut away
    }

    #[test]
    fn rects_snap_to_device_pixels_and_hairlines_stay() {
        let mut out = Vec::new();
        with_text(|t| {
            build(
                &[rect(0.3, 1.0, 10.2, 0.2, 0xFF00_0000)],
                b"",
                &[],
                2.0,
                t,
                &mut out,
            )
        });
        assert_eq!(out[0].rect, [1.0, 2.0, 20.0, 1.0]);
        assert_eq!(out[0].color, [0.0, 0.0, 0.0, 1.0]);
    }

    #[test]
    fn letter_spacing_goes_after_each_character() {
        // x with a combining circumflex, then b: twice, the second 10 points
        // apart per character. Its x and circumflex stay where they were, the
        // circumflex on its letter; its b, one character in, is 20 device
        // pixels (at 2x) further on.
        let plain = DItem {
            kind: ITEM_TEXT,
            y: 20.0,
            color: 0xFF1C_1C1C,
            size: 17.0,
            text: 0,
            text_len: 4,
            ..Default::default()
        };
        let spaced = DItem {
            spacing: 10.0,
            ..plain
        };
        let lefts = |item: DItem| {
            let mut out = Vec::new();
            with_text(|t| build(&[item], "x\u{302}b".as_bytes(), &[], 2.0, t, &mut out));
            out.iter().map(|q| q.rect[0]).collect::<Vec<_>>()
        };
        let (a, b) = (lefts(plain), lefts(spaced));
        assert_eq!(a.len(), 3, "{a:?}");
        assert_eq!((b[0], b[1]), (a[0], a[1]));
        assert_eq!(b[2] - a[2], 20.0);
    }

    #[test]
    fn text_becomes_glyph_quads_on_whole_pixels() {
        let item = DItem {
            kind: ITEM_TEXT,
            x: 10.3,
            y: 20.0,
            color: 0xFF1C_1C1C,
            size: 17.0,
            text: 0,
            text_len: 5,
            ..Default::default()
        };
        let mut out = Vec::new();
        with_text(|t| build(&[item], b"Tusk!", &[], 2.0, t, &mut out));
        assert_eq!(out.len(), 5);
        for q in &out {
            assert!(
                q.uv[2] > 0.0 && q.rect[0].fract() == 0.0 && q.rect[1].fract() == 0.0,
                "{q:?}"
            );
        }
        assert!(out.windows(2).all(|w| w[1].rect[0] > w[0].rect[0]));
    }

    #[test]
    fn a_frame_draws_its_layers_offscreen() {
        if MTLCreateSystemDefaultDevice().is_none() {
            eprintln!("no Metal device here: the offscreen frame isn't checked");
            return;
        }
        let pixels = with_compositor(|c| {
            c.set_layer(0, &[rect(2.0, 2.0, 4.0, 4.0, 0xFFFF_0000)], b"", &[], 1.0)?;
            c.place(
                0,
                Place {
                    scroll_y: 1.0,
                    ..Place::default()
                },
            );
            c.set_layer(1, &[rect(0.0, 0.0, 1.0, 1.0, 0xFF00_00FF)], b"", &[], 1.0)?;
            c.place(1, Place::default());
            c.render_pixels(8, 8, 0xFFFF_FFFF)
        })
        .unwrap();
        let at = |x: usize, y: usize| &pixels[(y * 8 + x) * 4..(y * 8 + x) * 4 + 4];
        assert_eq!(at(3, 1), [0, 0, 255, 255]); // the red rect, scrolled up by one pixel (BGRA)
        assert_eq!(at(3, 5), [255, 255, 255, 255]); // below it, the background
        assert_eq!(at(0, 0), [255, 0, 0, 255]); // the overlay doesn't scroll
    }

    #[test]
    fn calls_off_the_main_thread_are_refused() {
        // Test threads are not the main thread, where Metal objects live: every
        // entry point refuses, and none sets Metal up on this thread. The path
        // is empty, so a check that stopped refusing writes no file.
        let items = GSlice::<DItem> {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let text = GSlice::<u8> {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let path = GSlice::<u8> {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let paths = GSlice::<f32> {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let mut stats = GpFrameStats::default();
        assert_eq!(tp_start_metal(), ERR_NOT_MAIN_THREAD);
        assert_eq!(
            tp_set_layer(0, items, text, paths, 1.0),
            ERR_NOT_MAIN_THREAD
        );
        assert_eq!(
            tp_screenshot(path, 8.0, 8.0, 1.0, 0xFFFF_FFFF),
            ERR_NOT_MAIN_THREAD
        );
        assert_eq!(tp_place_layer(0, &Place::default()), ERR_NOT_MAIN_THREAD);
        assert_eq!(tp_drop_layer(0), ERR_NOT_MAIN_THREAD);
        assert_eq!(tp_frame_stats(&mut stats, false), ERR_NOT_MAIN_THREAD);
        assert!(COMPOSITOR.with(|cell| cell.borrow().is_none()));
    }

    #[test]
    fn metal_starts_once_before_anything_is_drawn() {
        // libtest runs each test on its own thread, so this one starts without
        // a compositor. Off the main thread tp_start_metal refuses, so this
        // checks what it runs.
        let started = || COMPOSITOR.with(|cell| cell.borrow().is_some());
        assert!(!started());
        if MTLCreateSystemDefaultDevice().is_none() {
            assert_eq!(start_metal(), Err(ERR_NO_DEVICE));
            assert!(!started());
            return;
        }
        assert_eq!(start_metal(), Ok(0));
        assert!(started());
        let queue = || with_compositor(|c| Ok(Retained::as_ptr(&c.queue))).unwrap();
        let first = queue();
        assert_eq!(start_metal(), Ok(0));
        assert_eq!(queue(), first); // the same compositor, not a second setup
    }

    #[test]
    fn a_full_path_sheet_starts_again_with_what_the_layers_draw() {
        if MTLCreateSystemDefaultDevice().is_none() {
            eprintln!("no Metal device here: the paths' sheet isn't checked");
            return;
        }
        // Twelve squares a little under 1000 points wide, at a pixel a
        // point: three quarters of the paths' sheet each time.
        let squares = |side: f32| {
            let mut items = Vec::new();
            let mut paths = Vec::new();
            for k in 0..12 {
                let s = side + k as f32;
                items.push(path_item(
                    0.0,
                    0.0,
                    paths.len() as i32,
                    13,
                    0xFF00_0000,
                    0.0,
                    0,
                ));
                paths.extend_from_slice(&[0.0, 0.0, 0.0, 1.0, s, 0.0, 1.0, s, s, 1.0, 0.0, s, 3.0]);
            }
            (items, paths)
        };
        let (a, pa) = squares(900.0);
        let (b, pb) = squares(950.0);
        let tri = [0.0, 0.0, 0.0, 1.0, 9.5, 0.0, 1.0, 0.0, 9.5, 3.0];
        let (drawn, other) = with_compositor(|c| {
            c.set_layer(
                1,
                &[path_item(0.0, 0.0, 0, 10, 0xFF00_0000, 0.0, 0)],
                b"",
                &tri,
                1.0,
            )?;
            c.set_layer(0, &a, b"", &pa, 1.0)?;
            // The second twelve don't fit beside the first: the sheet starts
            // again with them and the other layer's triangle.
            c.set_layer(0, &b, b"", &pb, 1.0)?;
            Ok((c.layers[0].instances.len(), c.layers[1].instances[0].uv))
        })
        .unwrap();
        assert_eq!(drawn, 12);
        // The other layer points at its triangle where the sheet has it now.
        let e = with_text(|t| t.atlas.path(&tri, 0.0, 0, 0, 0, None));
        assert_eq!(other, [e.x as f32, e.y as f32, e.w as f32, e.h as f32]);
    }

    #[test]
    fn a_layer_needing_more_than_the_paths_sheet_draws_every_path() {
        if MTLCreateSystemDefaultDevice().is_none() {
            eprintln!("no Metal device here: the paths' sheet isn't checked");
            return;
        }
        // Twenty squares 1000 points wide at a pixel a point, where sixteen
        // fill the sheet.
        let mut items = Vec::new();
        let mut paths = Vec::new();
        for k in 0..20 {
            let s = 1000.0 + k as f32;
            items.push(path_item(
                0.0,
                0.0,
                paths.len() as i32,
                13,
                0xFF00_0000,
                0.0,
                0,
            ));
            paths.extend_from_slice(&[0.0, 0.0, 0.0, 1.0, s, 0.0, 1.0, s, s, 1.0, 0.0, s, 3.0]);
        }
        let (drawn, after) = with_compositor(|c| {
            c.set_layer(1, &[], b"", &[], 1.0)?;
            c.set_layer(0, &items, b"", &paths, 1.0)?;
            let drawn = c.layers[0].instances.len();
            // A new square set next, with room for it, is drawn at its size.
            let big = [
                0.0, 0.0, 0.0, 1.0, 1100.0, 0.0, 1.0, 1100.0, 1100.0, 1.0, 0.0, 1100.0, 3.0,
            ];
            c.set_layer(0, &items[..1], b"", &big, 1.0)?;
            Ok((drawn, c.layers[0].instances[0].uv[2]))
        })
        .unwrap();
        assert_eq!(drawn, 20);
        assert!(after > 1100.0, "{after}");
    }

    #[test]
    fn a_clipped_path_has_a_mask_only_as_big_as_what_shows() {
        // A bar 10000 points long, its clip 100 wide.
        let paths = [
            0.0, 0.0, 0.0, 1.0, 10000.0, 0.0, 1.0, 10000.0, 4.0, 1.0, 0.0, 4.0, 3.0,
        ];
        let mut item = path_item(0.0, 0.0, 0, 13, 0xFF00_0000, 0.0, 0);
        item.clip_w = 100.0;
        item.clip_h = 4.0;
        let mut out = Vec::new();
        let scale = with_text(|t| {
            let scale = t.atlas.scale;
            build(&[item], b"", &paths, scale, t, &mut out);
            scale
        });
        assert_eq!(out.len(), 1);
        assert!(
            out[0].uv[2] as f64 <= 100.0 * scale + 2.0,
            "{:?}",
            out[0].uv
        );
    }

    #[test]
    fn a_clipped_layer_is_scissored_to_its_clip() {
        let scissor =
            |p: Place| uniforms(&p, 2.0, 200, 100).map(|(_, r)| (r.x, r.y, r.width, r.height));
        // Unclipped: the whole target.
        assert_eq!(scissor(Place::default()), Some((0, 0, 200, 100)));
        // Clipped: its clip where it lands, in device pixels.
        let clipped = Place {
            x: 10.0,
            y: 6.0,
            clip_w: 4.0,
            clip_h: 3.0,
            ..Place::default()
        };
        assert_eq!(scissor(clipped), Some((20, 12, 8, 6)));
        // Turned a quarter: the box around the turned clip.
        let turned = Place {
            b: 1.0,
            c: -1.0,
            ..clipped
        };
        assert_eq!(scissor(turned), Some((14, 12, 6, 8)));
        // Off the target, or hidden: nothing to draw.
        assert_eq!(
            scissor(Place {
                x: 500.0,
                ..clipped
            }),
            None
        );
        assert_eq!(
            scissor(Place {
                shown: 0,
                ..Place::default()
            }),
            None
        );
        // A clip of no area, or a layer faded out: nothing either. A clip off
        // the target's edge is cut at the edge, and one between pixels covers
        // every pixel it touches.
        for (w, h) in [(0.0, 3.0), (4.0, 0.0)] {
            let empty = Place {
                clip_x: 0.3,
                clip_w: w,
                clip_h: h,
                ..clipped
            };
            assert_eq!(scissor(empty), None);
        }
        assert_eq!(
            scissor(Place {
                opacity: 0.0,
                ..Place::default()
            }),
            None
        );
        let edge = Place {
            x: -5.0,
            y: 45.0,
            clip_w: 10.0,
            clip_h: 10.0,
            ..Place::default()
        };
        assert_eq!(scissor(edge), Some((0, 90, 10, 10)));
        let corner = Place {
            x: 95.0,
            y: -3.0,
            ..edge
        };
        assert_eq!(scissor(corner), Some((190, 0, 10, 14)));
        let between = Place {
            clip_x: 0.6,
            clip_y: 0.2,
            clip_w: 4.0,
            clip_h: 1.0,
            ..Place::default()
        };
        let at_one = uniforms(&between, 1.0, 200, 100).map(|(_, r)| (r.x, r.y, r.width, r.height));
        assert_eq!(at_one, Some((0, 0, 5, 2)));
    }

    #[test]
    fn an_unturned_layer_lands_on_whole_pixels() {
        let place = Place {
            x: 10.3,
            y: 5.6,
            scroll_x: 0.2,
            scroll_y: 2.7,
            ..Place::default()
        };
        let (u, _) = uniforms(&place, 2.0, 200, 100).unwrap();
        assert_eq!(&u.view[2..], &[21.0, 11.0]);
        assert_eq!(&u.scroll[..2], &[0.0, 5.0]);
        // Turned, it lands where it says: its glyphs are smoothed anyway.
        let turned = Place {
            b: 1.0,
            c: -1.0,
            ..place
        };
        let (u, _) = uniforms(&turned, 2.0, 200, 100).unwrap();
        assert!((u.view[2] - 20.6).abs() < 1e-4 && (u.view[3] - 11.2).abs() < 1e-4);
        assert!((u.scroll[0] - 0.4).abs() < 1e-4 && (u.scroll[1] - 5.4).abs() < 1e-4);
    }

    #[test]
    fn a_layer_clip_scales_and_its_radius_stops_at_a_pill() {
        let clip = |radius: f32| {
            let place = Place {
                clip_x: 1.0,
                clip_w: 20.0,
                clip_h: 10.0,
                radius,
                ..Place::default()
            };
            let (u, _) = uniforms(&place, 2.0, 200, 100).unwrap();
            (u.clip, u.style[0])
        };
        assert_eq!(clip(3.0), ([2.0, 0.0, 40.0, 20.0], 6.0));
        assert_eq!(clip(50.0).1, 10.0);
        // No clip, no rounding.
        let (u, _) = uniforms(
            &Place {
                radius: 5.0,
                ..Place::default()
            },
            2.0,
            200,
            100,
        )
        .unwrap();
        assert_eq!((u.clip, u.style[0]), ([0.0; 4], 0.0));
    }

    #[test]
    fn places_out_of_bounds_are_refused() {
        let ok = Place::default();
        assert!(ok.valid());
        assert!(
            Place {
                clip_w: -1.0,
                clip_h: -5.0,
                ..ok
            }
            .valid()
        );
        let bad = [
            Place { x: f32::NAN, ..ok },
            Place {
                scroll_y: f32::INFINITY,
                ..ok
            },
            Place { y: 2e7, ..ok },
            Place { radius: -2e7, ..ok },
            Place { a: 2e4, ..ok },
            Place { d: -2e4, ..ok },
            Place {
                clip_w: 5.0,
                clip_h: -1.0,
                ..ok
            },
            Place { radius: -1.0, ..ok },
            Place { opacity: 1.5, ..ok },
            Place {
                opacity: -0.5,
                ..ok
            },
            Place {
                opacity: f32::NAN,
                ..ok
            },
        ];
        for p in bad {
            assert!(!p.valid(), "{p:?}");
        }
    }

    #[test]
    fn place_matches_the_goose_layout() {
        use std::mem::{offset_of, size_of};
        assert_eq!(size_of::<Place>(), 64);
        let offsets = [
            offset_of!(Place, x),
            offset_of!(Place, y),
            offset_of!(Place, scroll_x),
            offset_of!(Place, scroll_y),
            offset_of!(Place, a),
            offset_of!(Place, b),
            offset_of!(Place, c),
            offset_of!(Place, d),
            offset_of!(Place, clip_x),
            offset_of!(Place, clip_y),
            offset_of!(Place, clip_w),
            offset_of!(Place, clip_h),
            offset_of!(Place, radius),
            offset_of!(Place, opacity),
            offset_of!(Place, z),
            offset_of!(Place, shown),
        ];
        assert_eq!(offsets, std::array::from_fn(|k| k * 4));
    }

    #[test]
    fn a_dropped_layer_is_gone_and_restacked() {
        if MTLCreateSystemDefaultDevice().is_none() {
            return;
        }
        let red = [rect(0.0, 0.0, 4.0, 4.0, 0xFFFF_0000)];
        let blue = [rect(0.0, 0.0, 4.0, 4.0, 0xFF00_00FF)];
        let (gone, buffer, restacked) = with_compositor(|c| {
            c.set_layer(0, &red, b"", &[], 1.0)?;
            c.place(0, Place::default());
            // Blue under red by its z, then dropped: red alone.
            c.set_layer(1, &blue, b"", &[], 1.0)?;
            c.place(
                1,
                Place {
                    z: -1,
                    ..Place::default()
                },
            );
            c.drop_layer(1);
            let gone = c.render_pixels(8, 8, 0xFFFF_FFFF)?;
            let buffer = c.layers[1].buffer.is_some();
            // Set again and placed at z 0, it is over red by its number: the
            // drop took its old z out of the order.
            c.set_layer(1, &blue, b"", &[], 1.0)?;
            c.place(1, Place::default());
            Ok((gone, buffer, c.render_pixels(8, 8, 0xFFFF_FFFF)?))
        })
        .unwrap();
        assert_eq!(pixel(&gone, 8, 1, 1), RED);
        assert!(!buffer);
        assert_eq!(pixel(&restacked, 8, 1, 1), BLUE);
    }

    #[test]
    fn a_layer_is_drawn_at_its_scale() {
        if MTLCreateSystemDefaultDevice().is_none() {
            return;
        }
        let square = [rect(1.0, 1.0, 4.0, 4.0, 0xFFFF_0000)];
        let p = with_compositor(|c| {
            c.set_layer(0, &square, b"", &[], 2.0)?;
            c.place(
                0,
                Place {
                    clip_w: 4.0,
                    clip_h: 4.0,
                    ..Place::default()
                },
            );
            c.set_layer(1, &[], b"", &[], 2.0)?;
            c.place(1, Place::default());
            c.render_pixels(16, 16, 0xFFFF_FFFF)
        })
        .unwrap();
        // The square covers device pixels 2 to 10; the clip, in points,
        // stops it at 8.
        assert_eq!(pixel(&p, 16, 1, 1), WHITE);
        assert_eq!(pixel(&p, 16, 2, 2), RED);
        assert_eq!(pixel(&p, 16, 7, 7), RED);
        assert_eq!(pixel(&p, 16, 8, 8), WHITE);
        assert_eq!(pixel(&p, 16, 9, 3), WHITE);
    }

    #[test]
    fn a_turned_layer_smooths_edges_as_a_turned_item_does() {
        // A plain rectangle and a rounded, bordered box, turned 30 degrees (and
        // shrunk) and moved by their own transform, or by their layer's: the
        // same pixels.
        let (s, c) = (30f32.to_radians().sin(), 30f32.to_radians().cos());
        let items = [
            rect(0.0, 0.0, 40.0, 20.0, 0xFFFF_0000),
            boxed(0.0, 0.0, 40.0, 20.0, 0xFFFF_0000, 6.0, 2.0, 0xFF00_00FF, 1),
        ];
        for (item, k) in [
            (items[0], 1.0),
            (items[1], 1.0),
            (items[0], 0.3),
            (items[1], 0.3),
        ] {
            let (s, c) = (s * k, c * k);
            let mut own = item;
            (own.m_a, own.m_b, own.m_c, own.m_d, own.m_e, own.m_f) = (c, s, -s, c, 24.0, 4.0);
            let Some(by_item) =
                drawn_placed(&[own], Place::default(), &[], Place::default(), 64, 48)
            else {
                return;
            };
            let turned = Place {
                x: 24.0,
                y: 4.0,
                a: c,
                b: s,
                c: -s,
                d: c,
                ..Place::default()
            };
            let by_layer = drawn_placed(&[item], turned, &[], Place::default(), 64, 48).unwrap();
            let soft = by_item
                .chunks(4)
                .filter(|p| (16..240).contains(&p[1]))
                .count();
            assert!(soft > 12, "{soft} soft pixels");
            let worst = by_item
                .iter()
                .zip(&by_layer)
                .map(|(a, b)| a.abs_diff(*b))
                .max()
                .unwrap();
            assert!(worst <= 2, "{worst}");
        }
    }
}
