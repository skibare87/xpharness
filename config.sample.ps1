# Copy this file to config.ps1 and fill in your key.
# config.ps1 is dot-sourced by harness.ps1 at startup.

$Config = @{
    ApiKey    = "sk-ant-REPLACE-ME"
    # Default model: a shortcut (sonnet/haiku/opus/local/local-110m/local-tl) or a literal model ID.
    Model     = "sonnet"
    BaseUrl   = "https://api.anthropic.com/v1/messages"

    # /models shortcut -> real model ID. Edit to pin a dated version or remap a
    # class; add your own shortcuts too. Omit to use the harness built-in defaults.
    Models = @{
        sonnet = "claude-sonnet-4-6"
        haiku  = "claude-haiku-4-5-20251001"
        opus   = "claude-opus-4-8"
    }
    Version   = "2023-06-01"
    MaxTokens = 4096

    # Paths to the XP-compatible curl build (curl-windows98) and a CA bundle.
    # Drop curl.exe + cacert.pem in the bin\ folder next to harness.ps1.
    CurlPath  = "bin\curl.exe"
    CaCert    = "bin\cacert.pem"

    # Exa API key (https://exa.ai) enables the web_search tool. Leave blank
    # to disable web search.
    ExaApiKey = ""

    # Local offline models (TinyStories / TinyLlama via llama2.c) are defined
    # in harness.ps1 ($LocalModels) and selected with /models local|local-110m|local-tl.

    # Bundled Tiny C Compiler (enables the compile_run tool). Runs on bare XP.
    TccPath = "tools\tcc\tcc.exe"

    # Keep a .bak copy before overwriting/editing existing files (undo_file restores it).
    BackupOnWrite = $true

    # Show a diff preview before confirming edit_file / write_file changes.
    DiffPreview = $true

    # Color for the startup banner + the banner tool. The XP console only has
    # 16 fixed colors. Crisp picks: Green (start-button green), Cyan (readable
    # blue), Yellow (Clippy yellow), White, Magenta. NOTE: plain Blue is dark
    # and low-contrast on black (use Cyan instead), and DarkYellow renders muddy
    # olive/brown - avoid both. Invalid names fall back to Green.
    BannerColor = "Green"

    # Safety: ask before running shell commands / writing files.
    Confirm   = $true

    # Working directory for the agent's file tools and saved sessions. Leave
    # blank to auto-pick (the harness folder if writable, else your home folder)
    # - handy when running from read-only media like a CD/DVD. Set a path to pin it.
    WorkDir   = ""

    # Down-convert non-ASCII (em-dashes, smart quotes, emoji) to ASCII for
    # display, since the XP console can't render them. The real UTF-8 still
    # goes to/from the API. Set $false if you have a Unicode-capable console.
    AsciiDisplay = $true

    # Stream the answer live instead of waiting for the whole response.
    Stream = $true

    # Render basic markdown (bold/italic/headings/lists) using console colors.
    RenderMarkdown = $true

    # Kill any run_command that runs longer than this many seconds (so a
    # hung/interactive command can't freeze the agent loop).
    CommandTimeoutSec = 30

    # Optional cost readout. Leave at 0 to show tokens only. If you set both
    # (USD per 1,000,000 tokens, from the Anthropic pricing page for your
    # model), each turn also prints a running ~$ estimate.
    PriceInPerMTok  = 0
    PriceOutPerMTok = 0
}
