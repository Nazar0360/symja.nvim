#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
JAR="${1:-$ROOT/backend/target/symja-nvim.jar}"
LIB_DIR="${2:-$(dirname -- "$JAR")/lib}"
LOCAL_SYMJA_LIB_DIR="${3:-${SYMJA_LIB_DIR:-}}"
if [[ -z "$LOCAL_SYMJA_LIB_DIR" && -n "${SYMJA_HOME:-}" ]]; then
  LOCAL_SYMJA_LIB_DIR="$SYMJA_HOME/lib"
fi
if [[ -z "$LOCAL_SYMJA_LIB_DIR" && -f "$(dirname -- "$JAR")/symja-local-lib-dir" ]]; then
  IFS= read -r LOCAL_SYMJA_LIB_DIR < "$(dirname -- "$JAR")/symja-local-lib-dir"
fi

if [[ ! -f "$JAR" || ! -d "$LIB_DIR" ]]; then
  echo "Build first: ./backend/build.sh" >&2
  exit 1
fi

python - "$ROOT" "$JAR" "$LIB_DIR" "$LOCAL_SYMJA_LIB_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

root, jar, lib_dir, local_symja_lib_dir = sys.argv[1:]
classpath = jar + ":" + lib_dir + "/*"
if local_symja_lib_dir:
    classpath += ":" + local_symja_lib_dir + "/*"

class RemoteHandler(BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        type(self).requests += 1
        body = b"# Integrate\n\nREMOTE FALLBACK SHOULD NOT BE USED\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/markdown; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

remote = HTTPServer(("127.0.0.1", 0), RemoteHandler)
thread = threading.Thread(target=remote.serve_forever, daemon=True)
thread.start()

try:
    with tempfile.TemporaryDirectory(prefix="symja-lsp-test-") as temporary:
        workspace = pathlib.Path(temporary)
        plugin_root = workspace / "symja-nvim"
        plugin_root.mkdir()

        # Mirror the user's sibling bundle layout and Symja's real
        # symja_android_library/doc/functions location.
        local_docs = workspace / "symja-3.1.1" / "symja_android_library" / "doc" / "functions"
        local_docs.mkdir(parents=True)
        (local_docs / "Integrate.md").write_text(
            "## Integrate\n\nLOCAL ORIGINAL MARKDOWN FIXTURE\n", encoding="utf-8"
        )

        # An empty explicit docs_dir must not prevent fallback to the adjacent
        # local Symja bundle. The remote server detects any network fallback.
        custom_docs = workspace / "custom-docs"
        custom_docs.mkdir()
        process = subprocess.Popen(
            ["java", "-cp", classpath, "org.symjanvim.SymjaLspServer",
             str(plugin_root), str(custom_docs), f"http://127.0.0.1:{remote.server_port}/"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        def send(message):
            body = json.dumps(message).encode("utf-8")
            process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
            process.stdin.flush()

        def receive():
            headers = {}
            while True:
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError("LSP process closed stdout unexpectedly")
                if line in (b"\r\n", b"\n"):
                    break
                key, value = line.decode("ascii").split(":", 1)
                headers[key.lower()] = value.strip()
            length = int(headers["content-length"])
            return json.loads(process.stdout.read(length))

        try:
            send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            initialized = receive()
            capabilities = initialized["result"]["capabilities"]
            assert capabilities["hoverProvider"] is True
            assert capabilities["textDocumentSync"]["openClose"] is True
            assert capabilities["textDocumentSync"]["change"] == 1

            uri = "file:///tmp/example.symja"
            send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
            send({
                "jsonrpc": "2.0", "method": "textDocument/didOpen",
                "params": {"textDocument": {"uri": uri, "languageId": "symja", "version": 1,
                                              "text": "Integrate[x, x]"}},
            })
            send({
                "jsonrpc": "2.0", "id": 2, "method": "textDocument/hover",
                "params": {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 3}},
            })
            hover = receive()
            value = hover["result"]["contents"]["value"]
            assert "LOCAL ORIGINAL MARKDOWN FIXTURE" in value
            assert "REMOTE FALLBACK SHOULD NOT BE USED" not in value
            assert RemoteHandler.requests == 0, "LSP tried the network despite a local Markdown page"

            send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": None})
            receive()
            send({"jsonrpc": "2.0", "method": "exit", "params": None})
            process.stdin.close()
            code = process.wait(timeout=5)
            if code != 0:
                raise RuntimeError(
                    f"LSP process exited with status {code}: "
                    f"{process.stderr.read().decode(errors='replace')}"
                )
        except Exception:
            process.kill()
            raise
finally:
    remote.shutdown()
    remote.server_close()
    thread.join(timeout=2)

print("Symja LSP smoke test passed: local bundle Markdown is preferred over network fallback.")
PY
