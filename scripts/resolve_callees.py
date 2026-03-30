#!/usr/bin/env python3
"""Resolve callee signatures for functions in assembly files.

Parses `bl` (branch-link) instructions from a function's assembly,
then searches headers under src/ for each callee's declaration.

Usage:
    python3 scripts/resolve_callees.py <asm_file> <func_name> [func_name...]

Output format:
    HSD_Randi(s32 range) — src/sysdolphin/baselib/random.h:8
    it_80272C6C(Item_GObj* gobj) — src/melee/it/it_2725.h:15
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"

# Keywords that appear before '(' but aren't function names
_KEYWORDS = frozenset({
    "if", "for", "while", "switch", "sizeof",
    "return", "typeof", "defined", "case",
})

# Return type keywords that start a declaration line
_DECL_START = re.compile(
    r"^(/\*.*?\*/\s*)?"  # optional comment prefix
    r"(extern\s+|static\s+|inline\s+)*"
    r"(void|int|s8|s16|s32|s64|u8|u16|u32|u64|f32|f64|float|double"
    r"|bool|char|enum_t|unk_t|size_t|UNK_RET"
    r"|struct\s+\w+\*?|union\s+\w+\*?"
    r"|[A-Z]\w+)"  # type name (HSD_GObj*, Item*, etc.)
)


def build_header_index():
    """Read all .h files under src/ and index declarations by function name.

    Returns dict mapping function name -> (signature, relative_path:line).
    Handles multi-line declarations by joining continuation lines.
    Prefers regular .h files over .static.h files.
    """
    index = {}

    for hfile in SRC_DIR.rglob("*.h"):
        try:
            rel = str(hfile.relative_to(REPO_ROOT))
            is_static = ".static.h" in hfile.name
            lines = hfile.read_text(encoding="utf-8", errors="replace").splitlines()
            nlines = len(lines)

            i = 0
            while i < nlines:
                text = lines[i].strip()
                decl_lineno = i + 1  # 1-based line number
                i += 1

                # Skip preprocessor, comments-only, includes
                if (
                    not text
                    or text.startswith("#")
                    or text.startswith("//")
                ):
                    continue

                # Must have an opening paren to be a declaration
                if "(" not in text:
                    continue

                # If no semicolon yet, join continuation lines
                full = text
                if ";" not in full and "{" not in full:
                    start_i = i
                    while i < nlines and i < start_i + 5:
                        cont = lines[i].strip()
                        i += 1
                        full = full + " " + cont
                        if ";" in cont or "{" in cont:
                            break

                # Must end with semicolon (declaration, not definition)
                if ";" not in full:
                    continue

                # Truncate at the first semicolon
                decl = full[: full.index(";")]

                # Must look like it starts with a return type
                if not _DECL_START.match(decl):
                    continue

                # Extract function name: word immediately before '('
                for m in re.finditer(r"\b(\w+)\s*\(", decl):
                    fname = m.group(1)
                    if fname in _KEYWORDS:
                        continue
                    # Clean up the signature
                    sig = decl.strip()
                    sig = re.sub(r"^/\*.*?\*/\s*", "", sig)
                    sig = re.sub(
                        r"^(extern|static|inline)\s+", "", sig
                    )
                    # Normalize whitespace
                    sig = re.sub(r"\s+", " ", sig)

                    existing = index.get(fname)
                    if existing is None:
                        index[fname] = (sig, f"{rel}:{decl_lineno}")
                    elif is_static:
                        # Don't overwrite a regular .h with a .static.h
                        pass
                    else:
                        # Overwrite .static.h entry with regular .h
                        old_loc = existing[1]
                        if ".static.h" in old_loc:
                            index[fname] = (sig, f"{rel}:{decl_lineno}")
        except (OSError, UnicodeDecodeError):
            continue
    return index


def extract_function_asm(asm_path, func_name):
    """Extract a single function's assembly from a .s file."""
    try:
        text = Path(asm_path).read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""

    # .fn/.endfn format
    pattern = (
        rf"\.fn {re.escape(func_name)}.*?"
        rf"\.endfn {re.escape(func_name)}"
    )
    m = re.search(pattern, text, re.DOTALL)
    if m:
        return m.group(0)

    # Fallback: glabel to next glabel
    pattern = rf"glabel {re.escape(func_name)}\b.*?(?=\nglabel |\Z)"
    m = re.search(pattern, text, re.DOTALL)
    if m:
        return m.group(0)

    return ""


def find_bl_targets(func_asm):
    """Extract unique bl target names from assembly text."""
    targets = []
    seen = set()
    for m in re.finditer(r"\tbl\s+(\w+)", func_asm):
        name = m.group(1)
        if name not in seen:
            seen.add(name)
            targets.append(name)
    return targets


def resolve_callees(asm_path, func_names):
    """Main entry: resolve callees for one or more functions."""
    all_targets = []
    seen = set()

    for func_name in func_names:
        func_asm = extract_function_asm(asm_path, func_name)
        if not func_asm:
            print(
                f"(function {func_name} not found in asm)",
                file=sys.stderr,
            )
            continue

        targets = find_bl_targets(func_asm)
        for t in targets:
            if t not in seen:
                seen.add(t)
                all_targets.append(t)

    if not all_targets:
        return

    # Build index once, then look up all targets
    index = build_header_index()

    header_paths = set()

    for name in all_targets:
        entry = index.get(name)
        if entry:
            sig, loc = entry
            print(f"{sig} \u2014 {loc}")
            # Collect header path (strip :line suffix)
            header_paths.add(loc.rsplit(":", 1)[0])
        else:
            print(f"{name}(...) \u2014 (declaration not found)")

    # Print suggested includes
    if header_paths:
        includes = []
        for hp in sorted(header_paths):
            if hp.startswith("src/melee/"):
                inc = hp[len("src/melee/"):]
                includes.append(f'#include "{inc}"')
            elif hp.startswith("src/sysdolphin/"):
                inc = hp[len("src/sysdolphin/"):]
                includes.append(f"#include <{inc}>")
            elif hp.startswith("src/"):
                inc = hp[len("src/"):]
                includes.append(f"#include <{inc}>")
        if includes:
            print()
            print("SUGGESTED INCLUDES:")
            for inc in sorted(set(includes)):
                print(f"  {inc}")


def main():
    if len(sys.argv) < 3:
        print(
            f"Usage: {sys.argv[0]} <asm_file> <func_name> [func_name...]",
            file=sys.stderr,
        )
        sys.exit(1)

    asm_path = sys.argv[1]
    func_names = sys.argv[2:]
    resolve_callees(asm_path, func_names)


if __name__ == "__main__":
    main()
