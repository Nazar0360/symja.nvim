#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/backend"
POM="$BACKEND/pom.xml"
TARGET="$BACKEND/target"

for command in java mvn; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

MVN_ARGS=(-q -f "$POM" -DskipTests)
[[ -n "${SYMJA_VERSION:-}" ]] && MVN_ARGS+=(-Dsymja.version="$SYMJA_VERSION")
[[ -n "${SYMJA_GROUP_ID:-}" ]] && MVN_ARGS+=(-Dsymja.groupId="$SYMJA_GROUP_ID")
[[ -n "${SYMJA_ARTIFACT_ID:-}" ]] && MVN_ARGS+=(-Dsymja.artifactId="$SYMJA_ARTIFACT_ID")

if [[ -n "${SYMJA_HOME:-}" || -n "${SYMJA_LIB_DIR:-}" ]]; then
  if [[ -n "${SYMJA_REPOSITORY_URL:-}" ]]; then
    echo "SYMJA_HOME/SYMJA_LIB_DIR and SYMJA_REPOSITORY_URL are mutually exclusive." >&2
    echo "Choose a local Symja app bundle or a Maven repository, not both." >&2
    exit 2
  fi

  if [[ -n "${SYMJA_LIB_DIR:-}" ]]; then
    if [[ ! -d "$SYMJA_LIB_DIR" ]]; then
      echo "Symja library directory not found: $SYMJA_LIB_DIR" >&2
      exit 1
    fi
    SYMJA_LIB_DIR="$(cd -- "$SYMJA_LIB_DIR" && pwd -P)"
  else
    if [[ ! -d "${SYMJA_HOME%/}/lib" ]]; then
      echo "Symja library directory not found: ${SYMJA_HOME%/}/lib" >&2
      echo "Set SYMJA_HOME to the extracted bundle root (it must contain lib/)," >&2
      echo "or set SYMJA_LIB_DIR to the directory containing the Symja JAR files." >&2
      exit 1
    fi
    SYMJA_LIB_DIR="$(cd -- "${SYMJA_HOME%/}/lib" && pwd -P)"
  fi

  if [[ ! -d "$SYMJA_LIB_DIR" ]]; then
    echo "Symja library directory not found: $SYMJA_LIB_DIR" >&2
    echo "Set SYMJA_HOME to the extracted bundle root (it must contain lib/)," >&2
    echo "or set SYMJA_LIB_DIR to the directory containing the Symja JAR files." >&2
    exit 1
  fi
  shopt -s nullglob
  SYMJA_JARS=("$SYMJA_LIB_DIR"/*.jar)
  if (( ${#SYMJA_JARS[@]} == 0 )); then
    echo "No .jar files found in local Symja library directory: $SYMJA_LIB_DIR" >&2
    exit 1
  fi
  for command in javac jar; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "Local Symja mode requires a JDK (missing command: $command)." >&2
      exit 1
    fi
  done

  echo "Building bridge against local Symja libraries: $SYMJA_LIB_DIR"
  mkdir -p "$TARGET/lib"
  mvn "${MVN_ARGS[@]}" \
    -Dsymja.local.lib.dir="$SYMJA_LIB_DIR" \
    -DincludeScope=runtime \
    -Dmdep.outputDir="$TARGET/lib" \
    clean dependency:copy-dependencies

  rm -rf "$TARGET/classes"
  mkdir -p "$TARGET/classes"
  find "$BACKEND/src/main/java" -type f -name '*.java' -print0 \
    | xargs -0 javac --release 17 -encoding UTF-8 \
        -classpath "$TARGET/lib/*:$SYMJA_LIB_DIR/*" \
        -d "$TARGET/classes"
  jar --create --file "$TARGET/symja-nvim.jar" -C "$TARGET/classes" .
  if ! compgen -G "$TARGET/lib/*.jar" >/dev/null; then
    echo "Maven did not copy the bridge's Jackson/Log4j support JARs into $TARGET/lib." >&2
    exit 1
  fi
  printf '%s\n' "$SYMJA_LIB_DIR" > "$TARGET/symja-local-lib-dir"
else
  [[ -n "${SYMJA_REPOSITORY_URL:-}" ]] && MVN_ARGS+=(-Dsymja.repository.url="$SYMJA_REPOSITORY_URL")
  echo "Building bridge using Symja Maven coordinates (${SYMJA_GROUP_ID:-org.matheclipse}:${SYMJA_ARTIFACT_ID:-matheclipse-core}:${SYMJA_VERSION:-3.1.1})"
  mvn "${MVN_ARGS[@]}" clean package
fi

if [[ ! -f "$TARGET/symja-nvim.jar" || ! -d "$TARGET/lib" ]]; then
  echo "Build completed without the bridge JAR or runtime library directory." >&2
  exit 1
fi

echo "Symja.nvim Java bridge built successfully."
