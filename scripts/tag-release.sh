#!/bin/bash
# meshyy — cut a release tag whose binary tells the truth about itself.
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# Usage: scripts/tag-release.sh 0.1.9
#
# Exists because it went wrong twice by hand: v0.1.7 shipped a binary reporting
# 0.1.0, and v0.1.8 was tagged before the constant caught up. `meshyyd version`
# is the one diagnostic an operator has for "is the new daemon installed?", and
# a diagnostic that lies is worse than none.

set -euo pipefail

VERSION="${1:?usage: scripts/tag-release.sh X.Y.Z}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: '$VERSION' is not X.Y.Z" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"

[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is not clean" >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "error: tag from main" >&2; exit 1; }

CONSTANT=$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/MeshyyCore/Meshyy.swift)
if [[ "$CONSTANT" != "$VERSION" ]]; then
    echo "error: Meshyy.version is \"$CONSTANT\" but the tag would be v$VERSION." >&2
    echo "Bump the constant (and merge it) first — the binary must report its tag." >&2
    exit 1
fi

git tag "v$VERSION"
git push origin "v$VERSION"
echo "tagged v$VERSION at $(git rev-parse --short HEAD); Meshyy.version agrees"
