#!/usr/bin/env python3
"""Refuse a release archive that does not hold what its name says it holds.

The build workflow ends in a hand-written list of `tar` lines, one per
platform, each naming a source directory and an archive. Nothing checks that
the two agree, and the failure a wrong line produces is invisible until a
consumer downloads the archive for their platform and gets somebody else's
binary.

Checking the architecture is not enough, and that is the whole reason this
script parses rather than shells out to `file`:

  * a Linux arm64 `.so` and an Android arm64 `.so` have the SAME ELF header --
    ELF64, e_machine 0xB7. So do the two x86_64 ones.
  * a macOS arm64 `.dylib`, an iOS device `.dylib` and an iOS simulator
    `.dylib` have the SAME Mach-O cputype.

Those are exactly the pairs a copy-paste slip in that list produces, so an
arch-only check would be green on the likeliest error. The discriminators
below are measured, not assumed:

  ELF     -- the libc in DT_NEEDED. glibc asks for `libc.so.6`; Bionic asks
             for `libc.so` and brings `liblog.so` with it.
  Mach-O  -- the platform field of LC_BUILD_VERSION: 1 macOS, 2 iOS,
             7 iOS simulator.

Deployment targets (`minos`) are PRINTED and not asserted. They are readable
here and a gate over them is tempting, but the values differ across the iOS
artefacts for reasons that belong with `check-targets`, not here.

Python, in a project whose scripts are otherwise Dart, for the reason
`verify_android_alignment.py` gives: this runs in workflow jobs that carry no
Flutter toolchain -- the release job is a checkout and a download -- and
`python3` is on every runner they use.

Usage:
    python3 scripts/verify_release_artifacts.py --crate-name NAME DIR

DIR is either a directory of `*.tar.gz` release archives or the directory
`actions/download-artifact` unpacked, one subdirectory per artefact. Both are
recognised by what is in them.

Every platform in the table must be present and every entry present must be in
the table: a check that passes because it found nothing to look at is not a
check, and one that ignores an archive nobody taught it about is worse.

That two-sided rule is why this file is rendered from the template rather than
copied like its neighbour: the set of archives a release carries depends on
whether the project builds for the Web, and a table naming an artefact the
build never produces would fail every release of a project without it.
"""

import argparse
import pathlib
import struct
import sys
import tarfile
import tempfile

# ELF
ELF_MAGIC = b"\x7fELF"
PT_DYNAMIC, DT_NULL, DT_NEEDED, DT_STRTAB = 2, 0, 1, 5
EM_386, EM_ARM, EM_X86_64, EM_AARCH64 = 0x03, 0x28, 0x3E, 0xB7

# Mach-O (64-bit, little endian: every Apple target this package ships for)
MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")
LC_BUILD_VERSION = 0x32
CPU_ARM64, CPU_X86_64 = 0x0100000C, 0x01000007
PLATFORM_MACOS, PLATFORM_IOS, PLATFORM_IOS_SIMULATOR = 1, 2, 7
PLATFORM_NAMES = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 7: "iOS simulator"}

WASM_MAGIC = b"\x00asm"

# platform slug -> what an archive for it must contain.
#
#   lib      'so' | 'dylib' | 'dll' | 'wasm'
#   arch     e_machine (ELF), cputype (Mach-O), IMAGE_FILE_MACHINE (PE)
#   flavour  'glibc' | 'bionic' for ELF, an LC_BUILD_VERSION platform for Mach-O
EXPECTED = {
    "linux-x86_64":         {"lib": "so",    "arch": EM_X86_64,   "flavour": "glibc"},
    "linux-arm64":          {"lib": "so",    "arch": EM_AARCH64,  "flavour": "glibc"},
    "android-arm64-v8a":    {"lib": "so",    "arch": EM_AARCH64,  "flavour": "bionic"},
    "android-armeabi-v7a":  {"lib": "so",    "arch": EM_ARM,      "flavour": "bionic"},
    "android-x86_64":       {"lib": "so",    "arch": EM_X86_64,   "flavour": "bionic"},
    "macos-arm64":          {"lib": "dylib", "arch": CPU_ARM64,   "flavour": PLATFORM_MACOS},
    "macos-x86_64":         {"lib": "dylib", "arch": CPU_X86_64,  "flavour": PLATFORM_MACOS},
    "ios-device-arm64":     {"lib": "dylib", "arch": CPU_ARM64,   "flavour": PLATFORM_IOS},
    "ios-simulator-arm64":  {"lib": "dylib", "arch": CPU_ARM64,   "flavour": PLATFORM_IOS_SIMULATOR},
    "ios-simulator-x86_64": {"lib": "dylib", "arch": CPU_X86_64,  "flavour": PLATFORM_IOS_SIMULATOR},
    "windows-x86_64":       {"lib": "dll",   "arch": 0x8664,      "flavour": None},
    "wasm32":               {"lib": "wasm",  "arch": None,        "flavour": None},
}


def elf_facts(data):
    """(e_machine, [DT_NEEDED names]) read through the program headers."""
    is64 = data[4] == 2
    en = "<" if data[5] == 1 else ">"
    machine = struct.unpack_from(en + "H", data, 18)[0]

    if is64:
        ph_off = struct.unpack_from(en + "Q", data, 0x20)[0]
        ph_size, ph_num = struct.unpack_from(en + "HH", data, 0x36)
        word, entry = en + "Q", 16
    else:
        ph_off = struct.unpack_from(en + "I", data, 0x1C)[0]
        ph_size, ph_num = struct.unpack_from(en + "HH", data, 0x2A)
        word, entry = en + "I", 8

    dynamic = None
    for i in range(ph_num):
        base = ph_off + i * ph_size
        if struct.unpack_from(en + "I", data, base)[0] == PT_DYNAMIC:
            dynamic = struct.unpack_from(word, data, base + (8 if is64 else 4))[0]
            break
    if dynamic is None:
        return machine, []

    needed_offsets, strtab = [], None
    cursor = dynamic
    while True:
        tag, value = struct.unpack_from(word[0] + word[1] * 2, data, cursor)
        if tag == DT_NULL:
            break
        if tag == DT_NEEDED:
            needed_offsets.append(value)
        elif tag == DT_STRTAB:
            strtab = value
        cursor += entry

    names = []
    if strtab is not None:
        for offset in needed_offsets:
            end = data.index(b"\0", strtab + offset)
            names.append(data[strtab + offset : end].decode())
    return machine, names


def macho_facts(data):
    """(cputype, LC_BUILD_VERSION platform, minos as text)."""
    cputype = struct.unpack_from("<I", data, 4)[0]
    ncmds = struct.unpack_from("<I", data, 16)[0]
    cursor, platform, minos = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, cursor)
        if cmd == LC_BUILD_VERSION:
            platform, packed, _sdk = struct.unpack_from("<III", data, cursor + 8)
            minos = f"{packed >> 16}.{(packed >> 8) & 0xFF}"
        cursor += size
    return cputype, platform, minos


def check(slug, path, expected, report):
    """Append a complaint to `report` for every way `path` is not `expected`."""
    data = path.read_bytes()

    if expected["lib"] == "wasm":
        if data[:4] != WASM_MAGIC:
            report.append(f"{slug}: {path.name} is not a WebAssembly module")
        else:
            print(f"  {slug:22s} {path.name:24s} wasm v{struct.unpack_from('<I', data, 4)[0]}")
        return

    if expected["lib"] == "so":
        if data[:4] != ELF_MAGIC:
            report.append(f"{slug}: {path.name} is not an ELF object")
            return
        machine, needed = elf_facts(data)
        flavour = "glibc" if "libc.so.6" in needed else ("bionic" if "libc.so" in needed else "?")
        print(f"  {slug:22s} {path.name:24s} ELF e_machine=0x{machine:02X} libc={flavour}")
        if machine != expected["arch"]:
            report.append(
                f"{slug}: {path.name} is e_machine 0x{machine:02X}, expected "
                f"0x{expected['arch']:02X}"
            )
        if flavour != expected["flavour"]:
            report.append(
                f"{slug}: {path.name} links {flavour} ({', '.join(needed) or 'nothing'}), "
                f"expected {expected['flavour']} — this is an archive holding another "
                f"platform's library, not a build flag"
            )
        return

    if expected["lib"] == "dylib":
        if data[:4] not in MACHO_MAGICS:
            report.append(f"{slug}: {path.name} is not a Mach-O object")
            return
        cputype, platform, minos = macho_facts(data)
        name = PLATFORM_NAMES.get(platform, "?")
        print(f"  {slug:22s} {path.name:24s} Mach-O cputype=0x{cputype:08X} platform={name} minos={minos}")
        if cputype != expected["arch"]:
            report.append(
                f"{slug}: {path.name} is cputype 0x{cputype:08X}, expected "
                f"0x{expected['arch']:08X}"
            )
        if platform != expected["flavour"]:
            report.append(
                f"{slug}: {path.name} was built for {name}, expected "
                f"{PLATFORM_NAMES[expected['flavour']]} — the cputype alone cannot tell "
                f"these apart, which is why this is checked"
            )
        return

    if expected["lib"] == "dll":
        if data[:2] != b"MZ":
            report.append(f"{slug}: {path.name} is not a PE image")
            return
        pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe_offset : pe_offset + 4] != b"PE\0\0":
            report.append(f"{slug}: {path.name} has no PE signature")
            return
        machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
        print(f"  {slug:22s} {path.name:24s} PE machine=0x{machine:04X}")
        if machine != expected["arch"]:
            report.append(
                f"{slug}: {path.name} is PE machine 0x{machine:04X}, expected "
                f"0x{expected['arch']:04X}"
            )


def library_names(crate_name, expected):
    """The file names an archive for this platform must contain."""
    if expected["lib"] == "so":
        return [f"lib{crate_name}.so"]
    if expected["lib"] == "dylib":
        return [f"lib{crate_name}.dylib"]
    if expected["lib"] == "dll":
        return [f"{crate_name}.dll"]
    return [f"{crate_name}_bg.wasm", f"{crate_name}.js"]


def slug_of(name):
    """The platform slug a file or directory name ends with, if any."""
    stem = name[: -len(".tar.gz")] if name.endswith(".tar.gz") else name
    for slug in EXPECTED:
        if stem.endswith("-" + slug):
            return slug
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--crate-name", required=True)
    args = parser.parse_args()

    if not args.directory.is_dir():
        print(f"::error::{args.directory} is not a directory", file=sys.stderr)
        return 1

    archives = sorted(p for p in args.directory.glob("*.tar.gz"))
    entries = {}
    with tempfile.TemporaryDirectory() as scratch:
        if archives:
            for archive in archives:
                slug = slug_of(archive.name)
                if slug is None:
                    entries.setdefault(None, []).append(archive.name)
                    continue
                target = pathlib.Path(scratch) / slug
                with tarfile.open(archive) as tar:
                    tar.extractall(target)
                entries[slug] = target
        else:
            for child in sorted(p for p in args.directory.iterdir() if p.is_dir()):
                slug = slug_of(child.name)
                if slug is None:
                    entries.setdefault(None, []).append(child.name)
                    continue
                entries[slug] = child

        unknown = entries.pop(None, [])
        report = []

        missing = sorted(set(EXPECTED) - set(entries))
        if missing:
            report.append(
                "nothing to check for: " + ", ".join(missing) + " — every platform in "
                "the table must be present, or this reports green over a surface it "
                "never read"
            )
        for name in unknown:
            report.append(
                f"{name} matches no platform this script knows — add it to EXPECTED, or "
                f"the archive list and this check have drifted apart"
            )

        print(f"verifying {len(entries)} platform(s) in {args.directory}:")
        for slug in sorted(entries):
            expected = EXPECTED[slug]
            for filename in library_names(args.crate_name, expected):
                path = entries[slug] / filename
                if not path.is_file():
                    report.append(f"{slug}: {filename} is missing")
                    continue
                if filename.endswith(".js"):
                    # The loader beside the module. Its presence is the check —
                    # it is JavaScript and carries no header to read.
                    print(f"  {slug:22s} {filename:24s} present")
                    continue
                check(slug, path, expected, report)
            for extra in ("LICENSE", "THIRD_PARTY_NOTICES.txt"):
                if archives and not (entries[slug] / extra).is_file():
                    report.append(f"{slug}: {extra} is missing from the archive")

    if report:
        print()
        for line in report:
            print(f"::error::{line}")
        return 1

    print(f"\nall {len(entries)} platform(s) hold what their name says")
    return 0


if __name__ == "__main__":
    sys.exit(main())
