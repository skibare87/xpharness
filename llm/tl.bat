@echo off
REM TinyLlama 1.1B Chat (int8) standalone on Windows XP via llama2.c runq.exe.
REM ~1.3GB RAM, real (small) chat model. Slow on old CPUs - be patient.
REM
REM Usage:  tl.bat "what is the capital of France?"
REM
REM This is raw-prompt mode. For proper chat-templated replies, run it from the
REM harness instead:  /models local-tl

set PROMPT=%~1
runq.exe tinyllama-q8.bin -z tokenizer.bin -t 0.7 -n 512 -i "%PROMPT%"
