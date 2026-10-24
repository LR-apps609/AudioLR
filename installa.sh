#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
#  Installa (o reinstalla) l'ultima versione di AudioLR, già pronta.
#  Si usa una volta sola, incollando nel Terminale:
#    curl -fsSL https://raw.githubusercontent.com/LR-apps609/AudioLR/main/installa.sh | zsh
#  Dopo, gli aggiornamenti arrivano dentro l'app (o con doppio clic sul file .audiolr).
#  Scaricato così, il Mac non lo blocca come «sviluppatore non identificato».
# ════════════════════════════════════════════════════════════════════
set -e
print ""
print "  AudioLR — installo l'ultima versione"
print "  ════════════════════════════════════"
fail() { print ""; print "  ❌ $1"; print ""; exit 1; }

WORK=$(mktemp -d /tmp/audiolr-installa.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

print "  1/3  Cerco l'ultima versione…"
# La versione più alta tra le ultime pubblicate (non l'ultima creata): «AudioLR.0.10.0.audiolr» → 0, 10, 0
URL=$(curl -fsSL "https://api.github.com/repos/LR-apps609/AudioLR/releases?per_page=30" \
  | grep -o '"browser_download_url": *"[^"]*\.audiolr"' | sed 's/.*"\(https[^"]*\)"/\1/' \
  | awk -F/ '{ n=$NF; sub(/\.audiolr$/, "", n); split(n, v, "."); printf "%06d%06d%06d %s\n", v[2], v[3], v[4], $0 }' \
  | sort | tail -n 1 | cut -d" " -f2)
[[ -n $URL ]] || fail "Non trovo la versione da scaricare. Controlla la connessione a internet."
print "       $(basename "$URL")"

print "  2/3  Scarico…"
curl -fL --progress-bar -o "$WORK/AudioLR.zip" "$URL" || fail "Download non riuscito."
ditto -x -k "$WORK/AudioLR.zip" "$WORK/x" || fail "Il file scaricato è rovinato."
APP=$(find "$WORK/x" -maxdepth 4 -path "*/Prebuilt/AudioLR.app" -type d | head -n 1)
[[ -n $APP ]] || fail "Nel pacchetto non c'è l'app."

print "  3/3  Installo in Applicazioni…"
osascript -e 'tell application "AudioLR" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/AudioLR.app
ditto "$APP" /Applications/AudioLR.app || fail "Non riesco a copiare l'app in Applicazioni."
xattr -dr com.apple.quarantine /Applications/AudioLR.app 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/AudioLR.app >/dev/null 2>&1 || true
open /Applications/AudioLR.app
print ""
print "  Fatto! 🎉  Da ora gli aggiornamenti arrivano da soli."
print ""
