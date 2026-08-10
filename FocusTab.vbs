' FocusTab.vbs - generic Stream Deck launcher for Focus-EdgeTab.ps1
'
' Copy this file once per Stream Deck button and RENAME it. The filename
' supplies the tab match string, so you never edit the script itself.
'
'   Focus <match> [#<index>] [@<profile>].vbs
'
' Examples:
'   Focus Voice -.vbs               -> tab containing "Voice -"
'   Focus Google Gemini.vbs         -> leftmost Google Gemini tab
'   Focus Google Gemini #2.vbs      -> second Google Gemini tab
'   Focus Google Drive @Personal.vbs-> leftmost Drive tab in the Personal profile
'
' Keep the copies next to Focus-EdgeTab.ps1, or in a subfolder beside it.
' Point Stream Deck's System > Open action at the renamed copy.

Option Explicit

Dim scriptDir, base, tabName, profileName, idx, cmd, p

' Locate Focus-EdgeTab.ps1 in this folder, or one level up if these
' launchers live in a TabButtons subfolder.
Dim fso, psPath, parentDir
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
psPath = scriptDir & "Focus-EdgeTab.ps1"

If Not fso.FileExists(psPath) Then
    parentDir = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
    If Right(parentDir, 1) <> "\" Then parentDir = parentDir & "\"
    If fso.FileExists(parentDir & "Focus-EdgeTab.ps1") Then psPath = parentDir & "Focus-EdgeTab.ps1"
End If

If Not fso.FileExists(psPath) Then
    MsgBox "Focus-EdgeTab.ps1 not found next to this launcher or one folder up."
    WScript.Quit 1
End If

base = WScript.ScriptName
If InStrRev(base, ".") > 0 Then base = Left(base, InStrRev(base, ".") - 1)

' Strip the leading "Focus " prefix if present.
If LCase(Left(base, 6)) = "focus " Then base = Mid(base, 7)

' Optional @profile suffix.
profileName = ""
p = InStr(base, "@")
If p > 0 Then
    profileName = Trim(Mid(base, p + 1))
    base = Trim(Left(base, p - 1))
End If

' Optional #index suffix.
idx = 1
p = InStr(base, "#")
If p > 0 Then
    idx = CInt(Trim(Mid(base, p + 1)))
    base = Trim(Left(base, p - 1))
End If

tabName = Trim(base)

If tabName = "" Then
    MsgBox "Rename this file to 'Focus <tab name>.vbs' - e.g. 'Focus Google Drive.vbs'."
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
      psPath & """ -TabName """ & tabName & """ -Index " & idx

If profileName <> "" Then cmd = cmd & " -EdgeProfile """ & profileName & """"

CreateObject("WScript.Shell").Run cmd, 0, False
