@echo off
rem git-tools : point d'entree "git-viewer" (TR-03). Aucune option de strategie d'execution.
powershell.exe -NoProfile -NoLogo -File "%~dp0git-viewer.ps1" %*
exit /b %ERRORLEVEL%
