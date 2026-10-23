#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
#  Installa AudioLR in Applicazioni.
#  Fai doppio clic su questo file. Se c'è l'app già pronta (cartella
#  Prebuilt, scaricata da GitHub) la installa subito; altrimenti la
#  costruisce con Xcode.
# ════════════════════════════════════════════════════════════════════
cd "${0:A:h}" || exit 1
clear
print ""
print "  AudioLR — installo l'app"
print "  ════════════════════════"
print ""

fail() { print ""; print "  ❌ $1"; print ""; print "  Mandami uno screenshot di questa finestra."; exit 1 }

APP_BUILT="$PWD/Prebuilt/AudioLR.app"
if [[ -d $APP_BUILT ]]; then
  print "  1/3  Uso l'app già pronta…"
  print "       ✅"
else
  # 1. Xcode
  print "  1/3  Controllo Xcode e preparo il progetto…"
  [[ -d /Applications/Xcode.app ]] || fail "Non trovo Xcode in Applicazioni. Installalo dal Mac App Store e aprilo una volta."
  if [[ $(xcode-select -p 2>/dev/null) != /Applications/Xcode.app/* ]]; then
    print "       Imposto Xcode come strumento predefinito (ti chiede la password del Mac)…"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || fail "Non riesco a impostare Xcode."
  fi
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    sudo xcodebuild -license accept >/dev/null 2>&1
    sudo xcodebuild -runFirstLaunch >/dev/null 2>&1
  fi
  [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  if ! command -v xcodegen >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || fail "Non trovo Homebrew."
    brew install --quiet xcodegen >/dev/null 2>&1 || fail "Non riesco a installare XcodeGen."
  fi
  xcodegen generate --quiet >/dev/null 2>&1 || xcodegen generate || fail "Non riesco a creare il progetto Xcode."
  print "       ✅"

  # 2. Compilazione, fuori da Documenti/Scrivania (iCloud aggiunge informazioni che rompono la firma)
  print "  2/3  Compilo l'app (la prima volta 1–3 minuti)…"
  BUILD_DIR="$HOME/Library/Caches/AudioLR-build"
  rm -rf build "$BUILD_DIR"
  xattr -cr . 2>/dev/null
  if ! xcodebuild -project AudioLR.xcodeproj -scheme AudioLR -configuration Release \
       -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
       CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
       -quiet build > build.log 2>&1; then
    print ""
    grep -E "error:" build.log | sed 's/^/     /' | head -n 25
    fail "La compilazione non è riuscita (dettagli completi in build.log)."
  fi
  APP_BUILT="$BUILD_DIR/Build/Products/Release/AudioLR.app"
  [[ -d $APP_BUILT ]] || fail "Non trovo l'app compilata."
  print "       ✅"
fi

# 3. Installazione e avvio
print "  3/3  Installo in Applicazioni…"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
osascript -e 'tell application "AudioLR" to quit' >/dev/null 2>&1
sleep 1
rm -rf /Applications/AudioLR.app
cp -R "$APP_BUILT" /Applications/ || fail "Non riesco a copiare l'app in Applicazioni."
xattr -dr com.apple.quarantine /Applications/AudioLR.app 2>/dev/null
$LSREG -u "$APP_BUILT" >/dev/null 2>&1
[[ -n $BUILD_DIR ]] && rm -rf "$BUILD_DIR"
$LSREG -f /Applications/AudioLR.app >/dev/null 2>&1
print "       ✅"

open /Applications/AudioLR.app
print ""
print "  Fatto! 🎉"
print ""
print "  • Trascina una canzone nella finestra di AudioLR"
print "  • Oppure tasto destro su una canzone nel Finder → Apri con → AudioLR"
print ""
