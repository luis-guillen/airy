#!/bin/bash
# Packages Airy as a macOS app signed with a stable local identity.
#
#   bash scripts/build-app.sh             → build/Airy.app
#   bash scripts/build-app.sh --install   → also copies it to /Applications
#
# Signing with the same identity on every build makes macOS keep the Full Disk Access
# permission (TCC ties it to the designated requirement: identifier + certificate).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Airy"
IDENTITY="Airy Local Signing"
APP="$ROOT/build/$APP_NAME.app"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# 1. Build in release mode.
echo "▸ Building (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# 2. Assemble the bundle.
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# stdio MCP server, next to the app's executable.
cp "$BIN_DIR/airy-mcp" "$APP/Contents/MacOS/airy-mcp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"
# The SwiftPM resource bundle goes in Contents/Resources (Catalog.bundled() looks for it there);
# at the root of the .app it would break the signature.
cp -R "$BIN_DIR/${APP_NAME}_DiskMapCore.bundle" "$APP/Contents/Resources/"
# The app's interface strings: English is the source language (the keys themselves), Spanish comes from
# the String Catalog. The app reads them from Bundle.main, so they go in Contents/Resources/<lang>.lproj.
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"
# The catalog has no English overrides, so xcstringstool only writes es.lproj; an empty English table keeps
# en.lproj as a real localization of the bundle.
mkdir -p "$APP/Contents/Resources/en.lproj"
if [ ! -f "$APP/Contents/Resources/en.lproj/Localizable.strings" ]; then
    printf '/* English is the development language: the keys are the English text. */\n' \
        > "$APP/Contents/Resources/en.lproj/Localizable.strings"
fi
# Info.plist strings (the Apple Events permission prompt), per language.
for lang in en es; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "$ROOT/Resources/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Local signing identity (created only once).
has_identity() {
    security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""
}

create_identity() {
    echo "▸ Creating the signing identity \"$IDENTITY\" in the login keychain…"
    local pass status=0
    # Global (not `local`) so the `trap` sees it; it is deleted no matter what (Ctrl-C included).
    KEY_TMP="$(mktemp -d)"
    trap 'rm -rf "$KEY_TMP"' EXIT INT TERM
    local tmp="$KEY_TMP"
    pass="$(/usr/bin/openssl rand -hex 16)"
    # The system LibreSSL: `security import` understands its PKCS#12 (OpenSSL 3+'s, without -legacy, it doesn't).
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
    # -T: codesign can use the key without asking for permission.
    # The certificate doesn't need to be marked as trusted (`security add-trusted-cert`):
    # codesign signs with an untrusted identity and TCC relies on the designated requirement
    # (the leaf certificate's hash), not on the chain of trust.
    rm -rf "$tmp"
    trap - EXIT INT TERM
    return $status
}

SIGNED_WITH_IDENTITY=0
if ! has_identity; then
    create_identity || echo "⚠︎ Couldn't create the identity \"$IDENTITY\"." >&2
fi

# 4. Sign. First airy-mcp (with its own identifier and without the app's entitlements), then the app.
# No --deep when signing the app: it would re-sign airy-mcp with the app's identifier and entitlements.
# Hardened runtime + permission to send Apple Events (Finder → empty the Trash), for the app only.
ENTITLEMENTS="$ROOT/Resources/$APP_NAME.entitlements"
MCP="$APP/Contents/MacOS/airy-mcp"
sign_bundle() {
    codesign --force --options runtime --timestamp=none -i local.airy.Airy.mcp -s "$1" "$MCP" \
    && codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" -s "$1" "$APP"
}
if has_identity && sign_bundle "$IDENTITY"; then
    SIGNED_WITH_IDENTITY=1
else
    sign_bundle -
    echo "⚠︎ Ad-hoc signature: you'll have to grant Full Disk Access again after every build." >&2
fi
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$MCP"
# airy-mcp must keep its own identifier (not the app's): otherwise the build fails.
MCP_IDENTIFIER="$(codesign -dv "$MCP" 2>&1 | sed -n 's/^Identifier=//p')"
if [ "$MCP_IDENTIFIER" != "local.airy.Airy.mcp" ]; then
    echo "✗ airy-mcp was signed as \"$MCP_IDENTIFIER\", not as local.airy.Airy.mcp." >&2
    exit 1
fi
if [ "$SIGNED_WITH_IDENTITY" = 1 ]; then
    echo "✓ Signed with \"$IDENTITY\""
fi
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

# 5. Install in /Applications (optional).
# Order: verified copy → replace Airy.app → only if everything went well, retire the old DiskMap.app.
# pkill is never used: apps are closed with a "quit" Apple Event and the script waits for them to exit.
confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    case "$answer" in
        # "s"/"sí" are still accepted (the prompt used to be in Spanish).
        [yY]|[yY][eE][sS]|[sS]|[sS][iíIÍ]) return 0 ;;
        *) return 1 ;;
    esac
}

# Quits (after asking) the app with that bundle id if it is open. Returns 1 if the user declines or it doesn't quit.
quit_if_running() {
    local bundle_id="$1" name="$2" exe="$3" waited=0
    if pgrep -f "$exe" >/dev/null 2>&1; then
        confirm "$name is open. Quit it to continue?" \
            || { echo "Installation cancelled: quit $name and run the script again." >&2; return 1; }
        osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
        while pgrep -f "$exe" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
            sleep 1; waited=$((waited + 1))
        done
        if pgrep -f "$exe" >/dev/null 2>&1; then
            echo "$name didn't quit within 10 s: quit it yourself and run the script again." >&2
            return 1
        fi
    fi
    return 0
}

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/$APP_NAME.app"
    STAGING="/Applications/.$APP_NAME.app.new"
    OLD_APP="/Applications/DiskMap.app"

    # 5.1 Copy alongside and verify the copy.
    rm -rf "$STAGING"
    cp -R "$APP" "$STAGING"
    if ! codesign --verify --deep --strict "$STAGING"; then
        rm -rf "$STAGING"
        echo "The copy doesn't pass codesign --verify; not installing." >&2
        exit 1
    fi

    # 5.2 Replace Airy.app if it exists.
    if [ -e "$DEST" ]; then
        if ! confirm "$DEST already exists. Replace it?"; then
            rm -rf "$STAGING"
            echo "Installation cancelled."
            exit 0
        fi
        # The app is never quit without asking: it could be cleaning something.
        quit_if_running "local.airy.Airy" "$APP_NAME" "$DEST/Contents/MacOS/$APP_NAME" || { rm -rf "$STAGING"; exit 1; }
        rm -rf "$DEST"
    fi
    mv "$STAGING" "$DEST"
    echo "✓ Installed in $DEST"

    # 5.3 Only if the above went well: the old DiskMap.app goes to the Trash (it is never deleted).
    if [ -e "$OLD_APP" ]; then
        quit_if_running "local.diskmap.DiskMap" "DiskMap" "$OLD_APP/Contents/MacOS/DiskMap" || exit 1
        mv "$OLD_APP" "$HOME/.Trash/DiskMap $(date +%Y%m%d-%H%M%S).app"
        echo "✓ DiskMap.app moved to the Trash"
    fi

    # 5.4
    echo "Grant Full Disk Access to Airy again (System Settings › Privacy & Security)."
fi
