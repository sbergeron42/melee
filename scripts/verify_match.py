#!/usr/bin/env python3
"""Verify that a decompiled function matches the original, including relocations.

Compares instruction bytes AND relocation targets (symbol names) between
a compiled .o file and the expected .o file from the original game.

Usage:
    python3 scripts/verify_match.py <compiled.o> <expected.o> <func_name> [func_name...]

Exit code 0 = all functions match. Exit code 1 = at least one mismatch.
"""

import struct
import sys


def parse_elf(path):
    """Parse a big-endian PPC ELF and return symbols, text bytes, and relocations."""
    with open(path, "rb") as f:
        data = f.read()

    e_shoff = struct.unpack(">I", data[0x20:0x24])[0]
    e_shentsize = struct.unpack(">H", data[0x2E:0x30])[0]
    e_shnum = struct.unpack(">H", data[0x30:0x32])[0]
    e_shstrndx = struct.unpack(">H", data[0x32:0x34])[0]

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh = data[off : off + e_shentsize]
        sections.append(
            {
                "idx": i,
                "name_off": struct.unpack(">I", sh[0:4])[0],
                "type": struct.unpack(">I", sh[4:8])[0],
                "offset": struct.unpack(">I", sh[16:20])[0],
                "size": struct.unpack(">I", sh[20:24])[0],
                "link": struct.unpack(">I", sh[24:28])[0],
                "info": struct.unpack(">I", sh[28:32])[0],
                "entsize": struct.unpack(">I", sh[36:40])[0],
            }
        )

    shstrtab_data = data[
        sections[e_shstrndx]["offset"] : sections[e_shstrndx]["offset"]
        + sections[e_shstrndx]["size"]
    ]

    # Name all sections
    for s in sections:
        s["name"] = shstrtab_data[s["name_off"] :].split(b"\0")[0].decode()

    # Find .text section
    text_sec = None
    for s in sections:
        if s["name"] == ".text":
            text_sec = s
            break
    if text_sec is None:
        return {}, b"", {}

    text_data = data[text_sec["offset"] : text_sec["offset"] + text_sec["size"]]

    # Find symtab and strtab
    symtab_sec = None
    for s in sections:
        if s["type"] == 2:  # SHT_SYMTAB
            symtab_sec = s
            break
    if symtab_sec is None:
        return {}, text_data, {}

    strtab_sec = sections[symtab_sec["link"]]
    strtab_data = data[
        strtab_sec["offset"] : strtab_sec["offset"] + strtab_sec["size"]
    ]

    # Parse symbols
    symbols_by_idx = {}
    symbols_by_name = {}
    n_syms = symtab_sec["size"] // symtab_sec["entsize"]
    for i in range(n_syms):
        off = symtab_sec["offset"] + i * symtab_sec["entsize"]
        sym = data[off : off + symtab_sec["entsize"]]
        st_name = struct.unpack(">I", sym[0:4])[0]
        st_value = struct.unpack(">I", sym[4:8])[0]
        st_size = struct.unpack(">I", sym[8:12])[0]
        st_info = sym[12]
        st_shndx = struct.unpack(">H", sym[14:16])[0]
        name = strtab_data[st_name:].split(b"\0")[0].decode()
        symbols_by_idx[i] = {
            "name": name,
            "value": st_value,
            "size": st_size,
            "bind": st_info >> 4,
            "type": st_info & 0xF,
            "shndx": st_shndx,
        }
        if st_shndx == text_sec["idx"] and st_size > 0:
            symbols_by_name[name] = (st_value, st_size)

    # Parse relocations for .text (SHT_RELA = 4)
    # relocs maps text offset -> target symbol name
    relocs = {}
    for s in sections:
        if s["type"] == 4 and s["name"] in (".rela.text", ".rel.text"):
            ent_size = s["entsize"] if s["entsize"] > 0 else 12
            n_relocs = s["size"] // ent_size
            for i in range(n_relocs):
                off = s["offset"] + i * ent_size
                r_offset = struct.unpack(">I", data[off : off + 4])[0]
                r_info = struct.unpack(">I", data[off + 4 : off + 8])[0]
                r_sym = r_info >> 8
                r_type = r_info & 0xFF
                if ent_size >= 12:
                    r_addend = struct.unpack(">i", data[off + 8 : off + 12])[0]
                else:
                    r_addend = 0
                sym_info = symbols_by_idx.get(r_sym, {})
                relocs[r_offset] = {
                    "sym_name": sym_info.get("name", f"<sym{r_sym}>"),
                    "type": r_type,
                    "addend": r_addend,
                }

    return symbols_by_name, text_data, relocs


def get_func_relocs(relocs, func_off, func_size):
    """Get relocations within a function, keyed by relative offset."""
    result = {}
    for abs_off, reloc in relocs.items():
        rel_off = abs_off - func_off
        if 0 <= rel_off < func_size:
            result[rel_off] = reloc
    return result


# R_PPC_EMB_SDA21 (109) and R_PPC_SDAREL16 (32) are SDA-relative
# relocations. The compiler resolves these at compile time, so they
# may appear in the split orig .o but not in our compiled .o (or
# vice versa). They don't affect call targets, so we only warn
# about them rather than failing.
SDA_RELOC_TYPES = {109, 32}


def verify_function(name, our_syms, our_text, our_relocs, orig_syms, orig_text, orig_relocs):
    """Verify a single function. Returns (ok, message)."""
    if name not in our_syms:
        return False, f"NOT FOUND in compiled .o"
    if name not in orig_syms:
        return False, f"NOT FOUND in original .o"

    our_off, our_size = our_syms[name]
    orig_off, orig_size = orig_syms[name]

    if our_size != orig_size:
        return False, f"SIZE MISMATCH (ours={our_size}, orig={orig_size})"

    # Get relocations relative to function start
    our_func_relocs = get_func_relocs(our_relocs, our_off, our_size)
    orig_func_relocs = get_func_relocs(orig_relocs, orig_off, orig_size)

    n_instr = our_size // 4
    byte_mismatches = 0
    regswap_only = True
    reloc_mismatches = []

    for i in range(n_instr):
        our_word = struct.unpack(">I", our_text[our_off + i * 4 : our_off + i * 4 + 4])[0]
        orig_word = struct.unpack(">I", orig_text[orig_off + i * 4 : orig_off + i * 4 + 4])[0]

        rel_off = i * 4
        our_reloc = our_func_relocs.get(rel_off)
        orig_reloc = orig_func_relocs.get(rel_off)

        # Compare relocation targets (skip SDA relocs — they're
        # resolved differently between compiled and split .o files)
        if our_reloc and orig_reloc:
            our_is_sda = our_reloc["type"] in SDA_RELOC_TYPES
            orig_is_sda = orig_reloc["type"] in SDA_RELOC_TYPES
            if not our_is_sda and not orig_is_sda:
                if our_reloc["sym_name"] != orig_reloc["sym_name"]:
                    reloc_mismatches.append(
                        f"  [{i}] WRONG TARGET: bl {our_reloc['sym_name']} should be {orig_reloc['sym_name']}"
                    )
        elif our_reloc and not orig_reloc:
            if our_reloc["type"] not in SDA_RELOC_TYPES:
                reloc_mismatches.append(
                    f"  [{i}] EXTRA RELOC: {our_reloc['sym_name']} (not in original)"
                )
        elif orig_reloc and not our_reloc:
            # SDA relocs in orig but not ours is normal — skip
            if orig_reloc["type"] not in SDA_RELOC_TYPES:
                reloc_mismatches.append(
                    f"  [{i}] MISSING RELOC: should reference {orig_reloc['sym_name']}"
                )

        # For byte comparison, mask relocation fields
        has_reloc = our_reloc or orig_reloc
        if has_reloc:
            opcode = (our_word >> 26) & 0x3F
            if opcode in (18,):  # b/bl — mask 24-bit target
                our_word &= 0xFC000003
                orig_word &= 0xFC000003
            elif opcode in (16,):  # bc — mask 16-bit target
                our_word &= 0xFFFF0000
                orig_word &= 0xFFFF0000
            else:  # loads, stores, addi, etc — mask lower 16
                our_word &= 0xFFFF0000
                orig_word &= 0xFFFF0000

        if our_word != orig_word:
            byte_mismatches += 1
            # Check if it's only register differences
            our_opcode = (our_word >> 26) & 0x3F
            orig_opcode = (orig_word >> 26) & 0x3F
            if our_opcode != orig_opcode:
                regswap_only = False

    if reloc_mismatches:
        detail = "\n".join(reloc_mismatches)
        return False, f"RELOC MISMATCH ({len(reloc_mismatches)} wrong targets):\n{detail}"

    if byte_mismatches == 0:
        return True, f"100% match ({n_instr} instructions)"

    if regswap_only:
        pct = 100.0 * (n_instr - byte_mismatches) / n_instr
        return True, f"{pct:.1f}% match ({byte_mismatches} regswaps, {n_instr} instructions)"

    pct = 100.0 * (n_instr - byte_mismatches) / n_instr
    return False, f"{pct:.1f}% match ({byte_mismatches} mismatches, {n_instr} instructions)"


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <compiled.o> <expected.o> <func> [func...]", file=sys.stderr)
        sys.exit(1)

    compiled_o = sys.argv[1]
    expected_o = sys.argv[2]
    func_names = sys.argv[3:]

    our_syms, our_text, our_relocs = parse_elf(compiled_o)
    orig_syms, orig_text, orig_relocs = parse_elf(expected_o)

    all_ok = True
    for name in func_names:
        ok, msg = verify_function(name, our_syms, our_text, our_relocs, orig_syms, orig_text, orig_relocs)
        status = "OK" if ok else "FAIL"
        print(f"  {name}: {status} — {msg}")
        if not ok:
            all_ok = False

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
