param(
    [string]$LogFile  = "$PWD\debug-capture.log",
    [string]$KeyDebug = "+{F9}"   # WshShell.SendKeys notation: + Shift, % Alt, ^ Ctrl
)

. "$PSScriptRoot\WinApi.ps1"

$chaserOutput = "$env:TEMP\idea-chaser-output.tmp"
$chaserErr    = "$env:TEMP\idea-chaser-error.tmp"

if (Test-Path $LogFile)      { Remove-Item $LogFile      -Force }
if (Test-Path $chaserOutput) { Remove-Item $chaserOutput -Force }
if (Test-Path $chaserErr)    { Remove-Item $chaserErr    -Force }

$chaserArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\Chase-DebugProcess.ps1`" " +
              "-LogFile `"$LogFile`" -MinimizeIntelliJ"
$chaser = Start-Process powershell -ArgumentList $chaserArgs `
    -RedirectStandardOutput $chaserOutput `
    -RedirectStandardError $chaserErr `
    -NoNewWindow -PassThru
Start-Sleep -Milliseconds 600

$handles = [WinApiShared]::FindByClass("SunAwtFrame")
if ($handles.Count -eq 0) {
    $chaser | Stop-Process -Force
    Write-Error "IntelliJ IDEA not found"
    exit 1
}

Invoke-BringToForeground $handles[0]
# SendKeys via a fresh wscript process so it runs in the interactive user session
$vbs = "$env:TEMP\idea-send-key.vbs"
"Set WshShell = WScript.CreateObject(`"WScript.Shell`")`nWshShell.SendKeys `"$KeyDebug`"" | Out-File $vbs -Encoding ASCII
Start-Process "wscript.exe" -ArgumentList "`"$vbs`"" -Wait
Write-Host "$KeyDebug sent. Chasing agent is running..."

$chaser.WaitForExit()

Write-Host "`n========== DEBUG OUTPUT =========="
if (Test-Path $chaserOutput) {
    Get-Content $chaserOutput -Encoding UTF8
    Remove-Item $chaserOutput -Force -ErrorAction SilentlyContinue
}
if (Test-Path $chaserErr) {
    $errs = Get-Content $chaserErr -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' }
    if ($errs) { Write-Host "`n[chaser errors]"; $errs }
    Remove-Item $chaserErr -Force -ErrorAction SilentlyContinue
}
if (Test-Path $vbs) { Remove-Item $vbs -Force -ErrorAction SilentlyContinue }
Write-Host "=================================="
