#Requires -Version 5.1
<#
.SYNOPSIS
    Windows launcher that lists, filters and resumes every Claude Code CLI session.

.DESCRIPTION
    Scans *.jsonl under ~/.claude/projects to build a session list, lets the user
    pick one from a TUI with incremental search, and runs claude --resume in a new
    Windows Terminal tab (all in one window) or window. The wt.exe launch arguments
    (--title / --tabColor) color each project differently so it is obvious at a
    glance which tab is doing what.

    It never touches settings.json and does not register any profiles.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Configuration
# ============================================================

# Defaults. Users override them in config.psd1 at the repository root (see config.example.psd1)
# instead of editing this file, so their settings survive updates.
$script:UserConfigPath = Join-Path $PSScriptRoot '..\config.psd1'

$script:Config = @{
    # UI language: 'auto' (follows the Windows display language, English if it has no
    # translation) or the name of a language folder next to this script, such as 'ja' or 'en'.
    # Any other value stops the tool at startup.
    Language           = 'auto'
    ProjectsDir        = Join-Path $env:USERPROFILE '.claude\projects'
    CacheDir           = Join-Path $env:LOCALAPPDATA 'claude-sessions'
    CachePath          = Join-Path $env:LOCALAPPDATA 'claude-sessions\index.json'
    # Session IDs pinned with Ctrl+P. Kept by this tool alone; Claude Code knows nothing of it.
    PinsPath           = Join-Path $env:LOCALAPPDATA 'claude-sessions\pins.json'
    # Directory where Claude Code keeps running sessions as <PID>.json (internal detail).
    LiveSessionsDir    = Join-Path $env:USERPROFILE '.claude\sessions'
    # How sessions are opened: 'tabs' puts every session in one window (named TabWindowName) as a
    # tab of its own; 'windows' opens each session in a window of its own (named WindowNamePrefix
    # followed by the session ID). Any other value stops the tool at startup.
    WindowMode         = 'tabs'
    # Name of the single window that holds every session in 'tabs' mode. Passed to wt -w.
    TabWindowName      = 'cs'
    # Prefix of the name given to windows opened by this tool in 'windows' mode. Passed to wt -w when focusing.
    WindowNamePrefix   = 'cs-'
    # Helper script that finds the HWND of a manually opened window. It reattaches the console,
    # so it runs in a separate process.
    ConsoleOwnerHelper = Join-Path $PSScriptRoot 'Get-ConsoleOwnerWindow.ps1'
    # Upper bound for waiting on the helper script. It normally finishes in under a second.
    ConsoleOwnerTimeoutMs = 5000
    # Class name returned when walking the owner chain leads back to the pseudo window itself
    # (terminals that set no owner). Such a window is not on screen, so it is never focused.
    FocusExcludedWindowClass = 'PseudoConsoleWindow'
    # Class name of Windows Terminal's top-level windows, searched for tabs in 'tabs' mode.
    TerminalWindowClass = 'CASCADIA_HOSTING_WINDOW_CLASS'
    ClaudeExe          = 'claude'
    WtExe              = 'wt.exe'
    # Shell that runs claude in the new window. Defaults to the PowerShell running this tool, so
    # it works where only Windows PowerShell 5.1 is installed.
    ShellExe           = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    # Maximum number of rows shown in the list at once (reduced when the screen is short).
    PageSize           = 20
    # Start in the view that shows only the latest session of each directory (plus any running
    # ones). Shift+Tab switches between that view and the list of every session.
    LatestPerDirectory = $true
    # Interval for re-reading the state of running sessions. Redraws only when the view changes.
    # 0 turns automatic re-reading off (Enter, Ctrl+D and Ctrl+R still re-read).
    RefreshIntervalMs  = 5000
    # Even when the frame signature matches, rebuild the frame once per this interval.
    # A safety net in case an input is missing from the signature (the cost is negligible
    # now that the fast path is in place).
    ForcedRedrawIntervalMs = 10000
    # Wait interval while no key is pressed.
    KeyPollIntervalMs  = 100
    # How long a message on the notice line (launch failure, deletion result, etc.) stays visible.
    NoticeDurationMs   = 3000
    # A session opened with Enter takes a few seconds to record itself in LiveSessionsDir, and
    # until then it does not look running. For this long (or until it shows up there), Enter
    # and Ctrl+D on it are held back, so a second Enter cannot start a second process on it.
    LaunchGraceMs      = 30000
    # Ctrl+N on the same project within this interval is ignored, so a double press does not
    # open two new sessions. Kept short so opening a second one on purpose is not delayed.
    NewSessionGraceMs  = 3000
    # Each project's tabColor is picked deterministically from this list by a hash of its cwd.
    TabColors          = @(
        '#66D9EF', '#A6E22E', '#FD971F', '#F92672', '#AE81FF', '#E6DB74', '#75715E', '#A1EFE4'
    )
    # Colors for the status values in ~/.claude/sessions/<PID>.json (Claude Code internal).
    # The labels are in $script:Messages. Color names are keys of $script:Ansi.Foreground (the same names as $PSStyle.Foreground).
    StatusColors       = @{ busy = 'Green'; shell = 'Green'; waiting = 'Yellow'; idle = 'BrightBlue' }
    # Display width of the last-used column (16 columns for '2026/09/23 18:05').
    DateColumnWidth    = 16
    DateFormat         = 'yyyy/MM/dd HH:mm'
    # The session names measured were at most 36 columns wide, so this cap rarely truncates them
    # and the width beyond it goes to the path column.
    TitleMaxWidth      = 40
    TitleMinWidth      = 20
    PathMinWidth       = 20
    # Ranges read by the fast path of Get-SessionFileInfo. cwd appears near the start and the
    # latest ai-title near the end, so both are found in far less than the whole file (see the
    # comments on that function). Measured on 45 local sessions: cwd by line 6 at the latest,
    # ai-title within the last 34KB. Both values leave several times that as headroom.
    HeadScanLines      = 32
    TailScanBytes      = 131072
    # Characters of the last prompt kept in the index for the preview block. It is shown in at
    # most two lines, so anything beyond two widths of the widest screen is never seen.
    PreviewMaxLength   = 300
}

# Character ranges within the BMP counted as 2 columns wide (CJK, kana, Hangul, full-width
# symbols, etc.). Surrogate pairs (emoji, etc.) are counted as 2 separately. Ambiguous-width
# characters such as '…' are excluded because Windows Terminal draws them 1 column wide by default.
$script:WideCharRanges = @(
    @(0x1100, 0x115F), @(0x2E80, 0x303E), @(0x3041, 0x33FF), @(0x3400, 0x4DBF),
    @(0x4E00, 0x9FFF), @(0xA000, 0xA4CF), @(0xAC00, 0xD7A3), @(0xF900, 0xFAFF),
    @(0xFE30, 0xFE4F), @(0xFF00, 0xFF60), @(0xFFE0, 0xFFE6)
)

# ANSI SGR sequences for the colors used on screen. $PSStyle would provide the same, but it only
# exists in PowerShell 7.2+, so the table is built here to work on Windows PowerShell 5.1 as well.
# The key names follow $PSStyle.Foreground, so StatusColors written for it keep working.
$script:Ansi = & {
    $esc = [char]27
    $names = 'Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White'
    $foreground = @{}
    $background = @{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $foreground[$names[$i]] = "$esc[$(30 + $i)m"
        $foreground["Bright$($names[$i])"] = "$esc[$(90 + $i)m"
        $background[$names[$i]] = "$esc[$(40 + $i)m"
        $background["Bright$($names[$i])"] = "$esc[$(100 + $i)m"
    }
    @{
        Reset = "$esc[0m"; Bold = "$esc[1m"; Underline = "$esc[4m"
        Foreground = $foreground; Background = $background
    }
}

# ============================================================
# Session index
# ============================================================

function ConvertFrom-JsonlStringField {
    <#
    Extracts "<Field>":"..." from a line and returns it with JSON escapes resolved.
    A lightweight helper that avoids parsing the whole line.
    #>
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$Field
    )
    $pattern = '"{0}":"((?:[^"\\]|\\.)*)"' -f [regex]::Escape($Field)
    $m = [regex]::Match($Line, $pattern)
    if (-not $m.Success) { return $null }
    try {
        return (ConvertFrom-Json -InputObject ('{{"v":"{0}"}}' -f $m.Groups[1].Value)).v
    } catch {
        return $m.Groups[1].Value
    }
}

# Upper bound on the length of a line recording aiTitle. Measured at 111 characters, with headroom.
# Conversation lines run from several KB to over ten KB each, so lines longer than this are
# assumed not to be ai-title and are not even searched (scanning long lines dominates indexing cost).
$script:MaxAiTitleLineLength = 4096

# Upper bound on the length of a line recording the last prompt. Such a line holds the whole
# prompt the user typed, so it can be far longer than an ai-title line; this only keeps a
# pasted wall of text from being parsed.
$script:MaxLastPromptLineLength = 65536

function Read-LastPromptRecord {
    <#
    Returns the prompt recorded by a '"type":"last-prompt"' line, cut to PreviewMaxLength
    characters, or $null for any other line. Claude Code also writes last-prompt lines that
    carry only leafUuid and no prompt; those return $null too, so the caller keeps the
    previous value. The whole line is parsed (it is short metadata), and the type is checked
    on the parsed object so a conversation line merely quoting the marker is not taken.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    if ($Line.Length -gt $script:MaxLastPromptLineLength -or -not $Line.Contains('"type":"last-prompt"')) {
        return $null
    }
    try { $obj = $Line | ConvertFrom-Json } catch { return $null }
    $typeProp = $obj.PSObject.Properties['type']
    $promptProp = $obj.PSObject.Properties['lastPrompt']
    if (-not $typeProp -or $typeProp.Value -ne 'last-prompt' -or -not $promptProp -or -not $promptProp.Value) {
        return $null
    }
    $text = [string]$promptProp.Value
    $max = $script:Config.PreviewMaxLength
    if ($text.Length -gt $max) {
        # Do not leave half of a surrogate pair (emoji, etc.) at the cut.
        if ([char]::IsHighSurrogate($text[$max - 1])) { $max-- }
        $text = $text.Substring(0, $max)
    }
    return $text
}

function Open-SharedReadStream {
    <#
    Opens a jsonl read-only. Claude Code may still hold a handle on a session it is writing,
    so FileShare.ReadWrite is given explicitly to avoid sharing violations (the default
    StreamReader(path) / FileStream(path, ..., Read) open with FileShare.Read, which cannot
    coexist with a write handle).
    #>
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
}

function Get-SessionFileInfoFull {
    <#
    Scans every line of one session's jsonl from start to end and returns its metadata.
    The reliable but slow path: the fallback when the fast path of Get-SessionFileInfo misses
    cwd / aiTitle, and the path used directly for small files.
    Once cwd is found, later lines are not checked for it.
    aiTitle and the last prompt get newer further down, so the scan runs to the end, but
    overly long lines are skipped.
    #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $cwd = $null
    $title = $null
    $lastPrompt = $null

    # StreamReader(Stream) detects the encoding from the BOM, just like StreamReader(path).
    $reader = [System.IO.StreamReader]::new((Open-SharedReadStream -Path $File.FullName))
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($line)) { continue }

            if (-not $cwd -and $line.Contains('"cwd":')) {
                $cwd = ConvertFrom-JsonlStringField -Line $line -Field 'cwd'
            }

            if ($line.Length -le $script:MaxAiTitleLineLength -and $line.Contains('"type":"ai-title"')) {
                try {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.aiTitle) { $title = $obj.aiTitle }
                } catch { }
            }

            # Checked here before the call, which would cost more than the check on every line.
            if ($line.Contains('"type":"last-prompt"')) {
                $prompt = Read-LastPromptRecord -Line $line
                if ($prompt) { $lastPrompt = $prompt }
            }
        }
    } finally {
        $reader.Dispose()
    }

    [pscustomobject]@{
        SessionId  = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        Path       = $File.FullName
        Cwd        = $cwd
        Title      = $title
        Modified   = $File.LastWriteTime
        Length     = $File.Length
        LastPrompt = $lastPrompt
    }
}

function Get-SessionFileInfoFast {
    <#
    The fast path of Get-SessionFileInfo. Relies on the measured tendency that cwd appears
    within the first few lines and the latest aiTitle within the last few tens of KB (see the
    function comments), and reads only those ranges to find both.
    Returns $null if either one is missing. The caller takes that as the signal to fall back
    to the reliable full scan in Get-SessionFileInfoFull.
    #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $cwd = $null
    $reader = [System.IO.StreamReader]::new((Open-SharedReadStream -Path $File.FullName))
    try {
        $lineCount = 0
        while (-not $cwd -and $lineCount -lt $script:Config.HeadScanLines -and -not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $lineCount++
            if ([string]::IsNullOrEmpty($line)) { continue }
            if ($line.Contains('"cwd":')) {
                $cwd = ConvertFrom-JsonlStringField -Line $line -Field 'cwd'
            }
        }
    } finally {
        $reader.Dispose()
    }
    if (-not $cwd) { return $null }

    $title = $null
    $lastPrompt = $null
    # Use UTF-8 without BOM explicitly. The default StreamReader constructor detects the
    # encoding from the BOM, but after seeking from the end the leading bytes it needs are not
    # read, so the encoding used by the whole file is fixed here instead.
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $stream = Open-SharedReadStream -Path $File.FullName
    try {
        # The file may have been truncated since $File was read, which makes this seek fail.
        $stream.Seek(-$script:Config.TailScanBytes, [System.IO.SeekOrigin]::End) | Out-Null
    } catch {
        $stream.Dispose()
        throw
    }
    $tailReader = [System.IO.StreamReader]::new($stream, $encoding)
    try {
        # The seek position may fall in the middle of a line or of a UTF-8 multi-byte
        # character, so the first line is always discarded as an incomplete fragment
        # (StreamReader.Dispose() also disposes the inner $stream, so no separate Dispose is needed).
        if (-not $tailReader.EndOfStream) { [void]$tailReader.ReadLine() }
        while (-not $tailReader.EndOfStream) {
            $line = $tailReader.ReadLine()
            if ([string]::IsNullOrEmpty($line)) { continue }
            if ($line.Length -le $script:MaxAiTitleLineLength -and $line.Contains('"type":"ai-title"')) {
                try {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.aiTitle) { $title = $obj.aiTitle }
                } catch { }
            }
            # Checked here before the call, which would cost more than the check on every line.
            if ($line.Contains('"type":"last-prompt"')) {
                $prompt = Read-LastPromptRecord -Line $line
                if ($prompt) { $lastPrompt = $prompt }
            }
        }
    } finally {
        $tailReader.Dispose()
    }
    # The last prompt is not required: Claude Code rewrites it near the end of the file, so it
    # is normally in this range, and a session where it is not just shows no preview. Falling
    # back to a full scan for it would read every large file to the end.
    if (-not $title) { return $null }

    [pscustomobject]@{
        SessionId  = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        Path       = $File.FullName
        Cwd        = $cwd
        Title      = $title
        Modified   = $File.LastWriteTime
        Length     = $File.Length
        LastPrompt = $lastPrompt
    }
}

function Get-SessionFileInfo {
    <#
    Scans one session's jsonl and returns its metadata.

    cwd appears within the first few lines and the latest aiTitle within the last few tens of
    KB (measured on 45 local sessions: cwd by line 6 at the latest, aiTitle within the last
    34KB). So the fast path in Get-SessionFileInfoFast, which reads only those ranges, is tried
    first to avoid a full scan of large files.

    When the file is no larger than $script:Config.TailScanBytes, or the fast path misses
    either cwd or aiTitle (for example old-format sessions that never recorded aiTitle), it
    falls back to a full scan with Get-SessionFileInfoFull to get a reliable result.
    #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    if ($File.Length -gt $script:Config.TailScanBytes) {
        $fast = Get-SessionFileInfoFast -File $File
        if ($fast) { return $fast }
    }
    return Get-SessionFileInfoFull -File $File
}

function Get-SessionIndex {
    <#
    Returns metadata for every session. Sessions whose LastWriteTime and Length match the
    previous run reuse the cache and are not rescanned.
    When a script block is passed to -OnProgress, it is called with (current, total) each time
    a file not in the cache (one that is actually scanned) is processed. Used to show progress
    where the scan can take hundreds of ms or more, such as the first launch or Ctrl+R.
    #>
    param(
        [switch]$Force,
        [scriptblock]$OnProgress
    )

    if (-not (Test-Path $script:Config.ProjectsDir)) {
        return @()
    }

    $cache = @{}
    if (-not $Force -and (Test-Path $script:Config.CachePath)) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:Config.CachePath) | ConvertFrom-Json
            foreach ($entry in $raw) {
                $cache[$entry.Path] = $entry
            }
        } catch {
            $cache = @{}
        }
    }

    # Session files sit one level down at <ProjectsDir>\<project>\<uuid>.jsonl.
    # Subagent transcripts live in <uuid>\subagents\agent-*.jsonl and are naturally excluded by -Depth 1.
    $files = @(Get-ChildItem -Path $script:Config.ProjectsDir -Recurse -Depth 1 -Filter '*.jsonl' -File)
    $results = [System.Collections.Generic.List[object]]::new()
    $scanned = 0
    $reused = 0

    foreach ($file in $files) {
        $cached = $cache[$file.FullName]
        # An entry with a missing property or an unparsable date (an edited or foreign cache)
        # throws under StrictMode; it is treated as not cached and rescanned.
        # An entry written before LastPrompt was indexed is rescanned as well, once, so that
        # sessions which never change again still get a preview.
        $cachedEntry = $null
        if ($cached -and $cached.PSObject.Properties['LastPrompt']) {
            try {
                $cachedEntry = [pscustomobject]@{
                    SessionId  = $cached.SessionId
                    Path       = $cached.Path
                    Cwd        = $cached.Cwd
                    Title      = $cached.Title
                    Modified   = [datetime]$cached.Modified
                    Length     = $cached.Length
                    LastPrompt = $cached.LastPrompt
                }
            } catch { }
        }
        if ($cachedEntry -and
            $cachedEntry.Length -eq $file.Length -and
            $cachedEntry.Modified -eq $file.LastWriteTime) {
            $results.Add($cachedEntry)
            $reused++
            continue
        }
        if ($OnProgress) { & $OnProgress ($scanned + 1) $files.Count }
        # A read failure on one file (just deleted, locked, etc.) must not break the whole index.
        # Use the old entry if there is one, and retry on the next scan.
        try {
            $results.Add((Get-SessionFileInfo -File $file))
            $scanned++
        } catch {
            if ($cachedEntry) {
                $results.Add($cachedEntry)
                $reused++
            }
        }
    }

    # With nothing rescanned or removed, the cache content is unchanged, so it is not rewritten.
    if ($scanned -eq 0 -and $reused -eq $cache.Count -and (Test-Path $script:Config.CachePath)) {
        return , @($results | Where-Object { $_.Cwd } | Sort-Object Modified -Descending)
    }

    if (-not (Test-Path $script:Config.CacheDir)) {
        New-Item -ItemType Directory -Path $script:Config.CacheDir -Force | Out-Null
    }
    $cacheOut = $results | ForEach-Object {
        [pscustomobject]@{
            SessionId  = $_.SessionId
            Path       = $_.Path
            Cwd        = $_.Cwd
            Title      = $_.Title
            Modified   = $_.Modified.ToString('o')
            Length     = $_.Length
            LastPrompt = $_.LastPrompt
        }
    }
    # Written as UTF-8 without BOM through .NET, because Set-Content -Encoding utf8 adds a BOM on
    # Windows PowerShell 5.1 but not on 7, and Get-Content on 5.1 reads a BOM-less file as ANSI.
    # ReadAllText above detects UTF-8 either way, so a cache written by one version reads fine in the other.
    $json = $cacheOut | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:Config.CachePath, [string]$json, [System.Text.UTF8Encoding]::new($false))

    # Callers can take the result as is without @() (same contract as Get-FilteredSessions etc.).
    # The leading comma sends the array down the function's output pipeline as a single object.
    # Without it, a single result is unwrapped to a scalar on the caller's side (confirmed by
    # testing; the [object[]] parameter types of the current callers happened to convert it back,
    # but untyped use would break under StrictMode).
    return , @($results | Where-Object { $_.Cwd } | Sort-Object Modified -Descending)
}

function Find-SessionFile {
    <#
    Returns the path of <ProjectsDir>\<project>\<SessionId>.jsonl for a session ID, or $null when
    no project folder has it yet (Claude Code creates the file only with the first message).
    Used to pick up a session that started after the index was built, without rescanning
    everything: one existence check per project folder, through .NET to keep it light.
    #>
    param([AllowNull()][string]$SessionId)
    if (-not (Test-SessionId -SessionId $SessionId)) { return $null }
    if (-not [System.IO.Directory]::Exists($script:Config.ProjectsDir)) { return $null }
    foreach ($dir in [System.IO.Directory]::GetDirectories($script:Config.ProjectsDir)) {
        $path = [System.IO.Path]::Combine($dir, "$SessionId.jsonl")
        if ([System.IO.File]::Exists($path)) { return $path }
    }
    return $null
}

function Get-SessionIdSet {
    # SessionId -> $true for every session in the list.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions)
    $ids = @{}
    foreach ($session in $Sessions) { $ids[$session.SessionId] = $true }
    return $ids
}

function Add-NewSessions {
    <#
    Adds sessions read after startup to the list and returns it newest first, like
    Get-SessionIndex. Entries without a cwd (the file has no message with one yet) and IDs
    already listed are skipped, so the same session can be offered again on the next poll.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$NewInfos
    )
    $known = Get-SessionIdSet -Sessions $Sessions
    $added = @($NewInfos | Where-Object { $_ -and $_.Cwd -and -not $known.ContainsKey($_.SessionId) })
    if ($added.Count -eq 0) { return , $Sessions }
    return , @(@($Sessions) + $added | Sort-Object Modified -Descending)
}

# ============================================================
# Project appearance (color, name)
# ============================================================

function Get-ProjectName {
    param([Parameter(Mandatory)][string]$Cwd)
    return Split-Path -Path $Cwd -Leaf
}

function Get-TabColorForPath {
    param([Parameter(Mandatory)][string]$Cwd)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Cwd))
    } finally {
        $md5.Dispose()
    }
    $index = $hash[0] % $script:Config.TabColors.Count
    return $script:Config.TabColors[$index]
}

# Characters of the session ID put in a tab title in 'tabs' mode: the first group of the GUID.
$script:TabTitleIdLength = 8

function Get-SessionTabTitle {
    <#
    Returns the tab title of a session. In 'tabs' mode several sessions of one project share a
    window, and Enter finds a session's tab by its title, so the title carries the start of the
    session ID ('<project> #1a2b3c4d') to tell them apart. In 'windows' mode it is the project
    name alone. The raw title is returned; escaping it for wt.exe is up to the caller.
    #>
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$SessionId
    )
    $projectName = Get-ProjectName -Cwd $Cwd
    if ($script:Config.WindowMode -ne 'tabs') { return $projectName }
    $shortId = $SessionId.Substring(0, [Math]::Min($script:TabTitleIdLength, $SessionId.Length))
    return "$projectName #$shortId"
}

# ============================================================
# Launching
# ============================================================

function Test-SessionId {
    <#
    Decides whether a string is a session ID in the form Claude Code uses (a GUID such as
    xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx). The ID comes from a jsonl file name or the index
    cache and ends up in a PowerShell -Command string, a wt.exe argument and a SHFileOperation path
    (which accepts wildcards), so anything else is rejected before it gets there.
    #>
    param([AllowNull()][string]$SessionId)
    $guid = [guid]::Empty
    return [guid]::TryParseExact([string]$SessionId, 'D', [ref]$guid)
}

function Test-JobId {
    <#
    Decides whether a string looks like the job ID of a background session (the short ID that
    'claude --bg' prints, such as 7f9d969b, recorded as jobId). Like the session ID it ends up
    in a -Command string, so only letters and digits are accepted.
    #>
    param([AllowNull()][string]$JobId)
    return [bool]($JobId -match '^[0-9A-Za-z]{1,64}$')
}

function ConvertTo-WtArgument {
    <#
    wt.exe splits its command line on ';' into separate subcommands, even inside quotes.
    A folder name may contain ';', so it is escaped as '\;', which wt passes on as a literal ';'.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Replace(';', '\;')
}

function ConvertTo-ProcessArgument {
    <#
    Quotes one argument so the child's command line parser (CommandLineToArgvW rules, which
    wt.exe and PowerShell both follow) gets it back as a single argument. Start-Process
    -ArgumentList joins the elements with spaces without quoting them, on 5.1 and 7 alike
    (confirmed by running it), so a folder name with a space would otherwise split in two,
    and Windows PowerShell 5.1 rejects an empty element outright.
    Backslashes are doubled only where they precede a quote, including the closing one
    added here, so 'D:\' comes back as 'D:\' rather than escaping that quote.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value * 2 + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

function ConvertTo-CommandName {
    <#
    Turns ClaudeExe into the command part of the PowerShell -Command string. A plain name or
    path is passed as is, so the default stays 'claude'. Anything else, such as a path with a
    space ('C:\Program Files\...') or a '$', would be parsed as script, so it is put in single
    quotes (where nothing is expanded, and a quote is written twice) after the call operator.
    #>
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '^[\w.:\\/-]+$') { return $Value }
    return "& '" + $Value.Replace("'", "''") + "'"
}

# Variables Claude Code sets for the processes it starts, besides the CLAUDE_CODE_* prefix
# (CLAUDECODE marks a child of a session, CLAUDE_PID is the parent's PID, CLAUDE_EFFORT its
# effort level). Found in the claude binary alongside CLAUDE_CODE_SESSION_ID etc.
$script:ClaudeSessionEnvNames = @('CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT')

function Get-ClaudeSessionEnv {
    <#
    When this tool itself is started from inside a Claude Code session, the variables Claude
    Code sets for its children are inherited by child processes, the new session is mistaken
    for a "child of another session", and transcript saving is disabled.
    Returns CLAUDE_CODE_* and $script:ClaudeSessionEnvNames as a name -> value hashtable, so
    the caller can remove them only while starting a child and put them back afterwards.
    #>
    $variables = @{}
    Get-ChildItem Env: | Where-Object {
        $_.Name -like 'CLAUDE_CODE_*' -or $script:ClaudeSessionEnvNames -contains $_.Name
    } | ForEach-Object {
        $variables[$_.Name] = $_.Value
    }
    return $variables
}

function Invoke-WindowsTerminal {
    <#
    Calls wt.exe (a Store app) asynchronously so PowerShell does not block on it.
    The variables from Get-ClaudeSessionEnv are removed from this process only while Start-Process runs,
    so the child does not inherit them; everything else (PATH, etc.) is passed through.
    Start-Process -Environment would do the same, but it only exists in PowerShell 7.4+.
    Each argument is quoted with ConvertTo-ProcessArgument, so callers pass raw values.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments)
    $quoted = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ })
    $saved = Get-ClaudeSessionEnv
    try {
        foreach ($name in $saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        Start-Process -FilePath $script:Config.WtExe -ArgumentList $quoted
    } finally {
        foreach ($name in $saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function Start-ClaudeSession {
    <#
    Colors each project directly through the wt.exe launch arguments (--title / --tabColor / -d).
    No Windows Terminal profile is registered, so color and tab name apply immediately even
    for a new project.

    wt.exe treats ';' on its command line as a command separator, so nothing like
    'cd; claude ...' is chained. The working directory is passed with -d, and -Command gets
    only 'claude --resume <uuid>'. The ID is checked with Test-SessionId, and the title and
    directory, which may contain ';', are escaped with ConvertTo-WtArgument.

    In 'tabs' mode the session opens as a new tab of the window named TabWindowName (wt creates
    the window if it does not exist), titled with Get-SessionTabTitle so Enter can find the tab
    again. In 'windows' mode the window is named cs-<sessionId> so it can later be focused with
    wt -w. A new session gets its ID generated up front and passed with --session-id, and the
    title or window name uses that same ID.

    -AttachJobId opens a session running in the background (claude --bg / agent view) with
    'claude attach <jobId>' instead of resuming it, which would start a second process on it.
    attach takes the job ID, not the session ID. A second attach tab is harmless: attach only
    shows the session that keeps running.
    #>
    param(
        [string]$Cwd,
        [string]$SessionId,
        [switch]$NewSession,
        [string]$AttachJobId
    )

    $tabColor = Get-TabColorForPath -Cwd $Cwd

    if ($NewSession -and $AttachJobId) { throw 'Start-ClaudeSession: -NewSession and -AttachJobId cannot be used together.' }
    $claudeExe = ConvertTo-CommandName -Value $script:Config.ClaudeExe
    if ($NewSession) {
        $SessionId = [guid]::NewGuid().ToString()
        $claudeCommand = "$claudeExe --session-id $SessionId"
    } elseif ($AttachJobId) {
        if (-not (Test-SessionId -SessionId $SessionId)) { throw ($script:Text.InvalidSessionId -f $SessionId) }
        if (-not (Test-JobId -JobId $AttachJobId)) { throw ($script:Text.InvalidSessionId -f $AttachJobId) }
        $claudeCommand = "$claudeExe attach $AttachJobId"
    } else {
        if (-not (Test-SessionId -SessionId $SessionId)) { throw ($script:Text.InvalidSessionId -f $SessionId) }
        $claudeCommand = "$claudeExe --resume $SessionId"
    }

    $target = if ($script:Config.WindowMode -eq 'tabs') {
        @('-w', (ConvertTo-WtArgument -Value $script:Config.TabWindowName), 'new-tab')
    } else {
        @('-w', "$($script:Config.WindowNamePrefix)$SessionId")
    }
    $title = Get-SessionTabTitle -Cwd $Cwd -SessionId $SessionId
    Invoke-WindowsTerminal -Arguments @(
        $target
        '--title', (ConvertTo-WtArgument -Value $title),
        '--tabColor', $tabColor,
        '--suppressApplicationTitle',
        '-d', (ConvertTo-WtArgument -Value $Cwd),
        # -ExecutionPolicy Bypass: npm installs claude as a claude.ps1 shim, which Windows PowerShell
        # 5.1 refuses to run under its default Restricted policy.
        $script:Config.ShellExe, '-NoLogo', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $claudeCommand
    )
}

function Show-ClaudeWindow {
    <#
    Brings a window opened by this tool (named cs-<sessionId>) to the front.
    If no window has that name, wt creates a new empty window instead, so check that it
    exists with Test-LaunchedByTool before calling this.
    #>
    param([Parameter(Mandatory)][string]$SessionId)
    if (-not (Test-SessionId -SessionId $SessionId)) { throw ($script:Text.InvalidSessionId -f $SessionId) }
    Invoke-WindowsTerminal -Arguments @(
        '-w', "$($script:Config.WindowNamePrefix)$SessionId",
        'focus-tab', '-t', '0'
    )
}

# ============================================================
# Detecting running sessions
# ============================================================

function Test-ProcessRecordMatch {
    <#
    Decides whether a running process and a ~/.claude/sessions/<PID>.json record refer to the
    same process. The OS can reuse a PID after the process exits, so matching the process name
    alone can tie a record left behind by a crash to an unrelated process. procStart (the
    process start time as a FILETIME in decimal string form, Claude Code internal) is compared
    to rule that out.
    If either value needed for the comparison is missing, no decision is possible, so it errs
    on the side of accepting ($true) rather than hiding the session.
    #>
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [AllowNull()][object]$ProcessStartFileTime,
        [AllowNull()][object]$RecordProcStart
    )

    # After a self-update the running process's exe is renamed to 'claude.exe.old.<timestamp>',
    # so match by prefix rather than exactly.
    if ($ProcessName -notlike 'claude*') { return $false }

    if ($null -eq $ProcessStartFileTime) { return $true }

    $recordFileTime = 0L
    if (-not [long]::TryParse([string]$RecordProcStart, [ref]$recordFileTime)) { return $true }

    return ([long]$ProcessStartFileTime -eq $recordFileTime)
}

function Get-OpenSessionMap {
    <#
    Returns running sessions as a dictionary of sessionId -> @{ Pid; Status }.
    Claude Code records each running session in ~/.claude/sessions/<PID>.json and rewrites
    status (busy / shell / waiting / idle) whenever it changes.
    These are internal files, not a public spec, so unreadable or malformed ones are silently
    ignored. Only records whose PID is alive, whose process name starts with claude, and whose
    procStart matches are accepted (guards against crash leftovers and PID reuse; see
    Test-ProcessRecordMatch for the check).

    Records also carry kind (interactive / bg / daemon / daemon-worker) and, for background
    sessions, jobId. Both are kept: a bg session has no window of its own, so Enter attaches to
    it by job ID instead of focusing (see Open-ClaudeSession).

    This runs every 5 seconds, so it calls .NET APIs directly to avoid the overhead of cmdlet
    pipeline setup, parameter binding and PSObject wrapping (measured several times faster
    than the cmdlet versions of Get-ChildItem and Get-Content).
    [Diagnostics.Process]::GetProcessById, the equivalent of Get-Process, throws when the PID
    does not exist (there is no -ErrorAction equivalent), so it is caught with try/catch. The
    Process object holds a handle, so it is always disposed in finally once the check is done.
    #>
    $map = @{}
    if (-not (Test-Path $script:Config.LiveSessionsDir)) { return $map }

    foreach ($path in [System.IO.Directory]::GetFiles($script:Config.LiveSessionsDir, '*.json')) {
        try {
            $entry = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            $proc = $null
            try { $proc = [System.Diagnostics.Process]::GetProcessById([int]$entry.pid) } catch { }
            if (-not $proc -or -not $entry.sessionId) { continue }

            try {
                $startFileTime = $null
                try { $startFileTime = $proc.StartTime.ToFileTime() } catch { }

                $procStartProp = $entry.PSObject.Properties['procStart']
                $recordProcStart = if ($procStartProp) { $procStartProp.Value } else { $null }

                if (Test-ProcessRecordMatch -ProcessName $proc.ProcessName `
                        -ProcessStartFileTime $startFileTime -RecordProcStart $recordProcStart) {
                    # Even without a status field the session is certainly running, so keep the entry.
                    $statusProp = $entry.PSObject.Properties['status']
                    $kindProp = $entry.PSObject.Properties['kind']
                    $jobIdProp = $entry.PSObject.Properties['jobId']
                    $map[[string]$entry.sessionId] = [pscustomobject]@{
                        Pid    = [int]$entry.pid
                        Status = if ($statusProp) { [string]$statusProp.Value } else { '' }
                        Kind   = if ($kindProp) { [string]$kindProp.Value } else { '' }
                        JobId  = if ($jobIdProp) { [string]$jobIdProp.Value } else { '' }
                    }
                }
            } finally {
                $proc.Dispose()
            }
        } catch { }
    }
    return $map
}

function Test-LaunchedByTool {
    <#
    Decides whether a running session belongs to a window opened by this tool.
    The arguments on claude.exe's own command line are not visible, but the parent shell's
    command line is. For a window opened by this tool the parent is
    '<ShellExe> ... -NoExit -Command "claude --resume <ID>"' (pwsh.exe or powershell.exe),
    so checking for the ID is enough.
    #>
    param(
        [Parameter(Mandatory)][int]$ClaudePid,
        [Parameter(Mandatory)][string]$SessionId
    )
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ClaudePid"
        if (-not $proc) { return $false }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)"
        return [bool]($parent -and $parent.CommandLine -and $parent.CommandLine.Contains($SessionId))
    } catch {
        return $false
    }
}

function Initialize-WindowApi {
    <#
    Declares the user32 functions used for focusing. Compiling them takes hundreds of ms, so
    it is not done at startup but once, the first time a manually opened window is focused.
    #>
    if ('ClaudeSessionsWindowApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ClaudeSessionsWindowApi {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);

    public static string ClassNameOf(IntPtr hwnd) {
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@
}

function Get-ConsoleOwnerWindow {
    <#
    Returns the HWND of the window showing the claude process ([IntPtr]::Zero if not found).
    See Get-ConsoleOwnerWindow.ps1 for how it is found. To keep console reattachment from
    breaking this process's standard I/O, the same PowerShell executable is started as a hidden separate
    process and the result is received through a temp file.
    Starting the child takes just under a second, during which key input stalls; that is
    acceptable because it happens right after Enter, when the user is moving to another window.
    #>
    param([Parameter(Mandatory)][int]$ClaudePid)

    $outFile = [System.IO.Path]::GetTempFileName()
    try {
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
            '-File', (ConvertTo-ProcessArgument -Value $script:Config.ConsoleOwnerHelper),
            '-ProcessId', $ClaudePid, '-OutFile', (ConvertTo-ProcessArgument -Value $outFile)
        )
        try {
            if (-not $child.WaitForExit($script:Config.ConsoleOwnerTimeoutMs)) {
                try { $child.Kill() } catch { }
                return [IntPtr]::Zero
            }
        } finally {
            $child.Dispose()
        }
        $value = 0L
        if (-not [long]::TryParse([System.IO.File]::ReadAllText($outFile), [ref]$value)) { return [IntPtr]::Zero }
        return [IntPtr]$value
    } finally {
        Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
    }
}

function Test-FocusableWindow {
    <#
    Decides whether a window may be focused. In terminals that set no owner (such as the
    VS Code integrated terminal), walking the owner chain leads back to the pseudo window
    itself, which is not on screen, so it is excluded.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ClassName,
        [Parameter(Mandatory)][bool]$IsVisible
    )
    return ($IsVisible -and $ClassName -and $ClassName -ne $script:Config.FocusExcludedWindowClass)
}

function Show-OwnerWindow {
    <#
    Brings the window found by Get-ConsoleOwnerWindow to the front and returns whether it
    succeeded. A minimized window is restored first (SetForegroundWindow alone does not show
    a minimized window). The tab is not switched.
    #>
    param([Parameter(Mandatory)][IntPtr]$Hwnd)

    $SW_RESTORE = 9
    Initialize-WindowApi
    $className = [ClaudeSessionsWindowApi]::ClassNameOf($Hwnd)
    if (-not (Test-FocusableWindow -ClassName $className -IsVisible ([ClaudeSessionsWindowApi]::IsWindowVisible($Hwnd)))) {
        return $false
    }
    if ([ClaudeSessionsWindowApi]::IsIconic($Hwnd)) {
        [void][ClaudeSessionsWindowApi]::ShowWindow($Hwnd, $SW_RESTORE)
    }
    return [ClaudeSessionsWindowApi]::SetForegroundWindow($Hwnd)
}

function Initialize-UiAutomation {
    <#
    Loads the UI Automation client assemblies, available on Windows PowerShell 5.1 and on
    PowerShell 7 for Windows alike. Loading takes about 150 ms, so like Initialize-WindowApi it
    is done once, the first time a tab is looked up. Returns whether UI Automation can be used.
    #>
    if ('System.Windows.Automation.AutomationElement' -as [type]) { return $true }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        return $true
    } catch {
        return $false
    }
}

function Select-TerminalTab {
    <#
    Finds the Windows Terminal tab titled exactly $Title, switches to it, and returns the HWND of
    its window ([IntPtr]::Zero if no tab has that title). Tabs opened in 'tabs' mode keep their
    title (--suppressApplicationTitle), so the title identifies the session even after the user
    reorders tabs or drags one to another window, which an index for wt focus-tab would not.
    Bringing the window to the front is up to the caller.

    Every Windows Terminal window is searched, since UI Automation does not expose the window
    names wt -w uses. Searching their descendants for tab items takes about 10 ms per window.
    A tab closed during the search throws, which is treated as not found.
    #>
    param([Parameter(Mandatory)][string]$Title)

    if (-not (Initialize-UiAutomation)) { return [IntPtr]::Zero }
    try {
        $element = [System.Windows.Automation.AutomationElement]
        $windowCondition = New-Object System.Windows.Automation.PropertyCondition(
            $element::ClassNameProperty, $script:Config.TerminalWindowClass)
        $tabCondition = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition(
                $element::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)),
            (New-Object System.Windows.Automation.PropertyCondition($element::NameProperty, $Title)))
        $windows = $element::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $windowCondition)
        foreach ($window in $windows) {
            $tab = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)
            if (-not $tab) { continue }
            $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $pattern.Select()
            return [IntPtr]$window.Current.NativeWindowHandle
        }
    } catch { }
    return [IntPtr]::Zero
}

function Invoke-LaunchAction {
    <#
    Runs an action that opens or focuses a window, and returns a message on failure ($null on success).
    Under $ErrorActionPreference = 'Stop', exceptions such as wt.exe not being found would
    escape the interactive loop and terminate the tool, so they are caught here and turned
    into a notice. A missing working directory is rejected up front, since wt would only open
    a failed window.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [AllowNull()][string]$Cwd
    )
    if ($Cwd -and -not (Test-Path -LiteralPath $Cwd -PathType Container)) {
        return $script:Text.CwdNotFound -f $Cwd
    }
    try {
        & $Action
        return $null
    } catch {
        return $script:Text.LaunchFailed -f $_.Exception.Message
    }
}

function Test-BackgroundSession {
    <#
    Decides whether a running session (an entry of Get-OpenSessionMap) runs in the background
    and can be attached to: kind 'bg' with a job ID. Entries built elsewhere (tests, older
    records) may lack Kind / JobId, so they are read defensively.
    #>
    param([AllowNull()][object]$OpenEntry)
    if (-not $OpenEntry) { return $false }
    $kindProp = $OpenEntry.PSObject.Properties['Kind']
    $jobIdProp = $OpenEntry.PSObject.Properties['JobId']
    return [bool]($kindProp -and $kindProp.Value -eq 'bg' -and $jobIdProp -and $jobIdProp.Value)
}

function Open-ClaudeSession {
    <#
    Dispatches Enter. Opens the session if it is not running. In 'tabs' mode it then switches to
    the session's tab, found by its title. Otherwise it attaches to the session in a new window
    or tab if it runs in the background, focuses it by window name if the tool opened the window
    ('windows' mode), and otherwise walks from the console to its window to focus it.
    If focusing fails, it only returns a message, to avoid launching the session twice.
    It never touches the screen and only returns a message ($null if none). The caller
    (Show-SessionMenu) shows it temporarily without blocking key input.
    #>
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][hashtable]$OpenMap
    )

    if (-not $OpenMap.ContainsKey($Session.SessionId)) {
        return Invoke-LaunchAction -Cwd $Session.Cwd -Action {
            Start-ClaudeSession -Cwd $Session.Cwd -SessionId $Session.SessionId
        }
    }

    $entry = $OpenMap[$Session.SessionId]
    $isBackground = Test-BackgroundSession -OpenEntry $entry

    # In 'tabs' mode a tab this tool opened (a session, or the attach tab of a background one)
    # is found by its title and switched to. If the tab is there but its window cannot be brought
    # forward, nothing new is opened.
    if ($script:Config.WindowMode -eq 'tabs') {
        $tabHwnd = [IntPtr]::Zero
        try {
            $tabHwnd = Select-TerminalTab -Title (Get-SessionTabTitle -Cwd $Session.Cwd -SessionId $Session.SessionId)
            if ($tabHwnd -ne [IntPtr]::Zero -and (Show-OwnerWindow -Hwnd $tabHwnd)) { return $null }
        } catch { }
        if ($tabHwnd -ne [IntPtr]::Zero) { return $script:Text.AlreadyOpen }
    }

    # A background session runs without a console or window, so there is nothing to focus.
    # It is opened in a new window (or tab) attached to it.
    if ($isBackground) {
        return Invoke-LaunchAction -Cwd $Session.Cwd -Action {
            Start-ClaudeSession -Cwd $Session.Cwd -SessionId $Session.SessionId -AttachJobId $entry.JobId
        }
    }

    $claudePid = $entry.Pid
    if ($script:Config.WindowMode -ne 'tabs' -and (Test-LaunchedByTool -ClaudePid $claudePid -SessionId $Session.SessionId)) {
        return Invoke-LaunchAction -Action { Show-ClaudeWindow -SessionId $Session.SessionId }
    }

    # A manually opened window, or one opened by the tool whose session ID later changed via
    # /clear etc. (or whose tab the user renamed). It cannot be addressed by window name or tab
    # title, so walk from claude's console to its
    # window and focus that. The reason for failure (helper script missing, window not visible,
    # etc.) does not matter to the user, so exceptions included, it all ends in the same message.
    try {
        $hwnd = Get-ConsoleOwnerWindow -ClaudePid $claudePid
        if ($hwnd -ne [IntPtr]::Zero -and (Show-OwnerWindow -Hwnd $hwnd)) { return $null }
    } catch { }
    return $script:Text.AlreadyOpen
}

# ============================================================
# Deletion
# ============================================================

function Initialize-RecycleBinApi {
    <#
    Declares shell32's SHFileOperation, used to send items to the Recycle Bin. Like
    Initialize-WindowApi, compiling takes hundreds of ms, so it is done once on the first delete.
    The Recycle Bin support in Microsoft.VisualBasic.FileIO.FileSystem only offers
    OnlyErrorDialogs / AllDialogs for UIOption, so a failure shows a GUI dialog and stalls the
    TUI; it is not used. Here the confirmation, progress and error dialogs are all suppressed,
    and failures are returned to the caller as exceptions.
    Items too large for the Recycle Bin, or on a drive without one, are deleted permanently
    without warning unless FOF_WANTNUKEWARNING is set (setting it brings up a confirmation
    dialog). The targets are logs under ~/.claude/projects, so neither case happens in practice.
    #>
    if ('ClaudeSessionsRecycleBinApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ClaudeSessionsRecycleBinApi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    const uint FO_DELETE = 0x3;
    const ushort FOF_SILENT = 0x4;
    const ushort FOF_NOCONFIRMATION = 0x10;
    const ushort FOF_ALLOWUNDO = 0x40;
    const ushort FOF_NOERRORUI = 0x400;

    public static void Send(string path) {
        var op = new SHFILEOPSTRUCT {
            wFunc = FO_DELETE,
            // pFrom is a NUL-separated list that must end with two NULs.
            // The marshaler appends one, so only one more is added here.
            pFrom = path + "\0",
            fFlags = (ushort)(FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI)
        };
        int rc = SHFileOperation(ref op);
        if (rc != 0) throw new InvalidOperationException("SHFileOperation failed (0x" + rc.ToString("X") + "): " + path);
        if (op.fAnyOperationsAborted) throw new InvalidOperationException("SHFileOperation aborted: " + path);
    }
}
'@
}

function Move-SessionToRecycleBin {
    <#
    Sends one file or folder to the Recycle Bin. Failures are thrown as exceptions.
    Kept as a separate function so the Remove-ClaudeSession tests do not actually recycle anything.
    #>
    param([Parameter(Mandatory)][string]$Path)
    Initialize-RecycleBinApi
    [ClaudeSessionsRecycleBinApi]::Send($Path)
}

function Test-SessionFilePath {
    <#
    Decides whether a path is a session file that may be deleted. $Session.Path may come from
    the cache (index.json); so that a corrupted cache never deletes an unrelated file, only
    <ProjectsDir>\<project>\<SessionId>.jsonl is allowed, with a valid session ID (no
    wildcards reach SHFileOperation) at exactly one project folder below ProjectsDir (so the
    same-named companion folder is never a project folder itself).
    #>
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$SessionId
    )
    if (-not $Path -or -not (Test-SessionId -SessionId $SessionId)) { return $false }
    $root = [System.IO.Path]::GetFullPath($script:Config.ProjectsDir).TrimEnd('\', '/')
    # .NET Framework (Windows PowerShell 5.1) throws for paths that .NET Core accepts, such as
    # a ':' after the drive; such a path is simply not a session file.
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    $projectDir = [System.IO.Path]::GetDirectoryName($full)
    return [System.IO.Path]::GetFileName($full) -eq "$($SessionId).jsonl" -and
        [string]::Equals([System.IO.Path]::GetDirectoryName($projectDir), $root, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-ClaudeSession {
    <#
    Sends a session's jsonl and its same-named folder (subagents / tool-results) to the Recycle Bin.
    Like Invoke-LaunchAction, it returns a message on failure ($null on success) and never
    lets exceptions leak into the interactive loop.

    Running sessions are not deleted. Claude keeps appending even after the file is gone, so a
    jsonl with missing history would be recreated. Ctrl+D checks the running state when pressed,
    but that check would miss a session started while confirmation was pending, so it is
    re-read right before deleting.
    The same-named folder is sent first, and on failure the jsonl is left alone. Deleting the
    jsonl first could leave the folder behind after the session vanished from the list.
    #>
    param([Parameter(Mandatory)][object]$Session)

    if ((Get-OpenSessionMap).ContainsKey($Session.SessionId)) {
        return $script:Text.CannotDeleteLive
    }
    if (-not (Test-SessionFilePath -Path $Session.Path -SessionId $Session.SessionId)) {
        return $script:Text.InvalidDeletePath -f $Session.Path
    }
    $full = [System.IO.Path]::GetFullPath($Session.Path)
    $companionDir = Join-Path ([System.IO.Path]::GetDirectoryName($full)) $Session.SessionId
    try {
        if (Test-Path -LiteralPath $companionDir -PathType Container) {
            Move-SessionToRecycleBin -Path $companionDir
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Move-SessionToRecycleBin -Path $full
        }
        return $null
    } catch {
        return $script:Text.DeleteFailed -f $_.Exception.Message
    }
}

# ============================================================
# TUI
# ============================================================

function ConvertTo-PrintableText {
    <#
    Replaces control characters (C0, DEL and C1) with spaces before text is written to the
    terminal. Session names are generated from conversation content and the index cache can be
    edited, so an ESC in them would otherwise reach the terminal as an escape sequence (breaking
    the layout, or worse, such as OSC 52 writing the clipboard). A line break would also shift
    the rows.
    #>
    param([AllowNull()][string]$Text)
    return [regex]::Replace([string]$Text, '[\x00-\x1F\x7F-\x9F]', ' ')
}

function Test-AsciiOnly {
    <#
    Returns whether a string consists only of ASCII (half-width) characters.
    [System.Text.Ascii]::IsValid cannot be used: called from PowerShell, the argument binder
    resolves it to the IsValid(byte) overload and a string cannot be passed (confirmed by
    running it). Instead, compare the UTF-8 byte count with the character count.
    A single non-ASCII character takes 2 or more bytes in UTF-8, so the byte count exceeds it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [System.Text.Encoding]::UTF8.GetByteCount($Text) -eq $Text.Length
}

function Get-TextElementWidth {
    <#
    Returns the display width of one character (grapheme). 2 for full-width/CJK etc. and
    surrogate pairs, 1 otherwise.
    #>
    param([Parameter(Mandatory)][string]$Element)
    if ($Element.Length -ge 2 -and [char]::IsHighSurrogate($Element[0])) { return 2 }
    $codePoint = [int]$Element[0]
    foreach ($range in $script:WideCharRanges) {
        if ($codePoint -ge $range[0] -and $codePoint -le $range[1]) { return 2 }
    }
    return 1
}

function Get-TextElements {
    param([AllowEmptyString()][string]$Text)
    $elements = [System.Collections.Generic.List[string]]::new()
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) { $elements.Add([string]$enumerator.Current) }
    return , $elements
}

function Get-DisplayWidth {
    <#
    Returns how many columns a string occupies on the console. String.Length counts a
    full-width character as 1, so use this to align columns that contain Japanese.
    ASCII-only strings (most paths) return Length directly without enumerating graphemes.
    #>
    param([AllowEmptyString()][string]$Text)
    if (Test-AsciiOnly -Text $Text) { return $Text.Length }
    $width = 0
    foreach ($element in (Get-TextElements -Text $Text)) { $width += Get-TextElementWidth -Element $element }
    return $width
}

function Format-FixedWidth {
    <#
    Returns the string truncated or space-padded to exactly $Width display columns.
    By default the end is cut with '…'. With -KeepEnd the start is cut with '...' and the end
    kept (for paths). If a full-width character straddles the boundary, the leftover column
    is padded with a space.

    For ASCII-only strings the display width equals the character count, so the grapheme
    enumeration is skipped and only Length / Substring are used (fast path). When $Width is
    below 4, the '...' marker of -KeepEnd alone uses up the width and the boundary behavior
    of the grapheme version below becomes inconsistent, so such cases are excluded from the
    fast path and left to the original path.
    #>
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width,
        [switch]$KeepEnd
    )
    if ($Width -ge 4 -and (Test-AsciiOnly -Text $Text)) {
        $len = $Text.Length
        if ($len -le $Width) { return $Text + (' ' * ($Width - $len)) }
        if ($KeepEnd) {
            $marker = '...'
            $budget = $Width - $marker.Length
            return $marker + $Text.Substring($len - $budget)
        }
        # '…' is non-ASCII, but like the original implementation its display width is treated as 1.
        return $Text.Substring(0, $Width - 1) + '…'
    }

    $textWidth = Get-DisplayWidth -Text $Text
    if ($textWidth -le $Width) { return $Text + (' ' * ($Width - $textWidth)) }

    $elements = Get-TextElements -Text $Text
    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    if ($KeepEnd) {
        $marker = '...'
        $budget = $Width - $marker.Length
        for ($i = $elements.Count - 1; $i -ge 0; $i--) {
            $w = Get-TextElementWidth -Element $elements[$i]
            if ($used + $w -gt $budget) { break }
            [void]$builder.Insert(0, $elements[$i])
            $used += $w
        }
        $result = $marker + $builder.ToString()
    } else {
        $marker = '…'
        $budget = $Width - 1
        foreach ($element in $elements) {
            $w = Get-TextElementWidth -Element $element
            if ($used + $w -gt $budget) { break }
            [void]$builder.Append($element)
            $used += $w
        }
        $result = $builder.ToString() + $marker
    }
    return $result + (' ' * ($Width - (Get-DisplayWidth -Text $result)))
}

function Format-PathCell {
    <#
    Fits the path column into $Width columns. By default the end (the project name side) is
    kept and the start cut with '...'.
    Only when a search term matches in the part that would be cut off does it switch to a
    window containing the match, with '...' on both sides. This keeps the typed term from
    disappearing off screen and making it look as if the search had no effect.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Width,
        [AllowEmptyCollection()][string[]]$Terms = @()
    )

    $tail = Format-FixedWidth -Text $Path -Width $Width -KeepEnd
    if ($Terms.Count -eq 0) { return $tail }

    # If even one match is visible in the tail window, use it as is.
    foreach ($term in $Terms) {
        if ($tail.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $tail }
    }

    $matchIndex = -1
    foreach ($term in $Terms) {
        $i = $Path.IndexOf($term, [StringComparison]::OrdinalIgnoreCase)
        if ($i -ge 0 -and ($matchIndex -lt 0 -or $i -lt $matchIndex)) { $matchIndex = $i }
    }
    if ($matchIndex -lt 0) { return $tail }

    # Cut from a little before the match and put ellipses on both sides.
    $lead = '...'
    $start = [Math]::Max(0, $matchIndex - 4)
    $window = $Path.Substring($start)
    $body = Format-FixedWidth -Text $window -Width ($Width - $lead.Length)
    return $lead + $body
}

function Get-MatchRanges {
    <#
    Finds every match range [start, end) of each term in the plain text, then merges
    overlapping and adjacent ranges and returns them. The ranges index into the plain text,
    so no re-search is needed after ANSI codes are inserted.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Terms
    )
    $ranges = [System.Collections.Generic.List[int[]]]::new()
    foreach ($term in $Terms) {
        if (-not $term) { continue }
        $position = 0
        while ($true) {
            $found = $Text.IndexOf($term, $position, [StringComparison]::OrdinalIgnoreCase)
            if ($found -lt 0) { break }
            # Note: PowerShell parses @($a, $a + $b) as 3 elements ($a, $a, +$b).
            # $a + $b must be wrapped in parentheses to make it a single expression.
            $ranges.Add(@($found, ($found + $term.Length)))
            # Advance by one character, not past the match, so overlapping matches ('aa' in
            # 'aaa') are found too; the merge below joins them. Empty terms were skipped above,
            # so the loop always moves forward.
            $position = $found + 1
        }
    }
    if ($ranges.Count -eq 0) { return , @() }

    # A single-element output of Sort-Object is unwrapped to a scalar (foreach over an int[]
    # then iterates its ints individually), which fails with "Index was outside the bounds"
    # under StrictMode, so @() guarantees an array.
    $sorted = @($ranges | Sort-Object { $_[0] })
    $merged = [System.Collections.Generic.List[int[]]]::new()
    foreach ($range in $sorted) {
        if ($merged.Count -gt 0 -and $range[0] -le $merged[-1][1]) {
            $merged[-1][1] = [Math]::Max($merged[-1][1], $range[1])
        } else {
            $merged.Add($range)
        }
    }
    return , $merged
}

function Add-MatchHighlight {
    <#
    Colors the parts of a cell string that match the search terms. All match ranges are
    computed on the plain text first and the result is assembled in one pass, so a later term
    can never match a fragment of an ANSI escape inserted for an earlier one (for example a
    lone 'm') and break it. ANSI codes have no display width, so columns do not shift either.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowEmptyCollection()][string[]]$Terms = @()
    )
    if ($Terms.Count -eq 0) { return $Text }
    $ranges = Get-MatchRanges -Text $Text -Terms $Terms
    if ($ranges.Count -eq 0) { return $Text }

    # Underlined rather than colored, so a match is not mistaken for a status color (the
    # yellow of "waiting" in particular) on the same row.
    $highlight = $script:Ansi.Underline
    $reset = $script:Ansi.Reset
    $builder = [System.Text.StringBuilder]::new()
    $position = 0
    foreach ($range in $ranges) {
        [void]$builder.Append($Text.Substring($position, $range[0] - $position))
        [void]$builder.Append($highlight).Append($Text.Substring($range[0], $range[1] - $range[0])).Append($reset)
        $position = $range[1]
    }
    [void]$builder.Append($Text.Substring($position))
    return $builder.ToString()
}

function Get-SessionColumnWidths {
    <#
    Computes the widths of the session name and directory path columns from the screen width.
    Session names measured at most 36 columns, so they get a cap and the rest all goes to the
    directory path column.
    On narrow screens the space is split in half as before; the cap only matters on wide ones.
    A line exactly as wide as the screen may wrap in some terminals, so one column is left spare.
    #>
    $width = try { [Console]::WindowWidth } catch { 100 }
    # Selection marker "> " (2) + status column + status/name gap (1) + name/date gap (1)
    # + date column + date/path gap (2) + spare column against wrapping (1)
    $fixedWidth = 2 + $script:StatusColumnWidth + 1 + 1 + $script:Config.DateColumnWidth + 2 + 1
    $remaining = [Math]::Max(40, $width - $fixedWidth)
    $titleWidth = [Math]::Min($script:Config.TitleMaxWidth,
        [Math]::Max($script:Config.TitleMinWidth, [int]($remaining / 2)))
    $pathWidth = [Math]::Max($script:Config.PathMinWidth, $remaining - $titleWidth)
    return [pscustomobject]@{ Title = $titleWidth; Path = $pathWidth }
}

function Get-StatusCell {
    <#
    Returns the state of a running session as [display label, $script:Ansi.Foreground color name].
    An empty label if the session is not running. An unknown status is shown as the "running"
    label without color.
    #>
    param([AllowNull()][object]$OpenEntry)
    if (-not $OpenEntry) { return @('', $null) }
    $status = $OpenEntry.Status
    if ($status -and $script:Text.StatusLabels.ContainsKey($status)) {
        return @($script:Text.StatusLabels[$status], $script:Config.StatusColors[$status])
    }
    return @($script:Text.UnknownStatusLabel, $null)
}

function Format-SessionRow {
    <#
    Returns one row as a string with ANSI escapes. The selected row is shown fully inverted;
    other rows color only the status cell with the status color.
    A positive -HiddenCount appends ' (+N)' to the session name. The name is truncated to make
    room for it, so the count stays visible however long the name is, and only the name part is
    highlighted so a search term like '3' does not color the count.
    -Pinned puts '*' in the second column of the selection marker, which is otherwise blank, so
    the column widths do not change.
    #>
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Widths,
        [AllowNull()][object]$OpenEntry,
        [AllowEmptyCollection()][string[]]$Terms = @(),
        [int]$HiddenCount = 0,
        [switch]$Pinned,
        [switch]$Selected
    )

    $label, $colorName = Get-StatusCell -OpenEntry $OpenEntry
    $status = Format-FixedWidth -Text $label -Width $script:StatusColumnWidth
    $title = if ($Session.Title) { ConvertTo-PrintableText -Text $Session.Title } else { '(unnamed)' }
    $badge = if ($HiddenCount -gt 0) { " (+$HiddenCount)" } else { '' }
    $titleBody = Format-FixedWidth -Text $title -Width ([Math]::Max(1, $Widths.Title - $badge.Length))
    $titleCell = $titleBody + $badge
    $pathCell = Format-PathCell -Path (ConvertTo-PrintableText -Text $Session.Cwd) -Width $Widths.Path -Terms $Terms
    $dateCell = Format-FixedWidth -Text $Session.Modified.ToString($script:Config.DateFormat) `
        -Width $script:Config.DateColumnWidth

    $reset = $script:Ansi.Reset
    $pinMark = if ($Pinned) { '*' } else { ' ' }
    if ($Selected) {
        # Another color on top of the inverted row is hard to read, so the selected row is not highlighted.
        return "$($script:Ansi.Foreground.Black)$($script:Ansi.Background.Cyan)>$pinMark$status $titleCell $dateCell  $pathCell$reset"
    }

    $body = '{0} {1}  {2}' -f `
        ((Add-MatchHighlight -Text $titleBody -Terms $Terms) + $badge),
        $dateCell,
        (Add-MatchHighlight -Text $pathCell -Terms $Terms)
    $statusColored = if ($colorName) { "$($script:Ansi.Foreground[$colorName])$status$reset" } else { $status }
    return " $pinMark$statusColored $body"
}

function Get-SearchTerms {
    <#
    Splits the search string into whitespace-separated terms. Only sessions matching all
    terms are kept (AND search).
    #>
    param([AllowEmptyString()][string]$Filter)
    if (-not $Filter) { return , @() }
    return , @($Filter -split '\s+' | Where-Object { $_ })
}

function Test-SessionMatch {
    <#
    Checks case-insensitively whether each term appears in either the session name or the
    working directory.
    IndexOf is used instead of -like so that '[' and '*' are treated as literal characters
    rather than wildcards.
    #>
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Terms
    )
    foreach ($term in $Terms) {
        $inTitle = $Session.Title -and $Session.Title.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $inPath = $Session.Cwd -and $Session.Cwd.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if (-not ($inTitle -or $inPath)) { return $false }
    }
    return $true
}

function Find-SessionIndexById {
    <#
    Finds a position by SessionId so the selected session is not lost when rebuilding the
    index reorders the list. When the session is not in the list (hidden by the latest per
    directory view) and -Cwd is given, the first row of the same directory is used instead.
    If neither is found, returns -Fallback clamped to the valid range.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [AllowNull()][AllowEmptyString()][string]$SessionId,
        [AllowNull()][AllowEmptyString()][string]$Cwd,
        [int]$Fallback = 0
    )
    if ($SessionId) {
        for ($i = 0; $i -lt $Sessions.Count; $i++) {
            if ($Sessions[$i].SessionId -eq $SessionId) { return $i }
        }
    }
    if ($Cwd) {
        $directoryKey = Get-DirectoryKey -Cwd $Cwd
        for ($i = 0; $i -lt $Sessions.Count; $i++) {
            if ((Get-DirectoryKey -Cwd $Sessions[$i].Cwd) -eq $directoryKey) { return $i }
        }
    }
    return [Math]::Max(0, [Math]::Min($Fallback, $Sessions.Count - 1))
}

function Test-RecentLaunch {
    <#
    Decides whether $Key (a session ID or a working directory) was launched less than $GraceMs
    ago, given a table of key -> launch time (UTC) kept by Show-SessionMenu.
    Used to hold back a second launch or a delete in the gap before a new session records
    itself as running.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Launches,
        [AllowNull()][AllowEmptyString()][string]$Key,
        [Parameter(Mandatory)][int]$GraceMs,
        [Parameter(Mandatory)][datetime]$Now
    )
    if (-not $Key -or -not $Launches.ContainsKey($Key)) { return $false }
    return ($Now - $Launches[$Key]).TotalMilliseconds -lt $GraceMs
}

function Get-FilteredSessions {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [AllowEmptyString()][string]$Filter
    )
    $terms = Get-SearchTerms -Filter $Filter
    if ($terms.Count -eq 0) { return , $Sessions }
    return , @($Sessions | Where-Object { Test-SessionMatch -Session $_ -Terms $terms })
}

function Get-DirectoryKey {
    <#
    Returns the key that decides whether two sessions share a working directory. Windows paths
    ignore case, and the recorded cwd may use '/' or end with a separator, so those differences
    are normalized away ('' for a missing cwd). Symbolic links are not resolved.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Cwd)
    if (-not $Cwd) { return '' }
    return $Cwd.Replace('/', '\').TrimEnd('\').ToUpperInvariant()
}

function Get-LatestPerDirectory {
    <#
    Reduces a list sorted newest first to the latest session of each directory, keeping every
    session in $KeepIds as well (running ones, so one waiting for input is never hidden, and
    pinned ones). The order of the input is kept.
    Returns @{ Sessions = rows to show; HiddenCounts = representative SessionId -> number of
    sessions of its directory left out }. The counts are kept apart from the rows so the rows
    stay plain session objects, as everywhere else in the list.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory)][hashtable]$KeepIds
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $hiddenCounts = @{}
    # Directory key -> SessionId of its representative (latest) row.
    $representatives = @{}
    foreach ($session in $Sessions) {
        $key = Get-DirectoryKey -Cwd $session.Cwd
        if (-not $representatives.ContainsKey($key)) {
            $representatives[$key] = $session.SessionId
            $hiddenCounts[$session.SessionId] = 0
            $rows.Add($session)
        } elseif ($KeepIds.ContainsKey($session.SessionId)) {
            $rows.Add($session)
        } else {
            $hiddenCounts[$representatives[$key]]++
        }
    }
    return @{ Sessions = $rows.ToArray(); HiddenCounts = $hiddenCounts }
}

function Get-DirectoryDeleteTargets {
    <#
    Picks the sessions Ctrl+D deletes at once in the latest per directory view: those of
    $Sessions (the search results) that share the working directory $Cwd, except running and
    pinned ones. Returns @{ Targets = sessions to delete; ExcludedCount = sessions of the
    directory left out as running or pinned }.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [AllowNull()][AllowEmptyString()][string]$Cwd,
        [Parameter(Mandatory)][hashtable]$RunningIds,
        [Parameter(Mandatory)][hashtable]$PinnedIds
    )
    $key = Get-DirectoryKey -Cwd $Cwd
    $targets = [System.Collections.Generic.List[object]]::new()
    $excluded = 0
    foreach ($session in $Sessions) {
        if ((Get-DirectoryKey -Cwd $session.Cwd) -ne $key) { continue }
        if ($RunningIds.ContainsKey($session.SessionId) -or $PinnedIds.ContainsKey($session.SessionId)) {
            $excluded++
        } else {
            $targets.Add($session)
        }
    }
    return @{ Targets = $targets.ToArray(); ExcludedCount = $excluded }
}

function Get-PinnedIds {
    <#
    Reads the pinned session IDs from PinsPath as a SessionId -> $true table. A missing or
    unreadable file means no pins: losing them is an inconvenience, while failing to start
    would lock the user out of the list.
    #>
    $ids = @{}
    if (-not (Test-Path -LiteralPath $script:Config.PinsPath -PathType Leaf)) { return $ids }
    try {
        $raw = [System.IO.File]::ReadAllText($script:Config.PinsPath) | ConvertFrom-Json
        foreach ($id in @($raw)) {
            if (Test-SessionId -SessionId $id) { $ids[[string]$id] = $true }
        }
    } catch { }
    return $ids
}

function Save-PinnedIds {
    <#
    Writes the pinned session IDs to PinsPath as a JSON array. UTF-8 without BOM, for the same
    reason as the index cache. Throws on failure; the caller turns it into a notice.
    -InputObject keeps a single ID an array (piping would unwrap it to a bare string).
    #>
    param([Parameter(Mandatory)][hashtable]$PinnedIds)
    $dir = [System.IO.Path]::GetDirectoryName($script:Config.PinsPath)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($PinnedIds.Keys | Sort-Object)
    [System.IO.File]::WriteAllText($script:Config.PinsPath, [string]$json, [System.Text.UTF8Encoding]::new($false))
}

function Remove-OrphanedPins {
    <#
    Drops pins whose session is no longer in the index (deleted outside this tool or aged out
    by Claude Code's cleanup), so pins.json does not keep growing. Returns whether anything
    was dropped, so the caller saves only then.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$PinnedIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions
    )
    # An empty index more likely means ProjectsDir could not be read than that every session
    # is gone, so the pins are kept for the next start.
    if ($Sessions.Count -eq 0) { return $false }
    $known = Get-SessionIdSet -Sessions $Sessions
    $orphans = @($PinnedIds.Keys | Where-Object { -not $known.ContainsKey($_) })
    foreach ($id in $orphans) { $PinnedIds.Remove($id) }
    return $orphans.Count -gt 0
}

function Get-PinnedFirst {
    <#
    Moves pinned sessions to the top, keeping the input order (newest first) within the pinned
    and within the other sessions.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory)][hashtable]$PinnedIds
    )
    if ($PinnedIds.Count -eq 0) { return , $Sessions }
    $pinned = [System.Collections.Generic.List[object]]::new()
    $others = [System.Collections.Generic.List[object]]::new()
    foreach ($session in $Sessions) {
        if ($PinnedIds.ContainsKey($session.SessionId)) { $pinned.Add($session) } else { $others.Add($session) }
    }
    $pinned.AddRange($others)
    return , $pinned.ToArray()
}

function Get-RunningIds {
    <#
    Returns the sessions treated as running in the latest per directory view, as a
    SessionId -> $true table: those recorded in $OpenMap and those opened with Enter less than
    LaunchGraceMs ago that have not recorded themselves yet.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$OpenMap,
        [Parameter(Mandatory)][hashtable]$Launches,
        [Parameter(Mandatory)][datetime]$Now
    )
    $ids = @{}
    foreach ($id in $OpenMap.Keys) { $ids[[string]$id] = $true }
    foreach ($id in $Launches.Keys) {
        if (Test-RecentLaunch -Launches $Launches -Key $id -GraceMs $script:Config.LaunchGraceMs -Now $Now) {
            $ids[[string]$id] = $true
        }
    }
    return $ids
}

# Lines of a frame other than the list rows: title, blank line, search, notice, column header
# and rule above the list; the rule with the counts and the two key help lines below it. The preview
# block comes on top of these when the screen has room for it (see Test-PreviewVisible).
$script:FrameFixedLines = 9

# Lines of the last prompt in the preview block, and of the whole block: its heading, the
# prompt, and the rule that closes it above the key help.
$script:PreviewBodyLines = 2
$script:PreviewLines = $script:PreviewBodyLines + 2

# Lines always kept for the key help (see Get-KeyHelpLines).
$script:KeyHelpLines = 2

function Get-KeyHelpLines {
    <#
    Wraps the key help into exactly KeyHelpLines lines of at most $Width columns. The text is
    split into items at runs of two spaces, and an item is never broken across lines. Lines
    left over are blank, so the frame has the same number of lines at every width and the
    list never moves up or down on a resize. What does not fit even then is truncated on the
    last line, so the items that come first in KeyHelp are the ones kept on a narrow screen.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    $separator = '  '
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($item in ($Text -split ' {2,}' | Where-Object { $_ })) {
        $candidate = if ($current) { $current + $separator + $item } else { $item }
        if (-not $current -or (Get-DisplayWidth -Text $candidate) -le $Width -or
            $lines.Count -eq $script:KeyHelpLines - 1) {
            $current = $candidate
        } else {
            $lines.Add($current)
            $current = $item
        }
    }
    $lines.Add($current)
    while ($lines.Count -lt $script:KeyHelpLines) { $lines.Add('') }
    return , @($lines | ForEach-Object { (Format-FixedWidth -Text $_ -Width $Width).TrimEnd() })
}

function Split-DisplayLines {
    <#
    Wraps $Text into exactly $MaxLines lines of at most $Width display columns. A break that
    would fall inside a word (a run of printable ASCII other than space) moves back to the
    start of that word, so an English prompt or a command name is not cut in two. Japanese
    text breaks at any character, and a word as wide as the whole line is broken where it
    must be. What does not fit on the last line is cut with '…'.
    Lines left over are '', so the caller always gets the same number of lines and the frame
    keeps its height.
    #>
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$MaxLines
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $rest = $Text
    while ($rest -and $lines.Count -lt $MaxLines - 1 -and (Get-DisplayWidth -Text $rest) -gt $Width) {
        # Length (in UTF-16 units) of the longest head of $rest that fits in $Width columns.
        # At least one character is taken, so the loop always moves forward.
        $cut = 0
        $used = 0
        foreach ($element in (Get-TextElements -Text $rest)) {
            $elementWidth = Get-TextElementWidth -Element $element
            if ($cut -gt 0 -and $used + $elementWidth -gt $Width) { break }
            $cut += $element.Length
            $used += $elementWidth
        }
        $wordStart = $cut
        while ($wordStart -gt 0 -and $rest[$wordStart - 1] -match '[!-~]') { $wordStart-- }
        if ($rest[$cut] -match '[!-~]' -and $wordStart -gt 0) { $cut = $wordStart }
        $lines.Add($rest.Substring(0, $cut).TrimEnd())
        $rest = $rest.Substring($cut).TrimStart()
    }
    if ($rest) { $lines.Add((Format-FixedWidth -Text $rest -Width $Width).TrimEnd()) }
    while ($lines.Count -lt $MaxLines) { $lines.Add('') }
    return , $lines.ToArray()
}

function Get-ConsoleHeight {
    try { [Console]::WindowHeight } catch { 30 }
}

function Test-PreviewVisible {
    <#
    Decides whether a screen $Height lines tall shows the preview block: only when the fixed
    lines, the preview block and at least one list row all fit, so on a very short screen the
    list keeps its row. Get-PageSizeForHeight and Get-SessionFrame both decide by this, so
    the row count and the drawn frame always agree.
    #>
    param([Parameter(Mandatory)][int]$Height)
    return $Height -ge $script:FrameFixedLines + $script:PreviewLines + 1
}

function Get-PageSizeForHeight {
    <#
    Returns how many list rows fit on a screen $Height lines tall, capped by PageSize.
    At least one row is always shown. A screen too short even for that overflows, but a
    frame without any row would be useless, and such a height is not usable anyway.
    #>
    param([Parameter(Mandatory)][int]$Height)
    $fixedLines = $script:FrameFixedLines + $(if (Test-PreviewVisible -Height $Height) { $script:PreviewLines } else { 0 })
    return [Math]::Max(1, [Math]::Min($script:Config.PageSize, $Height - $fixedLines))
}

function Get-VisiblePageSize {
    # On a short screen, reduce the row count so that the fixed lines fit as well.
    return Get-PageSizeForHeight -Height (Get-ConsoleHeight)
}

function Get-SearchCursorColumn {
    <#
    Returns the cursor column (1-based) on the search line: the display width of the label
    plus that of the search term.
    Full-width characters in the search term would throw off a character count, so display
    width is measured with Get-DisplayWidth.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Filter
    )
    return (Get-DisplayWidth -Text $Label) + (Get-DisplayWidth -Text $Filter) + 1
}

function Get-OpenMapSignature {
    <#
    A signature for cheaply telling whether the set of running sessions changed since last time.
    Concatenates only the sessionId and status used for display, in key order (Pid is not
    shown, so it is left out). Sorting is explicit so the signature does not depend on
    enumeration order and stays the same even if the hashtable's iteration order changes.
    #>
    param([Parameter(Mandatory)][hashtable]$OpenMap)
    if ($OpenMap.Count -eq 0) { return '' }
    $parts = foreach ($key in ($OpenMap.Keys | Sort-Object)) {
        '{0}={1}' -f $key, $OpenMap[$key].Status
    }
    return $parts -join ';'
}

function Get-FrameSignature {
    <#
    Builds a signature string from every input that determines the output of Get-SessionFrame.
    Matching signatures should mean an identical screen, so Show-SessionMenu uses this to skip
    calling Get-SessionFrame altogether. Forgetting to add an input here causes a subtle
    "screen does not update" bug, so the inputs correspond one to one with the parameters of
    Get-SessionFrame and the external state it reads (console size).

    The contents of $Filtered, $HiddenCounts and $PinnedIds are not included. Show-SessionMenu
    bumps SessionsRevision every time it recomputes them (Ctrl+R, deletion, the search term,
    the view mode, a pin, or a change in the running sessions), so the revision distinguishes them.
    #>
    param(
        [AllowEmptyString()][string]$Filter,
        [Parameter(Mandatory)][int]$SelectedIndex,
        [Parameter(Mandatory)][int]$TopIndex,
        [Parameter(Mandatory)][int]$PageSize,
        [Parameter(Mandatory)][int]$TotalCount,
        [Parameter(Mandatory)][int]$FilteredCount,
        [AllowEmptyString()][string]$Notice,
        [Parameter(Mandatory)][string]$ConsoleSize,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OpenMapSignature,
        [Parameter(Mandatory)][int]$SessionsRevision,
        [Parameter(Mandatory)][bool]$LatestPerDirectory,
        [AllowEmptyString()][string]$PreviewText
    )
    # Notice is typed [string], so $null becomes '' already at parameter binding (the -Notice
    # parameter of Get-SessionFrame has the same type and conversion, and rendering uses
    # if ($Notice) {...} else {''}, which does not distinguish $null from '').
    # So no distinction is made here either (confirmed by testing). The same goes for PreviewText.
    return @(
        $Filter, $SelectedIndex, $TopIndex, $PageSize, $TotalCount, $FilteredCount,
        $Notice, $ConsoleSize, $OpenMapSignature, $SessionsRevision, $LatestPerDirectory, $PreviewText
    ) -join '|'
}

# Dashes kept after the label of a rule drawn by Format-RuleWithLabel, so the label reads as
# set into the rule rather than ending it.
$script:RuleLabelTailWidth = 2

function Format-RuleWithLabel {
    <#
    Returns a gray rule exactly $Width columns wide with $Label set into its right end
    ('------ label --'). The label keeps the normal color, since it is information to read.
    A label too wide for the rule is truncated, and on a screen too narrow even for that the
    plain rule is returned. Widths are display widths, so a Japanese label lines up as well.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory)][int]$Width
    )
    $dim = $script:Ansi.Foreground.BrightBlack
    $reset = $script:Ansi.Reset
    # One dash before the label, a space on each side of it, and the tail.
    $room = $Width - 1 - 2 - $script:RuleLabelTailWidth
    if (-not $Label -or $room -lt 1) { return "$dim$('-' * [Math]::Max(0, $Width))$reset" }
    $text = $Label
    if ((Get-DisplayWidth -Text $text) -gt $room) { $text = (Format-FixedWidth -Text $text -Width $room).TrimEnd() }
    $head = $Width - (Get-DisplayWidth -Text $text) - 2 - $script:RuleLabelTailWidth
    return "$dim$('-' * $head)$reset $text $dim$('-' * $script:RuleLabelTailWidth)$reset"
}

function Get-SessionFrame {
    <#
    Assembles one full screen as a single string. Clearing everything with Clear-Host flickers,
    so the cursor is moved to the top-left and the screen overwritten, erasing the rest of each
    line and of the screen.
    An escape sequence at the end moves the cursor back to the search field. It is part of the
    string compared for differential drawing, so it naturally follows only when the search
    term changes.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Filtered,
        [Parameter(Mandatory)][int]$TotalCount,
        [Parameter(Mandatory)][hashtable]$OpenMap,
        [AllowEmptyString()][string]$Filter,
        [Parameter(Mandatory)][int]$SelectedIndex,
        [Parameter(Mandatory)][int]$TopIndex,
        [Parameter(Mandatory)][int]$PageSize,
        [AllowNull()][string]$Notice = $null,
        # SessionId -> number of hidden sessions, from Get-LatestPerDirectory.
        [hashtable]$HiddenCounts = @{},
        [switch]$LatestPerDirectory,
        # Last prompt of the selected session, shown on the preview line.
        [AllowNull()][string]$PreviewText = $null,
        # SessionId -> $true for pinned sessions, from Get-PinnedIds.
        [hashtable]$PinnedIds = @{}
    )

    $esc = [char]27
    $eraseLine = "$esc[K"
    $widths = Get-SessionColumnWidths
    $ruleWidth = 2 + $script:StatusColumnWidth + 1 + $widths.Title + 1 + `
        $script:Config.DateColumnWidth + 2 + $widths.Path
    # Gray is used only for the rules and the search placeholder. The header, counts and key
    # help are information to read, so they use the normal color.
    $dim = $script:Ansi.Foreground.BrightBlack
    $reset = $script:Ansi.Reset
    $label = $script:Text.SearchLabel

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$($script:Ansi.Foreground.Cyan)Claude Code Session Manager$reset")
    $lines.Add('')

    # The search line is always shown at the top (it never moves with notices or the number of
    # matches). When empty it shows a placeholder so it reads as an input field, and the real
    # terminal cursor is used.
    $searchBody = if ($Filter) { $Filter } else { "$dim$($script:Text.SearchPlaceholder)$reset" }
    $lines.Add("$($script:Ansi.Foreground.Yellow)$label$reset$searchBody")
    $cursorLine = $lines.Count
    $cursorColumn = Get-SearchCursorColumn -Label $label -Filter $Filter

    # Dedicated notice line, right below the search line. Kept as a blank line when there is no
    # notice, which also keeps the column header apart from the search line, so the list rows
    # never shift up or down. A long message (one containing a path, etc.) would wrap and push
    # lines down, so it is truncated to the rule width.
    $lines.Add($(if ($Notice) {
        "$($script:Ansi.Foreground.Yellow)$((Format-FixedWidth -Text "! $(ConvertTo-PrintableText -Text $Notice)" -Width $ruleWidth).TrimEnd())$reset"
    } else { '' }))

    $last = [Math]::Min($TopIndex + $PageSize, $Filtered.Count)
    $header = '  {0} {1} {2}  {3}' -f `
        (Format-FixedWidth -Text $script:Text.HeaderStatus -Width $script:StatusColumnWidth),
        (Format-FixedWidth -Text $script:Text.HeaderTitle -Width $widths.Title),
        (Format-FixedWidth -Text $script:Text.HeaderDate -Width $script:Config.DateColumnWidth),
        $script:Text.HeaderPath
    $lines.Add("$($script:Ansi.Bold)$header$reset")
    # The rule above the list carries the current view at its right end, and the rule below it
    # the counts: what the list is at its top, how much of it there is at its bottom.
    $modeLabel = if ($LatestPerDirectory) { $script:Text.ModeLatestPerDirectory } else { $script:Text.ModeAll }
    $lines.Add((Format-RuleWithLabel -Label $modeLabel -Width $ruleWidth))

    $terms = Get-SearchTerms -Filter $Filter
    for ($i = $TopIndex; $i -lt $last; $i++) {
        $session = $Filtered[$i]
        $openEntry = if ($OpenMap.ContainsKey($session.SessionId)) { $OpenMap[$session.SessionId] } else { $null }
        $hiddenCount = if ($HiddenCounts.ContainsKey($session.SessionId)) { $HiddenCounts[$session.SessionId] } else { 0 }
        $lines.Add((Format-SessionRow -Session $session -Widths $widths -OpenEntry $openEntry `
            -Terms $terms -HiddenCount $hiddenCount -Pinned:($PinnedIds.ContainsKey($session.SessionId)) `
            -Selected:($i -eq $SelectedIndex)))
    }
    if ($Filtered.Count -eq 0) { $lines.Add("  $($script:Text.NoMatch)") }

    $range = if ($Filtered.Count -gt 0) { '{0}-{1}' -f ($TopIndex + 1), $last } else { '0' }
    $countLabel = $script:Text.CountLine -f $range, $Filtered.Count, $TotalCount
    $lines.Add((Format-RuleWithLabel -Label $countLabel -Width $ruleWidth))

    $rule = "$dim$('-' * $ruleWidth)$reset"
    # The preview block: the last prompt of the selected session, right below the list. Its
    # heading starts with a '>' in the color of the selected row, to tie the block to that row.
    # Only the label is gray: the prompt itself is information to read. Line breaks and runs of
    # spaces in the prompt are collapsed, and it is wrapped into PreviewBodyLines lines. The
    # block has the same height whatever the prompt, so the key help does not move up and down
    # while selecting. Its closing rule belongs to the block, so hiding the block on a short
    # screen leaves a single rule above the key help.
    if (Test-PreviewVisible -Height (Get-ConsoleHeight)) {
        $lines.Add("$($script:Ansi.Foreground.Cyan)>$reset $dim$($script:Text.PreviewLabel)$reset")
        $preview = ((ConvertTo-PrintableText -Text $PreviewText) -replace '\s+', ' ').Trim()
        $bodyLines = if ($preview) {
            Split-DisplayLines -Text $preview -Width ($ruleWidth - 2) -MaxLines $script:PreviewBodyLines
        } else {
            # A blank block would look like a drawing failure, so say there is nothing.
            @("$dim$($script:Text.PreviewEmpty)$reset") + @('') * ($script:PreviewBodyLines - 1)
        }
        foreach ($bodyLine in $bodyLines) { $lines.Add($(if ($bodyLine) { "  $bodyLine" } else { '' })) }
        $lines.Add($rule)
    }

    # Wrapped and truncated to the rule width: a key help wider than the screen would wrap on
    # its own and scroll the frame.
    foreach ($helpLine in (Get-KeyHelpLines -Text $script:Text.KeyHelp -Width $ruleWidth)) { $lines.Add($helpLine) }

    # A newline after the last line would scroll by one line when the screen is exactly that
    # tall, so none is written.
    return "$esc[H" + (($lines | ForEach-Object { "$_$eraseLine" }) -join "`n") + "$esc[J" + `
        "$esc[$cursorLine;${cursorColumn}H"
}

function Get-ConsoleSizeKey {
    <#
    Returns the console window size as 'WIDTHxHEIGHT', or '' when it cannot be read.
    #>
    try { '{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight } catch { '' }
}

function Show-SessionMenu {
    <#
    The interactive loop of the list. It does not block waiting for keys; while watching
    KeyAvailable it re-reads the state of running sessions every RefreshIntervalMs (never when it
    is 0). Enter and Ctrl+D re-read it right before deciding, so they never act on a stale state
    such as a session started after the last poll. The wait also watches the window size, so a
    resize is redrawn right away regardless of RefreshIntervalMs. Assembling
    the screen is skipped entirely (Get-SessionFrame is not called) while the signature built
    from every input that determines the view (Get-FrameSignature) matches the previous one.
    As a guard against inputs missing from the signature, the frame is rebuilt at least once
    every ForcedRedrawIntervalMs even when it matches.
    When a frame is actually assembled, it is still compared with the previous string before
    being written, as before.
    All keys in the buffer are processed together, followed by a single redraw.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions)

    $esc = [char]27
    $filter = ''
    $selectedIndex = 0
    $topIndex = 0
    $openMap = Get-OpenSessionMap
    $openMapSignature = Get-OpenMapSignature -OpenMap $openMap
    $lastPoll = [DateTime]::UtcNow
    $autoRefresh = $script:Config.RefreshIntervalMs -gt 0
    $lastFrame = ''
    $lastFrameSignature = ''
    $lastForcedRedraw = [DateTime]::UtcNow
    $lastSize = ''
    $sessionsRevision = 0
    $latestPerDirectory = [bool]$script:Config.LatestPerDirectory
    $filtered = @()
    $hiddenCounts = @{}
    $runningSignature = ''
    $notice = $null
    $noticeExpiry = [DateTime]::MinValue
    # Sessions awaiting delete confirmation after Ctrl+D (an array: one session, or a whole
    # directory in the latest per directory view). While pending, the question stays on the notice line.
    $pendingDelete = $null
    # Set by Esc on an empty search. The next key decides: Esc quits, anything else cancels.
    # While set, the prompt stays on the notice line, as with $pendingDelete.
    $quitArmed = $false
    # Launch time (UTC) of sessions opened with Enter, by session ID, and of new sessions
    # started with Ctrl+N, by working directory. See LaunchGraceMs / NewSessionGraceMs.
    $recentLaunches = @{}
    $recentNewSessions = @{}
    # Time (UTC) a background session was last attached to with Enter, by session ID. Kept apart
    # from $recentLaunches, whose entries are dropped as soon as the session shows up as running
    # (a background session already does).
    $recentAttaches = @{}
    # IDs in $Sessions, to spot running sessions that are not listed yet, and the poll time they
    # were last checked against (MinValue: check on the first pass).
    $knownIds = Get-SessionIdSet -Sessions $Sessions
    $lastNewSessionCheck = [DateTime]::MinValue
    $clearScreen = "$esc[2J$esc[H"
    # Pinned sessions (Ctrl+P). Pins of sessions that are gone are dropped up front; a failure to
    # save that only matters to pins.json, so it is ignored here and retried on the next pin.
    $pinnedIds = Get-PinnedIds
    if (Remove-OrphanedPins -PinnedIds $pinnedIds -Sessions $Sessions) {
        try { Save-PinnedIds -PinnedIds $pinnedIds } catch { }
    }

    # Recomputes the rows to show from $Sessions, the search term, the view mode and the pins. Always
    # dot-sourced (. $updateView): invoked with & it would run in a child scope and its
    # assignments to $filtered etc. would never reach this function.
    $updateView = {
        $matched = Get-FilteredSessions -Sessions $Sessions -Filter $filter
        $runningIds = Get-RunningIds -OpenMap $openMap -Launches $recentLaunches -Now ([DateTime]::UtcNow)
        $runningSignature = @($runningIds.Keys | Sort-Object) -join ';'
        if ($latestPerDirectory) {
            $keepIds = $runningIds.Clone()
            foreach ($id in $pinnedIds.Keys) { $keepIds[$id] = $true }
            $view = Get-LatestPerDirectory -Sessions $matched -KeepIds $keepIds
            $filtered = $view.Sessions
            $hiddenCounts = $view.HiddenCounts
        } else {
            $filtered = $matched
            $hiddenCounts = @{}
        }
        $filtered = Get-PinnedFirst -Sessions $filtered -PinnedIds $pinnedIds
        $sessionsRevision++
    }
    . $updateView

    try {
        while ($true) {
            $pageSize = Get-VisiblePageSize

            # Temporary notices (such as the message for manually opened windows) are cleared
            # when they expire. Not while a delete or quit confirmation is pending.
            $holdNotice = $pendingDelete -or $quitArmed
            if ($notice -and -not $holdNotice -and [DateTime]::UtcNow -ge $noticeExpiry) { $notice = $null }

            # Clamp the selection and the first visible row to the filtered results.
            if ($selectedIndex -ge $filtered.Count) { $selectedIndex = [Math]::Max(0, $filtered.Count - 1) }
            if ($selectedIndex -lt $topIndex) { $topIndex = $selectedIndex }
            if ($selectedIndex -ge $topIndex + $pageSize) { $topIndex = $selectedIndex - $pageSize + 1 }
            $topIndex = [Math]::Max(0, [Math]::Min($topIndex, [Math]::Max(0, $filtered.Count - $pageSize)))

            # After a window resize, overwriting leaves remnants of the previous frame, so clear once.
            $size = Get-ConsoleSizeKey
            # Cleared with an escape sequence rather than Clear-Host, which on Windows PowerShell 5.1
            # goes through the console API and could wipe the main screen buffer that Main
            # switched away from.
            if ($size -ne $lastSize) {
                [Console]::Write($clearScreen)
                $lastSize = $size
                $lastFrame = ''
                $lastFrameSignature = ''
            }

            $previewText = if ($filtered.Count -gt 0) { $filtered[$selectedIndex].LastPrompt } else { '' }
            $frameSignature = Get-FrameSignature -Filter $filter -SelectedIndex $selectedIndex `
                -TopIndex $topIndex -PageSize $pageSize -TotalCount $Sessions.Count `
                -FilteredCount $filtered.Count -Notice $notice -ConsoleSize $size `
                -OpenMapSignature $openMapSignature -SessionsRevision $sessionsRevision `
                -LatestPerDirectory $latestPerDirectory -PreviewText $previewText
            $forceRedraw = ([DateTime]::UtcNow - $lastForcedRedraw).TotalMilliseconds -ge $script:Config.ForcedRedrawIntervalMs
            if ($frameSignature -ne $lastFrameSignature -or $forceRedraw) {
                $frame = Get-SessionFrame -Filtered $filtered -TotalCount $Sessions.Count -OpenMap $openMap `
                    -Filter $filter -SelectedIndex $selectedIndex -TopIndex $topIndex -PageSize $pageSize -Notice $notice `
                    -HiddenCounts $hiddenCounts -LatestPerDirectory:$latestPerDirectory -PreviewText $previewText `
                    -PinnedIds $pinnedIds
                if ($frame -ne $lastFrame) {
                    # Hide the cursor only while drawing. Show it again afterwards; the escape
                    # sequence at the end of the frame puts it at the input position of the search field.
                    [Console]::Write("$esc[?25l$frame$esc[?25h")
                    $lastFrame = $frame
                }
                $lastFrameSignature = $frameSignature
                $lastForcedRedraw = [DateTime]::UtcNow
            }

            # Wait until a key arrives, the window is resized, or it is time to re-read the state
            # or clear the notice.
            while (-not [Console]::KeyAvailable) {
                if ((Get-ConsoleSizeKey) -ne $lastSize) { break }
                if ($autoRefresh -and ([DateTime]::UtcNow - $lastPoll).TotalMilliseconds -ge $script:Config.RefreshIntervalMs) { break }
                if ($notice -and -not $holdNotice -and [DateTime]::UtcNow -ge $noticeExpiry) { break }
                Start-Sleep -Milliseconds $script:Config.KeyPollIntervalMs
            }
            if ($autoRefresh -and ([DateTime]::UtcNow - $lastPoll).TotalMilliseconds -ge $script:Config.RefreshIntervalMs) {
                $openMap = Get-OpenSessionMap
                $openMapSignature = Get-OpenMapSignature -OpenMap $openMap
                $lastPoll = [DateTime]::UtcNow
            }
            # A running session missing from the list started after the index was built (Ctrl+N,
            # claude started by hand, a new ID after /clear). Read just its file and add it, so it
            # shows up without Ctrl+R. Checked once per re-read of the running sessions; one whose
            # file does not exist yet (no message so far) is simply tried again next time.
            if ($lastPoll -ne $lastNewSessionCheck) {
                $lastNewSessionCheck = $lastPoll
                $newInfos = @(foreach ($id in @($openMap.Keys)) {
                    if ($knownIds.ContainsKey($id)) { continue }
                    $path = Find-SessionFile -SessionId $id
                    if (-not $path) { continue }
                    # A file being created or locked is read again on the next poll.
                    try { Get-SessionFileInfo -File ([System.IO.FileInfo]::new($path)) } catch { }
                })
                if ($newInfos.Count -gt 0) {
                    $before = $Sessions.Count
                    $Sessions = Add-NewSessions -Sessions $Sessions -NewInfos $newInfos
                    if ($Sessions.Count -ne $before) {
                        $knownIds = Get-SessionIdSet -Sessions $Sessions
                        $selected = if ($filtered.Count -gt 0) { $filtered[$selectedIndex] } else { $null }
                        . $updateView
                        if ($selected) {
                            $selectedIndex = Find-SessionIndexById -Sessions $filtered -SessionId $selected.SessionId `
                                -Cwd $selected.Cwd -Fallback $selectedIndex
                        }
                    }
                }
            }
            # A launched session that has recorded itself no longer needs the grace period. Dropping
            # it here lets Enter reopen the session right away if its window is closed soon after.
            foreach ($id in @($recentLaunches.Keys)) {
                if ($openMap.ContainsKey($id)) { $recentLaunches.Remove($id) }
            }
            # In the latest per directory view, older sessions are shown only while running, so the
            # rows change when one starts or stops, or when a launch grace period runs out.
            if ($latestPerDirectory) {
                $runningIds = Get-RunningIds -OpenMap $openMap -Launches $recentLaunches -Now ([DateTime]::UtcNow)
                if ((@($runningIds.Keys | Sort-Object) -join ';') -ne $runningSignature) {
                    $selected = if ($filtered.Count -gt 0) { $filtered[$selectedIndex] } else { $null }
                    . $updateView
                    if ($selected) {
                        $selectedIndex = Find-SessionIndexById -Sessions $filtered -SessionId $selected.SessionId `
                            -Cwd $selected.Cwd -Fallback $selectedIndex
                    }
                }
            }

            # Process all keys in the buffer together.
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $isCtrl = [bool]($key.Modifiers -band [ConsoleModifiers]::Control)
                $isShiftTab = $key.Key -eq [ConsoleKey]::Tab -and [bool]($key.Modifiers -band [ConsoleModifiers]::Shift)

                # While a delete confirmation is pending, the next key is treated only as the
                # answer. Passing it on to normal handling would add keys like n to the search
                # term, so anything other than y cancels and is discarded.
                if ($pendingDelete) {
                    $targets = $pendingDelete
                    $pendingDelete = $null
                    $notice = $null
                    if (-not $isCtrl -and ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y')) {
                        # Every session is tried even after a failure; the ones already in the
                        # Recycle Bin cannot be put back, so stopping would only leave the rest.
                        $removedIds = @{}
                        $failedCount = 0
                        $firstError = $null
                        foreach ($target in $targets) {
                            $result = Remove-ClaudeSession -Session $target
                            if ($result) {
                                $failedCount++
                                if (-not $firstError) { $firstError = $result }
                            } else {
                                $removedIds[$target.SessionId] = $true
                            }
                        }
                        if ($removedIds.Count -gt 0) {
                            $Sessions = @($Sessions | Where-Object { -not $removedIds.ContainsKey($_.SessionId) })
                            $knownIds = Get-SessionIdSet -Sessions $Sessions
                            $unpinned = @($removedIds.Keys | Where-Object { $pinnedIds.ContainsKey($_) })
                            if ($unpinned.Count -gt 0) {
                                foreach ($id in $unpinned) { $pinnedIds.Remove($id) }
                                # A stale pin is harmless and dropped at the next start, so a failure is ignored.
                                try { Save-PinnedIds -PinnedIds $pinnedIds } catch { }
                            }
                            . $updateView
                        }
                        $notice = if ($failedCount -eq 0) {
                            if ($targets.Count -eq 1) { $script:Text.MovedToTrash } else { $script:Text.MovedToTrashCount -f $removedIds.Count }
                        } elseif ($targets.Count -eq 1) {
                            $firstError
                        } else {
                            $script:Text.DeletePartiallyFailed -f $removedIds.Count, $failedCount, $firstError
                        }
                        $noticeExpiry = [DateTime]::UtcNow.AddMilliseconds($script:Config.NoticeDurationMs)
                    }
                    continue
                }

                # Any key other than Esc cancels a pending quit and is then handled as usual.
                if ($quitArmed -and $key.Key -ne [ConsoleKey]::Escape) {
                    $quitArmed = $false
                    $notice = $null
                }

                # Esc clears the search first. On an empty search it asks for a second Esc and then
                # quits, so a stray press never closes the list.
                if ($key.Key -eq [ConsoleKey]::Escape) {
                    if ($filter) {
                        $filter = ''
                        . $updateView
                        $selectedIndex = 0; $topIndex = 0
                    } elseif ($quitArmed) {
                        return
                    } else {
                        $quitArmed = $true
                        $notice = $script:Text.PressEscAgainToQuit
                    }
                }
                elseif ($key.Key -eq [ConsoleKey]::UpArrow) {
                    if ($selectedIndex -gt 0) { $selectedIndex-- }
                }
                elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
                    if ($selectedIndex -lt $filtered.Count - 1) { $selectedIndex++ }
                }
                elseif ($key.Key -eq [ConsoleKey]::PageUp) {
                    $selectedIndex = [Math]::Max(0, $selectedIndex - $pageSize)
                }
                elseif ($key.Key -eq [ConsoleKey]::PageDown) {
                    $selectedIndex = [Math]::Max(0, [Math]::Min($filtered.Count - 1, $selectedIndex + $pageSize))
                }
                elseif ($key.Key -eq [ConsoleKey]::Home) {
                    $selectedIndex = 0
                }
                elseif ($key.Key -eq [ConsoleKey]::End) {
                    $selectedIndex = [Math]::Max(0, $filtered.Count - 1)
                }
                elseif ($key.Key -eq [ConsoleKey]::Enter) {
                    if ($filtered.Count -gt 0) {
                        $session = $filtered[$selectedIndex]
                        $openMap = Get-OpenSessionMap
                        $openMapSignature = Get-OpenMapSignature -OpenMap $openMap
                        $lastPoll = [DateTime]::UtcNow
                        $wasOpen = $openMap.ContainsKey($session.SessionId)
                        $isBackground = $wasOpen -and (Test-BackgroundSession -OpenEntry $openMap[$session.SessionId])
                        # Just launched but not yet recorded as running: opening it again would start
                        # a second process, and focusing by window name would make wt open an empty
                        # window if the launch had failed, so only say it is on its way.
                        # A background session is already recorded, so only a double press on it is
                        # held back, for the same short time as Ctrl+N.
                        if ((-not $wasOpen -and (Test-RecentLaunch -Launches $recentLaunches -Key $session.SessionId `
                                    -GraceMs $script:Config.LaunchGraceMs -Now $lastPoll)) -or
                            ($isBackground -and (Test-RecentLaunch -Launches $recentAttaches -Key $session.SessionId `
                                    -GraceMs $script:Config.NewSessionGraceMs -Now $lastPoll))) {
                            $result = $script:Text.LaunchInProgress
                        } else {
                            $result = Open-ClaudeSession -Session $session -OpenMap $openMap
                            if (-not $result) {
                                if ($isBackground) {
                                    $recentAttaches[$session.SessionId] = $lastPoll
                                    $result = $script:Text.Attached
                                } elseif ($wasOpen) {
                                    $result = $script:Text.Focused
                                } else {
                                    $recentLaunches[$session.SessionId] = $lastPoll
                                    $result = $script:Text.Opened
                                }
                            }
                        }
                        $notice = $result
                        $noticeExpiry = [DateTime]::UtcNow.AddMilliseconds($script:Config.NoticeDurationMs)
                    }
                }
                elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($filter.Length -gt 0) {
                        $filter = $filter.Substring(0, $filter.Length - 1)
                        . $updateView
                        $selectedIndex = 0; $topIndex = 0
                    }
                }
                elseif ($isCtrl -and $key.Key -eq [ConsoleKey]::N) {
                    if ($filtered.Count -gt 0) {
                        $cwd = $filtered[$selectedIndex].Cwd
                        $now = [DateTime]::UtcNow
                        if (Test-RecentLaunch -Launches $recentNewSessions -Key $cwd `
                                -GraceMs $script:Config.NewSessionGraceMs -Now $now) {
                            $result = $script:Text.LaunchInProgress
                        } else {
                            $result = Invoke-LaunchAction -Cwd $cwd -Action { Start-ClaudeSession -Cwd $cwd -NewSession }
                            if (-not $result) {
                                $recentNewSessions[$cwd] = $now
                                $result = $script:Text.NewSessionOpened
                            }
                        }
                        $notice = $result
                        $noticeExpiry = [DateTime]::UtcNow.AddMilliseconds($script:Config.NoticeDurationMs)
                    }
                }
                elseif ($isCtrl -and $key.Key -eq [ConsoleKey]::D) {
                    if ($filtered.Count -gt 0) {
                        $target = $filtered[$selectedIndex]
                        $openMap = Get-OpenSessionMap
                        $openMapSignature = Get-OpenMapSignature -OpenMap $openMap
                        $lastPoll = [DateTime]::UtcNow
                        # A session opened moments ago is running even before it records itself.
                        $deleteRunningIds = Get-RunningIds -OpenMap $openMap -Launches $recentLaunches -Now $lastPoll
                        # In the latest per directory view the whole directory of the row goes at
                        # once (running and pinned sessions left out), so the sessions hidden behind
                        # it need no trip to the all sessions view. A pinned row is still deleted
                        # alone: it was chosen explicitly, while pins are what the bulk delete keeps.
                        $excludedCount = 0
                        $deleteTargets = if ($latestPerDirectory -and -not $pinnedIds.ContainsKey($target.SessionId)) {
                            $picked = Get-DirectoryDeleteTargets -Sessions $matched -Cwd $target.Cwd `
                                -RunningIds $deleteRunningIds -PinnedIds $pinnedIds
                            $excludedCount = $picked.ExcludedCount
                            , $picked.Targets
                        } elseif ($deleteRunningIds.ContainsKey($target.SessionId)) {
                            , @()
                        } else {
                            , @($target)
                        }
                        if ($deleteTargets.Count -eq 0) {
                            $notice = $script:Text.CannotDeleteLive
                            $noticeExpiry = [DateTime]::UtcNow.AddMilliseconds($script:Config.NoticeDurationMs)
                        } else {
                            $pendingDelete = $deleteTargets
                            $dirName = if ($target.Cwd) { Get-ProjectName -Cwd $target.Cwd } else { '' }
                            $notice = if ($deleteTargets.Count -eq 1) {
                                $only = $deleteTargets[0]
                                $script:Text.ConfirmDelete -f $(if ($only.Title) { $only.Title } else { $only.SessionId })
                            } elseif ($excludedCount -gt 0) {
                                $script:Text.ConfirmDeleteDirectoryExcluded -f $dirName, $deleteTargets.Count, $excludedCount
                            } else {
                                $script:Text.ConfirmDeleteDirectory -f $dirName, $deleteTargets.Count
                            }
                        }
                    }
                }
                elseif ($isCtrl -and $key.Key -eq [ConsoleKey]::R) {
                    $selectedId = if ($filtered.Count -gt 0) { $filtered[$selectedIndex].SessionId } else { $null }
                    [Console]::Write("$esc[?25h$clearScreen")
                    $Sessions = Get-SessionIndex -Force -OnProgress {
                        param($current, $total)
                        Write-Host ("`r" + ($script:Text.Rebuilding -f $current, $total)) -NoNewline -ForegroundColor DarkGray
                    }
                    [Console]::Write("$esc[?25l$clearScreen")
                    $lastFrame = ''
                    $lastFrameSignature = ''
                    $openMap = Get-OpenSessionMap
                    $openMapSignature = Get-OpenMapSignature -OpenMap $openMap
                    $lastPoll = [DateTime]::UtcNow
                    $knownIds = Get-SessionIdSet -Sessions $Sessions
                    if (Remove-OrphanedPins -PinnedIds $pinnedIds -Sessions $Sessions) {
                        try { Save-PinnedIds -PinnedIds $pinnedIds } catch { }
                    }
                    # Keep the search term, and return to the previously selected session even if the order changed.
                    . $updateView
                    $selectedIndex = Find-SessionIndexById -Sessions $filtered -SessionId $selectedId
                }
                elseif ($isCtrl -and $key.Key -eq [ConsoleKey]::P) {
                    # Pin or unpin the selected session and stay on it as it moves to or from the top.
                    if ($filtered.Count -gt 0) {
                        $selected = $filtered[$selectedIndex]
                        $wasPinned = $pinnedIds.ContainsKey($selected.SessionId)
                        if ($wasPinned) { $pinnedIds.Remove($selected.SessionId) } else { $pinnedIds[$selected.SessionId] = $true }
                        try {
                            Save-PinnedIds -PinnedIds $pinnedIds
                            $notice = if ($wasPinned) { $script:Text.Unpinned } else { $script:Text.Pinned }
                        } catch {
                            # Keep the pin for this run anyway; only remembering it failed.
                            $notice = $script:Text.PinSaveFailed -f $_.Exception.Message
                        }
                        $noticeExpiry = [DateTime]::UtcNow.AddMilliseconds($script:Config.NoticeDurationMs)
                        . $updateView
                        $selectedIndex = Find-SessionIndexById -Sessions $filtered -SessionId $selected.SessionId `
                            -Cwd $selected.Cwd -Fallback $selectedIndex
                    }
                }
                elseif ($isShiftTab) {
                    # Switch between the latest per directory view and every session, staying on the
                    # same session (or its directory's row when the new view hides it).
                    $selected = if ($filtered.Count -gt 0) { $filtered[$selectedIndex] } else { $null }
                    $latestPerDirectory = -not $latestPerDirectory
                    . $updateView
                    if ($selected) {
                        $selectedIndex = Find-SessionIndexById -Sessions $filtered -SessionId $selected.SessionId `
                            -Cwd $selected.Cwd -Fallback $selectedIndex
                    }
                }
                elseif ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                    $filter += $key.KeyChar
                    . $updateView
                    $selectedIndex = 0; $topIndex = 0
                }
            }
        }
    } finally {
        [Console]::Write("$esc[?25h")
    }
}

# ============================================================
# Language
# ============================================================

# UI strings live in <language>\Messages.psd1 next to this script and are read with
# Import-LocalizedData, so a language is added by adding a folder, without touching the code.
# en is the reference language and the fallback.
$script:MessagesFileName = 'Messages'
$script:FallbackLanguage = 'en'

function Import-UiMessages {
    <#
    Loads the UI strings for the Language setting and returns them as a hashtable.
    'auto' uses the UI culture (the Windows display language); Import-LocalizedData looks for
    its folder (ja-JP) and then the language folder (ja). If neither exists it falls back to
    English. PowerShell 7.5.5+ has a similar fallback of its own, but only without -UICulture,
    and this tool also supports 7.4 and Windows PowerShell 5.1, so it is done here.
    Any other value must name an existing language folder; otherwise it throws, so a typo such
    as 'jp' is caught at startup instead of silently falling back.
    Keys missing from the chosen language are filled from English, so a partial translation
    still works.
    #>
    param(
        [AllowEmptyString()][string]$Language,
        [AllowEmptyString()][string]$UICultureName,
        [string]$BaseDirectory = $PSScriptRoot
    )
    $import = {
        param([string]$Culture)
        Import-LocalizedData -BaseDirectory $BaseDirectory -FileName $script:MessagesFileName `
            -UICulture $Culture -ErrorAction Stop
    }

    $fallback = & $import $script:FallbackLanguage
    if ($Language -eq 'auto') {
        $selected = try { & $import $UICultureName } catch { $fallback }
    } else {
        # Only culture-name-like values, so the setting can never point outside $BaseDirectory.
        $selected = $null
        if ($Language -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') {
            $selected = try { & $import $Language } catch { $null }
        }
        if (-not $selected) {
            throw ("Invalid Language '$Language': $script:MessagesFileName.psd1 was not found under " +
                "'$BaseDirectory\$Language'. Use 'auto' or a language that has a folder there.")
        }
    }

    $messages = @{}
    foreach ($key in $fallback.Keys) { $messages[$key] = $fallback[$key] }
    foreach ($key in $selected.Keys) { $messages[$key] = $selected[$key] }
    return $messages
}

function Set-UiLanguage {
    <#
    Switches the UI strings ($script:Text) and recomputes the status column width, which
    depends on them: the widest of the status labels and the column header.
    #>
    param([Parameter(Mandatory)][hashtable]$Messages)
    $script:Text = $Messages
    $labels = @($script:Text.StatusLabels.Values) + $script:Text.UnknownStatusLabel + $script:Text.HeaderStatus
    $script:StatusColumnWidth = [int]($labels | ForEach-Object { Get-DisplayWidth -Text $_ } | Measure-Object -Maximum).Maximum
}

# ============================================================
# User settings
# ============================================================

# Lower bounds for numeric settings. Below them the key wait loop would spin without sleeping
# (KeyPollIntervalMs = 0 keeps a CPU core busy), Start-Sleep would throw on a negative value, or
# the frame would be rebuilt on every pass. RefreshIntervalMs = 0 means no automatic refresh.
$script:ConfigMinimums = @{
    RefreshIntervalMs      = 0
    KeyPollIntervalMs      = 10
    ForcedRedrawIntervalMs = 1000
    NoticeDurationMs       = 0
    PageSize               = 1
    ConsoleOwnerTimeoutMs  = 0
    LaunchGraceMs          = 0
    NewSessionGraceMs      = 0
    PreviewMaxLength       = 1
}

# Settings that accept only the listed values (compared ignoring case, like the rest of the code).
$script:ConfigChoices = @{
    WindowMode = @('tabs', 'windows')
}

# Settings that must be written as $true or $false. A quoted 'false' would otherwise pass through
# and count as true, because any non-empty string converts to $true.
$script:ConfigBooleans = @('LatestPerDirectory')

function Import-UserConfig {
    <#
    Overlays the user's settings file on $script:Config. Does nothing if the file does not exist.
    Import-PowerShellDataFile only accepts data, so the file cannot run code.
    A key that $script:Config does not have throws, so a typo such as 'PageSise' is caught at
    startup instead of being silently ignored.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $userConfig = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($key in $userConfig.Keys) {
        if (-not $script:Config.ContainsKey($key)) {
            throw "Unknown setting '$key' in $Path. See config.example.psd1 for the available settings."
        }
    }
    foreach ($key in $script:ConfigMinimums.Keys) {
        if (-not $userConfig.ContainsKey($key)) { continue }
        $value = $userConfig[$key] -as [int]
        if ($null -eq $value -or $value -lt $script:ConfigMinimums[$key]) {
            throw "Invalid setting '$key' in ${Path}: must be an integer of $($script:ConfigMinimums[$key]) or greater."
        }
    }
    foreach ($key in $script:ConfigChoices.Keys) {
        if (-not $userConfig.ContainsKey($key)) { continue }
        if ($userConfig[$key] -isnot [string] -or $script:ConfigChoices[$key] -notcontains $userConfig[$key]) {
            throw "Invalid setting '$key' in ${Path}: must be one of $(($script:ConfigChoices[$key] | ForEach-Object { "'$_'" }) -join ', ')."
        }
    }
    foreach ($key in $script:ConfigBooleans) {
        if (-not $userConfig.ContainsKey($key)) { continue }
        if ($userConfig[$key] -isnot [bool]) {
            throw "Invalid setting '$key' in ${Path}: must be `$true or `$false."
        }
    }
    foreach ($key in $userConfig.Keys) {
        $script:Config[$key] = $userConfig[$key]
    }
}

function Initialize-Settings {
    <#
    Applies the user's settings and the UI language. Called from Main rather than at load time,
    so dot-sourcing this script (as the tests do) has no side effects from the user's config.psd1.
    #>
    Import-UserConfig -Path $script:UserConfigPath
    Set-UiLanguage -Messages (Import-UiMessages -Language $script:Config.Language -UICultureName (Get-UICulture).Name)
}

# ============================================================
# Entry point
# ============================================================

function Initialize-ConsoleApi {
    <#
    Declares the kernel32 functions that turn on escape sequence processing for the console.
    PowerShell 7 turns it on by itself, but Windows PowerShell 5.1 on conhost may leave it off,
    in which case every color and cursor sequence is printed as text. Written in C# 5 syntax
    (no inline out variables) so the compiler that 5.1 uses accepts it.
    #>
    if ('ClaudeSessionsConsoleApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ClaudeSessionsConsoleApi {
    const int STD_OUTPUT_HANDLE = -11;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4;

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr handle, uint mode);

    // Returns the mode before the change, or -1 when stdout is not a console.
    public static long EnableVirtualTerminal() {
        IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
        uint mode;
        if (handle == IntPtr.Zero || handle == new IntPtr(-1) || !GetConsoleMode(handle, out mode)) { return -1; }
        SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        return mode;
    }

    public static void RestoreMode(long mode) {
        if (mode < 0) { return; }
        SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), (uint)mode);
    }
}
'@
}

function Main {
    # Windows PowerShell 5.1 only: escape sequence processing may be off (see
    # Initialize-ConsoleApi), and the console starts in the OEM code page (shift_jis on Japanese
    # Windows), where characters outside it, such as emoji in session names, become '?'.
    # PowerShell 7 needs neither, and compiling the API costs hundreds of ms at startup, so it
    # is left untouched. Both settings are put back on exit so the calling console is left as it was.
    $isDesktop = $PSVersionTable.PSEdition -eq 'Desktop'
    $savedMode = -1
    $savedEncoding = [Console]::OutputEncoding
    if ($isDesktop) {
        Initialize-ConsoleApi
        $savedMode = [ClaudeSessionsConsoleApi]::EnableVirtualTerminal()
    }
    # The list is drawn on the alternate screen buffer, so quitting puts back whatever the
    # terminal showed before instead of leaving the last frame behind. Entered after the
    # settings are read, so a startup error stays on the main screen where it can be read.
    $esc = [char]27
    $altScreen = $false
    try {
        if ($isDesktop) { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }
        Initialize-Settings
        [Console]::Write("$esc[?1049h$esc[2J$esc[H")
        $altScreen = $true
        $sessions = Get-SessionIndex -OnProgress {
            param($current, $total)
            Write-Host ("`r" + ($script:Text.Loading -f $current, $total)) -NoNewline -ForegroundColor DarkGray
        }
        Write-Host "`r" -NoNewline  # Return the cursor so the next frame overwrites the progress line
        Show-SessionMenu -Sessions $sessions
    } finally {
        if ($altScreen) { [Console]::Write("$esc[?1049l") }
        if ($isDesktop) {
            [Console]::OutputEncoding = $savedEncoding
            [ClaudeSessionsConsoleApi]::RestoreMode($savedMode)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
