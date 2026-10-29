' git-tools : lanceur sans fenetre de repli (ADR-05, reglage launcher wscript).
' Argument 1 : chemin de git-autosave.ps1
Set sh = CreateObject("WScript.Shell")
ps1 = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File """ & ps1 & """ run --scheduled"
sh.Run cmd, 0, True
