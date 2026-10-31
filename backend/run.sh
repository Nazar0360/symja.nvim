#!/usr/bin/env sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
JAR="$ROOT/target/symja-nvim.jar"
LIB="$ROOT/target/lib"
LOCAL_LIB=""

if [ -n "${SYMJA_LIB_DIR:-}" ]; then
  LOCAL_LIB=$SYMJA_LIB_DIR
elif [ -n "${SYMJA_HOME:-}" ]; then
  LOCAL_LIB=$SYMJA_HOME/lib
elif [ -f "$ROOT/target/symja-local-lib-dir" ]; then
  IFS= read -r LOCAL_LIB < "$ROOT/target/symja-local-lib-dir"
fi

if [ ! -f "$JAR" ] || [ ! -d "$LIB" ]; then
  echo "Build first: ./backend/build.sh" >&2
  exit 1
fi
if [ -n "$LOCAL_LIB" ] && [ ! -d "$LOCAL_LIB" ]; then
  echo "Local Symja library directory not found: $LOCAL_LIB" >&2
  exit 1
fi
CLASSPATH="$JAR:$LIB/*"
[ -z "$LOCAL_LIB" ] || CLASSPATH="$CLASSPATH:$LOCAL_LIB/*"
exec java -cp "$CLASSPATH" org.symjanvim.SymjaBridge "$@"
