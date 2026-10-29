' git-tools : lanceur sans fenetre de repli (ADR-05, reglage launcher wscript).
' Arguments : chemin de git-autosave.ps1, puis la sous-commande et ses arguments.
Set sh = CreateObject("WScript.Shell")
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & ps & """ -NoProfile -NonInteractive -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
  cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
sh.CurrentDirectory = sh.ExpandEnvironmentStrings("%SystemRoot%")
sh.Run cmd, 0, True
