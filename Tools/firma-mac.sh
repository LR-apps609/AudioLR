#!/bin/bash
# Firma e notarizzazione dell'app per il Mac, con il certificato «Developer ID Application» di Apple.
# Senza i segreti (APPLE_CERT_P12_BASE64, APPLE_CERT_PASSWORD, APPLE_TEAM_ID, APPLE_ID, APPLE_APP_PASSWORD)
# fa come prima: firma «ad hoc» e niente notarizzazione, così le prove e i rilasci continuano a funzionare.
#   Tools/firma-mac.sh firma <App.app>        firma l'app (runtime protetto, ora certificata)
#   Tools/firma-mac.sh notarizza <file.dmg>   manda il .dmg ad Apple, aspetta il via e lo «pinza» al file
set -euo pipefail
cmd=$1; target=$2
here=$(cd "$(dirname "$0")" && pwd)

if [ -z "${APPLE_CERT_P12_BASE64:-}" ]; then
  if [ "$cmd" = firma ]; then codesign --force --deep -s - "$target"; fi
  echo "::notice::Firma Apple non configurata: $cmd ad hoc ($target)"
  exit 0
fi

KC="$RUNNER_TEMP/isolr-firma.keychain-db"
if [ ! -f "$KC" ]; then
  PASS=$(uuidgen)
  echo "$APPLE_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security create-keychain -p "$PASS" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$PASS" "$KC"
  security import "$RUNNER_TEMP/cert.p12" -P "$APPLE_CERT_PASSWORD" -A -t cert -f pkcs12 -k "$KC"
  security set-key-partition-list -S apple-tool:,apple: -k "$PASS" "$KC" > /dev/null
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  rm -f "$RUNNER_TEMP/cert.p12"
fi
ID=$(security find-identity -v -p codesigning "$KC" | grep -o '"Developer ID Application[^"]*"' | head -n 1 | tr -d '"')
[ -n "$ID" ] || { echo "::error::Nel certificato non c'è un «Developer ID Application»"; exit 1; }

case "$cmd" in
  firma)
    # Prima le librerie e i modelli compilati dentro l'app, poi l'app (runtime protetto: lo chiede la notarizzazione)
    find "$target/Contents" -type f \( -name "*.dylib" -o -perm -111 \) ! -path "*/MacOS/*" -print0 2>/dev/null |
      xargs -0 -r codesign --force --options runtime --timestamp -s "$ID"
    codesign --force --options runtime --timestamp --entitlements "$here/IsoLR.entitlements" -s "$ID" "$target"
    codesign --verify --strict --deep "$target"
    echo "::notice::Firmata con «$ID»: $target"
    ;;
  notarizza)
    codesign --force --timestamp -s "$ID" "$target"
    xcrun notarytool submit "$target" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait --timeout 60m
    xcrun stapler staple "$target"
    echo "::notice::Notarizzata da Apple: $target"
    ;;
esac
