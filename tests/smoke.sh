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

if [[ ! -f "$JAR" ]]; then
  echo "Bridge JAR not found: $JAR" >&2
  echo "Build first: ./backend/build.sh" >&2
  exit 1
fi
if [[ ! -d "$LIB_DIR" ]]; then
  echo "Runtime dependency directory not found: $LIB_DIR" >&2
  echo "This version runs with a classpath, not java -jar." >&2
  exit 1
fi

python - "$JAR" "$LIB_DIR" "$LOCAL_SYMJA_LIB_DIR" <<'PY'
import json
import subprocess
import sys

jar = sys.argv[1]
lib_dir = sys.argv[2]
local_symja_lib_dir = sys.argv[3]
requests = [
    {"id": 1, "method": "eval", "mode": "native", "code": "shared = 40"},
    {"id": 2, "method": "eval", "mode": "mma", "code": "shared + 2"},
    {"id": 3, "method": "eval", "mode": "mma", "code": "square[x_] := x^2; square[5]"},
    {"id": 4, "method": "eval", "mode": "native", "code": "square(6)"},
    {"id": 5, "method": "complete", "code": "squ"},
    {"id": 6, "method": "reset"},
    {"id": 7, "method": "eval", "mode": "native", "code": "shared"},
    {"id": 8, "method": "check", "mode": "native", "code": "f(x_) := x^2; f(3)"},
    {"id": 9, "method": "check", "mode": "mma", "code": "f[x_] := x^2; f[3]"},
    {"id": 10, "method": "check", "mode": "native", "code": "f(]"},
    {"id": 11, "method": "check", "mode": "mma", "code": "f[}"},
    {"id": 12, "method": "latex", "mode": "native", "code": "Integrate(f(x), x)"},
    {"id": 13, "method": "latex", "mode": "native", "code": "Sum(n^2, {n, 1, m})"},
    {"id": 14, "method": "latex", "mode": "native", "code": "D(Sin(x), x)"},
    {"id": 15, "method": "eval", "mode": "native", "code": "Integrate(x^2, x)", "renderLatex": True},
    {"id": 16, "method": "eval", "mode": "native", "code": "Sum(n^2, {n, 1, 3})", "renderLatex": True},
    {"id": 17, "method": "eval", "mode": "native", "code": "D(Sin(x), x)", "renderLatex": True},
]
payload = "".join(json.dumps(item) + "\n" for item in requests)
classpath = jar + ":" + lib_dir + "/*"
if local_symja_lib_dir:
    classpath += ":" + local_symja_lib_dir + "/*"
run = subprocess.run(["java", "-cp", classpath, "org.symjanvim.SymjaBridge"],
                     input=payload, text=True, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, check=True)
responses = [json.loads(line) for line in run.stdout.splitlines() if line.strip()]
if len(responses) != len(requests):
    raise SystemExit(f"Expected {len(requests)} responses, got {len(responses)}\n{run.stdout}\n{run.stderr}")
for response in responses:
    if not response.get("ok"):
        raise SystemExit(f"Request {response.get('id')} failed: {response.get('error')}")
checks = {
    1: "40",
    2: "42",
    3: "25",
    4: "36",
}
for response in responses:
    expected = checks.get(response["id"])
    if expected is not None and response.get("result") != expected:
        raise SystemExit(f"Request {response['id']}: expected {expected!r}, got {response.get('result')!r}")
    if response.get("id") in checks and "latex" in response:
        raise SystemExit(f"Request {response.get('id')}: plain evaluation unexpectedly generated TeX")
if "square" not in responses[4].get("symbols", []):
    raise SystemExit("Dynamic completion did not include the user-defined symbol 'square'")
for response_id in (8, 9):
    response = next(item for item in responses if item["id"] == response_id)
    if not response.get("ok") or response.get("diagnostics"):
        raise SystemExit(f"Valid syntax check {response_id} unexpectedly failed: {response}")
for response_id in (10, 11):
    response = next(item for item in responses if item["id"] == response_id)
    if not response.get("ok") or not response.get("diagnostics"):
        raise SystemExit(f"Invalid syntax check {response_id} was not diagnosed: {response}")
latex_markers = {12: r"\int", 13: r"\sum", 14: r"\frac",
                 15: r"\frac", 17: r"\cos"}
for response_id, marker in latex_markers.items():
    response = next(item for item in responses if item["id"] == response_id)
    if not response.get("ok") or marker not in response.get("latex", ""):
        raise SystemExit(f"LaTeX conversion {response_id} did not produce {marker}: {response}")
for response_id in (15, 16, 17):
    response = next(item for item in responses if item["id"] == response_id)
    if not isinstance(response.get("latex"), str) or not response["latex"]:
        raise SystemExit(f"LaTeX-enabled evaluation {response_id} did not return TeX: {response}")
if next(item for item in responses if item["id"] == 16).get("result") != "14":
    raise SystemExit("Evaluated Sum did not return 14")
reset_result = next(response for response in responses if response["id"] == 7).get("result")
if reset_result == "40":
    raise SystemExit("Reset left the user variable 'shared' assigned")
print("Symja bridge smoke test passed: native, MMA, shared state, completion, reset, syntax checks, plain evaluation without TeX, and opt-in evaluated/unevaluated LaTeX.")
PY
