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

#[cfg(all(test, target_arch = "wasm32"))]
mod web_tests {
    use super::current_time;
    use std::time::UNIX_EPOCH;
    use wasm_bindgen_test::{wasm_bindgen_test, wasm_bindgen_test_configure};

    wasm_bindgen_test_configure!(run_in_browser);

    /// Run by `make test-web` and by nothing else in this project.
    ///
    /// The point is not the assertion, it is the execution. This wasm32 body
    /// of `current_time` is a DIFFERENT implementation from the native one —
    /// it calls out to JavaScript — so nothing that runs on the host exercises
    /// a line of it, and `make build-web` only proves it compiles. The
    /// threshold is what separates "the call reached JavaScript and came back"
    /// from a stub, a zero, or a value that never left Rust.
    #[wasm_bindgen_test]
    fn current_time_reaches_the_browser_clock() {
        // 2020-01-01T00:00:00Z, in milliseconds.
        const Y2020_MILLIS: u128 = 1_577_836_800_000;
        let millis = current_time()
            .duration_since(UNIX_EPOCH)
            .expect("current_time() is after the Unix epoch")
            .as_millis();
        assert!(millis > Y2020_MILLIS, "implausible browser clock: {millis} ms");
    }
}
