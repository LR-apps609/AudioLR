#!/usr/bin/env bash
# Prepara windows/dist: l'interfaccia di IsoLR per Windows (windows/ui), il motore del sito (site/app),
# ONNX Runtime Web, Signalsmith Stretch (velocità e tono) e il modello Veloce dentro l'installer.
# Uso: Tools/win-dist.sh  (serve GH_TOKEN per scaricare il modello dalla release «modelli-web»)
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf windows/dist && mkdir -p windows/dist/app windows/dist/vendor windows/dist/models windows/dist/img
cp -r windows/ui/index.html windows/ui/ui.css windows/ui/js windows/ui/core windows/dist/
rm -rf windows/dist/core/test
cp site/app/engine-core.js site/app/roformer-core.js windows/dist/app/
cp site/img/logo.png windows/dist/img/
T=$(mktemp -d)
(cd "$T" && npm pack onnxruntime-web@1.19.2 signalsmith-stretch@1.3.2 --silent >/dev/null && for f in *.tgz; do mkdir -p "${f%.tgz}" && tar xzf "$f" -C "${f%.tgz}"; done)
cp "$T"/onnxruntime-web-1.19.2/package/dist/ort.webgpu.min.js "$T"/onnxruntime-web-1.19.2/package/dist/ort-wasm-simd-threaded.jsep.mjs \
   "$T"/onnxruntime-web-1.19.2/package/dist/ort-wasm-simd-threaded.jsep.wasm windows/dist/vendor/
cp "$T"/signalsmith-stretch-1.3.2/package/SignalsmithStretch.js windows/dist/vendor/
[ "${SALTA_MODELLI:-}" = 1 ] && { echo "modello Veloce saltato"; exit 0; }
gh release download modelli-web --repo "${GITHUB_REPOSITORY:-LR-apps609/AudioLR}" --dir windows/dist/models --pattern "HTDemucsWeb.onnx.part*" --pattern "HTDemucsWeb.json" --clobber
python3 - <<'PY'
import json, os, glob
base = "windows/dist/models/"
d = json.load(open(base + "HTDemucsWeb.json"))
d["parts"] = sorted(os.path.basename(p) for p in glob.glob(base + "HTDemucsWeb.onnx.part*"))
d["bytes"] = sum(os.path.getsize(base + p) for p in d["parts"])
json.dump(d, open(base + "HTDemucsWeb.json", "w"))
PY
ls -la windows/dist windows/dist/vendor
