@echo off
rem git-tools : point d'entree "git-viewer" (TR-03). Aucune option de strategie d'execution.
rem Chemin complet : un powershell.exe depose dans le dossier courant n'est jamais lance.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -File "%~dp0git-viewer.ps1" %*
exit /b %ERRORLEVEL%
