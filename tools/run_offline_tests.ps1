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

function Invoke-Scene([string]$scene, [string]$name) {
    $arguments = @('--headless', '--path', ('"' + $projectPath + '"'), $scene)
    $process = Start-Process -FilePath $enginePath -ArgumentList $arguments -WorkingDirectory (Split-Path $enginePath -Parent) -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logPath/$name.log" -RedirectStandardError "$logPath/$name.err"
    # Обращение к Handle кэширует хэндл процесса: без него .NET не заполняет
    # ExitCode после WaitForExit(), и код возврата приходит пустым.
    $null = $process.Handle
    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()
    return $code
}

try {
    # 1. Обычный прогон: SDK на месте.
    $code = Invoke-Scene 'res://tools/regression_test.tscn' 'with-sdk'
    $log = Get-Content -LiteralPath "$logPath/with-sdk.log" -Raw
    if ($code -ne 0 -or $log -notmatch 'REGRESSION TEST: PASS') { throw "Regression failed with SDK. See $logPath" }
    Write-Output ('with-sdk: PASS (' + ([regex]::Matches($log, '(?m)^PASS')).Count + ' checks)')

    # 2. Прогон без SDK: игра обязана работать офлайн и не сыпать ошибками скриптов.
    if (Test-Path -LiteralPath $addon) { Move-Item -LiteralPath $addon -Destination $parked }
    $code = Invoke-Scene 'res://tools/regression_test.tscn' 'no-sdk'
    $log = Get-Content -LiteralPath "$logPath/no-sdk.log" -Raw
    $errors = Get-Content -LiteralPath "$logPath/no-sdk.err" -Raw
    if ($code -ne 0 -or $log -notmatch 'REGRESSION TEST: PASS') { throw "Regression failed without SDK. See $logPath" }
    if ($errors -match 'SCRIPT ERROR' -or $log -match 'SCRIPT ERROR') { throw "GDScript errors without SDK. See $logPath" }
    Write-Output ('no-sdk: PASS (' + ([regex]::Matches($log, '(?m)^PASS')).Count + ' checks)')
    Write-Output "Logs: $logPath"
} finally {
    if (Test-Path -LiteralPath $parked) { Move-Item -LiteralPath $parked -Destination $addon }
}
