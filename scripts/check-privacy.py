#!/usr/bin/env python3
# meshyy — privacy invariants (design doc §9).
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# "CI greps both trees for https?://, analytics, telemetry, sentry, crashlytics,
#  and fails on any hit outside comments and license headers."
#
# The naive version of this — strip //-comments with sed, then grep — is worse
# than no check at all: the `//` inside `https://` matches the comment pattern,
# so every URL in a string literal gets silently truncated into `https:` and the
# gate passes vacuously. That bug was live for one commit and is why this is a
# real scanner rather than a regex.

import pathlib
import re
import sys

PATTERN = re.compile(
    r"https?://|analytics|telemetry|sentry|crashlytics|amplitude|mixpanel"
    r"|firebase|datadog|bugsnag",
    re.IGNORECASE,
)


def strip_comments(source: str) -> list[tuple[int, str]]:
    """Return (line_number, code) with comments removed and string literals kept.

    Tracks whether the cursor is inside a double-quoted string so the `//` in a
    URL is not mistaken for a comment introducer, and handles block comments
    across lines."""
    out = []
    in_block = False
    for number, line in enumerate(source.splitlines(), start=1):
        code = []
        in_string = False
        index = 0
        while index < len(line):
            two = line[index:index + 2]
            if in_block:
                if two == "*/":
                    in_block = False
                    index += 2
                else:
                    index += 1
                continue
            char = line[index]
            if in_string:
                code.append(char)
                if char == "\\":
                    # Escape: consume the next character verbatim.
                    if index + 1 < len(line):
                        code.append(line[index + 1])
                    index += 2
                    continue
                if char == '"':
                    in_string = False
                index += 1
                continue
            if char == '"':
                in_string = True
                code.append(char)
                index += 1
                continue
            if two == "//":
                break          # rest of the line is a comment
            if two == "/*":
                in_block = True
                index += 2
                continue
            code.append(char)
            index += 1
        text = "".join(code)
        if text.strip():
            out.append((number, text))
    return out


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    failures = []

    for directory in ("Sources", "Tests"):
        for path in sorted((root / directory).rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            for number, code in strip_comments(source):
                if PATTERN.search(code):
                    failures.append(
                        f"{path.relative_to(root)}:{number}: {code.strip()[:100]}"
                    )

    # Design doc §8: binding a wildcard address needs an explicit config flag
    # and a startup warning, never a bare default.
    for path in sorted((root / "Sources").rglob("*.swift")):
        for number, code in strip_comments(path.read_text(encoding="utf-8")):
            if "0.0.0.0" in code and "bindAllInterfaces" not in code:
                failures.append(
                    f"{path.relative_to(root)}:{number}: wildcard bind without the "
                    f"§8 opt-in guard: {code.strip()[:80]}"
                )

    if failures:
        print("FAIL: privacy invariant violated outside comments:")
        for failure in failures:
            print(f"      {failure}")
        return 1

    print(
        "privacy: OK (no third-party endpoints, no telemetry symbols, "
        "no unguarded wildcard bind)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
