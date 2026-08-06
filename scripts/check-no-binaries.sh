#!/usr/bin/env bash
# meshyy — no compiled binaries in the tree (audit follow-up PR 1).
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# A 35 KB Mach-O executable sat at the repo root, tracked, for weeks. On a
# project whose entire value proposition is a defensible clean-room licence
# claim, an unexplained compiled binary is the worst-looking artifact a tree
# can carry: nobody auditing it can know what is inside. This is a FILE-TYPE
# check, not an extension check — the offender had no extension.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
while IFS= read -r tracked; do
    [[ -f $tracked ]] || continue
    # First four bytes decide: Mach-O (feedface/feedfacf/cafebabe, both
    # endiannesses) or ELF (7f454c46). Reading four bytes of every tracked
    # file is cheap; the tree is small by design.
    magic=$(xxd -p -l4 "$tracked" 2>/dev/null || true)
    case $magic in
        feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|7f454c46)
            echo "FAIL: $tracked is a compiled binary ($magic). Nothing compiled belongs in the tree."
            fail=1
            ;;
    esac
done < <(git ls-files)

if [[ $fail -eq 0 ]]; then
    echo "OK: no Mach-O or ELF files among $(git ls-files | wc -l | tr -d ' ') tracked files."
fi
exit $fail
