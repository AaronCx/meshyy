#!/usr/bin/env bash
# meshyy — structural clean-room check (design doc §0.1).
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# Cannot prove a negative about what a human read. What it CAN do is catch the
# mechanical ways mosh source would enter the tree: a submodule, a vendored
# copy, a dependency, or files carrying its distinctive identifiers.
#
# Design doc §0.1 permits naming mosh in prose — the README and docs must be able
# to explain what meshyy is not — so prose is excluded and source is not.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 1. No submodules at all. meshyy vendors nothing.
if [[ -f .gitmodules ]]; then
    echo "FAIL: .gitmodules exists. meshyy vendors nothing; see docs/DESIGN.md §0.1."
    fail=1
fi

# 2. No directory named after mosh or a known fork.
if find . -path ./.git -prune -o -type d \
        \( -iname '*mosh*' -o -iname '*blinksh*' \) -print 2>/dev/null | grep -q .; then
    echo "FAIL: a directory named after mosh or a fork of it exists."
    fail=1
fi

# 3. mosh's distinctive identifiers must not appear in source. These are names
#    from its published protocol and man pages, so seeing them in OUR source
#    would mean either a copy or an attempt at wire compatibility — and design
#    doc §2 forbids the latter as explicitly as §0.1 forbids the former.
markers='MOSH_KEY|MOSH_CONNECT|mosh-server|mosh-client|MOSH_SERVER_NETWORK_TMOUT|TransportSender|CompleteTerminal'
if grep -rlnE "$markers" Sources Tests 2>/dev/null | grep -q .; then
    echo "FAIL: mosh protocol identifiers appear in Sources or Tests:"
    grep -rnE "$markers" Sources Tests 2>/dev/null | sed 's/^/      /'
    echo "      meshyy is not wire compatible with mosh (design doc §2) and does"
    echo "      not derive from its source (§0.1)."
    fail=1
fi

# 4. No copyleft licence text anywhere outside docs.
if grep -rlniE 'GNU (GENERAL|LESSER|AFFERO) PUBLIC LICENSE' \
      --exclude-dir=.git --exclude-dir=.build --exclude-dir=docs . 2>/dev/null | grep -q .; then
    echo "FAIL: a GPL/LGPL/AGPL licence text is present in the tree."
    fail=1
fi

# 5. The ALPN must not be anything a mosh implementation would negotiate.
if grep -rn 'alpn' Sources --include='*.swift' -i 2>/dev/null | grep -qi 'mosh'; then
    echo "FAIL: the ALPN identifier references mosh. Incompatibility is a feature (§2)."
    fail=1
fi

if [[ "$fail" -eq 0 ]]; then
    echo "clean-room: OK (no submodules, no mosh source or identifiers, no copyleft licences)"
fi
exit "$fail"
