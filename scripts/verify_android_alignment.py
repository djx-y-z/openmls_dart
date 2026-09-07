#!/usr/bin/env python3
"""Refuse an Android library whose segments are not 16 KB-aligned.

Google Play has required an app's bundled native libraries to be 16 KB-aligned,
for apps targeting Android 15 or later, since 1 November 2025. A misaligned .so
here does not break this package's tests — it makes the CONSUMER's app
unpublishable, which is the worst place to find out.

The alignment is not a property of this source, and not of the NDK either:
`cargo-ndk` is what passes `-Wl,-z,max-page-size=16384` and its
`common-page-size` twin. Artefacts built with NDK r26 and r28 measure
`p_align=0x4000` alike. So the property belongs to the TOOL, the tool version is
pinned by hand in the workflows, and nothing bumps that pin for you — which is
exactly why this measures the result instead of trusting the pin.

Python, in a project whose scripts are otherwise Dart, because this runs in the
Android cross-compile jobs and those have no Flutter toolchain: making an ELF
header check pull in an SDK would cost more than the check. `python3` is on
every runner these jobs use.

Usage:
    python3 scripts/verify_android_alignment.py [FILE...]

With no arguments it checks every shared library under the Android target
directories, and fails when there are none — a check that silently passes
because it found nothing to look at is not a check.
"""

import glob
import struct
import sys

# 16 KB. A larger page size (65536) also satisfies Play, hence the modulo
# rather than an equality test.
REQUIRED_ALIGNMENT = 16384

PT_LOAD = 1

DEFAULT_GLOB = "rust/target/*android*/release/*.so"


def load_segment_alignments(path):
    """Return (is_64_bit, [p_align of every PT_LOAD]) for an ELF file."""
    with open(path, "rb") as handle:
        data = handle.read()

    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")

    is_64_bit = data[4] == 2
    endian = "<" if data[5] == 1 else ">"

    if is_64_bit:
        # Elf64_Ehdr: e_phoff at 0x20, e_phentsize/e_phnum at 0x36.
        # Elf64_Phdr: p_type(4) p_flags(4) p_offset(8) p_vaddr(8) p_paddr(8)
        #             p_filesz(8) p_memsz(8) p_align(8) -> p_align at +48.
        (ph_offset,) = struct.unpack_from(endian + "Q", data, 0x20)
        ph_entry_size, ph_count = struct.unpack_from(endian + "HH", data, 0x36)
        align_format, align_offset = "Q", 48
    else:
        # Elf32_Ehdr: e_phoff at 0x1C, e_phentsize/e_phnum at 0x2A.
        # Elf32_Phdr: p_type(4) p_offset(4) p_vaddr(4) p_paddr(4) p_filesz(4)
        #             p_memsz(4) p_flags(4) p_align(4) -> p_align at +28.
        (ph_offset,) = struct.unpack_from(endian + "I", data, 0x1C)
        ph_entry_size, ph_count = struct.unpack_from(endian + "HH", data, 0x2A)
        align_format, align_offset = "I", 28

    alignments = []
    for index in range(ph_count):
        header = ph_offset + index * ph_entry_size
        (segment_type,) = struct.unpack_from(endian + "I", data, header)
        if segment_type == PT_LOAD:
            (alignment,) = struct.unpack_from(
                endian + align_format, data, header + align_offset
            )
            alignments.append(alignment)

    return is_64_bit, alignments


def check(path):
    """Report on one library. Returns True when it is acceptable."""
    try:
        is_64_bit, alignments = load_segment_alignments(path)
    except (OSError, ValueError, struct.error) as error:
        print(f"::error::{path}: cannot read ELF program headers ({error})")
        return False

    if not alignments:
        print(f"::error::{path}: no PT_LOAD segments — nothing to verify")
        return False

    shown = ", ".join(hex(alignment) for alignment in alignments)

    # 32-bit ABIs are outside the requirement, which is a 64-bit one, and they
    # measure 0x1000 correctly. Reporting rather than skipping silently, so the
    # log says which libraries were actually judged.
    if not is_64_bit:
        print(f"  {path}: 32-bit, p_align {shown} — requirement does not apply")
        return True

    misaligned = [a for a in alignments if a == 0 or a % REQUIRED_ALIGNMENT != 0]
    if misaligned:
        print(
            f"::error::{path}: 64-bit PT_LOAD p_align {shown} — not a multiple "
            f"of {hex(REQUIRED_ALIGNMENT)}. Google Play refuses this library in "
            "an app targeting Android 15 or later. The linker flags come from "
            "cargo-ndk: check the version pinned in the Android jobs of "
            "build-*.yml and test-reusable.yml."
        )
        return False

    print(f"  {path}: 64-bit, p_align {shown} — 16 KB aligned")
    return True


def main(argv):
    paths = argv[1:] or sorted(glob.glob(DEFAULT_GLOB))

    if not paths:
        print(
            f"::error::No Android libraries found under {DEFAULT_GLOB}. "
            "Build them first (`make build-android`) — a check that passes "
            "because it found nothing verifies nothing."
        )
        return 1

    print(f"Verifying 16 KB alignment of {len(paths)} librar"
          f"{'y' if len(paths) == 1 else 'ies'}:")

    return 0 if all([check(path) for path in paths]) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
