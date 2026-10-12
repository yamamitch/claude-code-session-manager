#Requires -Version 5.1
<#
.SYNOPSIS
    Finds the HWND of the visible window for the console a given process runs in.

.DESCRIPTION
    Called by claude-sessions.ps1 as a throwaway child process when it focuses a manually
    opened claude window. Not meant to be used on its own.

    It reattaches to the target process's console (FreeConsole -> AttachConsole), takes
    GetConsoleWindow, and walks the owner chain with GetAncestor(GA_ROOTOWNER). On Windows
    Terminal this yields the WT window as the owner of the ConPTY pseudo window
    (PseudoConsoleWindow); on conhost it yields the console window itself.

    Reattaching the console breaks the caller's standard I/O, so the main process never does
    it and runs this script as a separate process instead. The result is also written to
    -OutFile as a decimal number rather than to standard output (how standard output behaves
    after reattaching is uncertain). 0 is written when no window is found.
#>
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = 'Stop'

$GA_ROOTOWNER = [uint32]3
$ATTACH_PARENT_PROCESS = [uint32]::MaxValue

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ConsoleOwnerProbe {
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    public static long Find(uint pid, uint rootOwnerFlag, uint parentFlag) {
        FreeConsole();
        IntPtr root = IntPtr.Zero;
        if (AttachConsole(pid)) {
            IntPtr console = GetConsoleWindow();
            if (console != IntPtr.Zero) { root = GetAncestor(console, rootOwnerFlag); }
            FreeConsole();
        }
        AttachConsole(parentFlag);
        return root.ToInt64();
    }
}
'@

$hwnd = 0L
try {
    $hwnd = [ConsoleOwnerProbe]::Find([uint32]$ProcessId, $GA_ROOTOWNER, $ATTACH_PARENT_PROCESS)
} catch {
    $hwnd = 0L
}
Set-Content -LiteralPath $OutFile -Value $hwnd -NoNewline
