#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NVIM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
NVIM_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
DEST="$NVIM_DATA/symja-nvim"

# This script is the standalone/manual installation route. Do not mix it with
# the Lazy.nvim local-plugin route; that can leave two copies of the Lua files
# and backend in runtime paths.
if [[ -f "$NVIM_CONFIG/lua/plugins/symja.lua" ]] \
  && grep -Eq 'symja([.-]nvim)' "$NVIM_CONFIG/lua/plugins/symja.lua"; then
  echo "A Lazy.nvim Symja spec was found at $NVIM_CONFIG/lua/plugins/symja.lua." >&2
  echo "Use Lazy.nvim to build/install this plugin; do not run ./install.sh as well." >&2
  exit 2
fi

if ! command -v java >/dev/null 2>&1; then
  echo "Java is missing. On Arch/EndeavourOS: sudo pacman -S jdk21-openjdk" >&2
  exit 1
fi
if ! command -v mvn >/dev/null 2>&1; then
  echo "Maven is missing. On Arch/EndeavourOS: sudo pacman -S maven" >&2
  exit 1
fi

mkdir -p "$DEST/backend" \
  "$DEST/scripts" \
  "$NVIM_CONFIG/plugin" \
  "$NVIM_CONFIG/ftdetect" \
  "$NVIM_CONFIG/syntax" \
  "$NVIM_CONFIG/after/ftplugin" \
  "$NVIM_CONFIG/lua/symja" \
  "$NVIM_CONFIG/lua"

cp -a "$ROOT/backend/." "$DEST/backend/"
cp -a "$ROOT/scripts/." "$DEST/scripts/"
install -m 0644 "$ROOT/lua/symja/init.lua" "$NVIM_CONFIG/lua/symja/init.lua"
install -m 0644 "$ROOT/lua/cmp_symja.lua" "$NVIM_CONFIG/lua/cmp_symja.lua"
install -m 0644 "$ROOT/plugin/symja.lua" "$NVIM_CONFIG/plugin/symja.lua"
install -m 0644 "$ROOT/ftdetect/symja.vim" "$NVIM_CONFIG/ftdetect/symja.vim"
install -m 0644 "$ROOT/syntax/symja.vim" "$NVIM_CONFIG/syntax/symja.vim"
install -m 0644 "$ROOT/syntax/symja_mma.vim" "$NVIM_CONFIG/syntax/symja_mma.vim"
install -m 0644 "$ROOT/after/ftplugin/symja.lua" "$NVIM_CONFIG/after/ftplugin/symja.lua"
install -m 0644 "$ROOT/after/ftplugin/symja_mma.lua" "$NVIM_CONFIG/after/ftplugin/symja_mma.lua"

printf 'Building Symja bridge...\n'
"$DEST/backend/build.sh"

if [[ ! -f "$DEST/backend/target/symja-nvim.jar" || ! -d "$DEST/backend/target/lib" ]]; then
  echo "Build finished but the bridge JAR or runtime dependencies are missing." >&2
  exit 1
fi

printf '\nInstalled. Restart Neovim.\n'
printf 'Native syntax: open a .symja file. Mathematica syntax: open a .mma, .wl, or .wls file.\n'
printf 'Commands: :SymjaRun, :SymjaEval, :SymjaRepl [native|mma], :SymjaMode [native|mma], :SymjaDoc [symbol], :SymjaReset, :SymjaPing\n'
printf 'For nvim-cmp, add the snippet in contrib/nvim-cmp.lua to your completion configuration.\n'
printf 'Build overrides: SYMJA_VERSION, SYMJA_GROUP_ID, SYMJA_ARTIFACT_ID, SYMJA_REPOSITORY_URL, SYMJA_HOME, SYMJA_LIB_DIR.\n'
