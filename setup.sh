#!/usr/bin/env bash
# =====================================================================
#  xpharness setup - run on a MODERN machine (Linux/mac), then SFTP the
#  whole folder to the Windows XP box. (XP itself can't TLS to these
#  hosts - that's the entire reason this project exists.)
#
#  Fetches: curl-for-XP + CA bundle, Tiny C Compiler, TinyStories models,
#  Llama-2 tokenizer; and cross-builds the llama2.c engines for 32-bit XP.
#  Optional: exports TinyLlama-1.1B-Chat to int8 (needs Python+torch).
#
#  Requirements: bash, curl, python3, i686-w64-mingw32-gcc
#                (Debian/Ubuntu: sudo apt install gcc-mingw-w64-i686)
#  Optional (for --tinyllama): python3 with torch + transformers
#
#  Usage:  ./setup.sh            # everything except TinyLlama
#          ./setup.sh --tinyllama
# =====================================================================
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
DO_TL=0; [ "$1" = "--tinyllama" ] && DO_TL=1

need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1"; exit 1; }; }
need curl; need python3; need i686-w64-mingw32-gcc

MINGW="i686-w64-mingw32-gcc -O2 -D_WIN32_WINNT=0x0501 -lm -static -static-libgcc -Wl,--large-address-aware"

# pick a RAR extractor (curl-windows98 ships a .rar); fall back to 7-Zip
extract_rar() { # $1=rar $2=destdir
    mkdir -p "$2"
    if command -v 7z   >/dev/null 2>&1; then 7z  x -y "$1" -o"$2" >/dev/null; return; fi
    if command -v 7zz  >/dev/null 2>&1; then 7zz x -y "$1" -o"$2" >/dev/null; return; fi
    if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$1" -C "$2"; return; fi
    echo "  no rar tool found; fetching standalone 7-Zip..."
    ( cd /tmp && curl -sL -o 7z.txz "https://www.7-zip.org/a/7z2501-linux-x64.tar.xz" && tar xf 7z.txz 7zz )
    /tmp/7zz x -y "$1" -o"$2" >/dev/null
}

echo "== [1/4] curl + CA bundle -> bin/ =="
mkdir -p bin
curl -sL -o bin/cacert.pem "https://curl.se/ca/cacert.pem"
curl -sL -o /tmp/xph-curl.rar "https://github.com/OmegaAOL/curl-windows98/releases/download/release/curl-7.42.1-BINARY.rar"
extract_rar /tmp/xph-curl.rar /tmp/xph-curl
cp "$(find /tmp/xph-curl -name curl.exe | head -1)" bin/curl.exe
rm -rf /tmp/xph-curl /tmp/xph-curl.rar

echo "== [2/4] Tiny C Compiler -> tools/tcc/ =="
mkdir -p tools
curl -sL -o /tmp/xph-tcc.zip "https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27-win32-bin.zip"
python3 -c "import zipfile; zipfile.ZipFile('/tmp/xph-tcc.zip').extractall('tools')"
rm -f /tmp/xph-tcc.zip tools/tcc/x86_64-win32-tcc.exe
rm -rf tools/tcc/doc tools/tcc/examples

echo "== [3/4] TinyStories models + tokenizer, build engines -> llm/ =="
cd "$ROOT/llm"
curl -sL -o tokenizer.bin   "https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin"
curl -sL -o stories15M.bin  "https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin"
curl -sL -o stories110M.bin "https://huggingface.co/karpathy/tinyllamas/resolve/main/stories110M.bin"
$MINGW run.c  win.c -o run.exe
$MINGW runq.c win.c -o runq.exe
echo "   built run.exe + runq.exe"

echo "== [4/4] TinyLlama 1.1B int8 (optional) =="
if [ "$DO_TL" = "1" ]; then
    if python3 -c "import torch, transformers" 2>/dev/null; then
        python3 export.py tinyllama-q8.bin --version 2 --hf TinyLlama/TinyLlama-1.1B-Chat-v1.0
        echo "   wrote tinyllama-q8.bin"
    else
        echo "   SKIPPED: needs python3 with torch + transformers"
    fi
else
    echo "   skipped (pass --tinyllama to build it; ~2.2GB download)"
fi

cd "$ROOT"
echo
echo "Done. Now: copy config.sample.ps1 -> config.ps1, add your API key,"
echo "then SFTP this whole folder to the XP box and run harness.ps1."
