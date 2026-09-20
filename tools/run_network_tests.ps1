param(
    [Parameter(Mandatory = $true)][string]$Godot,
    [switch]$Capture,
    [switch]$Packaged
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
$enginePath = (Resolve-Path -LiteralPath $Godot).Path
$runName = 'network-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$logPath = Join-Path $projectPath "build/$runName"
New-Item -ItemType Directory -Path $logPath -Force | Out-Null
$processes = @()
try {
    foreach ($role in @('host', 'client')) {
        $arguments = @('--path', ('"' + $projectPath + '"'), 'res://tools/multiplayer_test.tscn')
        if ($Packaged) { $arguments = @() }
        if ($Capture -and $role -eq 'client') {
            $arguments += @('--resolution', '1280x720')
        } else {
            $arguments += '--headless'
        }
        $arguments += @('--', "--role=$role", "--room=$runName")
        if ($Packaged) { $arguments += '--network-test' }
        if ($Capture -and $role -eq 'client') {
            $arguments += @('--capture', ('--capture-output="' + (Join-Path $projectPath 'build/network-proof.png') + '"'))
        }
        $processes += Start-Process -FilePath $enginePath -ArgumentList $arguments -WorkingDirectory (Split-Path $enginePath -Parent) -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logPath/$role.log" -RedirectStandardError "$logPath/$role.err"
        if ($role -eq 'host') { Start-Sleep -Seconds 2 }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(110)
    while (@($processes | Where-Object { -not $_.HasExited }).Count -gt 0) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Network test timed out.' }
        Start-Sleep -Milliseconds 250
    }
    foreach ($role in @('host', 'client')) {
        $log = Get-Content -LiteralPath "$logPath/$role.log" -Raw
        $errors = Get-Content -LiteralPath "$logPath/$role.err" -Raw
        if ($log -notmatch "NETWORK TEST ${role}: PASS failures=0" -or $log -match '(?m)^FAIL' -or $errors -match 'SCRIPT ERROR') {
            throw "Network test failed for $role. See $logPath"
        }
        $count = ([regex]::Matches($log, '(?m)^PASS')).Count
        Write-Output "${role}: PASS ($count checks)"
    }
    Write-Output "Logs: $logPath"
} finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id }
        $process.Dispose()
    }
}
