#!/usr/bin/env python3
"""Compare compiled function bytes against original assembly.

Extracts bytes from a compiled ELF .o file and compares them
instruction-by-instruction against the original .o file (assembled
from the authoritative .s source). Relocations are handled by
masking out the relocated bits so they don't cause false mismatches.

Usage:
    python3 scripts/compare_bytes.py build/GALE01/src/melee/it/items/ittincle.o itTincle_UnkMotion7_Coll
    python3 scripts/compare_bytes.py build/GALE01/src/melee/it/items/ittincle.o func1 func2 func3
"""

import argparse
import struct
import sys
from pathlib import Path

from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection

# PPC relocation types and the instruction bits they patch.
# Mask = bits that the linker fills in (should be ignored in comparison).
R_PPC_ADDR16_LO = 4  # lower 16 bits
R_PPC_ADDR16_HA = 6  # upper 16 bits (half-word, adjusted)
R_PPC_REL24 = 10     # bits 6..29 (branch relative, 24-bit)
R_PPC_EMB_SDA21 = 109  # bits 11..31 (SDA-relative, 21-bit)

# Which bits to zero out for each relocation type.
# Keyed by the byte offset of the relocation *within* the 4-byte instruction.
RELOC_MASKS = {
    # Type: (alignment within instruction, 32-bit mask of bits to KEEP)
    R_PPC_ADDR16_LO: 0xFFFF0000,   # keep opcode+reg, zero lower 16
    R_PPC_ADDR16_HA: 0xFFFF0000,   # keep opcode+reg, zero lower 16
    R_PPC_REL24:     0xFC000003,   # keep opcode bits and AA/LK
    R_PPC_EMB_SDA21: 0xFFE00000,   # keep opcode+rD, zero 21-bit offset
}

ROOT = Path(__file__).resolve().parents[1]


def resolve_paths(given_path: Path):
    """Return (original_obj, compiled_obj) resolved from the given path."""
    s = str(given_path)
    if "/obj/" in s:
        original = given_path
        compiled = Path(s.replace("/obj/", "/src/"))
    elif "/src/" in s:
        compiled = given_path
        original = Path(s.replace("/src/", "/obj/"))
    else:
        raise SystemExit(
            f"Cannot determine obj/src pair for: {given_path}\n"
            "Expected path containing /obj/ or /src/"
        )
    if not original.exists():
        raise SystemExit(f"Original object not found: {original}")
    if not compiled.exists():
        raise SystemExit(f"Compiled object not found: {compiled}")
    return original, compiled


def get_function_info(elf, func_name):
    """Return (offset_in_text, size) for a function symbol, or None."""
    symtab = elf.get_section_by_name(".symtab")
    if not isinstance(symtab, SymbolTableSection):
        return None
    for sym in symtab.iter_symbols():
        if sym.name == func_name and sym["st_info"]["type"] == "STT_FUNC":
            return sym["st_value"], sym["st_size"]
    return None


def get_relocations(elf, section_name=".rela.text"):
    """Return dict mapping byte offset -> (reloc_type, symbol_name)."""
    rela = elf.get_section_by_name(section_name)
    if rela is None:
        return {}
    symtab = elf.get_section_by_name(".symtab")
    relocs = {}
    for rel in rela.iter_relocations():
        offset = rel["r_offset"]
        rtype = rel["r_info_type"]
        sym_idx = rel["r_info_sym"]
        sym = symtab.get_symbol(sym_idx)
        sym_name = sym.name if sym else f"<sym#{sym_idx}>"
        relocs[offset] = (rtype, sym_name)
    return relocs


def mask_instruction(word, reloc_type):
    """Zero out the bits that a relocation would patch."""
    keep = RELOC_MASKS.get(reloc_type)
    if keep is not None:
        return word & keep
    # Unknown relocation type -- don't mask, but warn
    return word


def compare_function(orig_elf, comp_elf, func_name, verbose=False,
                     quiet=False):
    """Compare a single function. Returns True if matched."""
    orig_info = get_function_info(orig_elf, func_name)
    if orig_info is None:
        print(f"ERROR: Function '{func_name}' not found in original object")
        return False

    comp_info = get_function_info(comp_elf, func_name)
    if comp_info is None:
        print(f"ERROR: Function '{func_name}' not found in compiled object")
        return False

    orig_offset, orig_size = orig_info
    comp_offset, comp_size = comp_info

    if orig_size != comp_size:
        print(
            f"SIZE MISMATCH: {func_name}: "
            f"original={orig_size} bytes, compiled={comp_size} bytes"
        )

    orig_text = orig_elf.get_section_by_name(".text").data()
    comp_text = comp_elf.get_section_by_name(".text").data()

    orig_bytes = orig_text[orig_offset:orig_offset + orig_size]
    comp_bytes = comp_text[comp_offset:comp_offset + comp_size]

    # Build relocation maps for both objects (offset relative to function)
    orig_relocs = get_relocations(orig_elf)
    comp_relocs = get_relocations(comp_elf)

    # Map relocations to instruction offsets within the function
    def func_relocs(all_relocs, func_start, func_size):
        """Return dict: instruction_offset_in_func -> (reloc_type, sym)."""
        result = {}
        for abs_off, (rtype, sym) in all_relocs.items():
            if func_start <= abs_off < func_start + func_size:
                # Align to instruction boundary
                instr_off = (abs_off & ~3) - func_start
                result[instr_off] = (rtype, sym)
        return result

    orig_func_relocs = func_relocs(orig_relocs, orig_offset, orig_size)
    comp_func_relocs = func_relocs(comp_relocs, comp_offset, comp_size)

    # Compare instruction by instruction
    max_insns = max(len(orig_bytes), len(comp_bytes)) // 4
    mismatches = 0
    reloc_diffs = 0
    lines = []

    for i in range(max_insns):
        byte_off = i * 4

        if byte_off + 4 > len(orig_bytes):
            lines.append(
                f"  +{byte_off:04X}:  --------  "
                f"{comp_bytes[byte_off:byte_off+4].hex().upper():>8s}  "
                f"EXTRA (compiled)"
            )
            mismatches += 1
            continue
        if byte_off + 4 > len(comp_bytes):
            lines.append(
                f"  +{byte_off:04X}:  "
                f"{orig_bytes[byte_off:byte_off+4].hex().upper():>8s}  "
                f"--------  EXTRA (original)"
            )
            mismatches += 1
            continue

        orig_word = struct.unpack(">I", orig_bytes[byte_off:byte_off + 4])[0]
        comp_word = struct.unpack(">I", comp_bytes[byte_off:byte_off + 4])[0]

        # Check for relocations at this instruction
        orig_rel = orig_func_relocs.get(byte_off)
        comp_rel = comp_func_relocs.get(byte_off)

        has_reloc = orig_rel is not None or comp_rel is not None
        reloc_note = ""

        if has_reloc:
            # Determine the relocation type to use for masking
            # Prefer the original's type, fall back to compiled's
            if orig_rel and comp_rel:
                orig_rtype, orig_sym = orig_rel
                comp_rtype, comp_sym = comp_rel
                mask_type = orig_rtype
                if orig_rtype != comp_rtype:
                    reloc_note = (
                        f"  RELOC TYPE DIFF: orig={orig_rtype} "
                        f"comp={comp_rtype}"
                    )
                elif orig_sym != comp_sym:
                    reloc_note = (
                        f"  RELOC SYM DIFF: orig={orig_sym} "
                        f"comp={comp_sym}"
                    )
                    reloc_diffs += 1
                else:
                    reloc_note = f"  [reloc: {orig_sym}]"
            elif orig_rel:
                mask_type = orig_rel[0]
                reloc_note = (
                    f"  RELOC ONLY IN ORIG: {orig_rel[1]} "
                    f"(type={orig_rel[0]})"
                )
            else:
                mask_type = comp_rel[0]
                reloc_note = (
                    f"  RELOC ONLY IN COMP: {comp_rel[1]} "
                    f"(type={comp_rel[0]})"
                )

            masked_orig = mask_instruction(orig_word, mask_type)
            masked_comp = mask_instruction(comp_word, mask_type)
            match = masked_orig == masked_comp
        else:
            match = orig_word == comp_word

        if not match:
            mismatches += 1
            status = "<<< MISMATCH"
        elif has_reloc:
            status = "ok (reloc)" + reloc_note
            reloc_note = ""
        else:
            status = "ok"

        line = (
            f"  +{byte_off:04X}:  {orig_word:08X}  {comp_word:08X}  "
            f"{status}"
        )
        if reloc_note:
            line += reloc_note

        lines.append(line)

    # Print results
    total = max_insns
    matched = total - mismatches
    pct = (matched / total * 100) if total > 0 else 0

    if mismatches == 0 and reloc_diffs == 0:
        header = f"MATCH: {func_name} ({total} instructions, {orig_size} bytes)"
    else:
        header = (
            f"DIFF:  {func_name} "
            f"({matched}/{total} instructions match, "
            f"{mismatches} differ, {orig_size} bytes, {pct:.1f}%)"
        )
        if reloc_diffs > 0:
            header += f" [{reloc_diffs} relocation target diffs]"

    print(header)

    if not quiet:
        if verbose:
            # Show all instructions
            print(
                f"  {'OFFSET':>6s}  {'ORIGINAL':>8s}  "
                f"{'COMPILED':>8s}  STATUS"
            )
            for line in lines:
                print(line)
        elif mismatches > 0 or reloc_diffs > 0:
            # Default: only show mismatched lines
            print(
                f"  {'OFFSET':>6s}  {'ORIGINAL':>8s}  "
                f"{'COMPILED':>8s}  STATUS"
            )
            for line in lines:
                if "MISMATCH" in line or "EXTRA" in line or "DIFF" in line:
                    print(line)

    print()
    return mismatches == 0


def main():
    parser = argparse.ArgumentParser(
        description="Compare compiled function bytes against original assembly"
    )
    parser.add_argument(
        "object_file",
        type=str,
        help=(
            "Path to the compiled .o file "
            "(e.g. build/GALE01/src/melee/it/items/ittincle.o)"
        ),
    )
    parser.add_argument(
        "functions",
        nargs="+",
        help="Function name(s) to compare",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        default=False,
        help="Show all instructions, not just mismatches",
    )
    parser.add_argument(
        "-q", "--quiet",
        action="store_true",
        default=False,
        help="Only print summary line per function",
    )
    args = parser.parse_args()

    obj_path = Path(args.object_file)
    if not obj_path.is_absolute():
        obj_path = ROOT / obj_path

    if not obj_path.exists():
        raise SystemExit(f"Object file not found: {obj_path}")

    original, compiled = resolve_paths(obj_path)

    with open(original, "rb") as f:
        orig_elf = ELFFile(f)
        with open(compiled, "rb") as g:
            comp_elf = ELFFile(g)

            all_matched = True
            for func in args.functions:
                matched = compare_function(
                    orig_elf, comp_elf, func,
                    verbose=args.verbose,
                    quiet=args.quiet,
                )
                if not matched:
                    all_matched = False

    sys.exit(0 if all_matched else 1)


if __name__ == "__main__":
    main()
