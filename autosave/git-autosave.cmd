@echo off
rem git-tools : point d'entree "git-autosave" (TR-03). Aucune option de strategie d'execution.
powershell.exe -NoProfile -NoLogo -File "%~dp0git-autosave.ps1" %*
exit /b %ERRORLEVEL%
