# Third-party notices

xpharness itself (the PowerShell harness and scripts) is MIT-licensed — see
`LICENSE`. It does **not** redistribute any of the components below; `setup.sh`
downloads them from their original sources and builds the small binaries on your
machine. Each component remains under its own license, summarized here for
convenience. This is not legal advice — consult the upstream licenses directly.

| Component | Used for | License | Source |
|---|---|---|---|
| **llama2.c** (`run.c`, `runq.c`, `win.c/.h`, `export.py`, `model.py`) | local model inference; we compile `run.exe`/`runq.exe` from it | MIT | https://github.com/karpathy/llama2.c |
| **Tiny C Compiler (TCC)** | the `compile_run` tool (`tools/tcc/`) | **LGPL 2.1** | https://repo.or.cz/tinycc.git / https://download.savannah.gnu.org/releases/tinycc/ |
| **curl** (`bin/curl.exe`, XP build) | TLS 1.2 transport | curl license (MIT-style) | https://github.com/OmegaAOL/curl-windows98 (build) · https://curl.se (project) |
| **OpenSSL 1.0.2** (statically linked into that curl) | TLS | OpenSSL + SSLeay license | https://www.openssl.org |
| **Mozilla CA bundle** (`bin/cacert.pem`) | curl trust store | MPL 2.0 | https://curl.se/docs/caextract.html |
| **TinyStories checkpoints** (`stories15M.bin`, `stories110M.bin`) | toy local models | released by A. Karpathy (permissive); trained on Microsoft's TinyStories dataset (CDLA-Sharing-1.0) | https://huggingface.co/karpathy/tinyllamas |
| **TinyLlama-1.1B-Chat-v1.0** (`tinyllama-q8.bin`, our int8 export) | local chat model | Apache 2.0 | https://huggingface.co/TinyLlama/TinyLlama-1.1B-Chat-v1.0 |
| **Llama 2 tokenizer** (`tokenizer.bin`) | tokenization for all local models | **Meta Llama 2 Community License** | https://github.com/karpathy/llama2.c (tokenizer.bin) · https://ai.meta.com/llama/license |

Two components carry the most obligations if you ever redistribute them yourself
(rather than letting users download via `setup.sh`):

- **TCC — LGPL 2.1.** Ship the LGPL text, make the corresponding source available,
  and keep it dynamically linked / relinkable (we use the stock `tcc.exe` +
  `libtcc.dll`, so it is).
- **Llama 2 tokenizer — Meta license.** Redistribution carries Meta's terms
  (include the license, attribution, the acceptable-use policy, and the
  >700M-MAU clause). `setup.sh` pulls it from upstream so you are not the
  redistributor.

`export.py` and `model.py` are vendored from llama2.c (MIT). `export.py` is
patched locally to handle grouped-query attention (`num_key_value_heads`) so it
can quantize TinyLlama; the change is noted in `llm/README.md`.
