# Wait for a real external ADC input, then optionally run the full demod check.
#
# Typical use while connecting or adjusting an external QPSK source:
#   powershell -ExecutionPolicy Bypass -File scripts/wait_external_rx_signal.ps1 -RunFullCheck
#
# Faster preflight only, without expecting demod lock yet:
#   powershell -ExecutionPolicy Bypass -File scripts/wait_external_rx_signal.ps1 -MaxAttempts 10 -IntervalSeconds 2

[CmdletBinding()]
param(
    [ValidateSet("external_rx", "loopback", "loopback_prbs")]
    [string]$Mode = "external_rx",

    [string]$VivadoBat = "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat",
    [string]$PythonExe = "python",

    [int]$MaxAttempts = 0,
    [int]$IntervalSeconds = 3,
    [int]$SignalRepeat = 1,
    [int]$FullRepeat = 3,
    [int]$WarmupMs = 500,
    [int]$GapMs = 50,
    [string]$Target = "",
    [string]$Device = "",
    [string]$Ila = "",

    [switch]$RunFullCheck,
    [switch]$NoProgram,
    [switch]$ProgramEachAttempt,
    [switch]$DryRun,

    [int]$MinAdcSpan = 16,
    [double]$MinAdcAcRms = [double]::NaN,
    [double]$MinAdcBandPowerRatio = [double]::NaN,
    [double]$MinAdcPeakHz = [double]::NaN,
    [double]$MaxAdcPeakHz = [double]::NaN,
    [double]$AdcBandCenterHz = [double]::NaN,
    [double]$AdcBandWidthHz = [double]::NaN,

    [ValidateSet("", "positive", "negative", "nonzero")]
    [string]$ExpectNcoSign = "",
    [int]$MinNcoAbs = -1,
    [int]$MaxNcoAbs = -1,
    [switch]$CheckGrayCycle,

    [string[]]$ExistingCsv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($MaxAttempts -lt 0) {
    throw "-MaxAttempts must be nonnegative. Use 0 to wait indefinitely."
}
if ($IntervalSeconds -lt 0) {
    throw "-IntervalSeconds must be nonnegative."
}
if ($SignalRepeat -le 0) {
    throw "-SignalRepeat must be positive."
}
if ($FullRepeat -le 0) {
    throw "-FullRepeat must be positive."
}
if ($WarmupMs -lt 0) {
    throw "-WarmupMs must be nonnegative."
}
if ($GapMs -lt 0) {
    throw "-GapMs must be nonnegative."
}
if ($DryRun -and $MaxAttempts -eq 0) {
    $MaxAttempts = 1
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$CheckScript = Join-Path $ScriptDir "check_external_rx_board.ps1"
if (!(Test-Path -LiteralPath $CheckScript -PathType Leaf)) {
    throw "board check script not found: $CheckScript"
}

function Add-CommonArgs {
    param(
        [object[]]$BaseArgs,
        [int]$RepeatCount
    )
    $out = @($BaseArgs)
    $out += @(
        "-Mode", $Mode,
        "-VivadoBat", $VivadoBat,
        "-PythonExe", $PythonExe,
        "-Repeat", "$RepeatCount",
        "-WarmupMs", "$WarmupMs",
        "-GapMs", "$GapMs"
    )
    if (![double]::IsNaN($AdcBandCenterHz)) {
        $out += @("-AdcBandCenterHz", "$AdcBandCenterHz")
    }
    if (![double]::IsNaN($AdcBandWidthHz)) {
        $out += @("-AdcBandWidthHz", "$AdcBandWidthHz")
    }
    if (![double]::IsNaN($MinAdcAcRms)) {
        $out += @("-MinAdcAcRms", "$MinAdcAcRms")
    }
    if (![double]::IsNaN($MinAdcBandPowerRatio)) {
        $out += @("-MinAdcBandPowerRatio", "$MinAdcBandPowerRatio")
    }
    if (![double]::IsNaN($MinAdcPeakHz)) {
        $out += @("-MinAdcPeakHz", "$MinAdcPeakHz")
    }
    if (![double]::IsNaN($MaxAdcPeakHz)) {
        $out += @("-MaxAdcPeakHz", "$MaxAdcPeakHz")
    }
    if ($DryRun) {
        $out += "-DryRun"
    }
    if ($Target -ne "") {
        $out += @("-Target", $Target)
    }
    if ($Device -ne "") {
        $out += @("-Device", $Device)
    }
    if ($Ila -ne "") {
        $out += @("-Ila", $Ila)
    }
    if ($ExistingCsv.Count -gt 0) {
        $out += "-ExistingCsv"
        $out += $ExistingCsv
    }
    return $out
}

function Invoke-BoardCheck {
    param([object[]]$ArgList)
    Write-Host "INFO: running: powershell -ExecutionPolicy Bypass -File $CheckScript $($ArgList -join ' ')"
    & powershell -ExecutionPolicy Bypass -File $CheckScript @ArgList 2>&1 | Out-Host
    $code = $LASTEXITCODE
    return $code
}

$attempt = 0
$signalPassed = $false
$programmedOnce = $false

while (($MaxAttempts -eq 0) -or ($attempt -lt $MaxAttempts)) {
    $attempt++
    Write-Host ("INFO: signal preflight attempt {0}{1}" -f `
        $attempt, $(if ($MaxAttempts -gt 0) { " / $MaxAttempts" } else { "" }))

    $signalArgs = @("-SignalOnly", "-MinAdcSpan", "$MinAdcSpan")
    if ($NoProgram -or (($programmedOnce -or $attempt -gt 1) -and !$ProgramEachAttempt)) {
        $signalArgs += "-NoProgram"
    }
    $signalArgs = Add-CommonArgs -BaseArgs $signalArgs -RepeatCount $SignalRepeat

    $exitCode = Invoke-BoardCheck -ArgList $signalArgs
    if ($exitCode -eq 0) {
        $signalPassed = $true
        break
    }

    $programmedOnce = $true
    if (($MaxAttempts -ne 0) -and ($attempt -ge $MaxAttempts)) {
        break
    }
    if ($IntervalSeconds -gt 0) {
        Write-Host "INFO: ADC signal preflight not passing yet; waiting $IntervalSeconds second(s)."
        Start-Sleep -Seconds $IntervalSeconds
    }
}

if (!$signalPassed) {
    Write-Host "ERROR: ADC signal preflight did not pass."
    exit 2
}

Write-Host "INFO: ADC signal preflight passed."

if (!$RunFullCheck) {
    exit 0
}

$fullArgs = @()
if ($NoProgram -or !$ProgramEachAttempt) {
    $fullArgs += "-NoProgram"
}
if ($CheckGrayCycle) {
    $fullArgs += "-CheckGrayCycle"
}
if ($ExpectNcoSign -ne "") {
    $fullArgs += @("-ExpectNcoSign", $ExpectNcoSign)
}
if ($MinNcoAbs -ge 0) {
    $fullArgs += @("-MinNcoAbs", "$MinNcoAbs")
}
if ($MaxNcoAbs -ge 0) {
    $fullArgs += @("-MaxNcoAbs", "$MaxNcoAbs")
}
$fullArgs = Add-CommonArgs -BaseArgs $fullArgs -RepeatCount $FullRepeat

$fullExit = Invoke-BoardCheck -ArgList $fullArgs
if ($fullExit -ne 0) {
    Write-Host "ERROR: full external RX demod check failed after signal preflight passed."
    exit $fullExit
}

Write-Host "INFO: full external RX demod check passed."
exit 0
