#!/bin/bash
# Prints versions of the key tools in this image. The build stores the output in
# /usr/local/share/outlet-task-image/manifest.txt so agents can see what is installed.
set -u

version() {
  local name=$1
  shift
  printf '%-14s %s\n' "$name" "$("$@" 2>&1 | grep -v '^\s*$' | head -n 1)"
}

echo "# Intellectual Club task workspace image"
echo "built_at:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "debian:        $(cat /etc/debian_version)"
echo "workdir:       /workspace (runner default cwd)"
echo
version python python3 --version
version pip python3 -m pip --version
version uv uv --version
version node node --version
version npm npm --version
version libreoffice soffice --version
version chromium chromium --version
version chromedriver chromedriver --version
version playwright python3 -m playwright --version
version tesseract tesseract --version
printf '%-14s %s\n' tesseract-lang "$(tesseract --list-langs 2>/dev/null | tail -n +2 | tr '\n' ' ')"
version pandoc pandoc --version
version ffmpeg ffmpeg -version
version java java -version
version poppler pdftotext -v
version qpdf qpdf --version
version mutool mutool -v
version ghostscript gs --version
version imagemagick convert -version
version ripgrep rg --version
version jq jq --version
version git git --version
version sqlite3 sqlite3 --version
version psql psql --version
echo
echo "## Global npm packages (NODE_PATH=$NODE_PATH)"
npm ls --global --depth=0 2>/dev/null | tail -n +2
echo
echo "## pip freeze ($(command -v python3))"
python3 -m pip freeze
