//! Cross-platform utilities for openmls_frb.

use std::time::SystemTime;

/// Get current time as SystemTime.
///
/// This function provides cross-platform time support:
/// - On native platforms (macOS, Linux, Windows, iOS, Android): uses `SystemTime::now()`
/// - On WASM: uses `js_sys::Date::now()` converted to SystemTime
///
/// Returns UTC time (not local time).
#[cfg(not(target_arch = "wasm32"))]
pub fn current_time() -> SystemTime {
    SystemTime::now()
}

/// WASM implementation of current_time().
///
/// Uses JavaScript's Date.now() which returns milliseconds since Unix epoch (UTC).
#[cfg(target_arch = "wasm32")]
pub fn current_time() -> SystemTime {
    use std::time::{Duration, UNIX_EPOCH};
    let millis = js_sys::Date::now() as u64;
    UNIX_EPOCH + Duration::from_millis(millis)
}
