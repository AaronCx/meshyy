#!/usr/bin/env bash
# meshyy — dependency licence allowlist (design doc §0.3).
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# meshyy's policy is stronger than an allowlist: zero dependencies. That makes
# the check simple and unambiguous — if Package.swift or Package.resolved
# acquires anything, the build fails and a human decides.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 1. Package.swift must declare no dependencies.
if ! grep -qE '^\s*dependencies:\s*\[\s*\]\s*,?\s*$' Package.swift; then
    echo "FAIL: Package.swift no longer declares an empty top-level dependencies array."
    echo "      meshyy is zero-dependency by policy (CLAUDE.md, docs/provenance.md)."
    echo "      Adding a dependency is a design decision, not a commit."
    fail=1
fi

# 2. No resolved dependency graph should exist at all.
if [[ -f Package.resolved ]]; then
    pins=$(grep -c '"identity"' Package.resolved || true)
    if [[ "$pins" -gt 0 ]]; then
        echo "FAIL: Package.resolved pins $pins dependencies; expected none."
        fail=1
    fi
fi

# 3. No vendored source trees.
if [[ -d Vendor ]] || [[ -d ThirdParty ]]; then
    echo "FAIL: a vendored source tree exists. Record it in NOTICE and remove this check deliberately."
    fail=1
fi

# 4. Guard against a GPL/AGPL/LGPL licence file appearing anywhere in-tree.
if grep -rlniE 'GNU (GENERAL|LESSER|AFFERO) PUBLIC LICENSE' \
      --exclude-dir=.git --exclude-dir=.build --exclude-dir=docs . 2>/dev/null | head -1 | grep -q .; then
    echo "FAIL: a GPL/LGPL/AGPL licence text is present in the tree."
    echo "      This is the one thing meshyy exists to avoid. See docs/DESIGN.md §0."
    fail=1
fi

if [[ "$fail" -eq 0 ]]; then
    echo "licences: OK (zero dependencies, no vendored trees, no copyleft licence texts)"
fi
exit "$fail"
