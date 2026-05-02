param(
    [string]$LogFile         = "$PWD\debug-capture.log",
    [int]$WaitForProcessSec  = 120,
    [switch]$MinimizeIntelliJ
)

. "$PSScriptRoot\WinApi.ps1"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding            = [System.Text.Encoding]::UTF8

$ideaDir = Get-ChildItem "$env:LOCALAPPDATA\JetBrains" -Filter "IntelliJIdea*" -Directory |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
$testHistoryDir = "$ideaDir\testHistory"

# Snapshot all existing XMLs and their timestamps before the run starts
$baseline = @{}
Get-ChildItem "$testHistoryDir\*\*.xml" -ErrorAction SilentlyContinue | ForEach-Object {
    $baseline[$_.FullName] = $_.LastWriteTime
}

Write-Host "[chaser] armed, watching for new test results XML..."

$deadline = (Get-Date).AddSeconds($WaitForProcessSec)
$latest   = $null

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $candidate = Get-ChildItem "$testHistoryDir\*\*.xml" -ErrorAction SilentlyContinue |
        Where-Object {
            -not $baseline.ContainsKey($_.FullName) -or
            $_.LastWriteTime -gt $baseline[$_.FullName]
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($candidate) {
        # Wait a moment to let IntelliJ finish writing the file
        Start-Sleep -Milliseconds 1500
        $latest = Get-Item $candidate.FullName
        Write-Host "[chaser] new results: $($latest.Name)"
        break
    }
}

if (-not $latest) {
    Write-Error "[chaser] no new test results XML appeared within ${WaitForProcessSec}s"
    exit 1
}

if (Test-Path $LogFile) {
    Write-Host "[chaser] === LOG FILE: $LogFile ==="
    Get-Content $LogFile
} else {
    Write-Host "[chaser] === LOG FILE: not found ==="
    Write-Host "[chaser] HINT: the IntelliJ Run/Debug Configuration is missing one or both of:"
    Write-Host "[chaser]   1. Logs tab -> 'Save console output to file:' (target path)"
    Write-Host "[chaser]   2. VM options -> -Dlogging.file.name=<path>  (for Spring Boot apps)"
}

Write-Host "`n[chaser] === TEST HISTORY XML: $($latest.FullName) ==="
$raw  = ([System.IO.File]::ReadAllText($latest.FullName, [System.Text.Encoding]::UTF8)) -replace 'version="1\.1"','version="1.0"'
[xml]$xml = $raw
$counts = @{}
$xml.SelectNodes("//count") | ForEach-Object { $counts[$_.name] = $_.value }
$total  = $counts['total']
$passed = if ($counts['passed']) { $counts['passed'] } else { '0' }
$failed = if ($counts['failed']) { $counts['failed'] } else { '0' }
Write-Host "Total: $total  Passed: $passed  Failed: $failed"
Write-Host ""
foreach ($test in $xml.testrun.test) {
    $icon = if ($test.status -eq 'passed') { 'PASS' } else { 'FAIL' }
    $dur  = if ($test.duration) { "$($test.duration)ms" } else { '?' }
    Write-Host "[$icon] $($test.name) ($dur)"
    if ($test.status -ne 'passed') {
        $test.output | Where-Object type -eq 'stderr' | ForEach-Object { Write-Host $_.'#text' }
    }
}

if ($MinimizeIntelliJ) {
    $ideaHandles = [WinApiShared]::FindByClass("SunAwtFrame")
    if ($ideaHandles.Count -gt 0) {
        # SW_MINIMIZE = 6; cross-process call, no focus-stealing required
        [WinApiShared]::ShowWindow($ideaHandles[0], 6) | Out-Null
        Write-Host "[chaser] IntelliJ minimized; Claude Code surfaces"
    }
}
