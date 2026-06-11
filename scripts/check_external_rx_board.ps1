# Capture and check RX demod ILA data for board bring-up.
#
# Default use for a real external QPSK source:
#   powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1
#
# Local PRBS analog loopback smoke:
#   powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode loopback_prbs
#
# External source with known positive residual carrier offset:
#   powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -ExpectNcoSign positive -MinNcoAbs 96 -MaxNcoAbs 8192
#
# External source input-presence preflight, before expecting demod lock:
#   powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -SignalOnly -MinAdcAcRms 20 -MinAdcBandPowerRatio 0.5
#
# The script writes per-capture summary JSON files and an aggregate summary JSON
# with min/avg/max values across repeated captures.

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
    [string]$AggregateSummaryJson = "",

    [switch]$NoProgram,
    [switch]$CheckGrayCycle,
    [switch]$SignalOnly,
    [switch]$WriteDecodedCsv,
    [switch]$DryRun,

    [double]$MinLockRatio = [double]::NaN,
    [double]$MinValidRatio = [double]::NaN,
    [int]$MinAdcSpan = -1,
    [double]$MinGrayCycleRatio = [double]::NaN,
    [double]$AdcBandCenterHz = [double]::NaN,
    [double]$AdcBandWidthHz = [double]::NaN,
    [double]$MinAdcAcRms = [double]::NaN,
    [double]$MinAdcBandPowerRatio = [double]::NaN,
    [double]$MinAdcPeakHz = [double]::NaN,
    [double]$MaxAdcPeakHz = [double]::NaN,
    [ValidateSet("", "positive", "negative", "nonzero")]
    [string]$ExpectNcoSign = "",
    [int]$MinNcoAbs = -1,
    [int]$MaxNcoAbs = -1,

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

function Numeric-Stats {
    param([object[]]$Values)
    $nums = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($nums.Count -eq 0) {
        return [ordered]@{
            count = 0
            min = $null
            avg = $null
            max = $null
        }
    }
    $measure = $nums | Measure-Object -Minimum -Average -Maximum
    return [ordered]@{
        count = $nums.Count
        min = $measure.Minimum
        avg = $measure.Average
        max = $measure.Maximum
    }
}

function Get-JsonProperty {
    param(
        [object]$Item,
        [string]$Name
    )
    if ($Item.PSObject.Properties.Name -contains $Name) {
        return $Item.$Name
    }
    return $null
}

function Format-Stats {
    param(
        [string]$Name,
        [hashtable]$Stats
    )
    if ($Stats.count -eq 0) {
        return ("INFO: aggregate {0}: no samples" -f $Name)
    }
    return ("INFO: aggregate {0}: min={1:g6} avg={2:g6} max={3:g6} n={4}" -f `
        $Name, $Stats.min, $Stats.avg, $Stats.max, $Stats.count)
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
if ($SignalOnly -and ($MinAdcSpan -lt 0)) {
    $MinAdcSpan = 16
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir
$CaptureTcl = Join-Path $ScriptDir "capture_external_rx_ila.tcl"
$DecodePy = Join-Path $RepoRoot "Tool\python\decode_rx_demod_ila.py"
$ToolDataDir = Join-Path $RepoRoot "Tool\data"
$CheckStem = if ($SignalOnly) { "{0}_signal_check" -f $Mode } else { "{0}_board_check" -f $Mode }

if ($Out -eq "") {
    $Out = Join-Path $ToolDataDir ("{0}.csv" -f $CheckStem)
} else {
    $Out = Resolve-RepoPath $Out
}

if ($AggregateSummaryJson -eq "") {
    $AggregateSummaryJson = Join-Path $ToolDataDir ("{0}_aggregate_summary.json" -f $CheckStem)
} else {
    $AggregateSummaryJson = Resolve-RepoPath $AggregateSummaryJson
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
$CaptureResults = @()
foreach ($csv in $CsvFiles) {
    $summaryJson = Summary-JsonPath $csv
    $decodeArgs = @(
        $DecodePy,
        $csv,
        "--summary-json", $summaryJson
    )
    if (!$SignalOnly) {
        $decodeArgs += "--check-external-rx"
    }
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
    if (![double]::IsNaN($AdcBandCenterHz)) {
        $decodeArgs += @("--adc-band-center-hz", "$AdcBandCenterHz")
    }
    if (![double]::IsNaN($AdcBandWidthHz)) {
        $decodeArgs += @("--adc-band-width-hz", "$AdcBandWidthHz")
    }
    if (![double]::IsNaN($MinAdcAcRms)) {
        $decodeArgs += @("--min-adc-ac-rms", "$MinAdcAcRms")
    }
    if (![double]::IsNaN($MinAdcBandPowerRatio)) {
        $decodeArgs += @("--min-adc-band-power-ratio", "$MinAdcBandPowerRatio")
    }
    if (![double]::IsNaN($MinAdcPeakHz)) {
        $decodeArgs += @("--min-adc-peak-hz", "$MinAdcPeakHz")
    }
    if (![double]::IsNaN($MaxAdcPeakHz)) {
        $decodeArgs += @("--max-adc-peak-hz", "$MaxAdcPeakHz")
    }
    if ($ExpectNcoSign -ne "") {
        $decodeArgs += @("--expect-nco-sign", $ExpectNcoSign)
    }
    if ($MinNcoAbs -ge 0) {
        $decodeArgs += @("--min-nco-abs", "$MinNcoAbs")
    }
    if ($MaxNcoAbs -ge 0) {
        $decodeArgs += @("--max-nco-abs", "$MaxNcoAbs")
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
        $CaptureResults += [pscustomobject]@{
            csv = $csv
            summary_json = $summaryJson
            passed = $true
            exit_code = $LASTEXITCODE
        }
    } else {
        $failCount++
        Write-Warning "ILA check failed for $csv with exit code $LASTEXITCODE."
        $CaptureResults += [pscustomobject]@{
            csv = $csv
            summary_json = $summaryJson
            passed = $false
            exit_code = $LASTEXITCODE
        }
    }
}

if ($DryRun) {
    Write-Host "INFO: dry run completed."
    exit 0
}

Write-Host "INFO: passing captures: $passCount / $($CsvFiles.Count)"
$Summaries = @()
foreach ($result in $CaptureResults) {
    if (Test-Path -LiteralPath $result.summary_json -PathType Leaf) {
        $summary = Get-Content -LiteralPath $result.summary_json -Raw | ConvertFrom-Json
        $Summaries += [pscustomobject]@{
            csv = $result.csv
            summary_json = $result.summary_json
            passed = $result.passed
            exit_code = $result.exit_code
            summary = $summary
        }
    }
}

if ($Summaries.Count -gt 0) {
    $Aggregate = [ordered]@{
        mode = $Mode
        signal_only = [bool]$SignalOnly
        captures = $Summaries.Count
        pass_count = $passCount
        fail_count = $failCount
        lock_ratio = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "lock_ratio" })
        valid_ratio = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "valid_ratio" })
        adc_raw_span = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "adc_raw_span" })
        lock_score_max = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "lock_score_max" })
        iq_rms_when_valid = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "iq_rms_when_valid" })
        adc_ac_rms = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "adc_ac_rms" })
        adc_spectrum_peak_hz = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "adc_spectrum_peak_hz" })
        adc_spectrum_band_power_ratio = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "adc_spectrum_band_power_ratio" })
        adc_spectrum_band_peak_hz = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "adc_spectrum_band_peak_hz" })
        nco_freq_corr_last_when_locked = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "nco_freq_corr_last_when_locked" })
        nco_freq_corr_last_when_locked_hz = Numeric-Stats @($Summaries | ForEach-Object { Get-JsonProperty $_.summary "nco_freq_corr_last_when_locked_hz" })
        captures_detail = @($Summaries | ForEach-Object {
            [ordered]@{
                csv = $_.csv
                passed = $_.passed
                lock_ratio = Get-JsonProperty $_.summary "lock_ratio"
                valid_ratio = Get-JsonProperty $_.summary "valid_ratio"
                adc_raw_span = Get-JsonProperty $_.summary "adc_raw_span"
                adc_ac_rms = Get-JsonProperty $_.summary "adc_ac_rms"
                adc_spectrum_peak_hz = Get-JsonProperty $_.summary "adc_spectrum_peak_hz"
                adc_spectrum_band_power_ratio = Get-JsonProperty $_.summary "adc_spectrum_band_power_ratio"
                adc_spectrum_band_peak_hz = Get-JsonProperty $_.summary "adc_spectrum_band_peak_hz"
                lock_score_max = Get-JsonProperty $_.summary "lock_score_max"
                nco_freq_corr_last_when_locked = Get-JsonProperty $_.summary "nco_freq_corr_last_when_locked"
                nco_freq_corr_last_when_locked_hz = Get-JsonProperty $_.summary "nco_freq_corr_last_when_locked_hz"
                check_failures = Get-JsonProperty $_.summary "check_failures"
            }
        })
    }

    Write-Host (Format-Stats "lock_ratio" $Aggregate.lock_ratio)
    Write-Host (Format-Stats "valid_ratio" $Aggregate.valid_ratio)
    Write-Host (Format-Stats "adc_raw_span" $Aggregate.adc_raw_span)
    Write-Host (Format-Stats "adc_ac_rms" $Aggregate.adc_ac_rms)
    Write-Host (Format-Stats "adc_spectrum_peak_hz" $Aggregate.adc_spectrum_peak_hz)
    Write-Host (Format-Stats "adc_spectrum_band_power_ratio" $Aggregate.adc_spectrum_band_power_ratio)
    Write-Host (Format-Stats "adc_spectrum_band_peak_hz" $Aggregate.adc_spectrum_band_peak_hz)
    Write-Host (Format-Stats "lock_score_max" $Aggregate.lock_score_max)
    Write-Host (Format-Stats "iq_rms_when_valid" $Aggregate.iq_rms_when_valid)
    Write-Host (Format-Stats "nco_freq_corr_last_when_locked" $Aggregate.nco_freq_corr_last_when_locked)

    $aggregateDir = Split-Path -Parent $AggregateSummaryJson
    if ($aggregateDir -ne "") {
        New-Item -ItemType Directory -Force -Path $aggregateDir | Out-Null
    }
    $Aggregate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $AggregateSummaryJson -Encoding UTF8
    Write-Host "INFO: aggregate_summary_json: $AggregateSummaryJson"
}

if ($failCount -ne 0) {
    if ($SignalOnly) {
        Write-Host "ERROR: $failCount capture(s) failed ADC signal-only checks."
    } else {
        Write-Host "ERROR: $failCount capture(s) failed external RX checks."
    }
    exit 2
}

if ($SignalOnly) {
    Write-Host "INFO: ADC signal-only board check passed."
} else {
    Write-Host "INFO: external RX board check passed."
}
exit 0
