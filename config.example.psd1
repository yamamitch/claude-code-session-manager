# User settings for Claude Code Session Manager.
#
# Copy this file to config.psd1 in the same folder and uncomment the settings you want to change.
# config.psd1 is ignored by git, so your settings survive updates.
# Settings left out keep their defaults (see $script:Config in src/claude-sessions.ps1).
# An unknown setting name stops the tool at startup.
@{
    # UI language: 'auto' (follows the Windows display language), 'ja' or 'en'.
    # Language = 'auto'

    # Maximum rows shown at once (reduced automatically on short screens).
    # PageSize = 20

    # Start in the view showing only the latest session of each directory (running sessions are
    # always shown). $false starts with every session. Shift+Tab switches views either way.
    # LatestPerDirectory = $true

    # How sessions are opened: 'tabs' opens each as a tab of one window named 'cs'
    # (TabWindowName), 'windows' opens each in a window of its own.
    # WindowMode = 'tabs'

    # Interval in milliseconds for re-reading the state of running sessions.
    # 0 turns automatic re-reading off; Enter, Ctrl+D and Ctrl+R still re-read the state.
    # RefreshIntervalMs = 5000

    # How long a message stays on the notice line, in milliseconds.
    # NoticeDurationMs = 3000

    # Column cap for session names. The rest of the width goes to the path column.
    # TitleMaxWidth = 40

    # Format of the last-used column (.NET date format string).
    # DateFormat = 'yyyy/MM/dd HH:mm'

    # Tab color palette. Each project gets one of these, chosen by a hash of its path.
    # TabColors = @('#66D9EF', '#A6E22E', '#FD971F', '#F92672', '#AE81FF', '#E6DB74', '#75715E', '#A1EFE4')

    # Shell that runs claude in a new window. Defaults to the PowerShell running this tool
    # (pwsh.exe on PowerShell 7, powershell.exe on Windows PowerShell 5.1).
    # ShellExe = 'pwsh.exe'

    # Color of each status (the color names of $PSStyle.Foreground, such as Green or BrightBlue).
    # StatusColors = @{ busy = 'Green'; shell = 'Green'; waiting = 'Yellow'; idle = 'BrightBlue' }
}
