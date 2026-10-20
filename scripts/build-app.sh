#!/bin/bash
# Empaqueta DiskMap como app de macOS firmada con una identidad local estable.
#
#   bash scripts/build-app.sh             → build/DiskMap.app
#   bash scripts/build-app.sh --install   → además la copia a /Applications
#
# La firma con la misma identidad en cada compilación hace que macOS conserve el permiso de
# Acceso total al disco (TCC lo asocia al requisito designado: identificador + certificado).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="DiskMap"
IDENTITY="DiskMap Local Signing"
APP="$ROOT/build/$APP_NAME.app"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
    esac
done

# 1. Compilar en modo release.
echo "▸ Compilando (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# 2. Montar el bundle.
echo "▸ Montando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"
# El bundle de recursos de SwiftPM va en Contents/Resources (Catalog.bundled() lo busca ahí);
# en la raíz del .app rompería la firma.
cp -R "$BIN_DIR/${APP_NAME}_DiskMapCore.bundle" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Identidad de firma local (se crea una sola vez).
has_identity() {
    security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""
}

create_identity() {
    echo "▸ Creando la identidad de firma \"$IDENTITY\" en el llavero de inicio de sesión…"
    local pass status=0
    # Global (no `local`) para que el `trap` lo vea; se borra pase lo que pase (también con Ctrl-C).
    KEY_TMP="$(mktemp -d)"
    trap 'rm -rf "$KEY_TMP"' EXIT INT TERM
    local tmp="$KEY_TMP"
    pass="$(/usr/bin/openssl rand -hex 16)"
    # LibreSSL del sistema: su PKCS#12 lo entiende `security import` (el de OpenSSL 3+ no, sin -legacy).
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$IDENTITY" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "basicConstraints=critical,CA:false" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$IDENTITY" -out "$tmp/identity.p12" -passout "pass:$pass" \
    && security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$pass" -T /usr/bin/codesign \
    || status=$?
    # -T: codesign puede usar la clave sin pedir permiso.
    # No hace falta marcar el certificado como de confianza (`security add-trusted-cert`):
    # codesign firma con una identidad no fiable y TCC se basa en el requisito designado
    # (hash del certificado hoja), no en la cadena de confianza.
    rm -rf "$tmp"
    trap - EXIT INT TERM
    return $status
}

SIGNED_WITH_IDENTITY=0
if ! has_identity; then
    create_identity || echo "⚠︎ No se pudo crear la identidad \"$IDENTITY\"." >&2
fi

# 4. Firmar. Runtime endurecido + permiso para enviar Apple Events (Finder → vaciar Papelera).
ENTITLEMENTS="$ROOT/Resources/$APP_NAME.entitlements"
if has_identity && codesign --force --deep --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"; then
    SIGNED_WITH_IDENTITY=1
else
    codesign --force --deep --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" -s - "$APP"
    echo "⚠︎ Firma ad-hoc: tendrás que volver a dar Acceso total al disco tras cada compilación." >&2
fi
codesign --verify --deep --strict "$APP"
if [ "$SIGNED_WITH_IDENTITY" = 1 ]; then
    echo "✓ Firmada con \"$IDENTITY\""
fi
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

# 5. Instalar en /Applications (opcional).
if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/$APP_NAME.app"
    if [ -e "$DEST" ]; then
        read -r -p "Ya existe $DEST. ¿Reemplazarla? [s/N] " answer
        case "$answer" in
            [sS]|[sS][iíIÍ]) ;;
            *) echo "Instalación cancelada."; exit 0 ;;
        esac
        # Nunca se cierra la app sin preguntar: podría estar limpiando algo.
        if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
            read -r -p "$APP_NAME está abierta. ¿Cerrarla para instalar la nueva? [s/N] " quit_answer
            case "$quit_answer" in
                [sS]|[sS][iíIÍ]) pkill -f "$DEST/Contents/MacOS/$APP_NAME" 2>/dev/null || true; sleep 1 ;;
                *) echo "Instalación cancelada: cierra $APP_NAME y vuelve a ejecutar el script." >&2; exit 1 ;;
            esac
        fi
        rm -rf "$DEST"
    fi
    cp -R "$APP" "$DEST"
    echo "✓ Instalada en $DEST"
fi
