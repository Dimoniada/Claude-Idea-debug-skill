param(
    [string]$LogFile  = "$PWD\debug-capture.log",
    [string]$KeyCombo = ""    # WshShell.SendKeys notation: + Shift, % Alt, ^ Ctrl. Empty = use config.
)

. "$PSScriptRoot\WinApi.ps1"

# --- Config: persistent KeyCombo across runs ---
$configDir  = "$env:APPDATA\idea-debug-skill"
$configFile = "$configDir\config.json"
$firstRun   = $false

if (-not (Test-Path $configDir))  { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
if (-not (Test-Path $configFile)) {
    @{ KeyCombo = "+{F9}" } | ConvertTo-Json | Out-File $configFile -Encoding UTF8
    $firstRun = $true
}

if (-not $KeyCombo) {
    try {
        $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $KeyCombo = $cfg.KeyCombo
    } catch {
        $KeyCombo = "+{F9}"
    }
}

if ($firstRun) {
    Write-Host "[idea-debug] First-run: created config at $configFile with default KeyCombo='+{F9}' (Shift+F9)."
    Write-Host "[idea-debug] To change, edit the file or pass -KeyCombo on the command line."
    Write-Host "[idea-debug] SendKeys notation: + Shift, % Alt, ^ Ctrl. Examples: '+%{F10}' = Shift+Alt+F10, '^{F9}' = Ctrl+F9."
}

# --- Temp output capture ---
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
"Set WshShell = WScript.CreateObject(`"WScript.Shell`")`nWshShell.SendKeys `"$KeyCombo`"" | Out-File $vbs -Encoding ASCII
Start-Process "wscript.exe" -ArgumentList "`"$vbs`"" -Wait
Write-Host "$KeyCombo sent. Chasing agent is running..."

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
