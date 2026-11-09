Option Explicit
' 拾光阅读器启动器：静默启动本地服务 + 打开应用窗口
Dim fso, sh, dir, py, c
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

py = ""
Dim cands
cands = Array( _
  "C:\Users\EDY\.workbuddy\binaries\python\versions\3.13.12\pythonw.exe", _
  sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python313\pythonw.exe"), _
  sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe"), _
  "C:\Python313\pythonw.exe", _
  "C:\Python312\pythonw.exe")

For Each c In cands
  If fso.FileExists(c) Then
    py = c
    Exit For
  End If
Next

If py = "" Then py = "pythonw.exe"

sh.CurrentDirectory = dir
sh.Run """" & py & """ """ & dir & "\app.py""", 0, False
