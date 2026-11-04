@echo off
rem git-tools : installation en double-clic ou depuis cmd / PowerShell (ENF-06).
rem 1. Verifie la strategie d execution, sans jamais la contourner (FC3).
rem 2. Si le zip vient d internet, propose de debloquer ses fichiers APRES accord explicite :
rem    c est la procedure documentee (Unblock-File), pas un contournement.
rem 3. Lance install.ps1.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "GT_SRC=%~dp0"
set "POL="
for /f "usebackq delims=" %%P in (`%PS% -NoProfile -NoLogo -NonInteractive -Command Get-ExecutionPolicy`) do set "POL=%%P"
if /i "%POL%"=="Restricted" goto blocked
if /i "%POL%"=="AllSigned" goto signed

set "MOTW=0"
for /f "usebackq delims=" %%N in (`%PS% -NoProfile -NoLogo -NonInteractive -Command "(Get-ChildItem -LiteralPath $env:GT_SRC -Recurse -File | Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue } | Measure-Object).Count"`) do set "MOTW=%%N"
if not "%MOTW%"=="0" goto unblock

:run
"%PS%" -NoProfile -NoLogo -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"
goto end

:unblock
echo.
echo  %MOTW% fichier(s) de ce dossier sont marques comme telecharges d internet.
echo  Windows refusera de les executer tant qu ils ne sont pas debloques.
echo.
echo  Ne les debloquez que si ce paquet vient d une source de confiance (page Releases
echo  du projet) et, idealement, apres avoir compare son empreinte SHA-256 au fichier
echo  .sha256 publie a cote du zip.
echo.
choice /c ON /n /m " Debloquer les fichiers de ce dossier et continuer ? [O]ui / [N]on : "
if errorlevel 2 goto unblock_no
%PS% -NoProfile -NoLogo -NonInteractive -Command "Get-ChildItem -LiteralPath $env:GT_SRC -Recurse -File | Unblock-File"
if errorlevel 1 goto unblock_fail
echo  Fichiers debloques.
echo.
goto run

:unblock_no
echo.
echo  Installation annulee : aucun fichier n a ete modifie.
set "RC=1"
goto end

:unblock_fail
echo.
echo  Le deblocage a echoue. Votre poste l interdit peut-etre :
echo  transmettez docs\NOTE-DSI.md a votre service informatique.
set "RC=1"
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
