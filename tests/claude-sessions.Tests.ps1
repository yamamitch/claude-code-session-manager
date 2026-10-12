#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the pure functions in claude-sessions.ps1.

.DESCRIPTION
    Limited to functions whose input and output are deterministic (string formatting,
    search, color selection). Functions that start processes or run the key input loop
    (Get-SessionIndex, Start-ClaudeSession, Get-OpenSessionMap, Test-LaunchedByTool,
    Get-ConsoleOwnerWindow, Show-OwnerWindow, Show-SessionMenu, etc.) would need heavy
    mocking and are out of scope.
    As an exception, Get-SessionFileInfoFast / Full / Get-SessionFileInfo do file I/O, but
    synthetic files on TestDrive keep their input and output deterministic, so they are
    covered (a regression test that the fast path and the full scan agree).
    See the "Tests" section of README.md for how to run them.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\claude-sessions.ps1')
    $script:SrcDir = Join-Path $PSScriptRoot '..\src'
    # Pin the UI language so results do not depend on the Windows display language.
    Set-UiLanguage -Messages (Import-UiMessages -Language 'ja' -UICultureName 'ja-JP')
}

Describe 'Messages files' {
    <#
    Every language folder under src is checked against en, the reference language.
    #>
    BeforeAll {
        $script:reference = Import-PowerShellDataFile (Join-Path $script:SrcDir 'en\Messages.psd1')
        $script:languageFiles = @(Get-ChildItem -Path $script:SrcDir -Directory |
            ForEach-Object { Join-Path $_.FullName 'Messages.psd1' } | Where-Object { Test-Path $_ })
        function Get-Placeholders([string]$Text) {
            @([regex]::Matches($Text, '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }
    }
    It 'finds more than one language' {
        $script:languageFiles.Count | Should -BeGreaterThan 1
    }
    It 'has the same keys as en in every language' {
        $referenceKeys = @($script:reference.Keys | Sort-Object)
        foreach ($file in $script:languageFiles) {
            $messages = Import-PowerShellDataFile $file
            @($messages.Keys | Sort-Object) | Should -Be $referenceKeys -Because $file
            @($messages.StatusLabels.Keys | Sort-Object) |
                Should -Be @($script:reference.StatusLabels.Keys | Sort-Object) -Because "StatusLabels in $file"
        }
    }
    It 'uses the same {n} placeholders as en in every language' {
        # A placeholder index with no matching argument makes -f throw and would crash the TUI.
        foreach ($file in $script:languageFiles) {
            $messages = Import-PowerShellDataFile $file
            foreach ($key in $script:reference.Keys) {
                if ($script:reference[$key] -isnot [string]) { continue }
                Get-Placeholders $messages[$key] |
                    Should -Be (Get-Placeholders $script:reference[$key]) -Because "$key in $file"
            }
        }
    }
    It 'has a color for every status label' {
        foreach ($status in $script:reference.StatusLabels.Keys) {
            $script:Config.StatusColors.ContainsKey($status) | Should -BeTrue -Because $status
        }
    }
    It 'uses only status colors that have an ANSI sequence' {
        foreach ($color in $script:Config.StatusColors.Values) {
            $script:Ansi.Foreground.ContainsKey($color) | Should -BeTrue -Because $color
        }
    }
}

Describe 'Source files' {
    It 'saves every script and data file as UTF-8 with BOM' {
        # Windows PowerShell 5.1 reads a file without a BOM in the ANSI code page and garbles
        # non-ASCII text. config.psd1 is the user's own file and is not checked.
        $root = Join-Path $PSScriptRoot '..'
        $files = @(
            Get-ChildItem -Path (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -File -Include '*.ps1', '*.psd1'
            Get-ChildItem -Path $root -File -Filter '*.ps1'
            Get-Item -LiteralPath (Join-Path $root 'config.example.psd1')
        )
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $head = [System.IO.File]::ReadAllBytes($file.FullName) | Select-Object -First 3
            ($head -join ',') | Should -Be '239,187,191' -Because $file.FullName
        }
    }
}

Describe 'Import-UiMessages' {
    It 'loads the language that is named explicitly' {
        (Import-UiMessages -Language 'ja' -UICultureName 'en-US').StatusLabels.idle | Should -Be '完了'
        (Import-UiMessages -Language 'en' -UICultureName 'ja-JP').StatusLabels.idle | Should -Be 'Done'
    }
    It 'auto uses the language folder of the UI culture' {
        (Import-UiMessages -Language 'auto' -UICultureName 'ja-JP').StatusLabels.idle | Should -Be '完了'
        (Import-UiMessages -Language 'auto' -UICultureName 'en-GB').StatusLabels.idle | Should -Be 'Done'
    }
    It 'auto falls back to en when the UI culture has no translation' {
        (Import-UiMessages -Language 'auto' -UICultureName 'fr-FR').StatusLabels.idle | Should -Be 'Done'
        (Import-UiMessages -Language 'auto' -UICultureName '').StatusLabels.idle | Should -Be 'Done'
    }
    It 'throws for a language without a folder' {
        { Import-UiMessages -Language 'jp' -UICultureName 'ja-JP' } | Should -Throw '*Invalid Language*'
        { Import-UiMessages -Language '' -UICultureName 'ja-JP' } | Should -Throw '*Invalid Language*'
        { Import-UiMessages -Language '..\src' -UICultureName 'ja-JP' } | Should -Throw '*Invalid Language*'
    }
    It 'fills keys missing from a partial translation with en' {
        $base = Join-Path $TestDrive 'lang'
        New-Item -ItemType Directory -Path (Join-Path $base 'en'), (Join-Path $base 'xx') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $base 'en\Messages.psd1') -Value "@{ NoMatch = 'none'; MovedToTrash = 'moved' }"
        Set-Content -LiteralPath (Join-Path $base 'xx\Messages.psd1') -Value "@{ NoMatch = 'xx-none' }"
        $messages = Import-UiMessages -Language 'xx' -UICultureName 'en-US' -BaseDirectory $base
        $messages.NoMatch | Should -Be 'xx-none'
        $messages.MovedToTrash | Should -Be 'moved'
    }
}

Describe 'Import-UserConfig' {
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'does nothing when the file does not exist' {
        Import-UserConfig -Path (Join-Path $TestDrive 'no-such-config.psd1')
        $script:Config.PageSize | Should -Be $script:savedConfig.PageSize
    }
    It 'overrides known settings and keeps the others' {
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ PageSize = 7; Language = 'en' }"
        Import-UserConfig -Path $path
        $script:Config.PageSize | Should -Be 7
        $script:Config.Language | Should -Be 'en'
        $script:Config.RefreshIntervalMs | Should -Be $script:savedConfig.RefreshIntervalMs
    }
    It 'throws for an unknown setting and applies nothing' {
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ PageSize = 7; PageSise = 10 }"
        { Import-UserConfig -Path $path } | Should -Throw "*Unknown setting 'PageSise'*"
        $script:Config.PageSize | Should -Be $script:savedConfig.PageSize
    }
    It 'accepts RefreshIntervalMs = 0 (automatic refresh off)' {
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ RefreshIntervalMs = 0 }"
        Import-UserConfig -Path $path
        $script:Config.RefreshIntervalMs | Should -Be 0
    }
    It 'throws for a negative RefreshIntervalMs and applies nothing' {
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ PageSize = 7; RefreshIntervalMs = -1 }"
        { Import-UserConfig -Path $path } | Should -Throw "*Invalid setting 'RefreshIntervalMs'*"
        $script:Config.PageSize | Should -Be $script:savedConfig.PageSize
    }
    It 'throws for <Setting> below its lower bound and applies nothing' -TestCases @(
        @{ Setting = 'KeyPollIntervalMs = 0' }
        @{ Setting = 'ForcedRedrawIntervalMs = 0' }
        @{ Setting = 'PageSize = 0' }
        @{ Setting = "NoticeDurationMs = 'abc'" }
    ) {
        param($Setting)
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ Language = 'en'; $Setting }"
        { Import-UserConfig -Path $path } | Should -Throw "*Invalid setting*"
        $script:Config.Language | Should -Be $script:savedConfig.Language
    }
    It 'has a lower bound only for settings that exist' {
        foreach ($key in $script:ConfigMinimums.Keys) { $script:Config.ContainsKey($key) | Should -BeTrue -Because $key }
    }
    It 'throws for <Setting>, which is not a boolean, and applies nothing' -TestCases @(
        @{ Setting = "LatestPerDirectory = 'false'" }
        @{ Setting = "LatestPerDirectory = 'true'" }
        @{ Setting = 'LatestPerDirectory = 0' }
        @{ Setting = 'LatestPerDirectory = 1' }
        @{ Setting = 'LatestPerDirectory = $null' }
    ) {
        param($Setting)
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ Language = 'en'; $Setting }"
        { Import-UserConfig -Path $path } | Should -Throw "*Invalid setting 'LatestPerDirectory'*must be `$true or `$false*"
        $script:Config.Language | Should -Be $script:savedConfig.Language
    }
    It 'accepts LatestPerDirectory = <Value>' -TestCases @(
        @{ Value = '$true'; Expected = $true }
        @{ Value = '$false'; Expected = $false }
    ) {
        param($Value, $Expected)
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ LatestPerDirectory = $Value }"
        Import-UserConfig -Path $path
        $script:Config.LatestPerDirectory | Should -Be $Expected
    }
    It 'checks the type only of settings that exist' {
        foreach ($key in $script:ConfigBooleans) { $script:Config.ContainsKey($key) | Should -BeTrue -Because $key }
        foreach ($key in $script:ConfigChoices.Keys) { $script:Config.ContainsKey($key) | Should -BeTrue -Because $key }
    }
    It 'accepts WindowMode = <Value>' -TestCases @(
        @{ Value = 'tabs' }
        @{ Value = 'windows' }
    ) {
        param($Value)
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ WindowMode = '$Value' }"
        Import-UserConfig -Path $path
        $script:Config.WindowMode | Should -Be $Value
    }
    It 'throws for <Setting> and applies nothing' -TestCases @(
        @{ Setting = "WindowMode = 'tab'" }
        @{ Setting = "WindowMode = ''" }
        @{ Setting = 'WindowMode = $null' }
        @{ Setting = 'WindowMode = 1' }
    ) {
        param($Setting)
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value "@{ Language = 'en'; $Setting }"
        { Import-UserConfig -Path $path } | Should -Throw "*Invalid setting 'WindowMode'*'tabs', 'windows'*"
        $script:Config.Language | Should -Be $script:savedConfig.Language
    }
    It 'accepts every setting listed in config.example.psd1' {
        $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.psd1') -Raw
        $keys = [regex]::Matches($example, '(?m)^\s*#\s*(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value }
        $keys.Count | Should -BeGreaterThan 0
        foreach ($key in $keys) { $script:Config.ContainsKey($key) | Should -BeTrue -Because $key }
    }
}

Describe 'Set-UiLanguage' {
    AfterEach {
        Set-UiLanguage -Messages (Import-UiMessages -Language 'ja' -UICultureName 'ja-JP')
    }
    It 'sizes the status column to the widest label or header (ja)' {
        $script:StatusColumnWidth | Should -Be 8
    }
    It 'switches labels and messages to English and resizes the status column' {
        Set-UiLanguage -Messages (Import-UiMessages -Language 'en' -UICultureName 'en-US')
        $label, $null = Get-StatusCell -OpenEntry ([pscustomobject]@{ Pid = 1; Status = 'waiting' })
        $label | Should -Be 'Waiting'
        $label, $null = Get-StatusCell -OpenEntry ([pscustomobject]@{ Pid = 1; Status = 'future_status' })
        $label | Should -Be 'Running'
        $script:StatusColumnWidth | Should -Be 7
    }
    It 'returns English notices after switching to en' {
        Set-UiLanguage -Messages (Import-UiMessages -Language 'en' -UICultureName 'en-US')
        Mock Select-TerminalTab { [IntPtr]::Zero }
        Mock Test-LaunchedByTool { $false }
        Mock Get-ConsoleOwnerWindow { [IntPtr]::Zero }
        $session = [pscustomobject]@{ SessionId = 'abc'; Cwd = $TestDrive }
        $openMap = @{ 'abc' = [pscustomobject]@{ Pid = 1234; Status = 'idle' } }
        Open-ClaudeSession -Session $session -OpenMap $openMap | Should -BeLike '*already open*'
    }
    It 'lines up the path column of header and rows in every language' {
        $sessions = @(
            [pscustomobject]@{ SessionId = 'a'; Title = '画面の設計'; Cwd = 'C:\work\sample_app'; Modified = [datetime]'2026-09-25 10:00' }
            [pscustomobject]@{ SessionId = 'b'; Title = 'Fix bug'; Cwd = 'C:\work\other'; Modified = [datetime]'2026-09-24 09:00' }
        )
        $openMap = @{
            'a' = [pscustomobject]@{ Pid = 1; Status = 'waiting' }
            'b' = [pscustomobject]@{ Pid = 2; Status = 'future_status' }
        }
        # Display column where $Needle starts in $Line.
        $columnOf = { param($Line, $Needle) Get-DisplayWidth -Text $Line.Substring(0, $Line.IndexOf($Needle)) }
        foreach ($language in 'ja', 'en') {
            Set-UiLanguage -Messages (Import-UiMessages -Language $language -UICultureName 'en-US')
            $frame = Get-SessionFrame -Filtered $sessions -TotalCount 2 -OpenMap $openMap -Filter '' `
                -SelectedIndex 1 -TopIndex 0 -PageSize 10
            $lines = @(([regex]::Replace($frame, [char]27 + '\[[0-9;?]*[A-Za-z]', '')) -split "`n")
            $rule = @($lines | Select-String -Pattern '^-+( .+ --)?$')[0].LineNumber - 1
            $headerColumn = & $columnOf $lines[$rule - 1] $script:Text.HeaderPath
            & $columnOf $lines[$rule + 1] 'C:\work\sample_app' | Should -Be $headerColumn -Because $language
            & $columnOf $lines[$rule + 2] 'C:\work\other' | Should -Be $headerColumn -Because $language
            Get-DisplayWidth -Text $lines[$rule + 1].TrimEnd() | Should -BeLessOrEqual (Get-DisplayWidth -Text $lines[$rule]) -Because $language
        }
    }
}

Describe 'Test-AsciiOnly' {
    It 'is true for ASCII only' {
        Test-AsciiOnly -Text 'C:\project\path' | Should -BeTrue
    }
    It 'is true for an empty string' {
        Test-AsciiOnly -Text '' | Should -BeTrue
    }
    It 'is false when Japanese is mixed in' {
        Test-AsciiOnly -Text 'C:\作業フォルダ' | Should -BeFalse
    }
    It 'is false when a surrogate pair (emoji) is mixed in' {
        Test-AsciiOnly -Text ("abc" + [char]::ConvertFromUtf32(0x1F600)) | Should -BeFalse
    }
}

Describe 'Get-DisplayWidth' {
    It 'counts a half-width character as 1 column' {
        Get-DisplayWidth -Text 'abc' | Should -Be 3
    }
    It 'is 0 for an empty string' {
        Get-DisplayWidth -Text '' | Should -Be 0
    }
    It 'counts a full-width (Japanese) character as 2 columns' {
        Get-DisplayWidth -Text '日本語のテスト' | Should -Be 14
    }
    It 'counts mixed half-width and full-width text correctly' {
        Get-DisplayWidth -Text 'ABC-1234XYZ5 テスト UI 表示' | Should -Be 27
    }
    It 'counts a surrogate pair (emoji) as 2 columns' {
        Get-DisplayWidth -Text ([char]::ConvertFromUtf32(0x1F600)) | Should -Be 2
    }
}

Describe 'Format-FixedWidth' {
    It 'pads a string shorter than the width with spaces' {
        $result = Format-FixedWidth -Text 'abc' -Width 5
        $result | Should -Be 'abc  '
        Get-DisplayWidth -Text $result | Should -Be 5
    }
    It 'returns a string of exactly the width unchanged' {
        Format-FixedWidth -Text 'abcde' -Width 5 | Should -Be 'abcde'
    }
    It 'truncates a long string with … by default (cut at the end)' {
        $result = Format-FixedWidth -Text 'abcdefghij' -Width 5
        $result | Should -Match '…$'
        Get-DisplayWidth -Text $result | Should -Be 5
    }
    It '-KeepEnd truncates the start with ... and keeps the end' {
        $result = Format-FixedWidth -Text 'C:\very\long\path\to\project' -Width 15 -KeepEnd
        $result | Should -Match '^\.\.\.'
        $result | Should -Match 'project'
        Get-DisplayWidth -Text $result | Should -Be 15
    }
    It 'hits the exact display width even when truncating full-width text' {
        $result = Format-FixedWidth -Text '日本語の長いプロジェクト名' -Width 10
        Get-DisplayWidth -Text $result | Should -Be 10
    }
    It 'ASCII fast path and original path agree at the boundary width (Width=4)' {
        $result = Format-FixedWidth -Text 'abcdefghij' -Width 4
        $result | Should -Match '…$'
        Get-DisplayWidth -Text $result | Should -Be 4
    }
    It 'ASCII fast path with -KeepEnd agrees at the boundary width (Width=4)' {
        $result = Format-FixedWidth -Text 'abcdefghij' -Width 4 -KeepEnd
        $result | Should -Be '...j'
    }
    It 'ASCII with Width below 4 gives the same result as the original path (-KeepEnd)' {
        $result = Format-FixedWidth -Text 'abcdefghij' -Width 3 -KeepEnd
        Get-DisplayWidth -Text $result | Should -Be 3
    }
    It 'hits the exact display width with a few non-ASCII characters mixed in (not on the fast path)' {
        $result = Format-FixedWidth -Text 'abcdeテストfghij' -Width 8 -KeepEnd
        Get-DisplayWidth -Text $result | Should -Be 8
    }
    It 'pads correctly on the fast path for an ASCII string that fits' {
        $result = Format-FixedWidth -Text 'abc' -Width 8
        $result | Should -Be 'abc     '
        Get-DisplayWidth -Text $result | Should -Be 8
    }
}

Describe 'Get-SearchTerms' {
    <#
    Get-SearchTerms follows the leading-comma contract too (same as Get-FilteredSessions).
    The result is taken without @().
    #>
    It 'returns an empty array for an empty string' {
        (Get-SearchTerms -Filter '').Count | Should -Be 0
    }
    It 'splits into whitespace-separated terms' {
        $terms = Get-SearchTerms -Filter 'alpha beta'
        $terms.Count | Should -Be 2
        $terms | Should -Contain 'alpha'
        $terms | Should -Contain 'beta'
    }
    It 'ignores repeated and surrounding whitespace' {
        $terms = Get-SearchTerms -Filter '  alpha   beta  '
        $terms.Count | Should -Be 2
    }
}

Describe 'Test-SessionMatch' {
    BeforeAll {
        $session = [pscustomobject]@{ Title = 'Refactor TUI'; Cwd = 'C:\work\sample\backend' }
    }
    It 'matches the session name' {
        Test-SessionMatch -Session $session -Terms @('refactor') | Should -BeTrue
    }
    It 'matches a term found only in the path' {
        Test-SessionMatch -Session $session -Terms @('backend') | Should -BeTrue
    }
    It 'ignores case' {
        Test-SessionMatch -Session $session -Terms @('REFACTOR') | Should -BeTrue
    }
    It 'is true for multiple terms only when all match (AND)' {
        Test-SessionMatch -Session $session -Terms @('refactor', 'backend') | Should -BeTrue
        Test-SessionMatch -Session $session -Terms @('refactor', 'nomatch') | Should -BeFalse
    }
    It 'is false for a term that does not match' {
        Test-SessionMatch -Session $session -Terms @('nomatch') | Should -BeFalse
    }
    It 'treats [ and * as literal characters, not regex/wildcards' {
        $s = [pscustomobject]@{ Title = '[FIX] bug'; Cwd = 'C:\dev' }
        Test-SessionMatch -Session $s -Terms @('[FIX]') | Should -BeTrue
        Test-SessionMatch -Session $s -Terms @('*') | Should -BeFalse
    }
}

Describe 'Get-FilteredSessions' {
    <#
    Get-FilteredSessions uses a leading comma (, @(...)) internally, so by contract it returns
    the result as "one pipeline object = the array itself" (every call site in
    claude-sessions.ps1 assigns it directly without @() on that assumption). The tests take
    it without @() as well.
    #>
    BeforeAll {
        $sessions = @(
            [pscustomobject]@{ Title = 'frontend-spec'; Cwd = 'C:\work\frontend' }
            [pscustomobject]@{ Title = $null; Cwd = 'C:\work\backend\payment' }
        )
    }
    It 'returns everything when the filter is empty' {
        (Get-FilteredSessions -Sessions $sessions -Filter '').Count | Should -Be 2
    }
    It 'filters by a term found only in the path' {
        $r = Get-FilteredSessions -Sessions $sessions -Filter 'backend'
        $r.Count | Should -Be 1
        $r[0].Cwd | Should -Match 'backend'
    }
    It 'returns nothing for a term that does not match' {
        $r = Get-FilteredSessions -Sessions $sessions -Filter 'zzz_no_such_term'
        $r.Count | Should -Be 0
    }
}

Describe 'Get-ProjectName' {
    It 'returns the last element of the path' {
        Get-ProjectName -Cwd 'C:\work\frontend' | Should -Be 'frontend'
    }
}

Describe 'Get-TabColorForPath' {
    It 'always returns the same color for the same path (deterministic)' {
        $a = Get-TabColorForPath -Cwd 'C:\work\project-a'
        $b = Get-TabColorForPath -Cwd 'C:\work\project-a'
        $a | Should -Be $b
    }
    It 'returns a color from the configured palette' {
        $color = Get-TabColorForPath -Cwd 'C:\work\project-b'
        $script:Config.TabColors | Should -Contain $color
    }
}

Describe 'Get-MatchRanges and Add-MatchHighlight' {
    <#
    Get-MatchRanges also returns "one pipeline object = the List itself" via a leading comma
    (same contract as Get-FilteredSessions). The result is taken without @().
    #>
    It 'returns the match range of a single term' {
        $ranges = Get-MatchRanges -Text 'data-view' -Terms @('view')
        $ranges.Count | Should -Be 1
        $ranges[0][0] | Should -Be 5
        $ranges[0][1] | Should -Be 9
    }
    It 'merges overlapping and adjacent ranges of multiple terms into one' {
        $ranges = Get-MatchRanges -Text 'abcabc' -Terms @('abc', 'bca')
        $ranges.Count | Should -Be 1
        $ranges[0][0] | Should -Be 0
        $ranges[0][1] | Should -Be 6
    }
    It 'is empty when nothing matches' {
        (Get-MatchRanges -Text 'nomatch' -Terms @('xyz')).Count | Should -Be 0
    }
    It 'covers overlapping matches of one term' {
        $ranges = Get-MatchRanges -Text 'xaaay' -Terms @('aa')
        $ranges.Count | Should -Be 1
        $ranges[0][0] | Should -Be 1
        $ranges[0][1] | Should -Be 4
    }
    It 'merges a run of overlapping matches into one range' {
        $ranges = Get-MatchRanges -Text 'aaaa' -Terms @('aa')
        $ranges.Count | Should -Be 1
        $ranges[0][0] | Should -Be 0
        $ranges[0][1] | Should -Be 4
    }
    It 'keeps the display width after stripping ANSI (regression test)' {
        # There used to be a bug where a later term matched a fragment of an ANSI escape
        # inserted just before ("m" of "93m", etc.), breaking the escape and changing the width.
        $cell = Format-FixedWidth -Text 'import-module' -Width 20
        $highlighted = Add-MatchHighlight -Text $cell -Terms @('import', 'm')
        $stripped = [regex]::Replace($highlighted, [char]27 + '\[[0-9;]*m', '')
        Get-DisplayWidth -Text $stripped | Should -Be 20
    }
    It 'returns the original string unchanged when nothing matches (no ANSI)' {
        $result = Add-MatchHighlight -Text 'plain text' -Terms @('xyz')
        $result | Should -Be 'plain text'
    }
    It 'returns the original string unchanged when Terms is empty' {
        Add-MatchHighlight -Text 'plain text' -Terms @() | Should -Be 'plain text'
    }
}

Describe 'Get-StatusCell' {
    It 'gives an empty label when not running (OpenEntry is $null)' {
        $label, $color = Get-StatusCell -OpenEntry $null
        $label | Should -Be ''
        $color | Should -BeNullOrEmpty
    }
    It 'gives the configured label and color for a known status' {
        $entry = [pscustomobject]@{ Pid = 1; Status = 'busy' }
        $label, $color = Get-StatusCell -OpenEntry $entry
        $label | Should -Be $script:Text.StatusLabels['busy']
        $color | Should -Be $script:Config.StatusColors['busy']
    }
    It 'gives shell the same label and color as busy' {
        $entry = [pscustomobject]@{ Pid = 1; Status = 'shell' }
        $label, $color = Get-StatusCell -OpenEntry $entry
        $label | Should -Be $script:Text.StatusLabels['busy']
        $color | Should -Be $script:Config.StatusColors['busy']
    }
    It 'gives an unknown status UnknownStatusLabel and no color' {
        $entry = [pscustomobject]@{ Pid = 1; Status = 'future_status' }
        $label, $color = Get-StatusCell -OpenEntry $entry
        $label | Should -Be $script:Text.UnknownStatusLabel
        $color | Should -BeNullOrEmpty
    }
}

Describe 'Test-ProcessRecordMatch' {
    It 'is $false when the process name does not start with claude' {
        Test-ProcessRecordMatch -ProcessName 'notepad' -ProcessStartFileTime 100 -RecordProcStart '100' |
            Should -BeFalse
    }
    It 'also accepts a prefix match such as claude.exe.old.TIMESTAMP after a self-update' {
        Test-ProcessRecordMatch -ProcessName 'claude.exe.old.20260101' -ProcessStartFileTime 100 `
            -RecordProcStart '100' | Should -BeTrue
    }
    It 'is $true when procStart matches' {
        Test-ProcessRecordMatch -ProcessName 'claude' -ProcessStartFileTime 134346141787217922 `
            -RecordProcStart '134346141787217922' | Should -BeTrue
    }
    It 'is $false when procStart differs (PID reuse)' {
        Test-ProcessRecordMatch -ProcessName 'claude' -ProcessStartFileTime 134346141787217922 `
            -RecordProcStart '999999999999999999' | Should -BeFalse
    }
    It 'accepts as undecidable when ProcessStartFileTime is unavailable' {
        Test-ProcessRecordMatch -ProcessName 'claude' -ProcessStartFileTime $null `
            -RecordProcStart '134346141787217922' | Should -BeTrue
    }
    It 'accepts as undecidable when RecordProcStart is missing (older Claude Code, etc.)' {
        Test-ProcessRecordMatch -ProcessName 'claude' -ProcessStartFileTime 100 `
            -RecordProcStart $null | Should -BeTrue
    }
    It 'accepts as undecidable when RecordProcStart is not a number' {
        Test-ProcessRecordMatch -ProcessName 'claude' -ProcessStartFileTime 100 `
            -RecordProcStart 'not-a-number' | Should -BeTrue
    }
}

Describe 'Get-SearchCursorColumn' {
    It 'returns the label display width + 1 when the search term is empty' {
        Get-SearchCursorColumn -Label 'search: ' -Filter '' | Should -Be 9
    }
    It 'moves right by the character count for a half-width term' {
        Get-SearchCursorColumn -Label 'search: ' -Filter 'abc' | Should -Be 12
    }
    It 'moves right by 2 columns per full-width character' {
        Get-SearchCursorColumn -Label 'search: ' -Filter 'ポ' | Should -Be 11
    }
    It 'adds up by display width for mixed half-width and full-width text' {
        Get-SearchCursorColumn -Label 'search: ' -Filter 'aポb' | Should -Be 13
    }
}

Describe 'Get-SessionColumnWidths' {
    It 'keeps the total width including fixed parts within the screen width' {
        # [Console]::WindowWidth throws in a non-interactive environment and falls back to 100.
        $widths = Get-SessionColumnWidths
        $widths.Title | Should -BeGreaterOrEqual $script:Config.TitleMinWidth
        $widths.Path | Should -BeGreaterOrEqual $script:Config.PathMinWidth
    }
    It 'keeps the session name width within the cap' {
        $widths = Get-SessionColumnWidths
        $widths.Title | Should -BeLessOrEqual $script:Config.TitleMaxWidth
    }
}

Describe 'Get-SessionFrame preview line' {
    BeforeAll {
        $script:frameSessions = @(
            [pscustomobject]@{ SessionId = 'a'; Title = 't'; Cwd = 'C:\work\a'; Modified = [datetime]'2026-09-25 10:00' }
        )
        function Get-PlainLines([string]$Frame) {
            @(([regex]::Replace($Frame, [char]27 + '\[[0-9;?]*[A-Za-z]', '')) -split "`n")
        }
    }
    It 'shows a heading and the prompt between rules, right below the list and above the key help' {
        $esc = [char]27
        $frame = Get-SessionFrame -Filtered $script:frameSessions -TotalCount 1 -OpenMap @{} -Filter '' `
            -SelectedIndex 0 -TopIndex 0 -PageSize 10 -PreviewText "直して`r`n  ください$esc[2J"
        $lines = Get-PlainLines $frame
        $lines[-7] | Should -Match '^-+ .+ --$'
        $lines[-6] | Should -Be "> $($script:Text.PreviewLabel)"
        $lines[-5] | Should -Be '  直して ください [2J'
        $lines[-4] | Should -Be ''
        $lines[-3] | Should -Match '^-+$'
        $lines[-2].StartsWith($script:Text.KeyHelp.Substring(0, 10)) | Should -BeTrue
    }
    It 'wraps a long prompt into the body lines' {
        $frame = Get-SessionFrame -Filtered $script:frameSessions -TotalCount 1 -OpenMap @{} -Filter '' `
            -SelectedIndex 0 -TopIndex 0 -PageSize 10 -PreviewText ('あ' * 200)
        $lines = Get-PlainLines $frame
        $lines[-5] | Should -Match '^  あ+$'
        $lines[-4] | Should -Match '^  あ+…$'
    }
    It 'says nothing is recorded when there is no prompt, keeping the block height' {
        $frame = Get-SessionFrame -Filtered $script:frameSessions -TotalCount 1 -OpenMap @{} -Filter '' `
            -SelectedIndex 0 -TopIndex 0 -PageSize 10
        $lines = Get-PlainLines $frame
        $lines[-6] | Should -Be "> $($script:Text.PreviewLabel)"
        $lines[-5] | Should -Be "  $($script:Text.PreviewEmpty)"
        $lines[-4] | Should -Be ''
    }
    It 'colors the marker like the selected row, grays the label and leaves the prompt plain' {
        $frame = Get-SessionFrame -Filtered $script:frameSessions -TotalCount 1 -OpenMap @{} -Filter '' `
            -SelectedIndex 0 -TopIndex 0 -PageSize 10 -PreviewText 'fix it'
        $lines = @($frame -split "`n")
        $reset = $script:Ansi.Reset
        $lines[-6].StartsWith("$($script:Ansi.Foreground.Cyan)>$reset $($script:Ansi.Foreground.BrightBlack)$($script:Text.PreviewLabel)$reset") |
            Should -BeTrue
        $lines[-5].StartsWith('  fix it') | Should -BeTrue
    }
}

Describe 'Get-SessionFrame layout' {
    BeforeAll {
        $script:layoutSessions = @(1..5 | ForEach-Object {
            [pscustomobject]@{ SessionId = "s$_"; Title = "t$_"; Cwd = "C:\work\p$_"; Modified = [datetime]'2026-09-25 10:00' }
        })
        function Get-LayoutFrame([object[]]$Filtered, [string]$Filter, [string]$Notice) {
            Get-SessionFrame -Filtered $Filtered -TotalCount 9 -OpenMap @{} -Filter $Filter `
                -SelectedIndex 0 -TopIndex 0 -PageSize 5 -Notice $Notice
        }
        function Get-PlainLines([string]$Frame) {
            @(([regex]::Replace($Frame, [char]27 + '\[[0-9;?]*[A-Za-z]', '')) -split "`n")
        }
    }
    AfterEach {
        Set-UiLanguage -Messages (Import-UiMessages -Language 'ja' -UICultureName 'ja-JP')
    }
    It 'puts the search line under the title and a blank line, and the notice line below it' {
        $lines = Get-PlainLines (Get-LayoutFrame -Filtered $script:layoutSessions -Filter 'p')
        $lines[1] | Should -Be ''
        $lines[2] | Should -Be "$($script:Text.SearchLabel)p"
        $lines[3] | Should -Be ''
        $lines[4].Trim().StartsWith($script:Text.HeaderStatus) | Should -BeTrue
        $lines[5] | Should -Match '^-+ .+ --$'
    }
    It 'moves the cursor to the end of the search text on the third line' {
        $frame = Get-LayoutFrame -Filtered @($script:layoutSessions[0]) -Filter 'ab'
        $column = Get-SearchCursorColumn -Label $script:Text.SearchLabel -Filter 'ab'
        $frame | Should -Match ([regex]::Escape("$([char]27)[3;${column}H") + '$')
    }
    It 'shows a notice on the line right below the search line' {
        (Get-PlainLines (Get-LayoutFrame -Filtered $script:layoutSessions -Filter '' -Notice 'oops'))[3] | Should -Be '! oops'
    }
    It 'sets the view into the rule above the list and the counts into the rule below it, as wide as the other rules (<Language>)' -TestCases @(
        @{ Language = 'ja' }
        @{ Language = 'en' }
    ) {
        param($Language)
        Set-UiLanguage -Messages (Import-UiMessages -Language $Language -UICultureName 'en-US')
        $lines = Get-PlainLines (Get-LayoutFrame -Filtered @($script:layoutSessions | Select-Object -First 2) -Filter '')
        $width = $lines[-3].Length
        $lines[-3] | Should -Match '^-+$'
        foreach ($case in @(@{ Line = $lines[5]; Text = $script:Text.ModeAll },
                @{ Line = $lines[8]; Text = ($script:Text.CountLine -f '1-2', 2, 9) })) {
            $case.Line | Should -BeExactly "$('-' * ($width - (Get-DisplayWidth -Text $case.Text) - 4)) $($case.Text) --"
            Get-DisplayWidth -Text $case.Line | Should -Be $width
        }
        $lines[8].Contains($script:Text.ModeAll) | Should -BeFalse
    }
    It 'shows the latest per directory view in the rule above the list' {
        $frame = Get-SessionFrame -Filtered $script:layoutSessions -TotalCount 9 -OpenMap @{} -Filter '' `
            -SelectedIndex 0 -TopIndex 0 -PageSize 5 -LatestPerDirectory
        (Get-PlainLines $frame)[5].EndsWith(" $($script:Text.ModeLatestPerDirectory) --") | Should -BeTrue
    }
    It 'does not pad the list, so the frame is 4 lines shorter with <Count> match(es)' -TestCases @(
        @{ Count = 1 }
        @{ Count = 0 }
    ) {
        param($Count)
        $full = Get-PlainLines (Get-LayoutFrame -Filtered $script:layoutSessions -Filter '')
        $lines = Get-PlainLines (Get-LayoutFrame -Filtered @($script:layoutSessions | Select-Object -First $Count) -Filter 'p')
        $lines.Count | Should -Be ($full.Count - 4)
    }
    It 'goes straight from the counts rule to the key help when the preview is hidden' {
        Mock Test-PreviewVisible { $false }
        $lines = Get-PlainLines (Get-LayoutFrame -Filtered @($script:layoutSessions[0]) -Filter '')
        $lines[-3] | Should -Match '^-+ .+ --$'
        $lines[-2].StartsWith($script:Text.KeyHelp.Substring(0, 10)) | Should -BeTrue
        $lines | Should -Not -Contain "> $($script:Text.PreviewLabel)"
    }
}

Describe 'Format-RuleWithLabel' {
    BeforeAll {
        function Get-Plain([string]$Text) { [regex]::Replace($Text, [char]27 + '\[[0-9;?]*[A-Za-z]', '') }
    }
    It 'sets the label into the right end of a rule of the given width' {
        Get-Plain (Format-RuleWithLabel -Label 'abc' -Width 12) | Should -BeExactly '----- abc --'
    }
    It 'truncates a label too wide for the rule, keeping the width' {
        $rule = Get-Plain (Format-RuleWithLabel -Label ('x' * 30) -Width 12)
        $rule | Should -Match '^- x+… --$'
        Get-DisplayWidth -Text $rule | Should -Be 12
    }
    It 'returns a plain rule when the width leaves no room for a label' {
        Get-Plain (Format-RuleWithLabel -Label 'abc' -Width 5) | Should -BeExactly '-----'
    }
}

Describe 'Split-DisplayLines' {
    It 'keeps text that fits on the first line and pads with empty lines' {
        $lines = Split-DisplayLines -Text 'short' -Width 10 -MaxLines 2
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be 'short'
        $lines[1] | Should -Be ''
    }
    It 'breaks text without spaces at any character' {
        $lines = Split-DisplayLines -Text 'abcdefghij' -Width 4 -MaxLines 3
        $lines | Should -Be @('abcd', 'efgh', 'ij')
    }
    It 'moves a break inside a word back to the start of the word' {
        $lines = Split-DisplayLines -Text 'fix the tests' -Width 10 -MaxLines 2
        $lines | Should -Be @('fix the', 'tests')
    }
    It 'breaks before a word that follows Japanese text, not at an earlier space' {
        $lines = Split-DisplayLines -Text 'ab あいうPlease' -Width 12 -MaxLines 2
        $lines | Should -Be @('ab あいう', 'Please')
    }
    It 'breaks a word as wide as the line where it must' {
        $lines = Split-DisplayLines -Text 'C:\work\project' -Width 8 -MaxLines 2
        $lines | Should -Be @('C:\work\', 'project')
    }
    It 'measures full-width text by display width' {
        $lines = Split-DisplayLines -Text 'あいうえお' -Width 4 -MaxLines 3
        $lines | Should -Be @('あい', 'うえ', 'お')
    }
    It 'cuts what does not fit on the last line with an ellipsis' {
        $lines = Split-DisplayLines -Text 'abcdefghij' -Width 4 -MaxLines 2
        $lines | Should -Be @('abcd', 'efg…')
    }
    It 'returns MaxLines empty lines for empty text' {
        $lines = Split-DisplayLines -Text '' -Width 4 -MaxLines 2
        $lines | Should -Be @('', '')
    }
}

Describe 'Get-KeyHelpLines' {
    BeforeAll {
        $script:help = '[A] one  [B] two  [C] three'
    }
    It 'keeps everything on the first line and leaves the second blank when it fits' {
        $lines = Get-KeyHelpLines -Text $script:help -Width 40
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be $script:help
        $lines[1] | Should -Be ''
    }
    It 'wraps between items, never inside one' {
        $lines = Get-KeyHelpLines -Text $script:help -Width 18
        $lines[0] | Should -Be '[A] one  [B] two'
        $lines[1] | Should -Be '[C] three'
    }
    It 'truncates what does not fit on the last line' {
        $lines = Get-KeyHelpLines -Text $script:help -Width 8
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be '[A] one'
        $lines[1] | Should -Be '[B] two…'
    }
    It 'measures full-width text by display width' {
        $lines = Get-KeyHelpLines -Text '[A] 選択  [B] 起動' -Width 16
        $lines[0] | Should -Be '[A] 選択'
        $lines[1] | Should -Be '[B] 起動'
    }
    It 'fits the real key help of every language in two lines at 100 columns' {
        foreach ($language in 'ja', 'en') {
            $messages = Import-PowerShellDataFile (Join-Path $script:SrcDir "$language\Messages.psd1")
            $lines = Get-KeyHelpLines -Text $messages.KeyHelp -Width 99
            ($lines -join '  ') | Should -Be $messages.KeyHelp -Because $language
        }
    }
}

Describe 'Get-PageSizeForHeight' {
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
        $script:Config.PageSize = 20
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'caps the rows at PageSize on a tall screen' {
        Get-PageSizeForHeight -Height 100 | Should -Be 20
    }
    It 'leaves room for the fixed lines and the preview block on a short screen' {
        Get-PageSizeForHeight -Height ($script:FrameFixedLines + $script:PreviewLines + 3) | Should -Be 3
    }
    It 'drops the preview block before the last list row' {
        Test-PreviewVisible -Height ($script:FrameFixedLines + $script:PreviewLines + 1) | Should -BeTrue
        Get-PageSizeForHeight -Height ($script:FrameFixedLines + $script:PreviewLines + 1) | Should -Be 1
        Test-PreviewVisible -Height ($script:FrameFixedLines + $script:PreviewLines) | Should -BeFalse
        # The old lower bound of 3 rows scrolled a screen this short.
        Get-PageSizeForHeight -Height ($script:FrameFixedLines + 1) | Should -Be 1
    }
    It 'still shows one row on a screen too short for any' {
        Get-PageSizeForHeight -Height 5 | Should -Be 1
    }
}

Describe 'Get-OpenMapSignature' {
    It 'is an empty string when no session is running' {
        Get-OpenMapSignature -OpenMap @{} | Should -Be ''
    }
    It 'reflects a status change' {
        $before = Get-OpenMapSignature -OpenMap @{ 'a' = [pscustomobject]@{ Pid = 1; Status = 'busy' } }
        $after = Get-OpenMapSignature -OpenMap @{ 'a' = [pscustomobject]@{ Pid = 1; Status = 'idle' } }
        $before | Should -Not -Be $after
    }
    It 'does not change when only Pid changes (it is not displayed)' {
        $a = Get-OpenMapSignature -OpenMap @{ 'a' = [pscustomobject]@{ Pid = 1; Status = 'busy' } }
        $b = Get-OpenMapSignature -OpenMap @{ 'a' = [pscustomobject]@{ Pid = 2; Status = 'busy' } }
        $a | Should -Be $b
    }
    It 'does not depend on key enumeration order' {
        $a = Get-OpenMapSignature -OpenMap @{
            'a' = [pscustomobject]@{ Pid = 1; Status = 'busy' }
            'b' = [pscustomobject]@{ Pid = 2; Status = 'idle' }
        }
        $b = Get-OpenMapSignature -OpenMap @{
            'b' = [pscustomobject]@{ Pid = 2; Status = 'idle' }
            'a' = [pscustomobject]@{ Pid = 1; Status = 'busy' }
        }
        $a | Should -Be $b
    }
}

Describe 'Get-FrameSignature' {
    <#
    Changes the inputs of Get-SessionFrame one at a time and checks that the signature always
    changes. An input missing from the signature causes a subtle "screen does not update" bug,
    so they correspond one to one with the parameters of Get-SessionFrame and the external
    state it reads.
    #>
    BeforeAll {
        $base = @{
            Filter           = 'abc'
            SelectedIndex    = 1
            TopIndex         = 0
            PageSize         = 20
            TotalCount       = 10
            FilteredCount    = 5
            Notice           = 'notice'
            ConsoleSize      = '100x30'
            OpenMapSignature = 'a=busy'
            SessionsRevision = 0
            LatestPerDirectory = $false
            PreviewText      = 'last prompt'
        }
    }
    It 'builds a signature from the base values' {
        (Get-FrameSignature @base) | Should -Not -BeNullOrEmpty
    }
    It 'does not throw when Notice is $null (coerced to '''' by the string type)' {
        # The -Notice parameter of Get-SessionFrame has the same [string] type and conversion,
        # and rendering (if ($Notice) {...} else {''}) does not distinguish $null from '' either.
        # Overridden in a copy of the splat: Windows PowerShell 5.1 rejects a parameter given both
        # in a splat and explicitly (7 lets the explicit one win).
        $params = $base.Clone()
        $params.Notice = $null
        { Get-FrameSignature @params } | Should -Not -Throw
    }
    It 'changes when any parameter changes' {
        $baseSig = Get-FrameSignature @base
        $overrides = @{
            Filter           = 'xyz'
            SelectedIndex    = 2
            TopIndex         = 1
            PageSize         = 15
            TotalCount       = 11
            FilteredCount    = 6
            Notice           = 'different'
            ConsoleSize      = '120x40'
            OpenMapSignature = 'a=idle'
            SessionsRevision = 1
            LatestPerDirectory = $true
            PreviewText      = 'another prompt'
        }
        foreach ($key in $overrides.Keys) {
            $changed = $base.Clone()
            $changed[$key] = $overrides[$key]
            $sig = Get-FrameSignature @changed
            $sig | Should -Not -Be $baseSig -Because "a change in $key should be reflected in the signature"
        }
    }
}

Describe 'Get-SessionFileInfoFast / Get-SessionFileInfoFull agree (synthetic data)' {
    <#
    The fast path (Get-SessionFileInfoFast) is an approximation that looks for cwd only in the
    first few lines and for the latest aiTitle only in the last few tens of KB; the
    implementation assumes it always returns the same result as the full scan
    (Get-SessionFileInfoFull) (see the Get-SessionFileInfo comments in claude-sessions.ps1).
    This verifies that assumption with synthetic files on TestDrive.
    It does not depend on real data (~/.claude/projects), so it always runs.
    #>
    BeforeAll {
        function New-TestSessionFile {
            <#
            Creates a synthetic jsonl large enough to trigger the fast path (more than
            $script:Config.TailScanBytes). cwd goes on line 1, an "old" ai-title in the middle
            and the "latest" one near the end, to also confirm that the last value wins.
            #>
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Cwd,
                [string]$FinalTitle,
                [switch]$NoTitle
            )
            $cwdEscaped = $Cwd -replace '\\', '\\\\'
            $filler = '{"type":"message","content":"' + ('x' * 150) + '"}'

            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('{"type":"session-meta","cwd":"' + $cwdEscaped + '"}')
            for ($i = 0; $i -lt 400; $i++) { $lines.Add($filler) }
            if (-not $NoTitle) {
                # The first half of the file (400 lines) is already written at this point, to
                # push the "old" value outside the tail scan window. One old title goes here, to
                # also confirm that only the last value is used.
                $lines.Add('{"type":"ai-title","aiTitle":"古いタイトル"}')
            }
            for ($i = 0; $i -lt 400; $i++) { $lines.Add($filler) }
            if (-not $NoTitle) {
                $lines.Add('{"type":"ai-title","aiTitle":"' + $FinalTitle + '"}')
            }
            for ($i = 0; $i -lt 50; $i++) { $lines.Add($filler) }

            # Write UTF-8 without BOM, which the fast path assumes (Set-Content -Encoding utf8
            # is not used because whether it writes a BOM depends on the environment).
            [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'fast path and full scan agree on a large file with a latest ai-title' {
        $path = Join-Path $TestDrive 'large-with-title.jsonl'
        New-TestSessionFile -Path $path -Cwd 'C:\Users\test\large-project' -FinalTitle '最新タイトル'
        $file = Get-Item $path
        $file.Length | Should -BeGreaterThan $script:Config.TailScanBytes

        $fast = Get-SessionFileInfoFast -File $file
        $full = Get-SessionFileInfoFull -File $file

        $fast | Should -Not -BeNullOrEmpty
        $fast.Cwd | Should -Be $full.Cwd
        $fast.Title | Should -Be $full.Title
        $full.Title | Should -Be '最新タイトル'
    }

    It 'fast path returns $null without an ai-title and Get-SessionFileInfo falls back to the full scan' {
        $path = Join-Path $TestDrive 'large-no-title.jsonl'
        New-TestSessionFile -Path $path -Cwd 'C:\Users\test\no-title-project' -NoTitle
        $file = Get-Item $path
        $file.Length | Should -BeGreaterThan $script:Config.TailScanBytes

        Get-SessionFileInfoFast -File $file | Should -BeNullOrEmpty

        $dispatched = Get-SessionFileInfo -File $file
        $full = Get-SessionFileInfoFull -File $file
        $dispatched.Cwd | Should -Be $full.Cwd
        $dispatched.Title | Should -Be $full.Title
        $dispatched.Title | Should -BeNullOrEmpty
    }

    It 'a small file within TailScanBytes skips the fast path and matches the full scan' {
        $path = Join-Path $TestDrive 'small.jsonl'
        $lines = @(
            '{"type":"session-meta","cwd":"C:\\Users\\test\\small-project"}'
            '{"type":"ai-title","aiTitle":"small title"}'
        )
        [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
        $file = Get-Item $path
        $file.Length | Should -BeLessOrEqual $script:Config.TailScanBytes

        $result = Get-SessionFileInfo -File $file
        $result.Cwd | Should -Be 'C:\Users\test\small-project'
        $result.Title | Should -Be 'small title'
    }

    It 'fast path and full scan agree on the last prompt, skipping lines without one' {
        $path = Join-Path $TestDrive 'large-with-prompt.jsonl'
        $filler = '{"type":"message","content":"' + ('x' * 150) + '"}'
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('{"type":"session-meta","cwd":"C:\\Users\\test\\prompt-project"}')
        $lines.Add('{"type":"last-prompt","lastPrompt":"古い入力","sessionId":"s"}')
        for ($i = 0; $i -lt 900; $i++) { $lines.Add($filler) }
        $lines.Add('{"type":"ai-title","aiTitle":"title"}')
        $lines.Add('{"type":"last-prompt","lastPrompt":"最新の入力","leafUuid":"u1","sessionId":"s"}')
        # Claude Code also writes last-prompt lines with only leafUuid; they must not clear it.
        $lines.Add('{"type":"last-prompt","leafUuid":"u2","sessionId":"s"}')
        [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
        $file = Get-Item $path
        $file.Length | Should -BeGreaterThan $script:Config.TailScanBytes

        $fast = Get-SessionFileInfoFast -File $file
        $full = Get-SessionFileInfoFull -File $file
        $fast.LastPrompt | Should -Be '最新の入力'
        $full.LastPrompt | Should -Be '最新の入力'
    }

    It 'fast path leaves the last prompt empty when it is outside the tail instead of falling back' {
        $path = Join-Path $TestDrive 'large-old-prompt.jsonl'
        $filler = '{"type":"message","content":"' + ('x' * 150) + '"}'
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('{"type":"session-meta","cwd":"C:\\Users\\test\\old-prompt"}')
        $lines.Add('{"type":"last-prompt","lastPrompt":"ずっと前の入力"}')
        for ($i = 0; $i -lt 900; $i++) { $lines.Add($filler) }
        $lines.Add('{"type":"ai-title","aiTitle":"title"}')
        [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
        $fast = Get-SessionFileInfoFast -File (Get-Item $path)
        $fast | Should -Not -BeNullOrEmpty
        $fast.Title | Should -Be 'title'
        $fast.LastPrompt | Should -BeNullOrEmpty
    }
}

Describe 'Read-LastPromptRecord' {
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'returns the prompt of a last-prompt line' {
        Read-LastPromptRecord -Line '{"type":"last-prompt","lastPrompt":"テストを直して\nお願い","sessionId":"s"}' |
            Should -Be "テストを直して`nお願い"
    }
    It 'returns $null for a last-prompt line without a prompt' {
        Read-LastPromptRecord -Line '{"type":"last-prompt","leafUuid":"u","sessionId":"s"}' | Should -BeNullOrEmpty
    }
    It 'returns $null for another type that merely contains the marker' {
        Read-LastPromptRecord -Line '{"type":"user","lastPrompt":"x","nested":{"type":"last-prompt"}}' | Should -BeNullOrEmpty
    }
    It 'returns $null for a broken line instead of throwing' {
        Read-LastPromptRecord -Line '{"type":"last-prompt","lastPrompt":"cut' | Should -BeNullOrEmpty
    }
    It 'cuts a long prompt to PreviewMaxLength without splitting a surrogate pair' {
        $script:Config.PreviewMaxLength = 5
        Read-LastPromptRecord -Line '{"type":"last-prompt","lastPrompt":"abcdefgh"}' | Should -Be 'abcde'
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $result = Read-LastPromptRecord -Line ('{"type":"last-prompt","lastPrompt":"abcd' + $emoji + 'xyz"}')
        $result | Should -Be 'abcd'
    }
}

Describe 'Get-SessionIndex cache' {
    <#
    The cache must read back the same on Windows PowerShell 5.1 and 7, whichever wrote it,
    so it is written as UTF-8 without BOM and must be reused without rescanning.
    #>
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config.ProjectsDir = Join-Path $root 'projects'
        $script:Config.CacheDir = Join-Path $root 'cache'
        $script:Config.CachePath = Join-Path $root 'cache\index.json'
        $project = Join-Path $script:Config.ProjectsDir 'C--work-app'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $lines = @('{"cwd":"C:\\work\\app","type":"user"}', '{"type":"ai-title","aiTitle":"画面の設計"}')
        [System.IO.File]::WriteAllLines((Join-Path $project "$([guid]::NewGuid()).jsonl"), $lines,
            [System.Text.UTF8Encoding]::new($false))
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'writes the cache as UTF-8 without BOM' {
        $null = Get-SessionIndex
        $bytes = [System.IO.File]::ReadAllBytes($script:Config.CachePath)
        ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Match '画面の設計'
    }
    It 'reuses the cached entry, including a non-ASCII title, without rescanning' {
        $null = Get-SessionIndex
        Mock Get-SessionFileInfo { throw 'must not rescan' }
        $sessions = Get-SessionIndex
        $sessions.Count | Should -Be 1
        $sessions[0].Title | Should -Be '画面の設計'
        Should -Invoke Get-SessionFileInfo -Times 0
    }
    It 'rescans an entry written before LastPrompt was indexed, once' {
        $null = Get-SessionIndex
        $json = [System.IO.File]::ReadAllText($script:Config.CachePath) -replace ',\s*"LastPrompt":\s*null', ''
        $json | Should -Not -Match 'LastPrompt'
        [System.IO.File]::WriteAllText($script:Config.CachePath, $json)
        $sessions = Get-SessionIndex
        $sessions[0].Title | Should -Be '画面の設計'
        [System.IO.File]::ReadAllText($script:Config.CachePath) | Should -Match 'LastPrompt'
        Mock Get-SessionFileInfo { throw 'must not rescan' }
        $null = Get-SessionIndex
        Should -Invoke Get-SessionFileInfo -Times 0
    }
    It 'rescans an entry whose Modified is broken instead of failing' {
        $null = Get-SessionIndex
        $json = [System.IO.File]::ReadAllText($script:Config.CachePath) -replace '"Modified":\s*"[^"]*"', '"Modified": "not a date"'
        [System.IO.File]::WriteAllText($script:Config.CachePath, $json)
        $sessions = Get-SessionIndex
        $sessions.Count | Should -Be 1
        $sessions[0].Title | Should -Be '画面の設計'
    }
}

Describe 'Find-SessionFile / Add-NewSessions' {
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
        $script:Config.ProjectsDir = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))\projects"
        $script:id = [guid]::NewGuid().ToString()
        $script:projectDir = Join-Path $script:Config.ProjectsDir 'C--work-app'
        New-Item -ItemType Directory -Path (Join-Path $script:Config.ProjectsDir 'C--other'), $script:projectDir -Force | Out-Null
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'finds the jsonl of a session in whichever project folder holds it' {
        $path = Join-Path $script:projectDir "$($script:id).jsonl"
        Set-Content -LiteralPath $path -Value '{}'
        Find-SessionFile -SessionId $script:id | Should -Be $path
    }
    It 'returns $null when the file is not there yet, or only deeper down' {
        Find-SessionFile -SessionId $script:id | Should -BeNullOrEmpty
        $deep = Join-Path $script:projectDir 'sub'
        New-Item -ItemType Directory -Path $deep | Out-Null
        Set-Content -LiteralPath (Join-Path $deep "$($script:id).jsonl") -Value '{}'
        Find-SessionFile -SessionId $script:id | Should -BeNullOrEmpty
    }
    It 'rejects an ID that is not a GUID and a missing ProjectsDir' {
        Find-SessionFile -SessionId '*' | Should -BeNullOrEmpty
        $script:Config.ProjectsDir = Join-Path $TestDrive 'no-such-dir'
        Find-SessionFile -SessionId $script:id | Should -BeNullOrEmpty
    }
    It 'adds new sessions in date order and skips known IDs and entries without a cwd' {
        $sessions = @(
            [pscustomobject]@{ SessionId = 'b'; Cwd = 'C:\b'; Modified = [datetime]'2026-10-02' }
            [pscustomobject]@{ SessionId = 'd'; Cwd = 'C:\d'; Modified = [datetime]'2026-09-30' }
        )
        $new = @(
            [pscustomobject]@{ SessionId = 'a'; Cwd = 'C:\a'; Modified = [datetime]'2026-10-03' }
            [pscustomobject]@{ SessionId = 'c'; Cwd = 'C:\c'; Modified = [datetime]'2026-10-01' }
            [pscustomobject]@{ SessionId = 'b'; Cwd = 'C:\b'; Modified = [datetime]'2026-10-05' }
            [pscustomobject]@{ SessionId = 'e'; Cwd = $null; Modified = [datetime]'2026-10-05' }
        )
        $result = Add-NewSessions -Sessions $sessions -NewInfos $new
        @($result | ForEach-Object { $_.SessionId }) | Should -Be @('a', 'b', 'c', 'd')
    }
    It 'returns the list unchanged, as an array, when nothing is new' {
        $one = @([pscustomobject]@{ SessionId = 'a'; Cwd = 'C:\a'; Modified = [datetime]'2026-10-01' })
        $result = Add-NewSessions -Sessions $one -NewInfos @()
        $result -is [object[]] | Should -BeTrue
        $result.Count | Should -Be 1
        (Add-NewSessions -Sessions @() -NewInfos $one).Count | Should -Be 1
    }
}

Describe 'Get-SessionFileInfo (consistency with real data)' {
    <#
    A regression test, only where ~/.claude/projects exists, that the fast path and the full
    scan agree on real session files.
    The Skip condition is evaluated in the Discovery phase (before BeforeAll runs), so it builds
    the same path as Get-SessionIndex directly instead of relying on $script:Config.
    #>
    $hasProjectsDir = Test-Path (Join-Path $env:USERPROFILE '.claude\projects')

    It 'fast path and full scan agree on Cwd / Title for real session jsonl files' -Skip:(-not $hasProjectsDir) {
        $files = @(Get-ChildItem -Path $script:Config.ProjectsDir -Recurse -Depth 1 -Filter '*.jsonl' -File |
            Where-Object { $_.Length -gt $script:Config.TailScanBytes })
        $files.Count | Should -BeGreaterThan 0

        foreach ($file in $files) {
            $full = Get-SessionFileInfoFull -File $file
            $dispatched = Get-SessionFileInfo -File $file
            $dispatched.Cwd | Should -Be $full.Cwd -Because "cwd mismatch: $($file.Name)"
            $dispatched.Title | Should -Be $full.Title -Because "title mismatch: $($file.Name)"
        }
    }
}

Describe 'Open-SharedReadStream' {
    It 'reads even while another process holds a write handle' {
        $path = Join-Path $TestDrive 'locked.jsonl'
        [System.IO.File]::WriteAllText($path, "line1`n")
        # Simulates Claude Code keeping the file open for appending.
        $writer = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new((Open-SharedReadStream -Path $path))
            try { $reader.ReadLine() | Should -Be 'line1' } finally { $reader.Dispose() }
        } finally {
            $writer.Dispose()
        }
    }
}

Describe 'Invoke-LaunchAction / Open-ClaudeSession' {
    <#
    Start-ClaudeSession / Show-ClaudeWindow are mocked so wt.exe is never actually started,
    and failures or a missing working directory are checked to come back as a message rather
    than an exception.
    #>
    It 'returns $null on success' {
        Invoke-LaunchAction -Cwd $TestDrive -Action { } | Should -BeNullOrEmpty
    }
    It 'turns an exception into a message' {
        $result = Invoke-LaunchAction -Cwd $TestDrive -Action { throw 'wt.exe not found' }
        $result | Should -BeLike '*wt.exe not found*'
    }
    It 'returns a message without running the action when the working directory is missing' {
        $script:called = $false
        $missing = Join-Path $TestDrive 'no-such-dir'
        $result = Invoke-LaunchAction -Cwd $missing -Action { $script:called = $true }
        $result | Should -BeLike "*$missing*"
        $script:called | Should -BeFalse
    }
    It 'does not call Start-ClaudeSession when the cwd of a stopped session is gone' {
        Mock Start-ClaudeSession { }
        $session = [pscustomobject]@{ SessionId = 'abc'; Cwd = (Join-Path $TestDrive 'gone') }
        $result = Open-ClaudeSession -Session $session -OpenMap @{}
        $result | Should -Not -BeNullOrEmpty
        Should -Invoke Start-ClaudeSession -Times 0
    }
    It 'opens a stopped session with Start-ClaudeSession and returns $null' {
        Mock Start-ClaudeSession { }
        $session = [pscustomobject]@{ SessionId = 'abc'; Cwd = $TestDrive }
        Open-ClaudeSession -Session $session -OpenMap @{} | Should -BeNullOrEmpty
        Should -Invoke Start-ClaudeSession -Times 1 -ParameterFilter { $SessionId -eq 'abc' }
    }

    Context 'running session in windows mode' {
        BeforeEach {
            $script:savedConfig = $script:Config.Clone()
            $script:Config.WindowMode = 'windows'
            Mock Select-TerminalTab { [IntPtr]::Zero }
            $script:session = [pscustomobject]@{ SessionId = 'abc'; Cwd = $TestDrive }
            $script:openMap = @{ 'abc' = [pscustomobject]@{ Pid = 1234; Status = 'idle' } }
            Mock Start-ClaudeSession { }
            Mock Show-ClaudeWindow { }
            Mock Get-ConsoleOwnerWindow { [IntPtr]42 }
            Mock Show-OwnerWindow { $true }
        }
        AfterEach {
            $script:Config = $script:savedConfig
        }
        It 'never looks for a tab' {
            Mock Test-LaunchedByTool { $true }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeNullOrEmpty
            Should -Invoke Select-TerminalTab -Times 0
        }
        It 'focuses a window opened by the tool by its name without walking from the console' {
            Mock Test-LaunchedByTool { $true }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeNullOrEmpty
            Should -Invoke Show-ClaudeWindow -Times 1
            Should -Invoke Get-ConsoleOwnerWindow -Times 0
        }
        It 'focuses any other window by walking from the console and returns $null' {
            Mock Test-LaunchedByTool { $false }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeNullOrEmpty
            Should -Invoke Get-ConsoleOwnerWindow -Times 1 -ParameterFilter { $ClaudePid -eq 1234 }
            Should -Invoke Show-OwnerWindow -Times 1
            Should -Invoke Show-ClaudeWindow -Times 0
        }
        It 'returns a message and opens nothing new when the window is not found' {
            Mock Test-LaunchedByTool { $false }
            Mock Get-ConsoleOwnerWindow { [IntPtr]::Zero }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeLike '*既に開いています*'
            Should -Invoke Show-OwnerWindow -Times 0
            Should -Invoke Start-ClaudeSession -Times 0
        }
        It 'returns a message when focusing fails' {
            Mock Test-LaunchedByTool { $false }
            Mock Show-OwnerWindow { $false }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeLike '*既に開いています*'
        }
        It 'turns an exception into a message too' {
            Mock Test-LaunchedByTool { $false }
            Mock Get-ConsoleOwnerWindow { throw 'helper missing' }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeLike '*既に開いています*'
        }
        It 'attaches to a background session by its job ID instead of focusing' {
            Mock Test-LaunchedByTool { $true }
            $openMap = @{ 'abc' = [pscustomobject]@{ Pid = 1234; Status = 'idle'; Kind = 'bg'; JobId = '7f9d969b' } }
            Open-ClaudeSession -Session $script:session -OpenMap $openMap | Should -BeNullOrEmpty
            Should -Invoke Start-ClaudeSession -Times 1 -ParameterFilter { $AttachJobId -eq '7f9d969b' -and $SessionId -eq 'abc' }
            Should -Invoke Test-LaunchedByTool -Times 0
            Should -Invoke Get-ConsoleOwnerWindow -Times 0
        }
        It 'focuses as usual a background record without a job ID' {
            Mock Test-LaunchedByTool { $true }
            $openMap = @{ 'abc' = [pscustomobject]@{ Pid = 1234; Status = 'idle'; Kind = 'bg'; JobId = '' } }
            Open-ClaudeSession -Session $script:session -OpenMap $openMap | Should -BeNullOrEmpty
            Should -Invoke Show-ClaudeWindow -Times 1
            Should -Invoke Start-ClaudeSession -Times 0
        }
    }

    Context 'running session in tabs mode' {
        BeforeEach {
            $script:savedConfig = $script:Config.Clone()
            $script:Config.WindowMode = 'tabs'
            $script:session = [pscustomobject]@{ SessionId = 'abcdef12-0000-0000-0000-000000000000'; Cwd = $TestDrive }
            $script:openMap = @{ $script:session.SessionId = [pscustomobject]@{ Pid = 1234; Status = 'idle' } }
            $script:bgMap = @{ $script:session.SessionId = [pscustomobject]@{ Pid = 1234; Status = 'idle'; Kind = 'bg'; JobId = '7f9d969b' } }
            Mock Start-ClaudeSession { }
            Mock Show-ClaudeWindow { }
            Mock Test-LaunchedByTool { $true }
            Mock Get-ConsoleOwnerWindow { [IntPtr]42 }
            Mock Show-OwnerWindow { $true }
        }
        AfterEach {
            $script:Config = $script:savedConfig
        }
        It 'switches to the tab found by its title and brings its window forward' {
            Mock Select-TerminalTab { [IntPtr]7 }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeNullOrEmpty
            $expected = "$(Split-Path $TestDrive -Leaf) #abcdef12"
            Should -Invoke Select-TerminalTab -Times 1 -ParameterFilter { $Title -eq $expected }
            Should -Invoke Show-OwnerWindow -Times 1 -ParameterFilter { $Hwnd -eq [IntPtr]7 }
            Should -Invoke Get-ConsoleOwnerWindow -Times 0
            Should -Invoke Show-ClaudeWindow -Times 0
            Should -Invoke Start-ClaudeSession -Times 0
        }
        It 'returns a message and opens nothing when the tab is found but its window stays behind' {
            Mock Select-TerminalTab { [IntPtr]7 }
            Mock Show-OwnerWindow { $false }
            Open-ClaudeSession -Session $script:session -OpenMap $script:bgMap | Should -BeLike '*既に開いています*'
            Should -Invoke Start-ClaudeSession -Times 0
            Should -Invoke Get-ConsoleOwnerWindow -Times 0
        }
        It 'walks from the console when no tab has the title, without focusing by window name' {
            Mock Select-TerminalTab { [IntPtr]::Zero }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeNullOrEmpty
            Should -Invoke Get-ConsoleOwnerWindow -Times 1 -ParameterFilter { $ClaudePid -eq 1234 }
            Should -Invoke Test-LaunchedByTool -Times 0
            Should -Invoke Show-ClaudeWindow -Times 0
        }
        It 'returns a message and opens nothing new when neither the tab nor the window is found' {
            Mock Select-TerminalTab { [IntPtr]::Zero }
            Mock Get-ConsoleOwnerWindow { [IntPtr]::Zero }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeLike '*既に開いています*'
            Should -Invoke Start-ClaudeSession -Times 0
        }
        It 'falls back to the console walk when the tab search throws' {
            Mock Select-TerminalTab { throw 'UIA failure' }
            Open-ClaudeSession -Session $script:session -OpenMap $script:openMap | Should -BeNullOrEmpty
            Should -Invoke Get-ConsoleOwnerWindow -Times 1
        }
        It 'switches to the attach tab of a background session instead of attaching again' {
            Mock Select-TerminalTab { [IntPtr]7 }
            Open-ClaudeSession -Session $script:session -OpenMap $script:bgMap | Should -BeNullOrEmpty
            Should -Invoke Start-ClaudeSession -Times 0
        }
        It 'attaches to a background session in a new tab when it has no tab yet' {
            Mock Select-TerminalTab { [IntPtr]::Zero }
            Open-ClaudeSession -Session $script:session -OpenMap $script:bgMap | Should -BeNullOrEmpty
            Should -Invoke Start-ClaudeSession -Times 1 -ParameterFilter { $AttachJobId -eq '7f9d969b' }
            Should -Invoke Get-ConsoleOwnerWindow -Times 0
        }
        It 'looks the tab up by its raw title, with ; unescaped' {
            Mock Select-TerminalTab { [IntPtr]7 }
            $dir = Join-Path $TestDrive 'a;b'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $session = [pscustomobject]@{ SessionId = $script:session.SessionId; Cwd = $dir }
            Open-ClaudeSession -Session $session -OpenMap $script:openMap | Should -BeNullOrEmpty
            Should -Invoke Select-TerminalTab -Times 1 -ParameterFilter { $Title -eq 'a;b #abcdef12' }
        }
    }
}

Describe 'Get-SessionTabTitle' {
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'adds the start of the session ID in tabs mode' {
        $script:Config.WindowMode = 'tabs'
        Get-SessionTabTitle -Cwd 'C:\work\my app' -SessionId '1a2b3c4d-0000-0000-0000-000000000000' | Should -BeExactly 'my app #1a2b3c4d'
    }
    It 'is the project name alone in windows mode' {
        $script:Config.WindowMode = 'windows'
        Get-SessionTabTitle -Cwd 'C:\work\my app' -SessionId '1a2b3c4d-0000-0000-0000-000000000000' | Should -BeExactly 'my app'
    }
}

Describe 'Test-SessionId' {
    It 'accepts a GUID in the form Claude Code uses' {
        Test-SessionId -SessionId ([guid]::NewGuid().ToString()) | Should -BeTrue
    }
    It 'rejects anything else' {
        foreach ($value in @('abc', '*', 'x;calc', "$([guid]::NewGuid());calc",
                "{$([guid]::NewGuid())}", [guid]::NewGuid().ToString('N'), '', $null)) {
            Test-SessionId -SessionId $value | Should -BeFalse -Because "'$value'"
        }
    }
}

Describe 'Test-JobId / Test-BackgroundSession' {
    It 'accepts only letters and digits as a job ID' {
        Test-JobId -JobId '7f9d969b' | Should -BeTrue
        foreach ($value in @('', $null, 'x;calc', 'a b', '$(calc)', ('a' * 65))) {
            Test-JobId -JobId $value | Should -BeFalse -Because "'$value'"
        }
    }
    It 'treats only a bg entry with a job ID as attachable' {
        Test-BackgroundSession -OpenEntry ([pscustomobject]@{ Kind = 'bg'; JobId = '7f9d969b' }) | Should -BeTrue
        Test-BackgroundSession -OpenEntry ([pscustomobject]@{ Kind = 'interactive'; JobId = '' }) | Should -BeFalse
        Test-BackgroundSession -OpenEntry ([pscustomobject]@{ Kind = 'bg'; JobId = '' }) | Should -BeFalse
        Test-BackgroundSession -OpenEntry ([pscustomobject]@{ Pid = 1; Status = 'idle' }) | Should -BeFalse
        Test-BackgroundSession -OpenEntry $null | Should -BeFalse
    }
}

Describe 'ConvertTo-WtArgument' {
    It 'escapes ; so wt.exe does not split the command line there' {
        ConvertTo-WtArgument -Value 'C:\work\a;new-tab calc' | Should -Be 'C:\work\a\;new-tab calc'
    }
    It 'leaves a value without ; unchanged' {
        ConvertTo-WtArgument -Value 'C:\work\app' | Should -Be 'C:\work\app'
    }
}

Describe 'ConvertTo-ProcessArgument' {
    <#
    Round-trips each value through CommandLineToArgvW, the parser wt.exe and PowerShell use
    for their own command lines, and checks that it comes back as one identical argument.
    #>
    BeforeAll {
        if (-not ('ClaudeSessionsTestArgv' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ClaudeSessionsTestArgv {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CommandLineToArgvW(string cmdLine, out int argc);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr mem);

    public static string[] Split(string cmdLine) {
        int argc;
        IntPtr argv = CommandLineToArgvW(cmdLine, out argc);
        try {
            string[] result = new string[argc];
            for (int i = 0; i < argc; i++) {
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            }
            return result;
        } finally {
            LocalFree(argv);
        }
    }
}
'@
        }
    }
    It 'leaves a value without spaces or quotes unchanged' {
        ConvertTo-ProcessArgument -Value 'C:\work\app' | Should -Be 'C:\work\app'
        ConvertTo-ProcessArgument -Value 'D:\' | Should -Be 'D:\'
    }
    It 'round-trips <Name> as a single argument' -TestCases @(
        @{ Name = 'a space'; Value = 'C:\My Project' }
        @{ Name = 'a trailing backslash'; Value = 'D:\a b\' }
        @{ Name = 'an empty string'; Value = '' }
        @{ Name = 'an embedded quote'; Value = 'say "hi" \"x\\' }
        @{ Name = 'an escaped semicolon'; Value = 'C:\a b\;new-tab' }
    ) {
        param($Name, $Value)
        $parsed = [ClaudeSessionsTestArgv]::Split('exe ' + (ConvertTo-ProcessArgument -Value $Value) + ' next')
        $parsed.Count | Should -Be 3
        $parsed[1] | Should -BeExactly $Value
        $parsed[2] | Should -Be 'next'
    }
}

Describe 'Start-ClaudeSession / Show-ClaudeWindow' {
    <#
    Invoke-WindowsTerminal is mocked, so wt.exe is never started; the arguments it would get
    are captured in $script:wtArgs instead. Tests run in 'windows' mode unless they set 'tabs'.
    #>
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
        $script:Config.WindowMode = 'windows'
        $script:wtArgs = $null
        Mock Invoke-WindowsTerminal { $script:wtArgs = $Arguments }
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'opens a new tab of the shared window in tabs mode, titled with the short session ID' {
        $script:Config.WindowMode = 'tabs'
        $id = [guid]::NewGuid().ToString()
        Start-ClaudeSession -Cwd 'C:\work\a;b' -SessionId $id
        $script:wtArgs[0..2] -join ' ' | Should -Be '-w cs new-tab'
        $script:wtArgs[$script:wtArgs.IndexOf('--title') + 1] | Should -Be "a\;b #$($id.Substring(0, 8))"
        $script:wtArgs | Should -Contain '--suppressApplicationTitle'
        $script:wtArgs[-1] | Should -Be "claude --resume $id"
    }
    It 'titles a new session and an attach tab after their session ID in tabs mode' {
        $script:Config.WindowMode = 'tabs'
        Start-ClaudeSession -Cwd 'C:\work\app' -NewSession
        $newId = ($script:wtArgs[-1] -split ' ')[-1]
        $script:wtArgs[$script:wtArgs.IndexOf('--title') + 1] | Should -Be "app #$($newId.Substring(0, 8))"
        $id = [guid]::NewGuid().ToString()
        Start-ClaudeSession -Cwd 'C:\work\app' -SessionId $id -AttachJobId '7f9d969b'
        $script:wtArgs[0..2] -join ' ' | Should -Be '-w cs new-tab'
        $script:wtArgs[$script:wtArgs.IndexOf('--title') + 1] | Should -Be "app #$($id.Substring(0, 8))"
    }
    It 'escapes ; in the title and the working directory' {
        $id = [guid]::NewGuid().ToString()
        Start-ClaudeSession -Cwd 'C:\work\a;b' -SessionId $id
        $script:wtArgs[$script:wtArgs.IndexOf('--title') + 1] | Should -Be 'a\;b'
        $script:wtArgs[$script:wtArgs.IndexOf('-d') + 1] | Should -Be 'C:\work\a\;b'
        $script:wtArgs[-1] | Should -Be "claude --resume $id"
    }
    It 'refuses to resume a session ID that is not a GUID' {
        { Start-ClaudeSession -Cwd 'C:\work\app' -SessionId 'x; calc' } | Should -Throw '*x; calc*'
        Should -Invoke Invoke-WindowsTerminal -Times 0
    }
    It 'generates a valid ID for a new session' {
        Start-ClaudeSession -Cwd 'C:\work\app' -NewSession
        $script:wtArgs[-1] | Should -Match '^claude --session-id [0-9a-f-]{36}$'
    }
    It 'runs claude in the shell set by ShellExe, defaulting to the current PowerShell' {
        $expected = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $script:Config.ShellExe | Should -Be $expected
        Start-ClaudeSession -Cwd 'C:\work\app' -NewSession
        $shellIndex = $script:wtArgs.IndexOf($expected)
        $shellIndex | Should -BeGreaterThan 0
        # -ExecutionPolicy must come before -Command, or it would be passed to claude.
        $script:wtArgs.IndexOf('-ExecutionPolicy') | Should -BeGreaterThan $shellIndex
        $script:wtArgs.IndexOf('-ExecutionPolicy') | Should -BeLessThan $script:wtArgs.IndexOf('-Command')
    }
    It 'attaches to a background session by its job ID in a window named after the session' {
        $id = [guid]::NewGuid().ToString()
        Start-ClaudeSession -Cwd 'C:\work\app' -SessionId $id -AttachJobId '7f9d969b'
        $script:wtArgs[-1] | Should -Be 'claude attach 7f9d969b'
        $script:wtArgs[$script:wtArgs.IndexOf('-w') + 1] | Should -Be "cs-$id"
        $script:wtArgs[$script:wtArgs.IndexOf('-d') + 1] | Should -Be 'C:\work\app'
    }
    It 'refuses a job ID that could inject a command, and -NewSession with -AttachJobId' {
        $id = [guid]::NewGuid().ToString()
        { Start-ClaudeSession -Cwd 'C:\work\app' -SessionId $id -AttachJobId 'x; calc' } | Should -Throw '*x; calc*'
        { Start-ClaudeSession -Cwd 'C:\work\app' -NewSession -AttachJobId '7f9d969b' } | Should -Throw
        Should -Invoke Invoke-WindowsTerminal -Times 0
    }
    It 'quotes a ClaudeExe path that PowerShell would otherwise parse as script' {
        $saved = $script:Config.ClaudeExe
        try {
            $id = [guid]::NewGuid().ToString()
            $script:Config.ClaudeExe = "C:\Program Files\it's\`$x\claude.cmd"
            Start-ClaudeSession -Cwd 'C:\work\app' -SessionId $id
            $script:wtArgs[-1] | Should -BeExactly "& 'C:\Program Files\it''s\`$x\claude.cmd' --resume $id"
            $script:Config.ClaudeExe = 'C:\tools\claude.exe'
            Start-ClaudeSession -Cwd 'C:\work\app' -SessionId $id
            $script:wtArgs[-1] | Should -BeExactly "C:\tools\claude.exe --resume $id"
        } finally {
            $script:Config.ClaudeExe = $saved
        }
    }
    It 'refuses to focus a window for a session ID that is not a GUID' {
        { Show-ClaudeWindow -SessionId 'x; calc' } | Should -Throw
        Should -Invoke Invoke-WindowsTerminal -Times 0
    }
}

Describe 'Native API declarations' {
    <#
    The Add-Type C# code is compiled by a different compiler on Windows PowerShell 5.1 (C# 5)
    and on 7, and would otherwise only be compiled the first time a feature is used.
    Only compiling and declaring the types is checked; nothing is called.
    #>
    It 'compiles <Name>' -TestCases @(
        @{ Name = 'Initialize-WindowApi'; TypeName = 'ClaudeSessionsWindowApi' }
        @{ Name = 'Initialize-RecycleBinApi'; TypeName = 'ClaudeSessionsRecycleBinApi' }
        @{ Name = 'Initialize-ConsoleApi'; TypeName = 'ClaudeSessionsConsoleApi' }
    ) {
        param($Name, $TypeName)
        & $Name
        ($TypeName -as [type]) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-WindowsTerminal' {
    <#
    Start-Process is mocked; the mock records what the child would inherit at that moment.
    #>
    BeforeEach {
        $script:envName = 'CLAUDE_CODE_TEST_' + [guid]::NewGuid().ToString('N')
        [System.Environment]::SetEnvironmentVariable($script:envName, 'parent-value', 'Process')
        $script:seenByChild = 'not called'
    }
    AfterEach {
        [System.Environment]::SetEnvironmentVariable($script:envName, $null, 'Process')
    }
    It 'hides CLAUDE_CODE_* from the child and restores it afterwards' {
        Mock Start-Process { $script:seenByChild = [System.Environment]::GetEnvironmentVariable($script:envName) }
        Invoke-WindowsTerminal -Arguments @('-w', 'x')
        $script:seenByChild | Should -BeNullOrEmpty
        [System.Environment]::GetEnvironmentVariable($script:envName) | Should -Be 'parent-value'
    }
    It 'restores CLAUDE_CODE_* even when starting the child fails' {
        Mock Start-Process { throw 'wt.exe not found' }
        { Invoke-WindowsTerminal -Arguments @('-w', 'x') } | Should -Throw '*wt.exe not found*'
        [System.Environment]::GetEnvironmentVariable($script:envName) | Should -Be 'parent-value'
    }
    It 'hides CLAUDECODE from the child and restores it afterwards' {
        $saved = $env:CLAUDECODE
        try {
            $env:CLAUDECODE = '1'
            Mock Start-Process { $script:seenByChild = $env:CLAUDECODE }
            Invoke-WindowsTerminal -Arguments @('-w', 'x')
            $script:seenByChild | Should -BeNullOrEmpty
            $env:CLAUDECODE | Should -Be '1'
        } finally {
            [System.Environment]::SetEnvironmentVariable('CLAUDECODE', $saved, 'Process')
        }
    }
    It 'leaves other variables to the child' {
        Mock Start-Process { $script:seenByChild = $env:PATH }
        Invoke-WindowsTerminal -Arguments @('-w', 'x')
        $script:seenByChild | Should -Be $env:PATH
    }
    It 'quotes arguments that contain spaces or are empty' {
        Mock Start-Process { $script:seenByChild = $ArgumentList }
        Invoke-WindowsTerminal -Arguments @('--title', 'My Project', '-d', 'D:\a b\', '')
        $script:seenByChild | Should -Be @('--title', '"My Project"', '-d', '"D:\a b\\"', '""')
    }
}

Describe 'ConvertTo-PrintableText' {
    It 'replaces control characters, including ESC and line breaks, with spaces' {
        $esc = [char]27
        ConvertTo-PrintableText -Text "a$esc]52;c;eA==`ab`r`nc" | Should -Be 'a ]52;c;eA== b  c'
    }
    It 'keeps full-width text unchanged' {
        ConvertTo-PrintableText -Text '日本語のテスト' | Should -Be '日本語のテスト'
    }
    It 'returns an empty string for $null' {
        ConvertTo-PrintableText -Text $null | Should -Be ''
    }
    It 'keeps ESC in a session name from reaching the terminal' {
        $esc = [char]27
        $session = [pscustomobject]@{ Title = "evil$esc]52;c;eA==`a"; Cwd = "C:\work\app$esc[2J"; Modified = [datetime]'2026-09-25 10:00' }
        $row = Format-SessionRow -Session $session -Widths ([pscustomobject]@{ Title = 30; Path = 30 })
        # Only the row's own SGR color codes may contain ESC.
        [regex]::Replace($row, [char]27 + '\[[0-9;]*m', '') | Should -Not -Match ([char]27)
    }
}

Describe 'Test-SessionFilePath / Remove-ClaudeSession' {
    <#
    ProjectsDir is redirected to TestDrive, and Move-SessionToRecycleBin is mocked so nothing
    goes to the real Recycle Bin. The order of items sent is recorded in $script:sent.
    #>
    BeforeEach {
        $script:origProjectsDir = $script:Config.ProjectsDir
        $script:Config.ProjectsDir = Join-Path $TestDrive 'projects'
        $script:projectDir = Join-Path $script:Config.ProjectsDir 'proj'
        New-Item -ItemType Directory -Path $script:projectDir -Force | Out-Null
        $script:id = [guid]::NewGuid().ToString()
        $script:jsonl = Join-Path $script:projectDir "$($script:id).jsonl"
        Set-Content -LiteralPath $script:jsonl -Value '{}'
        $script:companion = Join-Path $script:projectDir $script:id
        $script:session = [pscustomobject]@{ SessionId = $script:id; Path = $script:jsonl }
        $script:sent = [System.Collections.Generic.List[string]]::new()
        Mock Get-OpenSessionMap { @{} }
        Mock Move-SessionToRecycleBin { $script:sent.Add($Path) }
    }
    AfterEach {
        $script:Config.ProjectsDir = $script:origProjectsDir
    }

    # Test names avoid <...> because Pester expands it as a template variable.
    It 'accepts only a jsonl under ProjectsDir named after the session ID as a deletion target' {
        Test-SessionFilePath -Path $script:jsonl -SessionId $script:id | Should -BeTrue
        Test-SessionFilePath -Path (Join-Path $TestDrive "$($script:id).jsonl") -SessionId $script:id | Should -BeFalse
        Test-SessionFilePath -Path (Join-Path $script:projectDir "$($script:id).txt") -SessionId $script:id | Should -BeFalse
        Test-SessionFilePath -Path $script:jsonl -SessionId 'other-id' | Should -BeFalse
        Test-SessionFilePath -Path $null -SessionId $script:id | Should -BeFalse
    }
    It 'rejects a jsonl placed directly in ProjectsDir or two folders deep' {
        $direct = Join-Path $script:Config.ProjectsDir "$($script:id).jsonl"
        $deep = Join-Path $script:projectDir "sub\$($script:id).jsonl"
        Test-SessionFilePath -Path $direct -SessionId $script:id | Should -BeFalse
        Test-SessionFilePath -Path $deep -SessionId $script:id | Should -BeFalse
    }
    It 'rejects a path that .NET cannot normalize instead of throwing' {
        $bad = [pscustomobject]@{ SessionId = $script:id; Path = "C:\a:b\$($script:id).jsonl" }
        Test-SessionFilePath -Path $bad.Path -SessionId $script:id | Should -BeFalse
        Remove-ClaudeSession -Session $bad | Should -BeLike '*パスが不正*'
        Should -Invoke Move-SessionToRecycleBin -Times 0
    }
    It 'rejects a session ID that is not a GUID even when the file name matches' {
        $wild = Join-Path $script:projectDir '*.jsonl'
        Test-SessionFilePath -Path $wild -SessionId '*' | Should -BeFalse
        Remove-ClaudeSession -Session ([pscustomobject]@{ SessionId = '*'; Path = $wild }) | Should -BeLike '*パスが不正*'
        Should -Invoke Move-SessionToRecycleBin -Times 0
    }
    It 'sends the same-named folder first, then the jsonl, and returns $null' {
        New-Item -ItemType Directory -Path $script:companion | Out-Null
        Remove-ClaudeSession -Session $script:session | Should -BeNullOrEmpty
        $script:sent | Should -Be @($script:companion, $script:jsonl)
    }
    It 'sends only the jsonl when there is no same-named folder' {
        Remove-ClaudeSession -Session $script:session | Should -BeNullOrEmpty
        $script:sent | Should -Be @($script:jsonl)
    }
    It 'sends nothing when the state re-read right before deletion shows it running' {
        Mock Get-OpenSessionMap { @{ $script:id = [pscustomobject]@{ Pid = 1234; Status = 'idle' } } }
        Remove-ClaudeSession -Session $script:session | Should -BeLike '*起動中*'
        Should -Invoke Move-SessionToRecycleBin -Times 0
    }
    It 'sends nothing when the path is invalid' {
        $bad = [pscustomobject]@{ SessionId = 'other-id'; Path = $script:jsonl }
        Remove-ClaudeSession -Session $bad | Should -BeLike '*パスが不正*'
        Should -Invoke Move-SessionToRecycleBin -Times 0
    }
    It 'does not send the jsonl and returns a message when the folder fails' {
        New-Item -ItemType Directory -Path $script:companion | Out-Null
        Mock Move-SessionToRecycleBin { throw 'locked' }
        Remove-ClaudeSession -Session $script:session | Should -BeLike '*削除に失敗しました*locked*'
        Should -Invoke Move-SessionToRecycleBin -Times 1
    }
}

Describe 'Move-SessionToRecycleBin' {
    <#
    Checks that the SHFileOperation declaration and call actually work. One dummy file on
    TestDrive goes to the real Recycle Bin.
    #>
    It 'removes the file from its original location' {
        $file = Join-Path $TestDrive 'claude-sessions-recycle-test.jsonl'
        Set-Content -LiteralPath $file -Value '{}'
        Move-SessionToRecycleBin -Path $file
        Test-Path -LiteralPath $file | Should -BeFalse
    }
    It 'throws for a path that does not exist' {
        { Move-SessionToRecycleBin -Path (Join-Path $TestDrive 'no-such-file.jsonl') } | Should -Throw
    }
}

Describe 'Test-FocusableWindow' {
    It 'accepts a normal visible window' {
        Test-FocusableWindow -ClassName 'CASCADIA_HOSTING_WINDOW_CLASS' -IsVisible $true | Should -BeTrue
        Test-FocusableWindow -ClassName 'ConsoleWindowClass' -IsVisible $true | Should -BeTrue
    }
    It 'rejects the pseudo window even when visible' {
        Test-FocusableWindow -ClassName 'PseudoConsoleWindow' -IsVisible $true | Should -BeFalse
    }
    It 'rejects hidden windows and windows without a class name' {
        Test-FocusableWindow -ClassName 'CASCADIA_HOSTING_WINDOW_CLASS' -IsVisible $false | Should -BeFalse
        Test-FocusableWindow -ClassName '' -IsVisible $true | Should -BeFalse
    }
}

Describe 'Find-SessionIndexById' {
    BeforeAll {
        $script:list = @(
            [pscustomobject]@{ SessionId = 'a' }
            [pscustomobject]@{ SessionId = 'b' }
            [pscustomobject]@{ SessionId = 'c' }
        )
    }
    It 'returns the position of the same SessionId' {
        Find-SessionIndexById -Sessions $script:list -SessionId 'c' | Should -Be 2
    }
    It 'returns Fallback clamped to the valid range when not found' {
        Find-SessionIndexById -Sessions $script:list -SessionId 'zz' -Fallback 1 | Should -Be 1
        Find-SessionIndexById -Sessions $script:list -SessionId 'zz' -Fallback 9 | Should -Be 2
    }
    It 'returns 0 for a $null SessionId or an empty list' {
        Find-SessionIndexById -Sessions $script:list -SessionId $null | Should -Be 0
        Find-SessionIndexById -Sessions @() -SessionId 'a' -Fallback 3 | Should -Be 0
        Find-SessionIndexById -Sessions @() -SessionId 'a' -Cwd 'C:\work' | Should -Be 0
    }
    It 'falls back to the first row of the same directory when the ID is not listed' {
        $rows = @(
            [pscustomobject]@{ SessionId = 'a'; Cwd = 'C:\work\one' }
            [pscustomobject]@{ SessionId = 'b'; Cwd = 'C:\work\two' }
            [pscustomobject]@{ SessionId = 'c'; Cwd = 'C:\work\two' }
        )
        Find-SessionIndexById -Sessions $rows -SessionId 'hidden' -Cwd 'c:/WORK/two/' -Fallback 0 | Should -Be 1
        Find-SessionIndexById -Sessions $rows -SessionId 'c' -Cwd 'C:\work\one' | Should -Be 2
        Find-SessionIndexById -Sessions $rows -SessionId 'hidden' -Cwd 'C:\other' -Fallback 2 | Should -Be 2
    }
}

Describe 'Get-DirectoryKey' {
    It 'ignores case, the separator style and a trailing separator' {
        $key = Get-DirectoryKey -Cwd 'C:\Work\App'
        Get-DirectoryKey -Cwd 'c:\work\app\' | Should -Be $key
        Get-DirectoryKey -Cwd 'C:/work/app' | Should -Be $key
        Get-DirectoryKey -Cwd 'C:/work/app/' | Should -Be $key
    }
    It 'keeps different directories apart' {
        Get-DirectoryKey -Cwd 'C:\work\app' | Should -Not -Be (Get-DirectoryKey -Cwd 'C:\work\app2')
    }
    It 'returns an empty key for $null or an empty string' {
        Get-DirectoryKey -Cwd $null | Should -Be ''
        Get-DirectoryKey -Cwd '' | Should -Be ''
    }
}

Describe 'Get-LatestPerDirectory' {
    BeforeAll {
        # Newest first, as Get-SessionIndex returns them.
        $script:all = @(
            [pscustomobject]@{ SessionId = 'a1'; Cwd = 'C:\work\a' }
            [pscustomobject]@{ SessionId = 'b1'; Cwd = 'C:\work\b' }
            [pscustomobject]@{ SessionId = 'a2'; Cwd = 'c:/WORK/a/' }
            [pscustomobject]@{ SessionId = 'a3'; Cwd = 'C:\work\a' }
            [pscustomobject]@{ SessionId = 'b2'; Cwd = 'C:\work\b' }
            [pscustomobject]@{ SessionId = 'a4'; Cwd = 'C:\work\a' }
        )
    }
    It 'keeps only the latest session of each directory, in the input order' {
        $view = Get-LatestPerDirectory -Sessions $script:all -KeepIds @{}
        @($view.Sessions | ForEach-Object { $_.SessionId }) | Should -Be @('a1', 'b1')
        $view.HiddenCounts['a1'] | Should -Be 3
        $view.HiddenCounts['b1'] | Should -Be 1
    }
    It 'keeps older running sessions in date order and leaves them out of the hidden count' {
        $view = Get-LatestPerDirectory -Sessions $script:all -KeepIds @{ a3 = $true; a4 = $true }
        @($view.Sessions | ForEach-Object { $_.SessionId }) | Should -Be @('a1', 'b1', 'a3', 'a4')
        $view.HiddenCounts['a1'] | Should -Be 1
        $view.HiddenCounts.ContainsKey('a3') | Should -BeFalse
    }
    It 'still counts the hidden sessions when the latest one is itself running' {
        $view = Get-LatestPerDirectory -Sessions $script:all -KeepIds @{ a1 = $true }
        $view.HiddenCounts['a1'] | Should -Be 3
    }
    It 'returns an array for a single session and an empty one for no session' {
        $single = Get-LatestPerDirectory -Sessions @($script:all[0]) -KeepIds @{}
        $single.Sessions -is [object[]] | Should -BeTrue
        $single.Sessions.Count | Should -Be 1
        $single.HiddenCounts['a1'] | Should -Be 0
        $empty = Get-LatestPerDirectory -Sessions @() -KeepIds @{}
        $empty.Sessions.Count | Should -Be 0
    }
}

Describe 'Pins' {
    BeforeEach {
        $script:savedConfig = $script:Config.Clone()
        $script:Config.PinsPath = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))\pins.json"
        $script:idA = [guid]::NewGuid().ToString()
        $script:idB = [guid]::NewGuid().ToString()
    }
    AfterEach {
        $script:Config = $script:savedConfig
    }
    It 'reads no pins when the file does not exist' {
        (Get-PinnedIds).Count | Should -Be 0
    }
    It 'saves and reads back a single pin, creating the folder' {
        Save-PinnedIds -PinnedIds @{ $script:idA = $true }
        [System.IO.File]::ReadAllText($script:Config.PinsPath) | Should -Match '^\s*\['
        $pins = Get-PinnedIds
        @($pins.Keys) | Should -Be @($script:idA)
    }
    It 'saves an empty set and reads it back' {
        Save-PinnedIds -PinnedIds @{}
        (Get-PinnedIds).Count | Should -Be 0
    }
    It 'ignores a broken file and entries that are not session IDs' {
        New-Item -ItemType Directory -Path (Split-Path $script:Config.PinsPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($script:Config.PinsPath, '[not json')
        (Get-PinnedIds).Count | Should -Be 0
        [System.IO.File]::WriteAllText($script:Config.PinsPath, "[`"$($script:idA)`", `"*`", 3]")
        @((Get-PinnedIds).Keys) | Should -Be @($script:idA)
    }
    It 'drops pins of sessions that are gone and tells whether it did' {
        $pins = @{ $script:idA = $true; $script:idB = $true }
        $sessions = @([pscustomobject]@{ SessionId = $script:idA })
        Remove-OrphanedPins -PinnedIds $pins -Sessions $sessions | Should -BeTrue
        @($pins.Keys) | Should -Be @($script:idA)
        Remove-OrphanedPins -PinnedIds $pins -Sessions $sessions | Should -BeFalse
    }
    It 'keeps every pin when the index is empty' {
        $pins = @{ $script:idA = $true }
        Remove-OrphanedPins -PinnedIds $pins -Sessions @() | Should -BeFalse
        $pins.Count | Should -Be 1
    }
    It 'moves pinned sessions to the top and keeps the order within each group' {
        $rows = @('a', 'b', 'c', 'd') | ForEach-Object { [pscustomobject]@{ SessionId = $_ } }
        $result = Get-PinnedFirst -Sessions $rows -PinnedIds @{ c = $true; b = $true }
        @($result | ForEach-Object { $_.SessionId }) | Should -Be @('b', 'c', 'a', 'd')
        (Get-PinnedFirst -Sessions $rows -PinnedIds @{}).Count | Should -Be 4
        (Get-PinnedFirst -Sessions @() -PinnedIds @{ a = $true }).Count | Should -Be 0
    }
    It 'returns an array for a single pinned session' {
        $result = Get-PinnedFirst -Sessions @([pscustomobject]@{ SessionId = 'a' }) -PinnedIds @{ a = $true }
        $result -is [object[]] | Should -BeTrue
    }
}

Describe 'Get-RunningIds' {
    It 'combines running sessions with launches still in their grace period' {
        $now = [datetime]::new(2026, 9, 26, 12, 0, 0, [DateTimeKind]::Utc)
        $launches = @{
            fresh = $now.AddMilliseconds(-1000)
            stale = $now.AddMilliseconds(-($script:Config.LaunchGraceMs + 1))
        }
        $openMap = @{ open = [pscustomobject]@{ Pid = 1; Status = 'idle' } }
        $ids = Get-RunningIds -OpenMap $openMap -Launches $launches -Now $now
        @($ids.Keys | Sort-Object) | Should -Be @('fresh', 'open')
    }
}

Describe 'Format-SessionRow' {
    BeforeAll {
        $script:widths = [pscustomobject]@{ Title = 20; Path = 30 }
        function Get-TitleCell([string]$Row) {
            # Row layout: marker (2) + status column + 1 space, then the title column.
            $plain = [regex]::Replace($Row, [char]27 + '\[[0-9;]*m', '')
            return $plain.Substring(2 + $script:StatusColumnWidth + 1, $script:widths.Title)
        }
        $script:session = [pscustomobject]@{
            SessionId = 'a'; Title = 'a very long session name that overflows'; Cwd = 'C:\work\a'
            Modified  = [datetime]::new(2026, 9, 26, 12, 0, 0)
        }
    }
    It 'keeps the hidden count at the end of a truncated name, selected or not' {
        foreach ($selected in $false, $true) {
            $row = Format-SessionRow -Session $script:session -Widths $script:widths -HiddenCount 12 -Selected:$selected
            $cell = Get-TitleCell $row
            $cell | Should -Match ' \(\+12\)$' -Because "selected = $selected"
            Get-DisplayWidth -Text $cell | Should -Be $script:widths.Title
        }
    }
    It 'marks a pinned row in the second marker column without shifting the columns' {
        foreach ($selected in $false, $true) {
            $plain = Format-SessionRow -Session $script:session -Widths $script:widths -Selected:$selected
            $pinned = Format-SessionRow -Session $script:session -Widths $script:widths -Pinned -Selected:$selected
            $strip = { param($Row) [regex]::Replace($Row, [char]27 + '\[[0-9;]*m', '') }
            (& $strip $pinned)[1] | Should -Be '*' -Because "selected = $selected"
            (& $strip $plain)[1] | Should -Be ' ' -Because "selected = $selected"
            (& $strip $pinned).Length | Should -Be (& $strip $plain).Length
            Get-TitleCell $pinned | Should -Be (Get-TitleCell $plain)
        }
    }
    It 'adds nothing when no session is hidden' {
        $row = Format-SessionRow -Session $script:session -Widths $script:widths -HiddenCount 0
        Get-TitleCell $row | Should -Not -Match '\(\+'
    }
    It 'does not highlight the hidden count' {
        $short = [pscustomobject]@{
            SessionId = 'a'; Title = 'fix 3'; Cwd = 'C:\work\a'; Modified = [datetime]::new(2026, 9, 26)
        }
        $row = Format-SessionRow -Session $short -Widths $script:widths -HiddenCount 3 -Terms @('3')
        $highlight = [regex]::Escape($script:Ansi.Underline)
        ([regex]::Matches($row, $highlight + '3')).Count | Should -Be 1
        $row | Should -Match '\(\+3\)'
    }
}

Describe 'Test-RecentLaunch' {
    BeforeAll {
        $script:launchedAt = [datetime]::new(2026, 9, 26, 12, 0, 0, [DateTimeKind]::Utc)
        $script:launches = @{ 'C:\work\app' = $script:launchedAt }
    }
    It 'is true within the grace period and false once it has passed' {
        Test-RecentLaunch -Launches $script:launches -Key 'C:\work\app' -GraceMs 3000 `
            -Now $script:launchedAt.AddMilliseconds(2999) | Should -BeTrue
        Test-RecentLaunch -Launches $script:launches -Key 'C:\work\app' -GraceMs 3000 `
            -Now $script:launchedAt.AddMilliseconds(3000) | Should -BeFalse
    }
    It 'matches keys case-insensitively, as Windows paths do' {
        Test-RecentLaunch -Launches $script:launches -Key 'c:\WORK\app' -GraceMs 3000 `
            -Now $script:launchedAt | Should -BeTrue
    }
    It 'is false for an unknown or empty key, or a grace period of 0' {
        Test-RecentLaunch -Launches $script:launches -Key 'C:\other' -GraceMs 3000 -Now $script:launchedAt | Should -BeFalse
        Test-RecentLaunch -Launches $script:launches -Key '' -GraceMs 3000 -Now $script:launchedAt | Should -BeFalse
        Test-RecentLaunch -Launches $script:launches -Key $null -GraceMs 3000 -Now $script:launchedAt | Should -BeFalse
        Test-RecentLaunch -Launches $script:launches -Key 'C:\work\app' -GraceMs 0 -Now $script:launchedAt | Should -BeFalse
    }
}
