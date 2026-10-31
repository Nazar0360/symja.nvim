#!/usr/bin/env bash
# Render one Symja-generated LaTeX expression to a transparent PNG.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: render-latex.sh INPUT.tex OUTPUT.png [DPI]" >&2
  exit 2
fi

input=$1
output=$2
dpi=${3:-240}
if [[ ! "$dpi" =~ ^[0-9]+$ ]] || (( dpi < 96 || dpi > 600 )); then
  echo "DPI must be an integer between 96 and 600" >&2
  exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/symja-latex.XXXXXX")
cleanup() {
  status=$?
  if (( status == 0 )); then
    rm -rf -- "$work"
  else
    printf 'LaTeX diagnostic directory: %s\n' "$work" >&2
    printf 'LaTeX source: %s/formula.tex\n' "$work" >&2
    if [[ -f "$work/pdflatex.log" ]]; then
      printf '%s\n' '----- pdflatex.log (last 100 lines) -----' >&2
      tail -n 100 "$work/pdflatex.log" >&2
    fi
  fi
}
trap cleanup EXIT

for command in pdflatex pdftocairo magick; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing renderer dependency: $command" >&2
    exit 127
  fi
done

cp -- "$input" "$work/formula.tex"
if ! pdflatex -interaction=nonstopmode -halt-on-error -file-line-error \
  -output-directory "$work" "$work/formula.tex" >"$work/pdflatex.log" 2>&1; then
  echo "pdflatex failed" >&2
  exit 1
fi
if ! pdftocairo -png -transp -singlefile -r "$dpi" "$work/formula.pdf" "$work/formula"; then
  echo "pdftocairo failed; inspect the retained diagnostic directory" >&2
  exit 1
fi
if ! magick "$work/formula.png" -trim +repage "$output"; then
  echo "ImageMagick conversion failed; inspect the retained diagnostic directory" >&2
  exit 1
fi
