# Server minimo per provare il sito in locale, con i tipi giusti per .mjs e .wasm
# (i Python vecchi non li conoscono e alcuni browser rifiutano i moduli serviti come file generici).
#   python3 site/test/server.py <cartella> [porta]
import http.server, sys, functools

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".mjs": "text/javascript", ".js": "text/javascript", ".wasm": "application/wasm",
                      ".json": "application/json", ".onnx": "application/octet-stream"}

    def log_message(self, *args):
        pass

root = sys.argv[1] if len(sys.argv) > 1 else "."
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=root)).serve_forever()
