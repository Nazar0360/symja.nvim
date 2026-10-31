#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERER="$ROOT/scripts/render-latex.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/symja-latex-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

write_tex() {
  local destination=$1
  local expression=$2
  cat > "$destination" <<TEX
\\documentclass{article}
\\usepackage[paperwidth=240pt,paperheight=1200pt,margin=0pt]{geometry}
\\usepackage{amsmath,amssymb}
\\usepackage{breqn}
\\pagestyle{empty}
\\setlength{\\parindent}{0pt}
\\setlength{\\textwidth}{240pt}
\\setlength{\\hsize}{240pt}
\\begin{document}
\\begin{dmath*}
$expression
\\end{dmath*}
\\end{document}
TEX
}

write_tex "$WORK/short.tex" 'x^2'
write_tex "$WORK/long.tex" '\int_0^1 \left(x^2+x^4+x^6+x^8+x^{10}+x^{12}+x^{14}+x^{16}+x^{18}+x^{20}+x^{22}+x^{24}+x^{26}+x^{28}+x^{30}+x^{32}+x^{34}+x^{36}+x^{38}+x^{40}\right) dx = \frac{1}{3}+\frac{1}{5}+\frac{1}{7}+\frac{1}{9}+\frac{1}{11}+\frac{1}{13}+\frac{1}{15}+\frac{1}{17}+\frac{1}{19}+\frac{1}{21}'

"$RENDERER" "$WORK/short.tex" "$WORK/short.png" 240
"$RENDERER" "$WORK/long.tex" "$WORK/long.png" 240

read -r short_width short_height < <(magick identify -format '%w %h\n' "$WORK/short.png")
read -r long_width long_height < <(magick identify -format '%w %h\n' "$WORK/long.png")

if (( long_width > 800 )); then
  echo "Expected long expression to wrap within the 240pt target width (got ${long_width}px)" >&2
  exit 1
fi
if (( long_height <= short_height + 20 )); then
  echo "Expected long expression to wrap into multiple lines (heights: $short_height vs $long_height)" >&2
  exit 1
fi

if "$RENDERER" "$WORK/short.tex" "$WORK/invalid.png" 80 >/dev/null 2>&1; then
  echo "Renderer accepted an out-of-range DPI" >&2
  exit 1
fi

printf 'LaTeX wrapping smoke test passed (short %sx%s, long %sx%s).\n' \
  "$short_width" "$short_height" "$long_width" "$long_height"
