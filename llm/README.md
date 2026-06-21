# Tiny local LLM on Windows XP (for fun)

A neural net generating text **entirely offline on Windows XP** — no API, no
network, no GPU. This is [Andrej Karpathy's llama2.c](https://github.com/karpathy/llama2.c)
(`run.c` + `win.c`/`win.h`) cross-compiled to a 32-bit XP executable, running the
TinyStories 15M model.

It is a **toy**: TinyStories writes simple toddler-grade short stories. It is not
a coding assistant and cannot do the tool-calling the main harness does. The point
is "look, a language model dreaming on a 25-year-old OS."

## Why it runs on XP when llama.cpp can't

Same trick as the rest of this project: a self-contained binary that asks nothing
modern of the OS. `run.exe` imports only `kernel32.dll` and `msvcrt.dll` — both
ship with stock XP — and libgcc is statically linked. **No redistributable
needed** (unlike `bin\curl.exe`, which wants the VC++ 2005 runtime).

## The real constraint: 32-bit, not 4GB

32-bit XP caps a single process at ~2GB (≈3GB with the `/3GB` boot switch). So the
ceiling isn't your 4GB of RAM — it's ~2GB per process. The 15M model is ~60MB, so
it's nowhere near the limit; you could go much bigger (a quantized ~1B via the
`runq.c` int8 variant is the practical max, and would be slow).

## Files

- `run.exe` — the 32-bit XP binary (cross-compiled with i686-w64-mingw32-gcc, static)
- `stories15M.bin` — TinyStories 15M weights (~60MB, fp32)
- `tokenizer.bin` — the tokenizer
- `run.bat` — convenience launcher
- `run.c`, `win.c`, `win.h` — source (kept for transparency / rebuilding)

## Run it

```
run.bat "Once upon a time"
```

or directly with options (temperature, steps, prompt):

```
run.exe stories15M.bin -z tokenizer.bin -t 0.9 -n 256 -i "The robot looked at the old computer and"
```

Flags: `-t` temperature, `-n` number of steps/tokens, `-i` prompt, `-s` seed.

## Models available

| Files | Engine | Harness name | Notes |
|---|---|---|---|
| `stories15M.bin` | `run.exe` (fp32) | `local` | ~0.5GB RAM, fast toy stories |
| `stories110M.bin` | `run.exe` (fp32) | `local-110m` | ~0.9GB RAM, better toy stories |
| `tinyllama-q8.bin` | `runq.exe` (int8) | `local-tl` | ~1.3GB RAM, real chat model, slow |

All share `tokenizer.bin` (the 32000-token Llama-2 tokenizer).

## From inside the harness

Type `/models local`, `/models local-110m`, or `/models local-tl`; your next
message becomes the prompt. `/models sonnet` (or `haiku`/`opus`) switches back to
the real API. The model definitions (exe/weights/tokenizer/steps/temp + an
optional chat template) live in `$LocalModels` in `harness.ps1`.

`local-tl` (TinyLlama Chat) gets the proper chat template applied automatically,
so it behaves like a (small, limited) assistant. The TinyStories models have no
template - they just continue your text. None of them can use tools.

## Building tinyllama-q8.bin yourself

Exported from HF with llama2.c's `export.py` (int8, group size 64). Note: the
upstream `export.py` mishandles grouped-query attention; `load_hf_model` must use
`num_key_value_heads` and permute `k_proj` with the KV head count (patched here).

```
python export.py tinyllama-q8.bin --version 2 --hf TinyLlama/TinyLlama-1.1B-Chat-v1.0
i686-w64-mingw32-gcc -O2 -D_WIN32_WINNT=0x0501 runq.c win.c -o runq.exe -lm -static -static-libgcc
```

Performance: on a Pentium-4 / early-Core-era CPU expect somewhere in the low tens
of tokens/sec for 15M — watchable, not instant. Bigger models scale down fast.

## Rebuild (on a Linux box with mingw)

```
i686-w64-mingw32-gcc -O2 -D_WIN32_WINNT=0x0501 run.c win.c -o run.exe -lm -static -static-libgcc
```
