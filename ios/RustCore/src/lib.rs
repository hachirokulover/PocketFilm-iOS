use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CString};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Recipe {
    film: String,
    paper: String,
    #[serde(rename = "sceneEV")]
    scene_ev: f64,
    grain: bool,
    halation: bool,
    monochrome: bool,
    grain_amount: f64,
    halation_amount: f64,
    border: Border,
    export: Export,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Border {
    enabled: bool,
    format: String,
    scan: String,
    holes: String,
    fog: f64,
    leaks: f64,
    frame_number: i32,
    camera_seed: i32,
    frame_seed: i32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Export {
    color_space: ColorSpace,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum ColorSpace {
    #[serde(rename = "sRGB")]
    Srgb,
    #[serde(rename = "adobeRGB")]
    AdobeRgb,
    DisplayP3,
    DciP3,
}

impl ColorSpace {
    fn engine_output(&self) -> (&'static str, bool) {
        match self {
            Self::Srgb => ("sRGB", true),
            Self::AdobeRgb => ("Adobe RGB (1998)", true),
            Self::DisplayP3 => ("Display P3", true),
            Self::DciP3 => ("ProPhoto RGB", false),
        }
    }
}

fn engine_delta(recipe: &Recipe, preview: bool, edge_text: &str) -> Value {
    let border = &recipe.border;
    let (space, transfer) = recipe.export.color_space.engine_output();
    json!({
        "product_defaults": true,
        "film_stock": recipe.film,
        "print_stock": recipe.paper,
        "input_color_space": "ProPhoto RGB",
        "input_cctf_decoding": false,
        "output_color_space": space,
        "output_cctf_encoding": transfer,
        "exposure_compensation_ev": recipe.scene_ev,
        "auto_exposure": true,
        "grain_active": !preview && recipe.grain && recipe.grain_amount > 0.0,
        "grain_amount": recipe.grain_amount,
        "grain_sublayers_active": !recipe.monochrome,
        "halation_active": recipe.halation && recipe.halation_amount > 0.0,
        "halation_amount": recipe.halation_amount,
        "glare_active": false,
        "extended_dynamic_range": false,
        "striped": !border.enabled,
        "overscan_active": border.enabled,
        "overscan_format": border.format,
        "overscan_mode": border.scan,
        "overscan_holes": border.holes,
        "overscan_gate": "auto",
        "overscan_fog": border.fog,
        "overscan_leaks": border.leaks,
        "overscan_camera_seed": border.camera_seed,
        "overscan_frame_seed": border.frame_seed,
        "overscan_frame_number": border.frame_number,
        "overscan_edge_text": edge_text,
        "overscan_pair": false,
        "overscan_carrier": "none",
        "strip_rows": 128,
        "preview_long_edge": 800,
    })
}

#[no_mangle]
pub extern "C" fn pf_processing_edge(max_edge: i64, border: bool, preview: bool) -> i64 {
    if preview {
        480
    } else if border {
        max_edge.min(2048)
    } else {
        max_edge
    }
}

#[no_mangle]
pub extern "C" fn pf_compression_quality(quality: f64) -> f64 {
    quality.clamp(1.0, 100.0) / 100.0
}

#[repr(C)]
pub struct ImageSize {
    pub width: f64,
    pub height: f64,
}

#[no_mangle]
pub extern "C" fn pf_resized_size(width: f64, height: f64, max_edge: i64) -> ImageSize {
    let scale = (max_edge as f64 / width.max(height)).min(1.0);
    ImageSize {
        width: (width * scale).round().max(1.0),
        height: (height * scale).round().max(1.0),
    }
}

// Used by the renderer and the hosted Swift settings contract tests.
unsafe fn make_delta(
    data: *const u8,
    length: usize,
    preview: bool,
    edge_text: *const c_char,
) -> Option<Value> {
    if data.is_null() || edge_text.is_null() || length > isize::MAX as usize {
        return None;
    }
    let recipe = serde_json::from_slice(std::slice::from_raw_parts(data, length)).ok()?;
    let edge_text = std::ffi::CStr::from_ptr(edge_text).to_str().ok()?;
    Some(engine_delta(&recipe, preview, edge_text))
}

/// # Safety
/// `data` must contain `length` readable bytes. `edge_text` must be NUL-terminated.
/// Return value is Rust-owned and must be released with `pf_free_string`.
#[no_mangle]
pub unsafe extern "C" fn pf_engine_delta(
    data: *const u8,
    length: usize,
    preview: bool,
    edge_text: *const c_char,
) -> *mut c_char {
    make_delta(data, length, preview, edge_text)
        .and_then(|delta| CString::new(delta.to_string()).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// A non-null value must come from this library and be released only once.
#[no_mangle]
pub unsafe extern "C" fn pf_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(target_os = "ios")]
mod native;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_recipe_shape_maps_to_engine_settings() {
        let payload = br#"{"film":"film","paper":"paper","sceneEV":1.5,
            "grain":true,"halation":true,"monochrome":false,"grainAmount":1.25,"halationAmount":0,
            "border":{"enabled":true,"format":"135","scan":"strip","holes":"white",
            "fog":1,"leaks":0,"frameNumber":0,"cameraSeed":1,"frameSeed":314},
            "export":{"format":"heif","colorSpace":"dciP3","quality":98}}"#;
        let recipe = serde_json::from_slice(payload).unwrap();
        let full = engine_delta(&recipe, false, "KODAK");
        assert_eq!(full["output_color_space"], "ProPhoto RGB");
        assert_eq!(full["output_cctf_encoding"], false);
        assert_eq!(full["striped"], false);
        assert_eq!(full["overscan_edge_text"], "KODAK");
        assert_eq!(full["overscan_frame_seed"], 314);
        assert_eq!(full["grain_active"], true);
        assert_eq!(full["halation_active"], false);
        assert_eq!(engine_delta(&recipe, true, "")["grain_active"], false);
    }

    #[test]
    fn export_and_resize_preserve_limits() {
        assert_eq!(pf_processing_edge(4032, true, false), 2048);
        assert_eq!(pf_processing_edge(4032, false, true), 480);
        let size = pf_resized_size(4032.0, 3024.0, 480);
        assert_eq!((size.width, size.height), (480.0, 360.0));
        assert_eq!(pf_resized_size(320.0, 240.0, 4032).width, 320.0);
        assert_eq!(pf_compression_quality(120.0), 1.0);
        assert_eq!(pf_compression_quality(85.0), 0.85);
    }
}
