#!/usr/bin/env bash
# meshyy — every test target must actually be run by a job, and every declared
# dependency must actually be imported.
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# Both halves close the same class of failure: something that LOOKS like coverage
# and is not.
#
#  * A test target nobody runs is worse than no tests — it reports green and
#    catches nothing. meshyy shipped that state for a day: 40 of 127 functions were
#    gated out of CI, and they were exactly the transport-level resume tests. The
#    §6.4 property test could not see a byte-losing client bug, and the tests that
#    could were dark.
#  * A dependency nobody imports reads, from the manifest, like a wired-up harness.
#    `MeshyyChaos` sat declared on MeshyyCoreTests and unimported for the same
#    reason: nothing in that area ran on merge, so nobody noticed.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 1. Every test target is executed by the CI test step.
#    `swift test` with no --filter runs all of them, so the check is that no job
#    narrows the run and that no suite is gated behind an env var.
# Parsed in Python because `.testTarget(` and its `name:` sit on separate lines,
# which a line-oriented grep cannot span.
declared=$(python3 - <<'PY'
import re, pathlib
manifest = pathlib.Path("Package.swift").read_text()
print(" ".join(sorted(set(
    re.findall(r'\.testTarget\(\s*name:\s*"([A-Za-z]+)"', manifest)
))))
PY
)
if [[ -z "$declared" ]]; then
    echo "FAIL: no test targets found in Package.swift — did the manifest change shape?"
    fail=1
fi

if grep -nE '^\s*run:.*swift test.*--filter' .github/workflows/*.yml >/dev/null 2>&1; then
    echo "FAIL: a CI job runs 'swift test --filter', so some tests never run on merge."
    grep -nE '^\s*run:.*swift test.*--filter' .github/workflows/*.yml | sed 's/^/      /'
    fail=1
fi

# A suite gated on an environment variable is the same failure wearing a flag.
if grep -rnE '\.enabled\(if:.*environment\[' Tests/ >/dev/null 2>&1; then
    echo "FAIL: a suite is gated on an environment variable, so CI may silently skip it:"
    grep -rnE '\.enabled\(if:.*environment\[' Tests/ | sed 's/^/      /'
    echo "      A capability probe is fine; an env-var opt-in is a bucket nobody reads."
    fail=1
fi

# 2. Every dependency a test target declares is imported by at least one of its files.
for target in $declared; do
    deps=$(python3 - "$target" <<'PY'
import re, sys, pathlib
name = sys.argv[1]
manifest = pathlib.Path("Package.swift").read_text()
m = re.search(r'\.testTarget\(\s*name: "' + re.escape(name) + r'".*?dependencies: \[(.*?)\]', manifest, re.S)
if m:
    print(" ".join(sorted(set(re.findall(r'"([A-Za-z]+)"', m.group(1))))))
PY
)
    for dep in $deps; do
        if ! grep -rqE "^\s*(@testable\s+)?import\s+$dep\b" "Tests/$target" 2>/dev/null; then
            echo "FAIL: $target declares a dependency on $dep but no file imports it."
            echo "      Either use it or drop it — a declared-and-unimported dependency"
            echo "      reads like coverage from the manifest."
            fail=1
        fi
    done
done

if [[ "$fail" -eq 0 ]]; then
    echo "test coverage: OK (every test target runs on merge; no unimported test dependencies)"
fi
exit "$fail"
