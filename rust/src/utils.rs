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

#[cfg(all(test, not(target_arch = "wasm32")))]
mod manifest_tests {
    /// The shipped release profile must not turn panics into aborts.
    ///
    /// `rust/Cargo.toml` says in prose that the absence of a `panic` key is
    /// load-bearing — `panic = "abort"` skips unwinding, so `Drop` never runs
    /// and every zeroize-on-Drop in this crate is silently bypassed, leaving
    /// key material in memory after any panic. This is what turns that prose
    /// into something that fails.
    ///
    /// It has to read the manifest rather than observe a running panic: Cargo
    /// forces `panic = "unwind"` for the `test` and `bench` profiles and
    /// rejects the key on per-package overrides, so the setting that actually
    /// ships is unobservable from inside a test binary.
    ///
    /// Native targets only. `wasm32-unknown-unknown` aborts by target default,
    /// which no profile key changes — say so in SECURITY.md rather than
    /// assuming the profile covers it.
    #[test]
    fn release_profile_must_not_abort_on_panic() {
        let manifest = include_str!("../Cargo.toml");
        let mut in_release = false;
        let mut saw_release = false;

        for raw in manifest.lines() {
            // Strip comments first. The manifest explains this invariant in
            // prose that names the very key being looked for, and nothing stops
            // that prose from moving inside the section.
            let line = raw.split('#').next().unwrap_or_default().trim();
            if line.is_empty() {
                continue;
            }
            if line.starts_with('[') {
                // Exact match on purpose. `[profile.release.package.*]` cannot
                // carry `panic` at all, so it is not this test's business.
                in_release = line == "[profile.release]";
                saw_release |= in_release;
                continue;
            }
            if !in_release {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            if key.trim() != "panic" {
                continue;
            }
            assert_ne!(
                value.trim().trim_matches(['"', '\'']),
                "abort",
                "[profile.release] sets `panic = \"abort\"`. Remove it: abort \
                 skips unwinding, so every zeroize-on-Drop in this crate stops \
                 running and key material survives a panic in memory.",
            );
        }

        assert!(
            saw_release,
            "no `[profile.release]` section in rust/Cargo.toml — this test can \
             no longer see the profile it is meant to guard.",
        );

        // The loop above matches `[profile.release]` exactly, which TOML gives
        // several ways around: `[profile]` with `release.panic = "abort"`, a
        // bare `profile.release.panic = "abort"`, or an inline
        // `release = { panic = "abort" }`. Rather than enumerate the shapes —
        // the enumeration is what would rot — reject the pair outright. No line
        // of this manifest has any business naming both, so anything that does
        // is either the setting itself in a shape the loop cannot see, or a
        // deliberate change that should come with a deliberate edit here.
        for raw in manifest.lines() {
            let line = raw.split('#').next().unwrap_or_default();
            assert!(
                !(line.contains("panic") && line.contains("abort")),
                "rust/Cargo.toml names both `panic` and `abort` outside a \
                 comment, on: {}\nIf this is a profile setting, it turns off \
                 unwinding and with it every zeroize-on-Drop in this crate.",
                line.trim(),
            );
        }
    }
}
