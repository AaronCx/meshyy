#!/usr/bin/env bash
# meshyy — every source file carries an MIT header (design doc §0.3).
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
while IFS= read -r file; do
    head -4 "$file" | grep -q 'MIT licence — see LICENSE' || {
        echo "FAIL: $file has no MIT header in its first four lines."
        fail=1
    }
done < <(find Sources Tests -name '*.swift' -type f 2>/dev/null)

while IFS= read -r file; do
    head -6 "$file" | grep -q 'MIT licence — see LICENSE' || {
        echo "FAIL: $file has no MIT header."
        fail=1
    }
done < <(find scripts -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null)

if [[ "$fail" -eq 0 ]]; then
    echo "headers: OK (every source file carries an MIT header)"
fi
exit "$fail"
