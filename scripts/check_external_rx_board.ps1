# Capture and check RX demod ILA data for board bring-up.
#
# Default use for a real external QPSK source:
#   powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1
#
# Local PRBS analog loopback smoke:
#   powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode loopback_prbs

[CmdletBinding()]
param(
    [ValidateSet("external_rx", "loopback", "loopback_prbs")]
    [string]$Mode = "external_rx",

    [string]$VivadoBat = "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat",
    [string]$PythonExe = "python",

    [int]$Repeat = 3,
    [int]$WarmupMs = 500,
    [int]$GapMs = 50,
    [string]$Out = "",

    [switch]$NoProgram,
    [switch]$CheckGrayCycle,
    [switch]$WriteDecodedCsv,
    [switch]$DryRun,

    [double]$MinLockRatio = [double]::NaN,
    [double]$MinValidRatio = [double]::NaN,
    [int]$MinAdcSpan = -1,
    [double]$MinGrayCycleRatio = [double]::NaN,

    [string[]]$ExistingCsv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$PathText)
    if ([System.IO.Path]::IsPathRooted($PathText)) {
        return $PathText
    }
    return (Join-Path $RepoRoot $PathText)
}

function Require-File {
    param(
        [string]$PathText,
        [string]$Label
    )
    if (!(Test-Path -LiteralPath $PathText -PathType Leaf)) {
        throw "$Label not found: $PathText"
    }
}

function Numbered-CsvPath {
    param(
        [string]$BasePath,
        [int]$Index,
        [int]$Total
    )
    if ($Total -le 1) {
        return $BasePath
    }
    $dir = Split-Path -Parent $BasePath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($BasePath)
    $ext = [System.IO.Path]::GetExtension($BasePath)
    return (Join-Path $dir ("{0}_{1:D2}{2}" -f $stem, $Index, $ext))
}

function Summary-JsonPath {
    param([string]$CsvPath)
    $dir = Split-Path -Parent $CsvPath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($CsvPath)
    return (Join-Path $dir ("{0}_summary.json" -f $stem))
}

function Decoded-CsvPath {
    param([string]$CsvPath)
    $dir = Split-Path -Parent $CsvPath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($CsvPath)
    return (Join-Path $dir ("{0}_decoded.csv" -f $stem))
}

if ($Repeat -le 0) {
    throw "-Repeat must be positive."
}
if ($WarmupMs -lt 0) {
    throw "-WarmupMs must be nonnegative."
}
if ($GapMs -lt 0) {
    throw "-GapMs must be nonnegative."
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir
$CaptureTcl = Join-Path $ScriptDir "capture_external_rx_ila.tcl"
$DecodePy = Join-Path $RepoRoot "Tool\python\decode_rx_demod_ila.py"
$ToolDataDir = Join-Path $RepoRoot "Tool\data"

if ($Out -eq "") {
    $Out = Join-Path $ToolDataDir ("{0}_board_check.csv" -f $Mode)
} else {
    $Out = Resolve-RepoPath $Out
}

$BitPath = Join-Path $RepoRoot ("artifacts\{0}\Ez_QPSK_{0}.bit" -f $Mode)
$LtxPath = Join-Path $RepoRoot ("artifacts\{0}\Ez_QPSK_{0}.ltx" -f $Mode)

Require-File $DecodePy "decode script"

$CsvFiles = @()
if ($ExistingCsv.Count -gt 0) {
    foreach ($csv in $ExistingCsv) {
        $csvPath = Resolve-RepoPath $csv
        Require-File $csvPath "existing ILA CSV"
        $CsvFiles += $csvPath
    }
} else {
    Require-File $CaptureTcl "capture script"
    Require-File $LtxPath "probe file"
    if (!$NoProgram) {
        Require-File $BitPath "bitstream"
    }

    $captureArgs = @(
        "-out", $Out,
        "-bit", $BitPath,
        "-ltx", $LtxPath,
        "-repeat", "$Repeat",
        "-warmup-ms", "$WarmupMs",
        "-gap-ms", "$GapMs"
    )
    if (!$NoProgram) {
        $captureArgs = @("-program") + $captureArgs
    }

    $vivadoArgs = @("-mode", "batch", "-source", $CaptureTcl, "-tclargs") + $captureArgs
    Write-Host "INFO: capture mode: $Mode"
    Write-Host "INFO: bitstream: $BitPath"
    Write-Host "INFO: probes: $LtxPath"
    Write-Host "INFO: output CSV base: $Out"
    Write-Host "INFO: Vivado command: $VivadoBat $($vivadoArgs -join ' ')"

    if (!$DryRun) {
        & $VivadoBat @vivadoArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado capture failed with exit code $LASTEXITCODE."
        }
    }

    for ($idx = 0; $idx -lt $Repeat; $idx++) {
        $CsvFiles += (Numbered-CsvPath $Out $idx $Repeat)
    }
}

$passCount = 0
$failCount = 0
foreach ($csv in $CsvFiles) {
    $summaryJson = Summary-JsonPath $csv
    $decodeArgs = @(
        $DecodePy,
        $csv,
        "--summary-json", $summaryJson,
        "--check-external-rx"
    )
    if ($CheckGrayCycle) {
        $decodeArgs += "--check-gray-cycle"
    }
    if (![double]::IsNaN($MinLockRatio)) {
        $decodeArgs += @("--min-lock-ratio", "$MinLockRatio")
    }
    if (![double]::IsNaN($MinValidRatio)) {
        $decodeArgs += @("--min-valid-ratio", "$MinValidRatio")
    }
    if ($MinAdcSpan -ge 0) {
        $decodeArgs += @("--min-adc-span", "$MinAdcSpan")
    }
    if (![double]::IsNaN($MinGrayCycleRatio)) {
        $decodeArgs += @("--min-gray-cycle-ratio", "$MinGrayCycleRatio")
    }
    if ($WriteDecodedCsv) {
        $decodeArgs += @("--decoded-csv", (Decoded-CsvPath $csv))
    }

    Write-Host "INFO: decode command: $PythonExe $($decodeArgs -join ' ')"
    if ($DryRun) {
        continue
    }

    & $PythonExe @decodeArgs
    if ($LASTEXITCODE -eq 0) {
        $passCount++
    } else {
        $failCount++
        Write-Warning "ILA check failed for $csv with exit code $LASTEXITCODE."
    }
}

if ($DryRun) {
    Write-Host "INFO: dry run completed."
    exit 0
}

Write-Host "INFO: passing captures: $passCount / $($CsvFiles.Count)"
if ($failCount -ne 0) {
    Write-Host "ERROR: $failCount capture(s) failed external RX checks."
    exit 2
}

Write-Host "INFO: external RX board check passed."
exit 0
