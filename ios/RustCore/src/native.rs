use super::make_delta;
use serde_json::Value;
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr::null_mut;

// The device input and retained texture result mirror spk_engine.h.
#[repr(C)]
struct DeviceImage {
    buffer: *mut c_void,
    width: u32,
    height: u32,
    channels: u32,
}

#[repr(C)]
struct SpkResult {
    rgba16: *const u16,
    texture: *mut c_void,
    width: u32,
    height: u32,
    row_stride_px: u32,
    elapsed_ms: f64,
    reprint: i32,
    negative_was_cached: i32,
    progress_id: [c_char; 40],
}

extern "C" {
    fn spk_open_device(
        engine: *mut c_void,
        input: *const DeviceImage,
        delta: *const c_char,
        reply: *mut *mut c_char,
    ) -> *mut c_void;
    fn spk_session_release(session: *mut c_void);
    fn spk_render(session: *mut c_void, tier: *const c_char, out: *mut SpkResult) -> i32;
    fn spk_last_error(engine: *mut c_void) -> *const c_char;
    fn spk_result_free(result: *mut SpkResult);
    fn spk_string_free(value: *mut c_char);
}

struct Session(*mut c_void);
impl Drop for Session {
    fn drop(&mut self) {
        unsafe { spk_session_release(self.0) }
    }
}

struct Reply(*mut c_char);
impl Drop for Reply {
    fn drop(&mut self) {
        unsafe { spk_string_free(self.0) }
    }
}

struct TextureResult(SpkResult);
impl Drop for TextureResult {
    fn drop(&mut self) {
        unsafe { spk_result_free(&mut self.0) }
    }
}

unsafe fn engine_error(engine: *mut c_void) -> CString {
    let message = spk_last_error(engine);
    if message.is_null() {
        c"胶片引擎无法完成显影。".into()
    } else {
        CStr::from_ptr(message).to_owned()
    }
}

unsafe fn render(
    engine: *mut c_void,
    input: DeviceImage,
    delta: Value,
) -> Result<*mut c_void, CString> {
    let settings = CString::new(delta.to_string()).map_err(|_| CString::from(c"显影设置无效。"))?;
    let mut reply = Reply(null_mut());
    let handle = spk_open_device(engine, &input, settings.as_ptr(), &mut reply.0);
    if handle.is_null() {
        return Err(engine_error(engine));
    }
    let session = Session(handle);
    let params = if reply.0.is_null() {
        None
    } else {
        serde_json::from_slice::<Value>(CStr::from_ptr(reply.0).to_bytes()).ok()
    };
    let valid_output = params.is_some_and(|reply| {
        let params = &reply["params"];
        params["output_color_space"] == delta["output_color_space"]
            && params["output_cctf_encoding"] == delta["output_cctf_encoding"]
    });
    if !valid_output {
        return Err(c"引擎输出颜色空间与应用约定不同。".into());
    }
    let mut output = TextureResult(std::mem::zeroed());
    if spk_render(session.0, c"full".as_ptr(), &mut output.0) != 0 {
        return Err(engine_error(engine));
    }
    if output.0.texture.is_null() {
        return Err(c"引擎没有返回纹理。".into());
    }
    // Transfer the +1 texture to Swift ARC. The guard still cleans up the
    // result struct without releasing the transferred texture.
    Ok(std::mem::replace(&mut output.0.texture, null_mut()))
}

/// # Safety
/// Engine and Metal buffer are borrowed during this synchronous call. Data and
/// edge text follow the requirements of pf_engine_delta. On success caller
/// owns one texture reference. On failure free out_error with pf_free_string.
#[no_mangle]
pub unsafe extern "C" fn pf_render_texture(
    engine: *mut c_void,
    buffer: *mut c_void,
    width: u32,
    height: u32,
    data: *const u8,
    length: usize,
    preview: bool,
    edge_text: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_void {
    if !out_error.is_null() {
        *out_error = null_mut();
    }
    let result = match make_delta(data, length, preview, edge_text) {
        Some(delta) if !engine.is_null() && !buffer.is_null() => render(
            engine,
            DeviceImage {
                buffer,
                width,
                height,
                channels: 4,
            },
            delta,
        ),
        _ => Err(c"无法读取显影设置或原始画面。".into()),
    };
    match result {
        Ok(texture) => texture,
        Err(error) => {
            if !out_error.is_null() {
                *out_error = error.into_raw();
            }
            null_mut()
        }
    }
}
