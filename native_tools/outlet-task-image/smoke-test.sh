#!/bin/bash
# Offline smoke test for the task workspace image; exits non-zero if any check fails.
#   docker run --rm --network none IMAGE /usr/local/lib/outlet-task-image/smoke-test.sh
set -u

failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
cd "$work" || exit 1

pass() { printf 'ok    %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
# check NAME COMMAND... — runs the command, prints the log tail on failure.
check() {
  local name=$1
  shift
  if "$@" >"$work/check.log" 2>&1; then
    pass "$name"
  else
    fail "$name"
    tail -n 20 "$work/check.log" | sed 's/^/      /'
  fi
}

check "/bin/sh is bash" bash -c '[[ "$(readlink -f /bin/sh)" == */bash ]]'
check "python3 is /usr/local Python 3.12" bash -c \
  '[[ "$(command -v python3)" == /usr/local/bin/python3 ]] && python3 -c "import sys; assert sys.version_info[:2] == (3, 12)"'
check "pip uses Python 3.12" bash -c 'pip --version | grep -q "python 3.12"'
check "runner contract (sleep, mkdir, cat, tr, awk, grep -z, /proc)" bash -c \
  'for b in sleep mkdir cat tr awk grep; do command -v "$b"; done && printf "a\0b\0" | grep -qzx b && test -r /proc/self/stat'
check "/workspace exists" test -d /workspace

missing=()
for cmd in pdftotext pdftoppm pdfinfo qpdf mutool gs soffice libreoffice java pandoc tesseract \
  chromium chromedriver xvfb-run ffmpeg ffprobe convert identify 7z unar cabextract innoextract \
  msiextract zstd zip unzip hunspell sqlite3 psql msgfmt xmllint xxd shellcheck strace rg fd jq \
  tree less vi nano rsync ssh dig ip nc ps pkill lsof file bc sudo git git-lfs curl wget gcc make \
  cmake ninja pkg-config node npm npx tsx tsc uv ruff yt-dlp ocrmypdf weasyprint markitdown \
  playwright pytest ipython; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
[[ -x /usr/bin/time ]] || missing+=("/usr/bin/time")
if ((${#missing[@]})); then fail "commands missing: ${missing[*]}"; else pass "commands present"; fi

check "python imports" python3 - <<'PY'
import importlib

modules = """
numpy pandas scipy matplotlib seaborn requests httpx bs4 lxml openpyxl PIL markitdown rich tqdm
IPython pytest fitz pypdf pikepdf reportlab docx ebooklib weasyprint markdown pytesseract pdf2image
ocrmypdf docxtpl odf extract_msg tabulate ddgs curl_cffi playwright selenium yt_dlp feedparser
deep_translator cv2 skimage imageio cairosvg svgwrite qrcode pyarrow duckdb networkx shapely pyproj
sympy plotly sklearn statsmodels soundfile pefile capstone polib yaml jinja2 psycopg paramiko
language_tool_python pdfplumber pptx xlrd xlsxwriter
""".split()
failed = []
for name in modules:
    try:
        importlib.import_module(name)
    except Exception as error:  # noqa: BLE001 - report every broken import
        failed.append(f"{name}: {error!r}")
if failed:
    raise SystemExit("\n".join(failed))
print(f"{len(modules)} modules imported")
PY

check "tesseract languages" bash -c \
  'langs=$(tesseract --list-langs 2>&1); for l in eng rus ukr deu fra spa ita jpn chi_sim osd; do grep -qx "$l" <<<"$langs" || { echo "missing $l"; exit 1; }; done'

check "reportlab PDF -> pdftotext/pdftoppm/PyMuPDF/qpdf" bash -c '
  python3 -c "from reportlab.pdfgen import canvas; c = canvas.Canvas(\"r.pdf\"); c.drawString(72, 720, \"Hello smoke test\"); c.save()" &&
  pdftotext r.pdf - | grep -q "Hello smoke test" &&
  pdftoppm -r 50 -png -singlefile r.pdf r && test -s r.png &&
  python3 -c "import fitz; assert \"Hello smoke test\" in fitz.open(\"r.pdf\")[0].get_text()" &&
  qpdf --check r.pdf'

check "LibreOffice converts python-docx DOCX to PDF" bash -c '
  python3 -c "import docx; d = docx.Document(); d.add_paragraph(\"Привет, office smoke test\"); d.save(\"d.docx\")" &&
  timeout 180 soffice --headless --norestore --convert-to pdf --outdir out d.docx &&
  pdftotext out/d.pdf - | grep -q "office smoke test"'

check "markitdown reads DOCX offline" bash -c 'markitdown d.docx | grep -q "office smoke test"'

check "tesseract OCR (eng+rus)" bash -c '
  python3 -c "
from PIL import Image, ImageDraw, ImageFont
font = ImageFont.truetype(\"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf\", 48)
image = Image.new(\"L\", (900, 160), 255)
ImageDraw.Draw(image).text((20, 50), \"Smoke test Проверка\", font=font, fill=0)
image.save(\"o.png\")" &&
  tesseract o.png - -l eng+rus 2>/dev/null | grep -q "Проверка"'

check "ocrmypdf" bash -c 'timeout 180 ocrmypdf --force-ocr -l eng --output-type pdf r.pdf ocr.pdf && pdftotext ocr.pdf - | grep -qi "smoke"'

check "weasyprint HTML -> PDF" bash -c \
  'echo "<h1>Weasy smoke</h1>" > w.html && weasyprint w.html w.pdf && pdftotext w.pdf - | grep -q "Weasy smoke"'

check "system chromium headless" bash -c '
  timeout 120 chromium --headless --screenshot="$PWD/c.png" --window-size=400,300 "data:text/html,<h1>chromium ok</h1>" &&
  test -s c.png &&
  timeout 60 chromium --headless --dump-dom about:blank | grep -q "<html"'

check "playwright headless chromium" python3 - <<'PY'
import os

from playwright.sync_api import sync_playwright

with sync_playwright() as playwright:
    browser = playwright.chromium.launch()
    page = browser.new_page()
    page.goto("data:text/html,<h1 id=x>playwright ok</h1>")
    assert page.inner_text("#x") == "playwright ok"
    page.screenshot(path="pw.png")
    browser.close()
assert os.path.getsize("pw.png") > 0
PY

check "selenium + chromedriver" python3 - <<'PY'
from selenium import webdriver
from selenium.webdriver.chrome.service import Service

options = webdriver.ChromeOptions()
options.binary_location = "/usr/bin/chromium"
options.add_argument("--headless=new")
driver = webdriver.Chrome(service=Service("/usr/bin/chromedriver"), options=options)
try:
    driver.get("data:text/html,<p id=s>selenium ok</p>")
    assert driver.find_element("id", "s").text == "selenium ok"
finally:
    driver.quit()
PY

check "fonts (Noto CJK, Liberation, Carlito, emoji)" bash -c \
  'fonts=$(fc-list); for f in "Noto Sans CJK" Liberation Carlito "Noto Color Emoji" "PT Sans"; do grep -qi "$f" <<<"$fonts" || { echo "missing $f"; exit 1; }; done'

check "node globals (docx, pptxgenjs, tsx, tsc)" bash -c \
  'node -e "require(\"docx\"); require(\"pptxgenjs\")" && echo "const x: number = 1; console.log(x)" > t.ts && tsx t.ts | grep -qx 1 && tsc --version'

check "ffmpeg encodes and probes" bash -c \
  'ffmpeg -loglevel error -f lavfi -i testsrc=duration=1:size=64x64:rate=5 -y t.mp4 && ffprobe -loglevel error -show_streams t.mp4 | grep -q codec_name'

check "java runs" java -version
check "7z round trip" bash -c 'echo data > a.txt && 7z a -bd a.7z a.txt && 7z l a.7z | grep -q a.txt'
check "sqlite3" bash -c 'sqlite3 :memory: "select 40 + 2" | grep -qx 42'
check "hunspell ru_RU dictionary" bash -c 'echo "привет превет" | hunspell -d ru_RU -l | grep -qx "превет"'
check "imagemagick" bash -c 'convert -size 10x10 xc:white i.png && identify i.png | grep -q PNG'

if ((failures)); then
  echo "smoke test: $failures check(s) failed"
  exit 1
fi
echo "smoke test: all checks passed"
