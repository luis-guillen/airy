#!/bin/bash
# Publishes an Airy release: tests → signed app → zip + SHA-256 → tag and GitHub release.
#
#   bash scripts/release.sh 0.2.0
#
# Requires a logged-in `gh` and a clean working tree on `main`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?Usage: scripts/release.sh <version, e.g. 0.3.0>}"
TAG="v$VERSION"
PLIST="Resources/Info.plist"
DIST="$ROOT/dist"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "Release from main." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Uncommitted changes." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists." >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "Missing [$VERSION] section in CHANGELOG.md." >&2; exit 1; }

# 1. Version in Info.plist (CFBundleVersion = commit count, always increasing).
BUILD="$(git rev-list --count HEAD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
if ! git diff --quiet -- "$PLIST"; then
    git add "$PLIST"
    git commit -m "chore: release $VERSION"
fi

# 2. Tests.
swift test --no-parallel

# 3. Signed app.
bash scripts/build-app.sh

# 4. Package.
mkdir -p "$DIST"
ZIP="$DIST/Airy-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Airy.app "$ZIP"
( cd "$DIST" && shasum -a 256 "Airy-$VERSION.zip" > "Airy-$VERSION.zip.sha256" )

# 5. Notes from the CHANGELOG, then the release.
NOTES="$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {p=1; next} /^## \[/ && p {exit} p' CHANGELOG.md)"
git tag -a "$TAG" -m "Airy $VERSION"
git push origin main "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Airy $VERSION" --notes "$NOTES

---
**Install:** unzip, move Airy.app to /Applications, right-click → Open the first time (locally signed, not notarized), then grant Full Disk Access.
**SHA-256:** \`$(cut -d' ' -f1 "$ZIP.sha256")\`"
echo "✓ Released $TAG"
