param(
    [Parameter(Mandatory = $true)][string]$Godot
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
$enginePath = (Resolve-Path -LiteralPath $Godot).Path
$logPath = Join-Path $projectPath ('build/offline-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
New-Item -ItemType Directory -Path $logPath -Force | Out-Null
$addon = Join-Path $projectPath 'addons/fusion'
$parked = Join-Path $projectPath 'addons/_fusion_parked'
$workspacePrefix = [IO.Path]::GetFullPath($projectPath).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
foreach ($sdkPath in @($addon, $parked)) {
    if (-not [IO.Path]::GetFullPath($sdkPath).StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SDK path leaves the project: $sdkPath"
    }
}
if (Test-Path -LiteralPath $parked) { throw "SDK parking directory already exists: $parked" }
$sdkWasMoved = $false
$scenarios = @(
    @{ Scene = 'regression_test'; Marker = 'REGRESSION TEST: PASS' },
    @{ Scene = 'combat_test'; Marker = 'COMBAT TEST: PASS' },
    @{ Scene = 'character_test'; Marker = 'CHARACTER TEST: PASS' },
    @{ Scene = 'physics_effects_test'; Marker = 'PHYSICS EFFECTS TEST: PASS' },
    @{ Scene = 'movement_test'; Marker = 'MOVEMENT TEST: PASS' },
    @{ Scene = 'effects_audio_test'; Marker = 'EFFECTS AUDIO TEST: PASS' },
    @{ Scene = 'inventory_damage_test'; Marker = 'INVENTORY DAMAGE TEST: PASS' },
    @{ Scene = 'navigation_test'; Marker = 'NAVIGATION TEST: PASS' },
    @{ Scene = 'match_test'; Marker = 'MATCH TEST: PASS' }
)

function Invoke-Suite([string]$mode) {
    foreach ($scenario in $scenarios) {
        $name = $scenario.Scene + '-' + $mode
        $arguments = @('--headless', '--path', ('"' + $projectPath + '"'), '--log-file', ('"' + $logPath + '/' + $name + '-engine.log"'), ('res://tools/' + $scenario.Scene + '.tscn'))
        $process = Start-Process -FilePath $enginePath -ArgumentList $arguments -WorkingDirectory (Split-Path $enginePath -Parent) -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logPath/$name.log" -RedirectStandardError "$logPath/$name.err"
        $null = $process.Handle
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            $process.Dispose()
            throw "$name timed out. See $logPath"
        }
        $code = $process.ExitCode
        $process.Dispose()
        $log = Get-Content -LiteralPath "$logPath/$name.log" -Raw
        $errors = Get-Content -LiteralPath "$logPath/$name.err" -Raw
        if ($code -ne 0 -or $log -notmatch [regex]::Escape($scenario.Marker) -or $errors -match 'SCRIPT ERROR' -or $log -match 'SCRIPT ERROR') {
            throw "$name failed. See $logPath"
        }
        Write-Output ($name + ': PASS (' + ([regex]::Matches($log, '(?m)^PASS')).Count + ' checks)')
    }
}

try {
    Invoke-Suite 'with-sdk'
    if (Test-Path -LiteralPath $addon) {
        Move-Item -LiteralPath $addon -Destination $parked
        $sdkWasMoved = $true
    }
    Invoke-Suite 'no-sdk'
    Write-Output "Logs: $logPath"
} finally {
    if ($sdkWasMoved -and (Test-Path -LiteralPath $parked)) {
        Move-Item -LiteralPath $parked -Destination $addon
    }
}
