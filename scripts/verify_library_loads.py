#!/usr/bin/env python3
"""Refuse a native library that cannot be loaded, or that is missing the FRB runtime.

The build workflow compiles a library per platform and ships it without ever
loading one. A library that fails at load time — a bad relocation, a dependency
that is not on the target, an architecture that does not match its name — is
green through every other check there is: it compiles, it packs, its checksum
matches, its provenance is signed. The consumer's app is where it first fails.

`ctypes.CDLL` is the whole check, and it is more than it looks: loading a shared
library runs its initialisers, resolves its dependencies and rejects a wrong
architecture. Then one symbol is looked up — `frb_init_frb_dart_api_dl`, which
flutter_rust_bridge exports from its own `ffi_binding/io.rs` rather than from
anything this project writes, so the name is the same in every generated
project and a library without it is not an FRB library.

⚠ This runs on the legs whose RUNNER IS THE TARGET — the workflow decides that,
not this script. A cross-compiled artefact cannot be loaded by the machine that
built it, and asking it to would report an error about the wrong thing.

Python, in a project whose scripts are otherwise Dart, for the reason
`verify_android_alignment.py` gives: the build jobs carry Rust and nothing else,
and `python3` is on every runner they use. Loading the library through the Dart
toolchain would mean installing one in five jobs to learn what `dlopen` already
answers.

Usage:
    python3 scripts/verify_library_loads.py FILE [FILE...]

Fails when given no file that exists: a check that passes because it found
nothing to look at is not a check.
"""

import ctypes
import os
import pathlib
import sys

# Exported by flutter_rust_bridge itself (`ffi_binding/io.rs`), not by the
# generated bindings, so it is present in every FRB cdylib under every crate
# name. The two `frb_free_*` symbols beside it are corroboration: all three
# missing means this is not an FRB library, one missing means something
# stranger.
FRB_SYMBOLS = (
    "frb_init_frb_dart_api_dl",
    "frb_free_wire_sync_rust2dart_dco",
    "frb_free_wire_sync_rust2dart_sse",
)


def verify(path):
    """Return a list of complaints about `path`; empty means it is fine."""
    if not path.is_file():
        return [f"{path}: no such file"]

    # On Windows a DLL's dependencies are searched next to the process, not next
    # to the DLL, so a self-contained library still loads while one that grew a
    # dependency would fail for a reason that has nothing to do with this build.
    cookie = None
    if os.name == "nt" and hasattr(os, "add_dll_directory"):
        cookie = os.add_dll_directory(str(path.parent.resolve()))

    try:
        library = ctypes.CDLL(str(path))
    except OSError as error:
        # Verbatim: the loader's own message is the only thing that says which
        # of the several load failures this is.
        return [f"{path}: will not load — {error}"]
    finally:
        if cookie is not None:
            cookie.close()

    missing = [name for name in FRB_SYMBOLS if not hasattr(library, name)]
    if missing:
        return [
            f"{path}: loaded, but flutter_rust_bridge's runtime is not in it "
            f"(missing {', '.join(missing)})"
        ]

    print(f"  {path.name}: loads, and exports the FRB runtime")
    return []


def main(argv):
    paths = [pathlib.Path(arg) for arg in argv]
    if not paths:
        print("::error::no library given — nothing was checked", file=sys.stderr)
        return 1

    print(f"loading {len(paths)} library/libraries on {sys.platform}:")
    complaints = []
    for path in paths:
        complaints.extend(verify(path))

    if complaints:
        print()
        for line in complaints:
            print(f"::error::{line}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
