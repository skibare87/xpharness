# =====================================================================
#  xpharness - a tiny agentic coding harness for Windows XP / PowerShell 2
#
#  Talks to the Anthropic Messages API through an XP-compatible curl
#  build (curl-windows98, OpenSSL 1.0.2u) so it can negotiate TLS 1.2
#  without relying on the OS SChannel (which caps at TLS 1.0 on XP).
#
#  Usage:   powershell -ExecutionPolicy Bypass -File harness.ps1
# =====================================================================

$ErrorActionPreference = "Stop"

# --- locate ourselves (PS2 has no $PSScriptRoot) -----------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
# Keep .NET's idea of the working dir in sync with PowerShell's location, so
# [IO.File] (read/write/edit_file) and child processes (run_command) resolve
# relative paths the same way Get-ChildItem (list_dir/grep/find) does.
[Environment]::CurrentDirectory = (Get-Location).Path

# --- load config -------------------------------------------------------
$cfgPath = Join-Path $ScriptDir "config.ps1"
if (-not (Test-Path $cfgPath)) {
    Write-Host "No config.ps1 found. Copy config.sample.ps1 to config.ps1 and add your API key." -ForegroundColor Red
    exit 1
}
. $cfgPath

# resolve relative tool paths against the script dir
function Resolve-Rel($p) {
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $ScriptDir $p)
}
$CurlExe = Resolve-Rel $Config.CurlPath
$CaCert  = Resolve-Rel $Config.CaCert

if (-not (Test-Path $CurlExe)) { Write-Host "curl not found at $CurlExe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $CaCert))  { Write-Host "cacert.pem not found at $CaCert" -ForegroundColor Red; exit 1 }

# --- optional extras (retro flair: banner + image_to_ascii) ------------
$extrasPath = Join-Path $ScriptDir "extras.ps1"
if (Test-Path $extrasPath) { . $extrasPath }

# --- JSON --------------------------------------------------------------
#  PowerShell 2 has no ConvertTo-Json / ConvertFrom-Json.
#  Parsing: .NET 3.5 JavaScriptSerializer.DeserializeObject works great
#  (returns plain Dictionary/object[]), so we keep it for responses.
#  Serializing: JavaScriptSerializer.Serialize chokes on PowerShell
#  hashtables (it reflects over the parameterized 'Item' property and
#  throws a circular-reference error), so we hand-roll the writer below.
[void][Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
$JsonSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$JsonSer.MaxJsonLength = 67108864   # 64 MB ceiling for big responses

function From-Json($str) { $JsonSer.DeserializeObject($str) }

function Escape-JsonString($s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int][char]$ch
        if     ($ch -eq '"')  { [void]$sb.Append('\"') }
        elseif ($ch -eq '\')  { [void]$sb.Append('\\') }
        elseif ($code -eq 8)  { [void]$sb.Append('\b') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9)  { [void]$sb.Append('\t') }
        elseif ($code -lt 32 -or $code -gt 126) {
            [void]$sb.Append('\u')
            [void]$sb.Append($code.ToString('x4'))
        }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function To-Json($obj) {
    if ($null -eq $obj) { return "null" }
    if ($obj -is [bool]) { if ($obj) { return "true" } else { return "false" } }
    if ($obj -is [string] -or $obj -is [char]) { return (Escape-JsonString ([string]$obj)) }
    if ($obj -is [int] -or $obj -is [long] -or $obj -is [int16] -or $obj -is [byte] `
        -or $obj -is [uint16] -or $obj -is [uint32] -or $obj -is [uint64]) {
        return [string]$obj
    }
    if ($obj -is [double] -or $obj -is [single] -or $obj -is [decimal]) {
        return $obj.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($obj -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($key in $obj.Keys) {
            $parts += (Escape-JsonString ([string]$key)) + ":" + (To-Json $obj[$key])
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($obj -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($item in $obj) { $parts += (To-Json $item) }
        return "[" + ($parts -join ",") + "]"
    }
    return (Escape-JsonString ([string]$obj))   # fallback
}

$Utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM

# --- console display sanitizer -----------------------------------------
#  The XP console (raster font, codepage 437) can't render em-dashes,
#  smart quotes, arrows, emoji, etc. We keep the real UTF-8 for the API
#  but down-convert to ASCII for what we print. Set $Config.AsciiDisplay
#  to $false to disable. Disabled only when explicitly set to $false, so
#  the default works even if the key is missing from config.ps1.
$AsciiMap = @{
    0x2013 = "-";  0x2014 = "--"; 0x2015 = "--";
    0x2018 = "'";  0x2019 = "'";  0x201A = ",";
    0x201C = '"';  0x201D = '"';  0x2026 = "...";
    0x2022 = "*";  0x00B7 = "*";  0x2192 = "->"; 0x2190 = "<-";
    0x00A0 = " ";  0x00B0 = " deg"; 0x00D7 = "x"; 0x2212 = "-"
}
function Format-ForConsole($s) {
    if ($Config.AsciiDisplay -eq $false) { return $s }
    if ($null -eq $s) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$s).ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$sb.Append($ch) }
        elseif ($AsciiMap.ContainsKey($code)) { [void]$sb.Append($AsciiMap[$code]) }
        else { [void]$sb.Append('?') }
    }
    return $sb.ToString()
}

# --- markdown-ish rendering -------------------------------------------
#  The XP console has 16 colors and no bold/italic attributes, so we
#  approximate: bold=White, italic=Yellow, code=Green, heading=Magenta,
#  list bullets/quotes tinted. Set $Config.RenderMarkdown=$false to print
#  plain teal instead. Inline parsing is line-based (see Render-Line).
function Write-Seg($text, $color) {
    if ($text.Length -gt 0) { Write-Host (Format-ForConsole $text) -NoNewline -ForegroundColor $color }
}
function Render-Inline($text) {
    $rx = [regex]'(\*\*.+?\*\*|`[^`]+`|\*[^*]+\*|_[^_]+_)'
    $idx = 0
    foreach ($m in $rx.Matches($text)) {
        if ($m.Index -gt $idx) { Write-Seg ($text.Substring($idx, $m.Index - $idx)) "Gray" }
        $tok = $m.Value
        if     ($tok.StartsWith('**')) { Write-Seg ($tok.Substring(2, $tok.Length - 4)) "White" }
        elseif ($tok.StartsWith('`'))  { Write-Seg ($tok.Substring(1, $tok.Length - 2)) "Green" }
        else                           { Write-Seg ($tok.Substring(1, $tok.Length - 2)) "Yellow" }
        $idx = $m.Index + $m.Length
    }
    if ($idx -lt $text.Length) { Write-Seg ($text.Substring($idx)) "Gray" }
    Write-Host ""
}
$script:MdInCode = $false
function Render-Line($line) {
    if ($Config.RenderMarkdown -eq $false) {
        Write-Host (Format-ForConsole $line) -ForegroundColor Cyan
        return
    }
    # fenced code blocks: print verbatim (no heading/inline parsing) so code
    # and ASCII art survive intact
    if ($line -match '^\s*```') {
        $script:MdInCode = -not $script:MdInCode
        Write-Host "  ----" -ForegroundColor DarkGray
        return
    }
    if ($script:MdInCode) { Write-Host ("  " + (Format-ForConsole $line)) -ForegroundColor Green; return }
    $m = [regex]::Match($line, '^(#{1,6})\s+(.*)$')                 # heading
    if ($m.Success) { Write-Host (Format-ForConsole $m.Groups[2].Value) -ForegroundColor Magenta; return }
    if ($line -match '^\s*([-*_])\1\1+\s*$') { Write-Host ("-" * 40) -ForegroundColor DarkGray; return }  # rule
    $m = [regex]::Match($line, '^(\s*)([-*+]|\d+\.)\s+(.*)$')       # list item
    if ($m.Success) {
        $marker = $m.Groups[2].Value
        if ($marker -match '^[-*+]$') { $marker = "-" }
        Write-Host ($m.Groups[1].Value + "  " + $marker + " ") -NoNewline -ForegroundColor Cyan
        Render-Inline $m.Groups[3].Value
        return
    }
    $m = [regex]::Match($line, '^>\s?(.*)$')                        # blockquote
    if ($m.Success) { Write-Host ("| " + (Format-ForConsole $m.Groups[1].Value)) -ForegroundColor DarkGray; return }
    Render-Inline $line
}
function Render-Markdown($text) {
    foreach ($ln in (($text -replace "`r`n", "`n") -split "`n")) { Render-Line $ln }
}
function Print-Answer($text) {
    Write-Host ""
    if ($Config.RenderMarkdown -eq $false) { Write-Host (Format-ForConsole $text) -ForegroundColor Cyan }
    else { Render-Markdown $text }
}

# =====================================================================
#  TOOLS  -  each returns a string that becomes the tool_result content
# =====================================================================

function Confirm-Action($prompt) {
    if (-not $Config.Confirm) { return $true }
    Write-Host ""
    Write-Host $prompt -ForegroundColor Yellow
    # Discard any type-ahead / pasted lines so they can't auto-answer this y/N.
    try { $Host.UI.RawUI.FlushInputBuffer() } catch {}
    $ans = Read-Host "  allow? [y/N]"
    return ($ans -eq "y" -or $ans -eq "Y")
}

function Tool-RunCommand($toolInput) {
    $cmd = [string]$toolInput["command"]
    if (-not (Confirm-Action "RUN: $cmd")) { return "(denied by user)" }

    $timeoutSec = 30
    if ($Config.CommandTimeoutSec) { $timeoutSec = [int]$Config.CommandTimeoutSec }

    # Run via a Process so we can enforce a timeout. Redirect output to a file
    # *inside* cmd (not through pipes) to avoid the classic buffer deadlock and
    # to keep partial output if we have to kill a runaway command.
    $outFile = Join-Path $env:TEMP "xph_cmd.out"
    if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = "cmd.exe"
        $psi.Arguments       = '/c ' + $cmd + ' > "' + $outFile + '" 2>&1'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.WindowStyle     = "Hidden"
        $psi.WorkingDirectory = (Get-Location).Path

        $p = [System.Diagnostics.Process]::Start($psi)
        $finished = $p.WaitForExit($timeoutSec * 1000)

        # cmd wrote with the console's OEM codepage; decode with the same.
        $enc = [System.Console]::OutputEncoding
        $out = ""
        if (Test-Path $outFile) { $out = [IO.File]::ReadAllText($outFile, $enc) }

        if (-not $finished) {
            try { $p.Kill() } catch {}
            return "ERROR: command exceeded ${timeoutSec}s timeout and was killed.`r`n--- partial output ---`r`n$out"
        }
        $code = $p.ExitCode
        if (-not $out) { $out = "(no output)" }
        return "exit ${code}`r`n$out"
    } catch {
        return "ERROR running command: $($_.Exception.Message)"
    }
}

function Tool-ReadFile($toolInput) {
    $path = [string]$toolInput["path"]
    try {
        if (-not (Test-Path $path)) { return "ERROR: file not found: $path" }
        $offset = 0; if ($toolInput["offset"]) { $offset = [int]$toolInput["offset"] }   # 1-based start line
        $limit  = 0; if ($toolInput["limit"])  { $limit  = [int]$toolInput["limit"] }
        $numbers = ($toolInput["line_numbers"] -eq $true)
        if ($offset -le 0 -and $limit -le 0 -and -not $numbers) {
            return [IO.File]::ReadAllText($path)            # whole file, undecorated
        }
        $all = [IO.File]::ReadAllLines($path)
        $start = 0; if ($offset -gt 0) { $start = $offset - 1 }
        if ($start -ge $all.Length) { return "(offset $offset past end; file has $($all.Length) lines)" }
        $end = $all.Length - 1
        if ($limit -gt 0) { $end = $start + $limit - 1; if ($end -gt $all.Length - 1) { $end = $all.Length - 1 } }
        $sb = New-Object System.Text.StringBuilder
        for ($i = $start; $i -le $end; $i++) {
            if ($numbers) { [void]$sb.Append("{0,6}: " -f ($i + 1)) }
            [void]$sb.Append($all[$i]); [void]$sb.Append("`r`n")
        }
        if (($end - $start + 1) -lt $all.Length) { [void]$sb.Append("(showing lines $($start+1)-$($end+1) of $($all.Length))") }
        return $sb.ToString()
    } catch { return "ERROR reading $path : $($_.Exception.Message)" }
}

# Copy a file to <path>.bak before we overwrite it (undo_file restores it).
function Backup-File($path) {
    if ($Config.BackupOnWrite -eq $false) { return }
    if (Test-Path $path) { try { Copy-Item -Path $path -Destination ($path + ".bak") -Force } catch {} }
}

# Print a minimal line diff (common prefix/suffix trimmed) before a confirm.
function Show-Diff($oldText, $newText) {
    if ($Config.DiffPreview -eq $false) { return }
    $o = (([string]$oldText) -replace "`r`n", "`n") -split "`n"
    $n = (([string]$newText) -replace "`r`n", "`n") -split "`n"
    $p = 0
    while ($p -lt $o.Length -and $p -lt $n.Length -and $o[$p] -eq $n[$p]) { $p++ }
    $so = $o.Length - 1; $sn = $n.Length - 1
    while ($so -ge $p -and $sn -ge $p -and $o[$so] -eq $n[$sn]) { $so--; $sn-- }
    Write-Host "  --- diff preview ---" -ForegroundColor DarkGray
    for ($i = $p; $i -le $so; $i++) { Write-Host ("  - " + (Format-ForConsole $o[$i])) -ForegroundColor Red }
    for ($i = $p; $i -le $sn; $i++) { Write-Host ("  + " + (Format-ForConsole $n[$i])) -ForegroundColor Green }
    if ($p -gt $so -and $p -gt $sn) { Write-Host "  (no line-level changes)" -ForegroundColor DarkGray }
}

function Tool-UndoFile($toolInput) {
    $path = [string]$toolInput["path"]
    $bak = $path + ".bak"
    if (-not (Test-Path $bak)) { return "ERROR: no backup ($bak) to restore" }
    if (-not (Confirm-Action "UNDO: restore $path from its .bak")) { return "(denied by user)" }
    try { Copy-Item -Path $bak -Destination $path -Force; return "restored $path from backup" }
    catch { return "ERROR restoring $path : $($_.Exception.Message)" }
}

function Tool-WriteFile($toolInput) {
    $path = [string]$toolInput["path"]
    $body = [string]$toolInput["content"]
    if (Test-Path $path) { try { Show-Diff ([IO.File]::ReadAllText($path)) $body } catch {} }
    if (-not (Confirm-Action "WRITE $($body.Length) chars to: $path")) { return "(denied by user)" }
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Backup-File $path
        [IO.File]::WriteAllText($path, $body, $Utf8)
        return "wrote $($body.Length) chars to $path"
    } catch {
        return "ERROR writing $path : $($_.Exception.Message)"
    }
}

function Tool-ListDir($toolInput) {
    $path = [string]$toolInput["path"]
    if (-not $path) { $path = "." }
    try {
        $items = Get-ChildItem -Force $path | ForEach-Object {
            $tag = if ($_.PSIsContainer) { "<DIR> " } else { "{0,8} " -f $_.Length }
            "$tag $($_.Name)"
        }
        return ($items -join "`r`n")
    } catch {
        return "ERROR listing $path : $($_.Exception.Message)"
    }
}

function Tool-WebSearch($toolInput) {
    if (-not $Config.ExaApiKey) {
        return "ERROR: web search not configured. Set ExaApiKey in config.ps1."
    }
    $query = [string]$toolInput["query"]
    $num = 5
    if ($toolInput.ContainsKey("num_results") -and $toolInput["num_results"]) {
        $num = [int]$toolInput["num_results"]
    }
    if ($num -lt 1)  { $num = 1 }
    if ($num -gt 10) { $num = 10 }

    $body = @{
        query      = $query
        numResults = $num
        contents   = @{ text = @{ maxCharacters = 800 } }
    }
    try {
        $raw = Invoke-CurlPost "https://api.exa.ai/search" @("x-api-key: $($Config.ExaApiKey)") (To-Json $body)
    } catch {
        return "ERROR contacting Exa: $($_.Exception.Message)"
    }
    $data = $null
    try { $data = From-Json $raw } catch { return "ERROR parsing Exa response: $raw" }
    if ($data.ContainsKey("error")) { return "Exa error: $($data["error"])" }

    $results = $data["results"]
    if (-not $results) { return "(no results for '$query')" }

    $sb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($r in $results) {
        $i++
        [void]$sb.Append("[$i] " + [string]$r["title"] + "`r`n")
        [void]$sb.Append([string]$r["url"] + "`r`n")
        $txt = [string]$r["text"]
        if ($txt) {
            if ($txt.Length -gt 800) { $txt = $txt.Substring(0, 800) + "..." }
            [void]$sb.Append($txt + "`r`n")
        }
        [void]$sb.Append("`r`n")
    }
    return $sb.ToString()
}

function Tool-Grep($toolInput) {
    $pattern = [string]$toolInput["pattern"]
    $path = [string]$toolInput["path"]
    if (-not $path) { $path = "." }
    $recurse = ($toolInput["recurse"] -eq $true)
    $ignoreCase = ($toolInput["ignore_case"] -ne $false)   # default true
    if (-not $pattern) { return "ERROR: pattern is required" }
    try {
        if (Test-Path $path -PathType Leaf) {
            $files = @($path)
        } else {
            $files = Get-ChildItem -Path $path -Recurse:$recurse -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.FullName }
        }
        if (-not $files -or $files.Count -eq 0) { return "(no files under $path)" }
        $res = Select-String -Path $files -Pattern $pattern -CaseSensitive:(-not $ignoreCase) -ErrorAction SilentlyContinue
        if (-not $res) { return "(no matches for '$pattern')" }
        $lines = $res | Select-Object -First 200 |
                 ForEach-Object { "$($_.Path):$($_.LineNumber): $(([string]$_.Line).Trim())" }
        $out = $lines -join "`r`n"
        if (@($res).Count -gt 200) { $out += "`r`n... ($(@($res).Count) matches total, showing first 200)" }
        return $out
    } catch {
        return "ERROR grep: $($_.Exception.Message)"
    }
}

function Tool-Find($toolInput) {
    $name = [string]$toolInput["name"]
    $path = [string]$toolInput["path"]
    if (-not $path) { $path = "." }
    $recurse = ($toolInput["recurse"] -ne $false)   # default true
    if (-not $name) { return "ERROR: name (filename pattern, e.g. *.ps1) is required" }
    try {
        $items = Get-ChildItem -Path $path -Filter $name -Recurse:$recurse -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.FullName }
        if (-not $items -or $items.Count -eq 0) { return "(no files matching '$name' under $path)" }
        $shown = $items | Select-Object -First 200
        $out = $shown -join "`r`n"
        if (@($items).Count -gt 200) { $out += "`r`n... ($(@($items).Count) total, showing first 200)" }
        return $out
    } catch {
        return "ERROR find: $($_.Exception.Message)"
    }
}

function Tool-EditFile($toolInput) {
    $path = [string]$toolInput["path"]
    $old  = [string]$toolInput["old_text"]
    $new  = [string]$toolInput["new_text"]
    $all  = ($toolInput["replace_all"] -eq $true)
    if (-not (Test-Path $path)) { return "ERROR: file not found: $path" }
    if ($old.Length -eq 0) { return "ERROR: old_text is empty" }
    try {
        $content = [IO.File]::ReadAllText($path)
        # count occurrences
        $count = 0; $pos = 0
        while (($pos = $content.IndexOf($old, $pos)) -ge 0) { $count++; $pos += $old.Length }
        if ($count -eq 0) { return "ERROR: old_text not found in $path" }
        if ($count -gt 1 -and -not $all) {
            return "ERROR: old_text appears $count times in $path. Add more context to make it unique, or set replace_all=true."
        }
        Show-Diff $old $new
        if (-not (Confirm-Action "EDIT $path ($count replacement(s))")) { return "(denied by user)" }
        if ($all) {
            $content = $content.Replace($old, $new)
        } else {
            $i = $content.IndexOf($old)
            $content = $content.Substring(0, $i) + $new + $content.Substring($i + $old.Length)
        }
        Backup-File $path
        [IO.File]::WriteAllText($path, $content, $Utf8)
        return "edited $path ($count replacement(s))"
    } catch {
        return "ERROR editing $path : $($_.Exception.Message)"
    }
}

# Change the working directory for ALL tools (PS location + .NET cwd together).
function Set-Cwd($path) {
    $resolved = $path
    if (-not [IO.Path]::IsPathRooted($path)) { $resolved = Join-Path (Get-Location).Path $path }
    if (-not (Test-Path $resolved -PathType Container)) { throw "not a directory: $resolved" }
    $full = (Resolve-Path $resolved).Path
    Set-Location $full
    [Environment]::CurrentDirectory = $full
    return $full
}

function Tool-SetCwd($toolInput) {
    $path = [string]$toolInput["path"]
    if (-not $path) { return "ERROR: path required" }
    try { return "cwd is now " + (Set-Cwd $path) }
    catch { return "ERROR: $($_.Exception.Message)" }
}

function Tool-MakeDir($toolInput) {
    $path = [string]$toolInput["path"]
    if (-not $path) { return "ERROR: path required" }
    if (Test-Path $path) { return "$path already exists" }
    if (-not (Confirm-Action "MKDIR $path")) { return "(denied by user)" }
    try {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        return "created $path"
    } catch { return "ERROR mkdir $path : $($_.Exception.Message)" }
}

# Run a prebuilt command line (caller handles inner quoting) via cmd, sending
# all output to a file, with an optional timeout-kill. /s + outer quotes give
# robust parsing when the inner command contains quoted paths with spaces.
function Run-CmdToFile($cmdLine, $outFile, $timeoutSec) {
    if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = '/s /c "' + $cmdLine + ' > "' + $outFile + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path
    $p = [System.Diagnostics.Process]::Start($psi)
    $finished = $true
    if ($timeoutSec -and $timeoutSec -gt 0) { $finished = $p.WaitForExit($timeoutSec * 1000) }
    else { $p.WaitForExit() }
    $out = ""
    if (Test-Path $outFile) { $out = [IO.File]::ReadAllText($outFile, [System.Console]::OutputEncoding) }
    $exit = $null
    if ($finished) { $exit = $p.ExitCode } else { try { $p.Kill() } catch {} }
    return @{ finished = $finished; exit = $exit; out = $out }
}

function Tool-CompileRun($toolInput) {
    $tcc = Resolve-Rel $Config.TccPath
    if (-not (Test-Path $tcc)) { return "ERROR: TCC not found at $tcc (set TccPath in config.ps1)" }
    $code = [string]$toolInput["code"]
    if (-not $code) { return "ERROR: code is required" }
    $progArgs = [string]$toolInput["args"]
    if (-not (Confirm-Action "COMPILE & RUN C ($($code.Length) chars)")) { return "(denied by user)" }

    $tccDir = Split-Path -Parent $tcc
    $src = Join-Path $env:TEMP "xph_build.c"
    $exe = Join-Path $env:TEMP "xph_build.exe"
    [IO.File]::WriteAllText($src, $code, $Utf8)
    if (Test-Path $exe) { Remove-Item $exe -Force -ErrorAction SilentlyContinue }

    $ccCmd = '"' + $tcc + '" -B"' + $tccDir + '" "' + $src + '" -o "' + $exe + '"'
    $cc = Run-CmdToFile $ccCmd (Join-Path $env:TEMP "xph_cc.out") 0
    if (-not (Test-Path $exe)) { return "COMPILE ERROR:`r`n" + $cc["out"] }

    $timeoutSec = 30; if ($Config.CommandTimeoutSec) { $timeoutSec = [int]$Config.CommandTimeoutSec }
    $runCmd = '"' + $exe + '"'
    if ($progArgs) { $runCmd += ' ' + $progArgs }
    $r = Run-CmdToFile $runCmd (Join-Path $env:TEMP "xph_run.out") $timeoutSec

    $head = "compiled OK."
    if ($cc["out"]) { $head += " compiler notes: " + ([string]$cc["out"]).Trim() }
    if (-not $r["finished"]) { return "$head`r`nRUN timed out after ${timeoutSec}s and was killed.`r`n" + $r["out"] }
    $body = [string]$r["out"]; if (-not $body) { $body = "(no output)" }
    return "$head`r`nexit $($r['exit'])`r`n$body"
}

function Tool-DetectToolchains($toolInput) {
    $cands = @(
        @{ name = "tcc (bundled)"; cmd = ('"' + (Resolve-Rel $Config.TccPath) + '" -v') },
        @{ name = "gcc";          cmd = "gcc --version" },
        @{ name = "g++";          cmd = "g++ --version" },
        @{ name = "cl (MSVC)";    cmd = "cl" },
        @{ name = "python";       cmd = "python --version" },
        @{ name = "perl";         cmd = "perl --version" },
        @{ name = "lua";          cmd = "lua -v" },
        @{ name = "node";         cmd = "node --version" }
    )
    $lines = New-Object System.Collections.ArrayList
    foreach ($c in $cands) {
        $r = Run-CmdToFile $c["cmd"] (Join-Path $env:TEMP "xph_probe.out") 10
        $o = ([string]$r["out"]).Trim()
        $first = $o
        $nl = $o.IndexOf("`n"); if ($nl -ge 0) { $first = $o.Substring(0, $nl).Trim() }
        if ($o -and ($o -notmatch "is not recognized|cannot find|No such file")) {
            [void]$lines.Add("FOUND  $($c['name']): $first")
        } else {
            [void]$lines.Add("absent $($c['name'])")
        }
    }
    return ($lines -join "`r`n")
}

# tool name -> function dispatch
function Invoke-Tool($name, $toolInput) {
    switch ($name) {
        "run_command" { return Tool-RunCommand $toolInput }
        "compile_run"      { return Tool-CompileRun      $toolInput }
        "detect_toolchains" { return Tool-DetectToolchains $toolInput }
        "banner"          { return Tool-Banner          $toolInput }
        "image_to_ascii"  { return Tool-ImageToAscii     $toolInput }
        "read_file"   { return Tool-ReadFile  $toolInput }
        "write_file"  { return Tool-WriteFile $toolInput }
        "edit_file"   { return Tool-EditFile  $toolInput }
        "undo_file"   { return Tool-UndoFile  $toolInput }
        "list_dir"    { return Tool-ListDir   $toolInput }
        "grep"        { return Tool-Grep      $toolInput }
        "find"        { return Tool-Find      $toolInput }
        "set_cwd"     { return Tool-SetCwd    $toolInput }
        "make_dir"    { return Tool-MakeDir   $toolInput }
        "web_search"  { return Tool-WebSearch $toolInput }
        default       { return "ERROR: unknown tool '$name'" }
    }
}

# --- tool schemas advertised to the model ------------------------------
$Tools = @(
    @{ name = "run_command"
       description = "Run a Windows command via cmd.exe and return its combined stdout/stderr."
       input_schema = @{ type = "object"
           properties = @{ command = @{ type = "string"; description = "The command line to execute" } }
           required = @("command") } },
    @{ name = "read_file"
       description = "Read a text file. By default returns the whole file. For large files pass offset (1-based start line) and limit (line count) to read a window, and line_numbers=true to prefix line numbers (display only - do not include them in edit_file old_text)."
       input_schema = @{ type = "object"
           properties = @{
               path         = @{ type = "string" }
               offset       = @{ type = "integer"; description = "1-based first line to read" }
               limit        = @{ type = "integer"; description = "number of lines to read" }
               line_numbers = @{ type = "boolean"; description = "prefix line numbers (default false)" } }
           required = @("path") } },
    @{ name = "write_file"
       description = "Create or overwrite a text file (UTF-8). For small changes to an existing file, prefer edit_file."
       input_schema = @{ type = "object"
           properties = @{ path = @{ type = "string" }; content = @{ type = "string" } }
           required = @("path","content") } },
    @{ name = "edit_file"
       description = "Make a surgical edit by replacing an exact text snippet. old_text must match the file exactly. Fails if old_text is not unique unless replace_all is true."
       input_schema = @{ type = "object"
           properties = @{
               path        = @{ type = "string" }
               old_text    = @{ type = "string"; description = "Exact existing text to replace" }
               new_text    = @{ type = "string"; description = "Replacement text" }
               replace_all = @{ type = "boolean"; description = "Replace every occurrence (default false)" } }
           required = @("path","old_text","new_text") } },
    @{ name = "undo_file"
       description = "Restore a file from the .bak copy made before the last write_file/edit_file."
       input_schema = @{ type = "object"
           properties = @{ path = @{ type = "string" } }
           required = @("path") } },
    @{ name = "grep"
       description = "Search file contents for a regex/text pattern. Returns path:line: text. Use recurse=true to search a directory tree."
       input_schema = @{ type = "object"
           properties = @{
               pattern     = @{ type = "string" }
               path        = @{ type = "string"; description = "File or directory (default current dir)" }
               recurse     = @{ type = "boolean"; description = "Recurse into subdirectories (default false)" }
               ignore_case = @{ type = "boolean"; description = "Case-insensitive (default true)" } }
           required = @("pattern") } },
    @{ name = "find"
       description = "Find files by name pattern (e.g. *.ps1). Returns full paths."
       input_schema = @{ type = "object"
           properties = @{
               name    = @{ type = "string"; description = "Filename wildcard, e.g. *.txt" }
               path    = @{ type = "string"; description = "Root directory (default current dir)" }
               recurse = @{ type = "boolean"; description = "Recurse into subdirectories (default true)" } }
           required = @("name") } },
    @{ name = "list_dir"
       description = "List files and folders in a directory."
       input_schema = @{ type = "object"
           properties = @{ path = @{ type = "string"; description = "Directory path (default current dir)" } }
           required = @() } },
    @{ name = "set_cwd"
       description = "Change the current working directory for all subsequent tools (run_command, file tools, list_dir, grep, find). Persists across calls. Use this to work inside a project folder instead of prefixing every path."
       input_schema = @{ type = "object"
           properties = @{ path = @{ type = "string"; description = "Absolute or relative directory to switch to" } }
           required = @("path") } },
    @{ name = "make_dir"
       description = "Create a directory (including any missing parent directories)."
       input_schema = @{ type = "object"
           properties = @{ path = @{ type = "string" } }
           required = @("path") } },
    @{ name = "web_search"
       description = "Search the web via Exa and return titles, URLs, and text snippets. Use this for current information, documentation, library/API references, error messages, or anything not available locally on this XP machine."
       input_schema = @{ type = "object"
           properties = @{
               query       = @{ type = "string"; description = "The search query" }
               num_results = @{ type = "integer"; description = "How many results (1-10, default 5)" } }
           required = @("query") } },
    @{ name = "compile_run"
       description = "Compile and run a C program natively on this Windows XP box using the bundled Tiny C Compiler. Returns compiler errors if the build fails, otherwise the program's combined stdout/stderr (subject to the command timeout). Use this to actually test C code you write."
       input_schema = @{ type = "object"
           properties = @{
               code = @{ type = "string"; description = "Full C source code" }
               args = @{ type = "string"; description = "Optional command-line arguments for the program" } }
           required = @("code") } },
    @{ name = "detect_toolchains"
       description = "Report which compilers and interpreters are available on this machine (the bundled TCC, plus any installed gcc, g++, MSVC cl, python, perl, lua, node). Use this before assuming a toolchain exists."
       input_schema = @{ type = "object"; properties = @{}; required = @() } },
    @{ name = "banner"
       description = "Render short text as big ASCII-art letters (retro banner) and display it on the console. Good for headers/titles."
       input_schema = @{ type = "object"
           properties = @{ text = @{ type = "string"; description = "Short text (letters, digits, basic punctuation)" } }
           required = @("text") } },
    @{ name = "image_to_ascii"
       description = "Convert an image file (BMP/JPG/PNG/GIF) on this machine to ASCII art and display it on the console. Fully offline."
       input_schema = @{ type = "object"
           properties = @{
               path   = @{ type = "string"; description = "Path to the image file" }
               width  = @{ type = "integer"; description = "Output width in characters (8-200, default 80)" }
               invert = @{ type = "boolean"; description = "Invert brightness (for light-on-dark vs dark-on-light)" } }
           required = @("path") } }
)

$SystemPrompt = @"
You are a coding assistant running on a Windows XP machine through a PowerShell 2 harness.
The shell is cmd.exe / PowerShell 2 on Windows XP - assume old tooling: no modern unix
utilities, short path conventions, and limited memory. Prefer built-in Windows commands.
Use the provided tools to inspect and modify files and run commands. Use set_cwd to move
into a project folder (it persists for all later tools, so you don't have to prefix every
path), and make_dir to create folders. run_command runs in the current working directory.
For editing, prefer grep/find to locate code and edit_file for surgical changes (write_file
only for new or fully-rewritten files). You also have a web_search tool (Exa) - use it to look up current
docs, APIs, library usage, or error messages, since your training data may be stale and
this machine is old. You can compile and run C natively with compile_run (bundled Tiny C
Compiler), and detect_toolchains tells you what other compilers/interpreters are installed.
For retro flair you have banner (big ASCII-art text) and image_to_ascii (render an image
file as ASCII). Be concise. Do not use emoji - the Windows XP console cannot display them
(they show as '?'); use plain ASCII text instead. When you output code or ASCII art in your
own replies, wrap it in triple-backtick fences so it renders verbatim.
"@

# =====================================================================
#  HTTP  -  POST JSON through curl over TLS 1.2 (shared by all APIs)
# =====================================================================
#  Body goes to a temp file (--data-binary @file) and the response to a
#  temp file (-o), read back as UTF-8. Capturing curl's stdout through a
#  pipe would decode it with the console's OEM codepage and corrupt every
#  non-ASCII byte before we ever parse it. $headers is an array of full
#  "Name: value" strings; content-type is added automatically.
function Invoke-CurlPost($url, $headers, $bodyJson) {
    $bodyPath = Join-Path $env:TEMP "xph_req.json"
    $respPath = Join-Path $env:TEMP "xph_resp.json"
    [IO.File]::WriteAllText($bodyPath, $bodyJson, $Utf8)
    if (Test-Path $respPath) { Remove-Item $respPath -Force -ErrorAction SilentlyContinue }

    $curlArgs = @("-s", "-S", "--cacert", $CaCert, "--tlsv1.2", "-o", $respPath, "-X", "POST")
    foreach ($h in $headers) { $curlArgs += "-H"; $curlArgs += $h }
    $curlArgs += @("-H", "content-type: application/json", "--data-binary", "@$bodyPath", $url)

    & $CurlExe $curlArgs
    if (-not (Test-Path $respPath)) { throw "no response file (network/TLS failure?)" }
    $raw = [IO.File]::ReadAllText($respPath, [System.Text.Encoding]::UTF8)
    if (-not $raw) { throw "empty response from curl (network/TLS failure?)" }
    return $raw
}

function Send-ToClaude($messages) {
    $req = @{
        model      = $Config.Model
        max_tokens = $Config.MaxTokens
        system     = $SystemPrompt
        tools      = $Tools
        messages   = $messages
    }
    $headers = @(
        "x-api-key: $($Config.ApiKey)",
        "anthropic-version: $($Config.Version)"
    )
    $raw = Invoke-CurlPost $Config.BaseUrl $headers (To-Json $req)
    try { return (From-Json $raw) }
    catch { throw "could not parse response: $raw" }
}

# ProcessStartInfo.Arguments is a single string, so quote args with spaces
# (TEMP paths contain "Documents and Settings", headers contain spaces).
function Quote-Arg($a) {
    $s = [string]$a
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}

# Streaming variant. Reads curl's raw stdout as UTF-8 ourselves (XP can't
# set a UTF-8 console codepage reliably), parses the SSE events, prints text
# live, and reconstructs the same {content, stop_reason, usage} shape that
# Send-ToClaude returns so Run-Turn can treat both identically.
function Send-ToClaudeStream($messages) {
    $req = @{
        model      = $Config.Model
        max_tokens = $Config.MaxTokens
        system     = $SystemPrompt
        tools      = $Tools
        messages   = $messages
        stream     = $true
    }
    $bodyPath = Join-Path $env:TEMP "xph_req.json"
    [IO.File]::WriteAllText($bodyPath, (To-Json $req), $Utf8)

    $argArray = @(
        "-s", "-S", "-N", "--cacert", $CaCert, "--tlsv1.2", "-X", "POST",
        "-H", "x-api-key: $($Config.ApiKey)",
        "-H", "anthropic-version: $($Config.Version)",
        "-H", "content-type: application/json",
        "--data-binary", "@$bodyPath", $Config.BaseUrl
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CurlExe
    $psi.Arguments = (($argArray | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $reader = New-Object System.IO.StreamReader($p.StandardOutput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))

    $blocks  = @{}     # index -> block hashtable
    $jsonBuf = @{}     # index -> accumulated tool_use input json
    $order   = New-Object System.Collections.ArrayList
    $stopReason = $null
    $inTok = 0; $outTok = 0
    $lineBuf = ""
    $errObj = $null
    $printed = $false
    $rawAll = ""

    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        $rawAll += ($line + "`n")
        if (-not $line.StartsWith("data:")) { continue }
        $payload = $line.Substring(5).Trim()
        if (-not $payload -or $payload -eq "[DONE]") { continue }
        $evt = $null
        try { $evt = From-Json $payload } catch { continue }
        $etype = [string]$evt["type"]

        if ($etype -eq "message_start") {
            $u = $evt["message"]["usage"]
            if ($u -and $u.ContainsKey("input_tokens")) { $inTok = [int]$u["input_tokens"] }
        }
        elseif ($etype -eq "content_block_start") {
            $i = [int]$evt["index"]
            $cb = $evt["content_block"]
            if ([string]$cb["type"] -eq "text") {
                $blocks[$i] = @{ type = "text"; text = "" }
            } else {
                $blocks[$i] = @{ type = "tool_use"; id = [string]$cb["id"]; name = [string]$cb["name"]; input = @{} }
                $jsonBuf[$i] = ""
            }
            [void]$order.Add($i)
        }
        elseif ($etype -eq "content_block_delta") {
            $i = [int]$evt["index"]
            $d = $evt["delta"]
            $dtype = [string]$d["type"]
            if ($dtype -eq "text_delta") {
                $txt = [string]$d["text"]
                $blocks[$i]["text"] = [string]$blocks[$i]["text"] + $txt
                if (-not $printed) { Write-Host ""; $printed = $true }
                if ($Config.RenderMarkdown -eq $false) {
                    Write-Host (Format-ForConsole $txt) -NoNewline -ForegroundColor Cyan
                } else {
                    $lineBuf += $txt
                    while ($lineBuf.Contains("`n")) {
                        $nl = $lineBuf.IndexOf("`n")
                        Render-Line $lineBuf.Substring(0, $nl)
                        $lineBuf = $lineBuf.Substring($nl + 1)
                    }
                }
            }
            elseif ($dtype -eq "input_json_delta") {
                $jsonBuf[$i] = [string]$jsonBuf[$i] + [string]$d["partial_json"]
            }
        }
        elseif ($etype -eq "content_block_stop") {
            $i = [int]$evt["index"]
            if ($blocks[$i]["type"] -eq "tool_use") {
                $pj = [string]$jsonBuf[$i]
                if ($pj) { try { $blocks[$i]["input"] = From-Json $pj } catch {} }
            }
        }
        elseif ($etype -eq "message_delta") {
            $d = $evt["delta"]
            if ($d -and $d.ContainsKey("stop_reason")) { $stopReason = [string]$d["stop_reason"] }
            $u = $evt["usage"]
            if ($u -and $u.ContainsKey("output_tokens")) { $outTok = [int]$u["output_tokens"] }
        }
        elseif ($etype -eq "error") {
            $errObj = $evt["error"]
        }
    }
    $p.WaitForExit()

    # flush any trailing partial line / close the printed line
    if ($Config.RenderMarkdown -eq $false) {
        if ($printed) { Write-Host "" }
    } elseif ($lineBuf.Length -gt 0) {
        Render-Line $lineBuf
    }

    if ($errObj) { return @{ error = $errObj } }

    # No SSE events at all usually means an HTTP error body (e.g. 401) which
    # curl printed as plain JSON. Try to surface it instead of a blank turn.
    if ($order.Count -eq 0) {
        try {
            $j = From-Json $rawAll
            if ($j -and $j.ContainsKey("error")) { return @{ error = $j["error"] } }
        } catch {}
        return @{ error = @{ type = "empty"; message = "no response from curl: $rawAll" } }
    }

    $content = New-Object System.Collections.ArrayList
    foreach ($i in $order) { [void]$content.Add($blocks[$i]) }
    return @{ content = $content.ToArray(); stop_reason = $stopReason; usage = @{ input_tokens = $inTok; output_tokens = $outTok } }
}

# Local TinyStories model (llama2.c run.exe). Not a chat/instruct model and
# can't tool-call: we just feed the last user message as a prompt and stream
# the continuation. Returns the same shape as the API path with no tools.
function Send-ToLocal($messages) {
    $spec = $LocalModels[$Config.Model]
    if (-not $spec) { return @{ error = @{ type = "local"; message = "no local model spec for '$($Config.Model)'" } } }
    $exe = Resolve-Rel $spec["exe"]
    $bin = Resolve-Rel $spec["bin"]
    $tok = Resolve-Rel $spec["tok"]
    if (-not (Test-Path $exe)) { return @{ error = @{ type = "local"; message = "local exe not found: $exe" } } }
    if (-not (Test-Path $bin)) { return @{ error = @{ type = "local"; message = "local weights not found: $bin" } } }

    # prompt = most recent plain-string user message
    $prompt = ""
    for ($k = $messages.Count - 1; $k -ge 0; $k--) {
        $c = $messages[$k]["content"]
        if (([string]$messages[$k]["role"] -eq "user") -and ($c -is [string])) { $prompt = $c; break }
    }
    # wrap in the model's chat template if it has one
    $tmpl = [string]$spec["template"]
    if ($tmpl) { $prompt = $tmpl.Replace("{prompt}", $prompt) }

    $steps = 256; if ($spec["steps"]) { $steps = [int]$spec["steps"] }
    $temp  = 0.9; if ($spec["temp"]) { $temp = [double]$spec["temp"] }
    $tempStr = ([double]$temp).ToString([Globalization.CultureInfo]::InvariantCulture)

    $argArray = @($bin, "-z", $tok, "-t", $tempStr, "-n", ([string]$steps), "-i", $prompt)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argArray | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true

    # llama2.c echoes the prompt as it ingests it and only stops on BOS. For a
    # chat model that means it prints the template (<|user|>..<|assistant|>) and,
    # after answering, keeps going into a hallucinated next turn. So for templated
    # models we (1) suppress output until the 'start' marker, and (2) stop at the
    # first 'stop' marker (e.g. </s>), killing the process early.
    $start = [string]$spec["start"]          # "" = print from the beginning
    $stops = $spec["stops"]                   # array of strings, or $null
    $maxStop = 0
    if ($stops) { foreach ($s in $stops) { if ($s.Length -gt $maxStop) { $maxStop = $s.Length } } }

    $p = [System.Diagnostics.Process]::Start($psi)
    $script:LocalProc = $p          # tracked so Ctrl-C / exit can kill it
    $reader = New-Object System.IO.StreamReader($p.StandardOutput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ""

    $full = New-Object System.Text.StringBuilder   # everything (used to find start)
    $ans  = New-Object System.Text.StringBuilder   # text after the start marker
    $started = ($start -eq "")
    $printed = 0
    $stopped = $false

    while ($true) {
        # let Ctrl-C cancel a slow generation (and kill the child) mid-stream
        if ($UseRawInput) {
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control)) {
                        try { $p.Kill() } catch {}
                        Write-Host "`n(cancelled)" -ForegroundColor DarkGray
                        $stopped = $true; break
                    }
                }
            } catch {}
        }
        $ci = $reader.Read()
        if ($ci -lt 0) { break }
        $c = [char]$ci
        if (-not $started) {
            [void]$full.Append($c)
            $fs = $full.ToString()
            $si = $fs.IndexOf($start)
            if ($si -ge 0) {
                $started = $true
                [void]$ans.Append($fs.Substring($si + $start.Length).TrimStart("`r", "`n"))
            }
            continue
        }
        [void]$ans.Append($c)
        $a = $ans.ToString()
        if ($stops) {
            $cut = -1
            foreach ($s in $stops) { $idx = $a.IndexOf($s); if ($idx -ge 0 -and ($cut -lt 0 -or $idx -lt $cut)) { $cut = $idx } }
            if ($cut -ge 0) {
                if ($cut -gt $printed) { Write-Host (Format-ForConsole $a.Substring($printed, $cut - $printed)) -NoNewline -ForegroundColor Cyan }
                $ans = New-Object System.Text.StringBuilder
                [void]$ans.Append($a.Substring(0, $cut))
                $stopped = $true
                try { $p.Kill() } catch {}
                break
            }
        }
        # print up to (len - maxStop) so a partial stop marker is never shown
        $safe = $a.Length - $maxStop
        if ($safe -gt $printed) {
            Write-Host (Format-ForConsole $a.Substring($printed, $safe - $printed)) -NoNewline -ForegroundColor Cyan
            $printed = $safe
        }
    }
    if (-not $stopped) {
        $p.WaitForExit()
        if (-not $started) { [void]$ans.Append($full.ToString()) }   # marker never appeared - show raw
        $a = $ans.ToString()
        if ($a.Length -gt $printed) { Write-Host (Format-ForConsole $a.Substring($printed)) -NoNewline -ForegroundColor Cyan }
    }
    $script:LocalProc = $null
    Write-Host ""
    return @{ content = @(@{ type = "text"; text = $ans.ToString().Trim() }); stop_reason = "end_turn" }
}

# =====================================================================
#  TOKEN / COST ACCOUNTING
# =====================================================================
$script:TokIn  = 0
$script:TokOut = 0

function Show-Usage($resp) {
    if (-not $resp.ContainsKey("usage")) { return }
    $u = $resp["usage"]
    $inT  = [int]$u["input_tokens"]
    $outT = [int]$u["output_tokens"]
    $script:TokIn  += $inT
    $script:TokOut += $outT

    $line = "  [tokens] call: in $inT out $outT  |  session: in $($script:TokIn) out $($script:TokOut)"

    # optional cost: only if prices (per million tokens) are set in config
    if ($Config.PriceInPerMTok -and $Config.PriceOutPerMTok) {
        $cost = ($script:TokIn  / 1000000.0) * [double]$Config.PriceInPerMTok +
                ($script:TokOut / 1000000.0) * [double]$Config.PriceOutPerMTok
        $line += ("  |  ~`$" + $cost.ToString("F4"))
    }
    Write-Host $line -ForegroundColor DarkGray
}

# =====================================================================
#  AGENT LOOP
# =====================================================================
function Run-Turn($messages) {
    while ($true) {
        if ($LocalModels.ContainsKey($Config.Model)) { $resp = Send-ToLocal $messages }
        elseif ($Config.Stream -eq $false) { $resp = Send-ToClaude $messages }
        else { $resp = Send-ToClaudeStream $messages }

        if ($resp.ContainsKey("error")) {
            $e = $resp["error"]
            Write-Host "API error: $($e["type"]) - $($e["message"])" -ForegroundColor Red
            return
        }

        Show-Usage $resp

        $content    = $resp["content"]      # object[] of blocks
        $stop       = [string]$resp["stop_reason"]
        $toolBlocks = New-Object System.Collections.ArrayList

        foreach ($block in $content) {
            $t = [string]$block["type"]
            if ($t -eq "text") {
                # when streaming (or local), the text was already printed live
                if ($Config.Stream -eq $false -and -not $LocalModels.ContainsKey($Config.Model)) { Print-Answer $block["text"] }
            } elseif ($t -eq "tool_use") {
                [void]$toolBlocks.Add($block)
            }
        }

        # record the assistant's turn verbatim (text + tool_use blocks)
        [void]$messages.Add(@{ role = "assistant"; content = $content })

        if ($stop -ne "tool_use") { return }   # final answer; back to prompt

        # execute every requested tool, gather results into one user message
        $results = New-Object System.Collections.ArrayList
        foreach ($tb in $toolBlocks) {
            $name = [string]$tb["name"]
            Write-Host "  -> $name" -ForegroundColor DarkGray
            $out = Invoke-Tool $name $tb["input"]
            [void]$results.Add(@{
                type        = "tool_result"
                tool_use_id = [string]$tb["id"]
                content     = [string]$out
            })
        }
        [void]$messages.Add(@{ role = "user"; content = $results.ToArray() })
        # loop again so the model can react to the tool results
    }
}

# =====================================================================
#  SLASH COMMANDS
# =====================================================================
# API model shortcuts -> real model IDs. These defaults can be overridden or
# extended by a $Config.Models hashtable in config.ps1 (pin a dated version,
# remap a class, add a new shortcut) without touching the harness.
$Models = @{
    sonnet = "claude-sonnet-4-6"
    haiku  = "claude-haiku-4-5-20251001"
    opus   = "claude-opus-4-8"
}
if ($Config.Models -is [System.Collections.IDictionary]) {
    foreach ($k in $Config.Models.Keys) { $Models["$k"] = [string]$Config.Models[$k] }
}
# offline model shortcuts (resolved via $LocalModels below)
$Models["local"]      = "local"      # TinyStories 15M  (fast toy)
$Models["local-110m"] = "local-110m" # TinyStories 110M (better toy)
$Models["local-tl"]   = "local-tl"   # TinyLlama 1.1B Chat int8 (smart, slow)

# the default model in config may be a shortcut (sonnet/opus/local-tl/...) or a literal ID
if ($Models.ContainsKey([string]$Config.Model)) { $Config.Model = $Models[[string]$Config.Model] }

# Offline models run via llama2.c (no tools). Paths resolve against the script
# dir. 'template' wraps the user prompt ({prompt} placeholder) for chat-tuned
# models; leave "" for raw continuation (TinyStories).
$LocalModels = @{
    "local"      = @{ exe = "llm\run.exe";  bin = "llm\stories15M.bin";   tok = "llm\tokenizer.bin"; steps = 256; temp = 0.9; template = "" }
    "local-110m" = @{ exe = "llm\run.exe";  bin = "llm\stories110M.bin";  tok = "llm\tokenizer.bin"; steps = 256; temp = 0.9; template = "" }
    "local-tl"   = @{ exe = "llm\runq.exe"; bin = "llm\tinyllama-q8.bin"; tok = "llm\tokenizer.bin"; steps = 512; temp = 0.7; template = "<|user|>`n{prompt}</s>`n<|assistant|>`n"; start = "<|assistant|>"; stops = @("</s>", "<|user|>") }
}

function Show-Totals {
    $line = "session tokens: in $($script:TokIn) out $($script:TokOut)"
    if ($Config.PriceInPerMTok -and $Config.PriceOutPerMTok) {
        $cost = ($script:TokIn  / 1000000.0) * [double]$Config.PriceInPerMTok +
                ($script:TokOut / 1000000.0) * [double]$Config.PriceOutPerMTok
        $line += ("  ~`$" + $cost.ToString("F4"))
    }
    Write-Host $line -ForegroundColor DarkGray
}

function Save-Transcript($messages, $path) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $messages) {
        $role = ([string]$m["role"]).ToUpper()
        $c = $m["content"]
        if ($c -is [string]) {
            [void]$sb.Append("$role`: $c`r`n`r`n")
        } else {
            foreach ($block in $c) {
                if (-not ($block -is [System.Collections.IDictionary])) { continue }
                $bt = [string]$block["type"]
                if ($bt -eq "text") {
                    [void]$sb.Append("$role`: $([string]$block['text'])`r`n`r`n")
                } elseif ($bt -eq "tool_use") {
                    [void]$sb.Append("[tool_use $([string]$block['name'])] $(To-Json $block['input'])`r`n`r`n")
                } elseif ($bt -eq "tool_result") {
                    [void]$sb.Append("[tool_result] $([string]$block['content'])`r`n`r`n")
                }
            }
        }
    }
    [IO.File]::WriteAllText($path, $sb.ToString(), $Utf8)
}

# Resumable session: the raw message array as JSON (reloadable by /load).
function Save-Session($messages, $path) {
    [IO.File]::WriteAllText($path, (To-Json $messages), $Utf8)
}
function Load-Session($messages, $path) {
    $data = From-Json ([IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))
    $messages.Clear()
    foreach ($m in $data) { [void]$messages.Add($m) }
    return @($data).Count
}

# Handle a /command line. Returns nothing; mutates $messages / $Config in place.
function Handle-Command($line, $messages) {
    $body = $line.Substring(1)
    $sp = $body.IndexOf(' ')
    if ($sp -ge 0) {
        $cmd = $body.Substring(0, $sp).ToLower()
        $arg = $body.Substring($sp + 1).Trim()
    } else {
        $cmd = $body.ToLower()
        $arg = ""
    }

    switch ($cmd) {
        "help" {
            Write-Host "commands:" -ForegroundColor Green
            Write-Host "  /help            show this"
            Write-Host "  /paste           submit your clipboard contents as the prompt"
            Write-Host "  /multi           enter multi-line input (end with a line of just '.')"
            Write-Host "  /models [name]   list models or switch (sonnet|haiku|opus)"
            Write-Host "  /cwd             show current working directory"
            Write-Host "  /cd <path>       change working directory"
            Write-Host "  /tokens          session token + cost totals"
            Write-Host "  /tools           list available tools"
            Write-Host "  /reset           clear the conversation"
            Write-Host "  /save [file]     save resumable session (default xph_session.json)"
            Write-Host "  /load [file]     restore a saved session (default xph_session.json)"
            Write-Host "  /export [file]   save readable transcript (default xph_transcript.txt)"
            Write-Host "  exit | quit      leave"
        }
        "models" {
            if (-not $arg) {
                Write-Host "current model: $($Config.Model)" -ForegroundColor Green
                Write-Host "switch with /models <name>:"
                foreach ($k in $Models.Keys) { Write-Host ("  {0,-7} {1}" -f $k, $Models[$k]) }
            } elseif ($Models.ContainsKey($arg.ToLower())) {
                $Config.Model = $Models[$arg.ToLower()]
                Write-Host "model -> $($Config.Model)" -ForegroundColor Green
            } else {
                Write-Host "unknown model '$arg'. choices: $($Models.Keys -join ', ')" -ForegroundColor Red
            }
        }
        "model"  { Handle-Command ("/models " + $arg) $messages }
        "cwd"    { Write-Host (Get-Location).Path -ForegroundColor Green }
        "cd"     {
            if (-not $arg) { Write-Host "usage: /cd <path>" -ForegroundColor Red }
            else {
                try { Write-Host ("cwd is now " + (Set-Cwd $arg)) -ForegroundColor Green }
                catch { Write-Host "cd failed: $($_.Exception.Message)" -ForegroundColor Red }
            }
        }
        "tokens" { Show-Totals }
        "tools"  {
            Write-Host "tools:" -ForegroundColor Green
            foreach ($t in $Tools) { Write-Host ("  {0,-12} {1}" -f $t["name"], $t["description"]) }
        }
        "reset"  {
            $messages.Clear()
            Write-Host "conversation cleared." -ForegroundColor Green
        }
        "save"   {
            $path = $arg
            if (-not $path) { $path = "xph_session.json" }
            try { Save-Session $messages $path; Write-Host "session saved to $path" -ForegroundColor Green }
            catch { Write-Host "save failed: $($_.Exception.Message)" -ForegroundColor Red }
        }
        "load"   {
            $path = $arg
            if (-not $path) { $path = "xph_session.json" }
            if (-not (Test-Path $path)) { Write-Host "no such file: $path" -ForegroundColor Red }
            else {
                try { $n = Load-Session $messages $path; Write-Host "loaded $n messages from $path" -ForegroundColor Green }
                catch { Write-Host "load failed: $($_.Exception.Message)" -ForegroundColor Red }
            }
        }
        "export" {
            $path = $arg
            if (-not $path) { $path = "xph_transcript.txt" }
            try { Save-Transcript $messages $path; Write-Host "transcript exported to $path" -ForegroundColor Green }
            catch { Write-Host "export failed: $($_.Exception.Message)" -ForegroundColor Red }
        }
        default  { Write-Host "unknown command: /$cmd (try /help)" -ForegroundColor Red }
    }
}

# Read clipboard text. The PS2 console host is MTA, but Clipboard.GetText()
# needs STA, so we fetch it inside a short-lived STA runspace.
function Get-ClipboardText {
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = "STA"
        $rs.ThreadOptions  = "ReuseThread"
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript('[void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms"); [System.Windows.Forms.Clipboard]::GetText()')
        $res = $ps.Invoke()
        $ps.Dispose(); $rs.Close()
        if ($res -and $res.Count -gt 0) { return [string]$res[0] }
        return ""
    } catch { return "" }
}

# Line reader that surfaces Ctrl-C (returns "__CTRLC__") instead of killing the
# script. Needs [Console]::TreatControlCAsInput = $true. Handles typing,
# Backspace, and Enter; ignores arrows/function keys.
function Read-Prompt {
    $buf = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
            return "__CTRLC__"
        }
        if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ""; break }
        elseif ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buf.Length -gt 0) { [void]$buf.Remove($buf.Length - 1, 1); Write-Host "`b `b" -NoNewline }
        }
        elseif ($key.KeyChar -and ([int][char]$key.KeyChar) -ge 32) {
            [void]$buf.Append($key.KeyChar)
            Write-Host ([string]$key.KeyChar) -NoNewline
        }
    }
    return $buf.ToString()
}

# =====================================================================
#  REPL
# =====================================================================
# resolve banner color from config (validate against ConsoleColor; fallback)
$BannerColor = "Green"
if ($Config.BannerColor) {
    try { [void][System.ConsoleColor]$Config.BannerColor; $BannerColor = $Config.BannerColor } catch {}
}
if (Test-Path Function:\Make-Banner) { Write-Host ""; Write-Host (Make-Banner "CLIPPY-XP") -ForegroundColor $BannerColor }
if ($ClippyArt) { Write-Host $ClippyArt -ForegroundColor $BannerColor }
Write-Host ""
Write-Host "It looks like you're coding on Windows XP. Want some help?" -ForegroundColor $BannerColor
Write-Host "ready. Model: $($Config.Model)" -ForegroundColor Green
Write-Host "cwd: $((Get-Location).Path)" -ForegroundColor DarkGray
Write-Host "Type a request, /help for commands, Ctrl-C or 'exit' to quit." -ForegroundColor Green

# Ctrl-C handling: catch it as input (so it cancels a running model instead of
# nuking the harness) and require two presses at the prompt to exit.
$UseRawInput = $true
try { [Console]::TreatControlCAsInput = $true } catch { $UseRawInput = $false }
$script:LocalProc = $null
$ctrlcArmed = $false

$messages = New-Object System.Collections.ArrayList
try {
while ($true) {
    Write-Host ""
    Write-Host ("[" + (Get-Location).Path + "]") -ForegroundColor DarkGray
    Write-Host "you: " -NoNewline -ForegroundColor Green
    if ($UseRawInput) { $userInput = Read-Prompt } else { $userInput = Read-Host }

    if ($userInput -eq "__CTRLC__") {
        if ($ctrlcArmed) { Write-Host ""; break }
        $ctrlcArmed = $true
        Write-Host "(press Ctrl-C again to exit, or type a command)" -ForegroundColor DarkGray
        continue
    }
    $ctrlcArmed = $false

    if ($userInput -eq "exit" -or $userInput -eq "quit") { break }
    if (-not $userInput) { continue }
    if ($userInput -eq "/paste") {
        $clip = Get-ClipboardText
        if (-not $clip) { Write-Host "(clipboard is empty or has no text)" -ForegroundColor Red; continue }
        $userInput = $clip.TrimEnd("`r", "`n")
        Write-Host "(pasted $(($userInput -split "`n").Count) line(s) from clipboard)" -ForegroundColor DarkGray
    } elseif ($userInput -eq "/multi") {
        Write-Host "enter text, then a line containing only '.' to send (or '/cancel'):" -ForegroundColor DarkGray
        $buf = New-Object System.Collections.ArrayList
        while ($true) {
            $l = Read-Host
            if ($l -eq ".") { break }
            if ($l -eq "/cancel") { $buf.Clear(); break }
            [void]$buf.Add($l)
        }
        $userInput = ($buf.ToArray() -join "`n")
        if (-not $userInput) { continue }
    } elseif ($userInput.StartsWith("/")) {
        Handle-Command $userInput $messages; continue
    }

    [void]$messages.Add(@{ role = "user"; content = $userInput })
    try {
        Run-Turn $messages
    } catch {
        Write-Host "turn failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
} finally {
    # never leave a spawned local model running
    if ($script:LocalProc -and -not $script:LocalProc.HasExited) { try { $script:LocalProc.Kill() } catch {} }
    try { [Console]::TreatControlCAsInput = $false } catch {}
}
Write-Host "bye." -ForegroundColor Green
