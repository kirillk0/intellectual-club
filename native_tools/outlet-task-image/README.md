# Task Workspace Image

Default image for [`outlet-task-container`](../crates/outlet-task-container/README.md):
one disposable container per chat family. It is preloaded with the tools agents
reached for most often, so typical document, OCR, browser and data tasks do not start
with `apt-get`/`pip install`.

Contents at a glance (exact versions: `cat /usr/local/share/outlet-task-image/manifest.txt`
inside a container):

- Python 3.12 (system interpreter of `python:3.12-bookworm`, root installs, no venv),
  `uv`, data/science stack, PDF/Office libraries (PyMuPDF, pypdf, pikepdf, reportlab,
  python-docx, python-pptx via markitdown, openpyxl, weasyprint, ocrmypdf), web
  (requests, httpx, curl_cffi, ddgs, playwright, selenium, yt-dlp), images (Pillow,
  OpenCV, scikit-image), geometry/science (shapely, pyproj, sympy, scikit-learn);
- Node 24 with `docx`, `pptxgenjs`, `tsx`, `typescript` globally (`NODE_PATH` is set);
- poppler, qpdf, mupdf-tools, Ghostscript, LibreOffice (headless), pandoc, Java 17;
- Tesseract with eng/rus/ukr/deu/fra/spa/ita/jpn/chi_sim/osd;
- Debian Chromium + chromedriver (container-safe default flags), Playwright's
  headless Chromium shell in `/ms-playwright`, Xvfb, FFmpeg;
- fonts: DejaVu, Liberation, Carlito/Caladea (Calibri/Cambria metrics), Noto incl.
  CJK and color emoji, PT fonts; hunspell ru/en/de;
- archives (7z, unar, cabextract, innoextract, msitools, zstd), ripgrep, fd, jq,
  sqlite3, psql, gettext, xmllint, shellcheck, strace, git-lfs and common CLI tools.

## Runner contract

The runner overrides the entrypoint with an idle process, runs every command as root
through `/bin/sh -c` (not a login shell) in `/workspace`, and stops a timed-out or
canceled command with a POSIX-sh helper. Therefore the image:

- declares no `VOLUME` (the runner rejects such images);
- provides `/bin/sh`, `sleep`, `mkdir`, `cat`, `tr`, `awk`, GNU `grep` (`-z`) and `/proc`;
- configures everything through `ENV`, not `profile.d`;
- makes `/bin/sh` bash, because agents often write bash syntax;
- passes `--no-sandbox --disable-dev-shm-usage --disable-gpu` (and `--headless=new`
  when `DISPLAY` is unset) to Debian Chromium via `/etc/chromium.d/90-container`,
  since commands run as root with Docker's default 64 MB `/dev/shm`.

It is labelled `org.intellectual-club.keep=true` so host cleanup jobs can keep the
locally built image that the runner cannot pull from a registry.

## How the package list was chosen

About 38,000 agent `run_command` calls from CI/CD chats were analyzed (Docker shell
outlets, an agent VM and desktop shells): which programs and Python modules agents
used, what they installed with `apt`/`pip`/`npm`, and which commands failed with
`command not found` or `No module named`. The most frequent gaps of the previous
shell image were poppler (`pdftotext`/`pdftoppm`), Tesseract, Chromium, PyMuPDF,
LibreOffice, fonts, Node, python-docx and pypdf. Rarely used heavy stacks (PyTorch,
Whisper, Wine, TeX Live, CAD kernels) are intentionally left out; agents can still
install anything as root.

## Build and test

```sh
docker buildx build -t intellectual-club-task-workspace:dev native_tools/outlet-task-image
docker run --rm --network none intellectual-club-task-workspace:dev \
  /usr/local/lib/outlet-task-image/smoke-test.sh
```

The build also runs the smoke test as its last step. On a shared host, bound the
build, e.g. `--cgroup-parent <limited>.slice` (honored by the BuildKit docker driver).
The image is about 6 GB; the first build takes roughly 20–40 minutes on two vCPUs.

## Adding packages

Layers are ordered from rarely to frequently changed:

1. `apt-packages.txt` — heavy document/OCR/browser/media/font stack;
2. `requirements.txt` — pip packages (resolved at build time, recorded in the manifest);
3. `npm-global.txt` — global npm packages;
4. Playwright headless shell;
5. `apt-tools.txt` — small CLI/dev tools (cheapest place for new apt packages).

Add an entry to the right file (comments with `#` are allowed), extend
`smoke-test.sh` with an import or command check, and rebuild. Prefer pip over apt for
Python tools: Debian packages that depend on `python3` add a second interpreter
(this is why LibreOffice uses the component `-nogui` packages instead of
`libreoffice-nogui`).
