#!/bin/zsh
# Cut an official release: build the release app, zip it, tag, and publish a
# GitHub release with the zip attached.
#
#   ./scripts/release.sh 0.2.0 ["release notes markdown"]
#
# Remember to bump VERSION in scripts/bundle.sh first (this script checks).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Release v$VERSION}"

BUNDLED_VERSION=$(grep '^VERSION=' scripts/bundle.sh | cut -d'"' -f2)
if [[ "$BUNDLED_VERSION" != "$VERSION" ]]; then
    echo "error: scripts/bundle.sh has VERSION=\"$BUNDLED_VERSION\" — update it to \"$VERSION\" first" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — commit first" >&2
    exit 1
fi

./scripts/bundle.sh --release

ZIP="build/Crisp-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Crisp.app" "$ZIP"

git tag "v$VERSION"
git push origin HEAD "v$VERSION"

gh release create "v$VERSION" "$ZIP" --title "Crisp v$VERSION" --notes "$NOTES"

echo "Released v$VERSION"
