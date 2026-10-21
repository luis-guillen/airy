#!/bin/bash
# Publica una versión de Airy: pruebas → app firmada → zip + SHA256 → etiqueta y release en GitHub.
#
#   bash scripts/release.sh 0.2.0
#
# Requiere `gh` con sesión iniciada y un árbol de trabajo limpio en `main`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?Uso: scripts/release.sh <versión, p. ej. 0.2.0>}"
TAG="v$VERSION"
PLIST="Resources/Info.plist"
DIST="$ROOT/dist"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Versión no válida: $VERSION" >&2; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "Publica desde main." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Hay cambios sin confirmar." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "La etiqueta $TAG ya existe." >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "Falta la sección [$VERSION] en CHANGELOG.md." >&2; exit 1; }

# 1. Versión en Info.plist (CFBundleVersion = número de commits, siempre creciente).
BUILD="$(git rev-list --count HEAD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
if ! git diff --quiet -- "$PLIST"; then
    git add "$PLIST"
    git commit -m "chore: versión $VERSION"
fi

# 2. Pruebas.
swift test --no-parallel

# 3. App firmada.
bash scripts/build-app.sh

# 4. Paquete.
mkdir -p "$DIST"
ZIP="$DIST/Airy-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Airy.app "$ZIP"
( cd "$DIST" && shasum -a 256 "Airy-$VERSION.zip" > "Airy-$VERSION.zip.sha256" )

# 5. Notas desde el CHANGELOG y release.
NOTES="$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {p=1; next} /^## \[/ && p {exit} p' CHANGELOG.md)"
git tag -a "$TAG" -m "Airy $VERSION"
git push origin main "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Airy $VERSION" --notes "$NOTES

---
**Instalación:** descomprime, mueve Airy.app a /Aplicaciones, haz clic derecho → Abrir la primera vez (firma local, sin notarizar) y concede Acceso total al disco.
**SHA-256:** \`$(cut -d' ' -f1 "$ZIP.sha256")\`"
echo "✓ Publicada $TAG"
