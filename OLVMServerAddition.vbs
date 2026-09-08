Option Explicit

Const HiddenWindow = 0
Const WaitForCompletion = True

Dim shell, fileSystem, processEnvironment, packageDirectory, applicationDirectory
Dim commandLauncher, commandProcessor
Dim commandLine, exitCode, launchError, systemRoot, packageLocation, packageDrive
Dim startupDay, startupMilliseconds

startupDay = DateDiff("d", DateSerial(1970, 1, 1), Date)
startupMilliseconds = CLng(Fix(Timer * 1000))

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set processEnvironment = shell.Environment("PROCESS")
processEnvironment("OLVM_SERVER_ADDITION_STARTUP_PROTOCOL") = "1"
processEnvironment("OLVM_SERVER_ADDITION_STARTUP_ENTRY") = "VBS"
processEnvironment("OLVM_SERVER_ADDITION_VBS_DAY") = CStr(startupDay)
processEnvironment("OLVM_SERVER_ADDITION_VBS_MS") = CStr(startupMilliseconds)

packageDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
applicationDirectory = fileSystem.BuildPath(packageDirectory, "Application")
commandLauncher = fileSystem.BuildPath(applicationDirectory, "OLVMServerAddition.cmd")
packageLocation = "Local"
If Left(packageDirectory, 2) = "\\" Then
    packageLocation = "UNC"
Else
    On Error Resume Next
    Set packageDrive = fileSystem.GetDrive(fileSystem.GetDriveName(packageDirectory))
    If Err.Number = 0 Then
        If packageDrive.DriveType = 3 Then packageLocation = "MappedNetwork"
    End If
    Err.Clear
    On Error GoTo 0
End If
processEnvironment("OLVM_SERVER_ADDITION_PACKAGE_LOCATION") = packageLocation

If Not fileSystem.FileExists(commandLauncher) Then
    MsgBox "Application\OLVMServerAddition.cmd was not found in the application package.", _
        vbCritical, "OLVM Server Addition - startup stopped"
    WScript.Quit 2
End If

commandProcessor = shell.ExpandEnvironmentStrings("%ComSpec%")
If Not fileSystem.FileExists(commandProcessor) Then
    MsgBox "Windows Command Processor was not found.", _
        vbCritical, "OLVM Server Addition - startup stopped"
    WScript.Quit 3
End If

' Prevent the hidden command process from inheriting a UNC working directory.
' The CMD launcher then establishes the package directory with its existing pushd.
systemRoot = shell.ExpandEnvironmentStrings("%SystemRoot%")
If fileSystem.FolderExists(systemRoot) Then
    shell.CurrentDirectory = systemRoot
End If

commandLine = Quote(commandProcessor) & " /D /S /C " & _
    Chr(34) & Quote(commandLauncher) & " --hidden" & Chr(34)

On Error Resume Next
exitCode = shell.Run(commandLine, HiddenWindow, WaitForCompletion)
If Err.Number <> 0 Then
    launchError = Err.Description
    Err.Clear
End If
On Error GoTo 0

If Len(launchError) > 0 Then
    MsgBox "OLVM Server Addition could not be started." & vbCrLf & vbCrLf & launchError, _
        vbCritical, "OLVM Server Addition - startup stopped"
    WScript.Quit 4
End If

If exitCode <> 0 Then
    MsgBox "OLVM Server Addition stopped with exit code " & CStr(exitCode) & "." & _
        vbCrLf & vbCrLf & _
        "Review the application log, or run Application\OLVMServerAddition.cmd directly for diagnostic output.", _
        vbCritical, "OLVM Server Addition - application stopped"
End If

WScript.Quit exitCode

Function Quote(ByVal value)
    Quote = Chr(34) & CStr(value) & Chr(34)
End Function
