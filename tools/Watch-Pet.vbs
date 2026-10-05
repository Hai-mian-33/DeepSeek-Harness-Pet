' ============================================================================
' Watch-Pet.vbs - launch the Blue Whale Pet watchdog with no console window.
'
' INSTALLED AND MAINTAINED BY tools\Install-Autostart.ps1 -- do not edit the copy in
' the Startup folder, because reinstalling overwrites it. Edit THIS file instead.
'
' Where it goes:
'     %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\BlueWhalePet.vbs
'
' Why a .vbs rather than putting the .ps1 in Startup directly:
'   * a .ps1 in Startup opens a visible console window at every logon;
'   * Windows would run it under the default execution policy, which may refuse it;
'   * WScript.Shell.Run with style 0 starts it hidden and detached, so this launcher
'     exits immediately and leaves nothing on screen.
'
' Why a watchdog rather than starting the pet right here:
'   the pet must be visible exactly while DeepSeek Harness is open, and must put itself
'   away when Harness closes. That needs a resident process -- tools\Watch-Pet.ps1.
'
' __PET_ROOT__ is replaced by the installer with the real project path. It is injected
' rather than hardcoded so the same file works from any install location, and so a copy
' placed in the Startup folder (which cannot derive the project path from its own
' location) still knows where the project is.
' ============================================================================

Option Explicit

Dim shell, fso, scriptDir, root, watchScript, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = "__PET_ROOT__"

' If this file is being run from the project's own tools\ directory, prefer the path
' derived from its location: that keeps a working copy usable even if the project is
' moved without reinstalling. One level up from tools\ is the project root.
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
If fso.FileExists(fso.BuildPath(scriptDir, "Watch-Pet.ps1")) Then
    root = fso.GetAbsolutePathName(fso.BuildPath(scriptDir, ".."))
End If

watchScript = fso.BuildPath(root, "tools\Watch-Pet.ps1")

If Not fso.FileExists(watchScript) Then
    ' Fail loudly and visibly: a watchdog that silently does nothing is the worst
    ' outcome, because the pet simply never appears and nothing explains why.
    MsgBox "Blue Whale Pet: cannot find the watchdog script." & vbCrLf & vbCrLf & _
           "Expected at:" & vbCrLf & watchScript & vbCrLf & vbCrLf & _
           "Reinstall with:" & vbCrLf & _
           "  powershell -NoProfile -File """ & root & "\tools\Install-Autostart.ps1""", _
           16, "Blue Whale Pet"
    WScript.Quit 1
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
        & watchScript & """"

' 0 = hidden window, False = do not wait for it to finish.
shell.Run command, 0, False
