# English UI strings. This is the reference language: every other language must have the same
# keys, and a key missing from another language falls back to the value here.
# Placeholders like {0} are filled with the -f operator; keep the same numbers when translating.
@{
    # Labels for the status values in ~/.claude/sessions/<PID>.json (Claude Code internal).
    # shell means a shell command is running; Claude Code itself treats it the same as busy
    # ("working"), so it shares the same label here.
    StatusLabels       = @{ busy = 'Working'; shell = 'Working'; waiting = 'Waiting'; idle = 'Done' }
    # Shown when a session is running but its status value is unknown.
    UnknownStatusLabel = 'Running'
    # Label of the search line, and the placeholder that marks it as an input field when empty.
    SearchLabel        = 'Search (name/path): '
    SearchPlaceholder  = 'Type to filter'
    # {0}: visible range such as 1-20, {1}: filtered count, {2}: total count
    CountLine          = 'Showing {0} of {1} ({2} total)'
    HeaderStatus       = 'Status'
    HeaderTitle        = 'Session'
    HeaderDate         = 'Last used'
    HeaderPath         = 'Directory'
    NoMatch            = '(no matches)'
    # Heading of the block under the list that shows the last prompt of the selected session,
    # and what the block says when the session has none recorded.
    PreviewLabel       = 'Last prompt'
    PreviewEmpty       = '(none recorded)'
    KeyHelp            = '[Enter] Open  [Esc] Clear/Quit  [Shift+Tab] All/Latest  [Ctrl+N] New  [Ctrl+P] Pin  [Ctrl+D] Delete  [Ctrl+R] Reload'
    # Shown at the right end of the rule above the list to tell which view is shown (Shift+Tab switches them).
    ModeLatestPerDirectory = '[Latest per directory]'
    ModeAll            = '[All sessions]'
    # Shown after Esc on an empty search; a second Esc quits.
    PressEscAgainToQuit = 'Press Esc again to quit'
    # Enter or Ctrl+N on a session that was launched moments ago and is not recorded as running yet.
    LaunchInProgress   = 'Still starting; wait a moment'
    Opened             = 'Opened in a new window'
    Focused            = 'Brought its window to the front'
    Attached           = 'Opened the background session in a new window'
    NewSessionOpened   = 'Started a new session in a new window'
    CwdNotFound        = 'Working directory not found: {0}'
    LaunchFailed       = 'Failed to launch: {0}'
    InvalidSessionId   = 'Invalid session ID: {0}'
    AlreadyOpen        = 'Already open (could not bring its window to the front; not opening it twice)'
    CannotDeleteLive   = 'Cannot delete a running session'
    InvalidDeletePath  = 'Invalid path to delete: {0}'
    DeleteFailed       = 'Failed to delete: {0}'
    MovedToTrash       = 'Moved to the Recycle Bin'
    Pinned             = 'Pinned to the top'
    Unpinned           = 'Unpinned'
    PinSaveFailed      = 'Failed to save pins: {0}'
    ConfirmDelete      = 'Move "{0}" to the Recycle Bin? [y/N]'
    # {0}: current, {1}: total
    Rebuilding         = 'Rebuilding index... [{0}/{1}]'
    Loading            = 'Loading sessions... [{0}/{1}]'
}
