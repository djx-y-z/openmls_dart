//! Link settings of the shipped library that the manifest has no key for.
//!
//! **`-headerpad_max_install_names` on Apple targets.** `dart run`, `dart test`
//! and `flutter test` copy the dylib into the consuming project and rewrite its
//! install name to the copy's absolute path (`install_name_tool -id`). The
//! linker leaves only the room the build machine's own path needed, so that
//! rewrite fails once the copy's path is a little longer — about 180 characters
//! with the libraries the release workflow builds — with "larger updated load
//! commands do not fit". This flag reserves room for every path in the header
//! to grow to `MAXPATHLEN`. Flutter app builds never hit it: they install the
//! library as a framework under a short `@rpath/` name.
//!
//! A build script and not `rustflags` in `.cargo/config.toml`, because the
//! latter is not reliably seen: `make build` runs cargo from the repository
//! root, where `rust/.cargo/` is not read, and a `RUSTFLAGS` in the environment
//! replaces config rustflags wholesale. `rustc-link-arg-cdylib` reaches the
//! cdylib's link either way, and no other artefact.
//!
//! `make verify-release-artifacts` refuses a release whose Apple libraries
//! leave less room than that (`MIN_INSTALL_NAME_ROOM`), so a lost flag fails
//! the release instead of a consumer's build.

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple") {
        println!("cargo::rustc-link-arg-cdylib=-Wl,-headerpad_max_install_names");
    }
}
