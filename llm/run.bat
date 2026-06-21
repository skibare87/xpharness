@echo off
REM Tiny local LLM on Windows XP - Karpathy's llama2.c running TinyStories 15M.
REM Pure CPU, no GPU, no network, no dependencies beyond XP's own msvcrt.dll.
REM
REM Usage:  run.bat "Once upon a time"
REM         run.bat                      (no prompt = free generation)

set PROMPT=%~1
run.exe stories15M.bin -z tokenizer.bin -t 0.9 -n 256 -i "%PROMPT%"
