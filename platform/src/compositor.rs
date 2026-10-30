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
    MTLResourceOptions, MTLSize, MTLStorageMode, MTLStoreAction, MTLTexture, MTLTextureDescriptor,
    MTLTextureUsage,
};
use objc2_quartz_core::CAMetalDrawable;

use crate::cg::*;
use crate::text::{Atlas, PHASES, Text, with_text};
use crate::{ERR_ARGUMENT, ERR_METAL, ERR_NO_DEVICE, ERR_NOT_MAIN_THREAD, GSlice, guarded};

// Display item kinds; engine/layout.goose mirrors these numbers.
pub const ITEM_RECT: i32 = 1;
pub const ITEM_TEXT: i32 = 2;

const LAYERS: usize = 2; // 0: the page, scrolled; 1: the overlay, fixed

/// One display item, laid out as Goose's `struct DItem`: positions in points,
/// a text item's y on its baseline and its text a span of the text buffer.
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
}

/// One quad, in device pixels: solid when `uv[2]` is 0, otherwise the atlas
/// mask at `uv` (in texels) times `color`, which is premultiplied.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct Instance {
    pub rect: [f32; 4],
    pub uv: [f32; 4],
    pub color: [f32; 4],
}

#[repr(C)]
struct Uniforms {
    viewport: [f32; 2],
    scroll: [f32; 2],
}

const SHADERS: &str = r#"
#include <metal_stdlib>
using namespace metal;

struct Instance { float4 rect; float4 uv; float4 color; };
struct Uniforms { float2 viewport; float2 scroll; };
struct Out { float4 position [[position]]; float2 uv; float4 color; float textured; };

vertex Out quad_vertex(uint v [[vertex_id]], uint i [[instance_id]],
                       const device Instance* instances [[buffer(0)]],
                       constant Uniforms& u [[buffer(1)]]) {
    Instance q = instances[i];
    float2 corner = float2(v & 1, v >> 1);
    float2 p = q.rect.xy + corner * q.rect.zw - u.scroll;
    Out o;
    o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
    o.uv = q.uv.xy + corner * q.uv.zw;
    o.color = q.color;
    o.textured = q.uv.z > 0.0 ? 1.0 : 0.0;
    return o;
}

fragment float4 quad_fragment(Out in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    if (in.textured > 0.5) {
        constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
        return in.color * atlas.sample(s, in.uv).r;
    }
    return in.color;
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
    instances: Vec<Instance>,
    buffer: Option<Retained<ProtocolObject<dyn MTLBuffer>>>,
}

pub struct Compositor {
    pub device: Retained<ProtocolObject<dyn MTLDevice>>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    pipeline: Retained<ProtocolObject<dyn MTLRenderPipelineState>>,
    atlas: Retained<ProtocolObject<dyn MTLTexture>>,
    atlas_rows: u32,
    layers: [Layer; LAYERS],
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
        Ok(Compositor {
            device,
            queue,
            pipeline,
            atlas,
            atlas_rows: 1,
            layers: Default::default(),
            stats: Stats::default(),
            last_frame: None,
        })
    }

    /// Turns a display list into layer `layer`'s instances and uploads them,
    /// with any glyphs the atlas gained.
    fn set_layer(
        &mut self,
        layer: usize,
        items: &[DItem],
        text: &[u8],
        scale: f64,
    ) -> Result<(), i32> {
        let mut instances = std::mem::take(&mut self.layers[layer].instances);
        instances.clear();
        let mut rescaled = false;
        with_text(|t| {
            if t.atlas.scale != scale {
                // Glyphs drawn for another backing scale are of no use now.
                t.atlas = Atlas::new(scale);
                self.atlas_rows = 0;
                rescaled = true;
            }
            build(items, text, scale, t, &mut instances);
            self.upload_atlas(&mut t.atlas)
        })?;
        if rescaled {
            // The other layers' glyphs point into the old atlas: they draw
            // nothing until they are set again at the new scale.
            for (i, other) in self.layers.iter_mut().enumerate() {
                if i != layer {
                    *other = Layer::default();
                }
            }
        }
        self.layers[layer].buffer = if instances.is_empty() {
            None
        } else {
            let bytes = std::mem::size_of_val(instances.as_slice());
            let ptr = NonNull::new(instances.as_ptr() as *mut std::ffi::c_void).ok_or(ERR_METAL)?;
            Some(
                unsafe {
                    self.device.newBufferWithBytes_length_options(
                        ptr,
                        bytes,
                        MTLResourceOptions::StorageModeShared,
                    )
                }
                .ok_or(ERR_METAL)?,
            )
        };
        self.layers[layer].instances = instances;
        Ok(())
    }

    fn upload_atlas(&mut self, atlas: &mut Atlas) -> Result<(), i32> {
        let rows = if self.atlas_rows != atlas.height {
            self.atlas = new_atlas_texture(&self.device, atlas.width, atlas.height)?;
            self.atlas_rows = atlas.height;
            Some((0, atlas.height))
        } else {
            atlas.dirty
        };
        atlas.dirty = None;
        let Some((first, end)) = rows else {
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
                width: atlas.width as usize,
                height: (end - first) as usize,
                depth: 1,
            },
        };
        let start = (first * atlas.width) as usize;
        let ptr = NonNull::new(atlas.pixels[start..].as_ptr() as *mut std::ffi::c_void)
            .ok_or(ERR_METAL)?;
        unsafe {
            self.atlas.replaceRegion_mipmapLevel_withBytes_bytesPerRow(
                region,
                0,
                ptr,
                atlas.width as usize,
            )
        };
        Ok(())
    }

    /// Encodes one frame into `target`: cleared to `background`, then each
    /// layer, the page moved up by `scroll` device pixels.
    fn encode(
        &self,
        target: &ProtocolObject<dyn MTLTexture>,
        scroll: f64,
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
        unsafe { encoder.setFragmentTexture_atIndex(Some(&self.atlas), 0) };
        let viewport = [target.width() as f32, target.height() as f32];
        for (i, layer) in self.layers.iter().enumerate() {
            let Some(buffer) = &layer.buffer else {
                continue;
            };
            // Whole device pixels, so glyphs stay on the pixel grid they were drawn for.
            let y = if i == 0 { scroll.round() as f32 } else { 0.0 };
            let u = Uniforms {
                viewport,
                scroll: [0.0, y],
            };
            unsafe {
                encoder.setVertexBuffer_offset_atIndex(Some(buffer), 0, 0);
                encoder.setVertexBytes_length_atIndex(
                    NonNull::from(&u).cast(),
                    std::mem::size_of::<Uniforms>(),
                    1,
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
        scroll: f64,
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
        let commands = self.encode(&texture, scroll, background)?;
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
    fn render_pixels(
        &self,
        width: usize,
        height: usize,
        scroll: f64,
        background: u32,
    ) -> Result<Vec<u8>, i32> {
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
        let commands = self.encode(&target, scroll, background)?;
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

/// Turns display items into instances at `scale` device pixels per point. Rect
/// edges snap to whole pixels; each glyph goes to the whole pixel left of its
/// pen position, with the rest taken by one of the atlas's subpixel phases.
pub fn build(items: &[DItem], text: &[u8], scale: f64, t: &mut Text, out: &mut Vec<Instance>) {
    let mut glyphs = Vec::new();
    for &item in items {
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
            let x0 = (x as f64 * scale).round();
            let y0 = (y as f64 * scale).round();
            // A hairline still shows: never less than one device pixel.
            let x1 = ((x + w) as f64 * scale).round().max(x0 + 1.0);
            let y1 = ((y + h) as f64 * scale).round().max(y0 + 1.0);
            out.push(Instance {
                rect: [x0 as f32, y0 as f32, (x1 - x0) as f32, (y1 - y0) as f32],
                uv: [0.0; 4],
                color,
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
            let baseline = y as f64 * scale;
            for g in &glyphs {
                let pen = (x as f64 + g.x as f64) * scale;
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
                });
            }
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

/// Hands layer `layer` (0, the page, or 1, the overlay) a new display list.
/// Positions are in points; `scale` is device pixels per point. The lists are
/// copied, so Goose may reuse its arrays at once.
#[unsafe(no_mangle)]
pub extern "C" fn tp_set_layer(
    layer: i32,
    items: GSlice<DItem>,
    text: GSlice<u8>,
    scale: f32,
) -> i32 {
    guarded(|| {
        on_main_thread()?;
        let items = unsafe { items.as_slice() }.ok_or(ERR_ARGUMENT)?;
        let text = unsafe { text.as_slice() }.ok_or(ERR_ARGUMENT)?;
        if !(0..LAYERS as i32).contains(&layer) || !(scale > 0.0 && scale <= 8.0) {
            return Err(ERR_ARGUMENT);
        }
        with_compositor(|c| c.set_layer(layer as usize, items, text, scale as f64))?;
        Ok(0)
    })
}

/// Draws the layers offscreen, `width` × `height` points at `scale`, the page
/// scrolled by `scroll` points, and writes a PNG to `path`. Needs no window.
#[unsafe(no_mangle)]
pub extern "C" fn tp_screenshot(
    path: GSlice<u8>,
    width: f32,
    height: f32,
    scale: f32,
    scroll: f32,
    background: u32,
) -> i32 {
    guarded(|| {
        on_main_thread()?;
        let path = unsafe { path.as_slice() }.ok_or(ERR_ARGUMENT)?;
        let (w, h) = ((width * scale).round(), (height * scale).round());
        if path.is_empty() || !(w >= 1.0 && h >= 1.0 && w <= 16384.0 && h <= 16384.0) {
            return Err(ERR_ARGUMENT);
        }
        let mut pixels = with_compositor(|c| {
            c.render_pixels(w as usize, h as usize, (scroll * scale) as f64, background)
        })?;
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

    #[test]
    fn items_match_the_goose_layout() {
        assert_eq!(std::mem::size_of::<DItem>(), 44);
        assert_eq!(std::mem::align_of::<DItem>(), 1);
        assert_eq!(std::mem::size_of::<GpFrameStats>(), 28);
    }

    #[test]
    fn rects_snap_to_device_pixels_and_hairlines_stay() {
        let mut out = Vec::new();
        with_text(|t| {
            build(
                &[rect(0.3, 1.0, 10.2, 0.2, 0xFF00_0000)],
                b"",
                2.0,
                t,
                &mut out,
            )
        });
        assert_eq!(out[0].rect, [1.0, 2.0, 20.0, 1.0]);
        assert_eq!(out[0].color, [0.0, 0.0, 0.0, 1.0]);
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
        with_text(|t| build(&[item], b"Tusk!", 2.0, t, &mut out));
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
        let pixels = with_compositor(|c| {
            c.set_layer(0, &[rect(2.0, 2.0, 4.0, 4.0, 0xFFFF_0000)], b"", 1.0)?;
            c.set_layer(1, &[rect(0.0, 0.0, 1.0, 1.0, 0xFF00_00FF)], b"", 1.0)?;
            c.render_pixels(8, 8, 1.0, 0xFFFF_FFFF)
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
        let mut stats = GpFrameStats::default();
        assert_eq!(tp_start_metal(), ERR_NOT_MAIN_THREAD);
        assert_eq!(tp_set_layer(0, items, text, 1.0), ERR_NOT_MAIN_THREAD);
        assert_eq!(
            tp_screenshot(path, 8.0, 8.0, 1.0, 0.0, 0xFFFF_FFFF),
            ERR_NOT_MAIN_THREAD
        );
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
}
