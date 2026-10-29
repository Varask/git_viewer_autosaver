@echo off
rem git-tools : installation en double-clic ou depuis cmd / PowerShell (ENF-06).
rem Verifie la strategie d execution AVANT de lancer install.ps1, sans jamais la contourner (FC3).
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "POL="
for /f "usebackq delims=" %%P in (`%PS% -NoProfile -NoLogo -NonInteractive -Command Get-ExecutionPolicy`) do set "POL=%%P"
if /i "%POL%"=="Restricted" goto blocked
if /i "%POL%"=="AllSigned" goto signed
"%PS%" -NoProfile -NoLogo -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"
goto end
:blocked
echo.
echo  PowerShell refuse les scripts sur ce compte (strategie "Restricted", valeur par defaut de Windows).
echo  git-tools a besoin de "RemoteSigned" : scripts locaux autorises, scripts telecharges refuses.
echo  Pour l activer pour VOTRE compte seulement, sans droits administrateur :
echo.
echo      powershell -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
echo.
echo  puis relancez install.cmd. Si la commande est refusee (poste gere par une DSI),
echo  transmettez docs\NOTE-DSI.md a votre service informatique.
set "RC=1"
goto end
:signed
echo.
echo  Ce poste n accepte que des scripts signes (strategie "AllSigned").
echo  Transmettez docs\NOTE-DSI.md a votre service informatique (section AllSigned).
set "RC=1"
:end
rem Garder la fenetre ouverte (double-clic) pour lire le resultat.
echo.
pause
exit /b %RC%
