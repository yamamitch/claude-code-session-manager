@echo off
rem Claude Code Session Manager launcher.
rem Uses PowerShell 7 (pwsh) when installed, otherwise Windows PowerShell 5.1.
rem -ExecutionPolicy Bypass: Windows PowerShell's default policy (Restricted) refuses to run scripts.
setlocal
set "PS_EXE=pwsh"
where pwsh >nul 2>&1
if errorlevel 1 set "PS_EXE=powershell"
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\claude-sessions.ps1" %*
exit /b %ERRORLEVEL%
