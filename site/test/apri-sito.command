#!/bin/bash
# Apre il sito di AudioLR sul tuo Mac, solo in locale: niente va su internet.
# Doppio clic per avviarlo; chiudi questa finestra per fermarlo.
cd "$(dirname "$0")"
PORT=8080
echo "Sito di AudioLR su http://localhost:$PORT  (chiudi questa finestra per fermarlo)"
(sleep 1; open "http://localhost:$PORT/") &
if command -v python3 >/dev/null 2>&1 && python3 -c "" >/dev/null 2>&1; then
  # Server minimo con i tipi giusti per .mjs e .wasm (i Python vecchi non li conoscono)
  exec python3 - "$PORT" <<'PY'
import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".mjs": "text/javascript", ".js": "text/javascript", ".wasm": "application/wasm",
                      ".json": "application/json", ".onnx": "application/octet-stream"}
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
else
  exec ruby -run -e httpd . -p "$PORT" -b 127.0.0.1
fi
