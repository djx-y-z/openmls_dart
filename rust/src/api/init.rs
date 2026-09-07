//! Library initialization API.

/// Initialize the openmls library.
///
/// This function is called from Dart during library initialization.
/// The library_path parameter is typically used for loading external
/// dependencies if needed.
#[flutter_rust_bridge::frb(sync)]
pub fn init_openmls(_library_path: String) -> Result<(), String> {
    // Add any initialization logic here
    Ok(())
}

/// Check if the openmls library is initialized.
///
/// Returns true if the library has been successfully initialized.
#[flutter_rust_bridge::frb(sync)]
pub fn is_openmls_initialized() -> bool {
    // Add initialization state check logic here
    true
}

/// Temporary probe for the codegen-guard negative test. The bindings are
/// deliberately NOT regenerated for it: the guard is supposed to notice.
pub fn codegen_guard_probe(value: u32) -> u32 {
    value + 1
}
