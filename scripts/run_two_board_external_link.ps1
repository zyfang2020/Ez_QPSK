# Orchestrate the two-board external QPSK link bring-up.
#
# Fixed roles:
#   original AX7020-style interface -> TX
#   new high-speed interface        -> RX
#
# Typical dry run after mapping JTAG serials:
#   powershell -ExecutionPolicy Bypass -File scripts/run_two_board_external_link.ps1 `
#       -DryRun -TxTarget <tx_hw_target> -RxTarget <rx_hw_target> `
#       -TxPsTarget <tx_xsct_target> -RxPsTarget <rx_xsct_target>
#
# First hardware preflight:
#   powershell -ExecutionPolicy Bypass -File scripts/run_two_board_external_link.ps1 `
#       -TxTarget <tx_hw_target> -RxTarget <rx_hw_target> `
#       -TxPsTarget <tx_xsct_target> -RxPsTarget <rx_xsct_target> `
#       -MinAdcAcRms 20 -MinAdcBandPowerRatio 0.5
#
# Full demod check after ADC activity is present:
#   powershell -ExecutionPolicy Bypass -File scripts/run_two_board_external_link.ps1 `
#       -TxTarget <tx_hw_target> -RxTarget <rx_hw_target> `
#       -TxPsTarget <tx_xsct_target> -RxPsTarget <rx_xsct_target> `
#       -RunFullCheck -MinAdcAcRms 20 -MinAdcBandPowerRatio 0.5

[CmdletBinding()]
param(
    [ValidateSet("prbs", "gray")]
    [string]$TxMode = "prbs",

    [string]$TxTarget = "",
    [string]$RxTarget = "",
    [string]$TxDevice = "",
    [string]$RxDevice = "",
    [string]$RxIla = "",
    [string]$TxPsTarget = "",
    [string]$RxPsTarget = "",

    [string]$VivadoBat = "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat",
    [string]$XsctBat = "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat",
    [string]$PythonExe = "python",

    [switch]$ListTargets,
    [switch]$DryRun,
    [switch]$SkipProgramTx,
    [switch]$SkipProgramRx,
    [switch]$SkipPsInit,
    [switch]$SkipTxPsInit,
    [switch]$SkipRxPsInit,
    [switch]$RunFullCheck,
    [switch]$CheckGrayCycle,
    [switch]$AllowSameHwTarget,
    [switch]$AllowSamePsTarget,

    [int]$SignalRepeat = 1,
    [int]$FullRepeat = 3,
    [int]$WarmupMs = 500,
    [int]$GapMs = 50,
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
    [int]$MaxNcoAbs = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir
$ListHwTargetsTcl = Join-Path $ScriptDir "list_hw_targets.tcl"
$ProgramTcl = Join-Path $ScriptDir "program_bitstream.tcl"
$InitPsTcl = Join-Path $ScriptDir "init_ps7_fclk.tcl"
$WaitScript = Join-Path $ScriptDir "wait_external_rx_signal.ps1"
$CheckScript = Join-Path $ScriptDir "check_external_rx_board.ps1"

$TxArtifactMode = if ($TxMode -eq "gray") { "original_tx_gray" } else { "original_tx_prbs" }
$TxBit = Join-Path $RepoRoot ("artifacts\{0}\Ez_QPSK_{0}.bit" -f $TxArtifactMode)
$TxLtx = Join-Path $RepoRoot ("artifacts\{0}\Ez_QPSK_{0}.ltx" -f $TxArtifactMode)
$RxBit = Join-Path $RepoRoot "artifacts\new_interface_rx\Ez_QPSK_new_interface_rx.bit"
$RxLtx = Join-Path $RepoRoot "artifacts\new_interface_rx\Ez_QPSK_new_interface_rx.ltx"

function Require-File {
    param(
        [string]$PathText,
        [string]$Label
    )
    if (!(Test-Path -LiteralPath $PathText -PathType Leaf)) {
        throw "$Label not found: $PathText"
    }
}

function Add-IfValue {
    param(
        [object[]]$ArgList,
        [string]$Name,
        [string]$Value
    )
    $out = @($ArgList)
    if ($Value -ne "") {
        $out += @($Name, $Value)
    }
    return $out
}

function Add-IfDouble {
    param(
        [object[]]$ArgList,
        [string]$Name,
        [double]$Value
    )
    $out = @($ArgList)
    if (![double]::IsNaN($Value)) {
        $out += @($Name, "$Value")
    }
    return $out
}

function Invoke-Step {
    param(
        [string]$Label,
        [string]$Exe,
        [object[]]$ArgList
    )

    Write-Host "INFO: $Label"
    Write-Host "INFO: command: $Exe $($ArgList -join ' ')"
    if ($DryRun) {
        return
    }

    & $Exe @ArgList
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

if ($ListTargets) {
    Require-File $ListHwTargetsTcl "Vivado target listing script"
    Require-File $InitPsTcl "XSCT PS init script"
    Invoke-Step -Label "List Vivado hardware targets" `
        -Exe $VivadoBat `
        -ArgList @("-mode", "batch", "-source", $ListHwTargetsTcl)
    Invoke-Step -Label "List XSCT targets" `
        -Exe $XsctBat `
        -ArgList @($InitPsTcl, "-list")
    exit 0
}

if (!$SkipProgramTx -and ($TxTarget -eq "")) {
    throw "-TxTarget is required unless -SkipProgramTx is used."
}
if (!$SkipProgramRx -and ($RxTarget -eq "")) {
    throw "-RxTarget is required unless -SkipProgramRx is used."
}
if (!$SkipPsInit -and !$SkipTxPsInit -and ($TxPsTarget -eq "")) {
    throw "-TxPsTarget is required unless -SkipPsInit or -SkipTxPsInit is used."
}
if (!$SkipPsInit -and !$SkipRxPsInit -and ($RxPsTarget -eq "")) {
    throw "-RxPsTarget is required unless -SkipPsInit or -SkipRxPsInit is used."
}
if ($RxTarget -eq "") {
    throw "-RxTarget is required for RX board checks."
}
if (!$AllowSameHwTarget -and ($TxTarget -ne "") -and ($RxTarget -ne "") -and ($TxTarget -eq $RxTarget)) {
    $deviceInfoMissing = (($TxDevice -eq "") -or ($RxDevice -eq ""))
    $sameDevice = (($TxDevice -ne "") -and ($RxDevice -ne "") -and ($TxDevice -eq $RxDevice))
    if ($deviceInfoMissing -or $sameDevice) {
        throw "-TxTarget and -RxTarget both resolve to '$TxTarget'. Refusing to risk swapping TX/RX roles. Use separate targets, specify different -TxDevice/-RxDevice on a shared chain, or pass -AllowSameHwTarget intentionally."
    }
}
if (!$AllowSamePsTarget -and !$SkipPsInit -and !$SkipTxPsInit -and !$SkipRxPsInit -and
    ($TxPsTarget -ne "") -and ($RxPsTarget -ne "") -and ($TxPsTarget -eq $RxPsTarget)) {
    throw "-TxPsTarget and -RxPsTarget both resolve to '$TxPsTarget'. Refusing to initialize the same PS target for both roles. Pass distinct XSCT targets or -AllowSamePsTarget intentionally."
}

Require-File $ProgramTcl "programming script"
Require-File $WaitScript "wait/check script"
Require-File $CheckScript "board check script"
if (!$DryRun) {
    if (!$SkipProgramTx) {
        Require-File $TxBit "TX bitstream"
        Require-File $TxLtx "TX probe file"
    }
    if (!$SkipProgramRx) {
        Require-File $RxBit "RX bitstream"
        Require-File $RxLtx "RX probe file"
    }
}

if (!$SkipProgramTx) {
    $stepArgs = @("-mode", "batch", "-source", $ProgramTcl, "-tclargs",
        "-bit", $TxBit, "-ltx", $TxLtx, "-target", $TxTarget)
    $stepArgs = Add-IfValue $stepArgs "-device" $TxDevice
    Invoke-Step -Label "Program original-interface TX ($TxArtifactMode)" -Exe $VivadoBat -ArgList $stepArgs
}

if (!$SkipPsInit -and !$SkipTxPsInit) {
    Require-File $InitPsTcl "PS init script"
    Invoke-Step -Label "Initialize TX PS/FCLK" -Exe $XsctBat -ArgList @($InitPsTcl, "-target", $TxPsTarget)
}

if (!$SkipProgramRx) {
    $stepArgs = @("-mode", "batch", "-source", $ProgramTcl, "-tclargs",
        "-bit", $RxBit, "-ltx", $RxLtx, "-target", $RxTarget)
    $stepArgs = Add-IfValue $stepArgs "-device" $RxDevice
    Invoke-Step -Label "Program new-interface RX" -Exe $VivadoBat -ArgList $stepArgs
}

if (!$SkipPsInit -and !$SkipRxPsInit) {
    Require-File $InitPsTcl "PS init script"
    Invoke-Step -Label "Initialize RX PS/FCLK" -Exe $XsctBat -ArgList @($InitPsTcl, "-target", $RxPsTarget)
}

$commonCheckArgs = @(
    "-Mode", "new_interface_rx",
    "-VivadoBat", $VivadoBat,
    "-PythonExe", $PythonExe,
    "-WarmupMs", "$WarmupMs",
    "-GapMs", "$GapMs",
    "-NoProgram",
    "-Target", $RxTarget
)
$commonCheckArgs = Add-IfValue $commonCheckArgs "-Device" $RxDevice
$commonCheckArgs = Add-IfValue $commonCheckArgs "-Ila" $RxIla
$commonCheckArgs = Add-IfDouble $commonCheckArgs "-AdcBandCenterHz" $AdcBandCenterHz
$commonCheckArgs = Add-IfDouble $commonCheckArgs "-AdcBandWidthHz" $AdcBandWidthHz
$commonCheckArgs = Add-IfDouble $commonCheckArgs "-MinAdcAcRms" $MinAdcAcRms
$commonCheckArgs = Add-IfDouble $commonCheckArgs "-MinAdcBandPowerRatio" $MinAdcBandPowerRatio
$commonCheckArgs = Add-IfDouble $commonCheckArgs "-MinAdcPeakHz" $MinAdcPeakHz
$commonCheckArgs = Add-IfDouble $commonCheckArgs "-MaxAdcPeakHz" $MaxAdcPeakHz
if ($DryRun) {
    $commonCheckArgs += "-DryRun"
}

if ($RunFullCheck) {
    $stepArgs = @(
        "-RunFullCheck",
        "-SignalRepeat", "$SignalRepeat",
        "-FullRepeat", "$FullRepeat",
        "-MinAdcSpan", "$MinAdcSpan"
    ) + $commonCheckArgs
    if ($CheckGrayCycle) {
        $stepArgs += "-CheckGrayCycle"
    }
    if ($ExpectNcoSign -ne "") {
        $stepArgs += @("-ExpectNcoSign", $ExpectNcoSign)
    }
    if ($MinNcoAbs -ge 0) {
        $stepArgs += @("-MinNcoAbs", "$MinNcoAbs")
    }
    if ($MaxNcoAbs -ge 0) {
        $stepArgs += @("-MaxNcoAbs", "$MaxNcoAbs")
    }
    Invoke-Step -Label "Wait for RX signal and run full demod check" `
        -Exe "powershell" `
        -ArgList (@("-ExecutionPolicy", "Bypass", "-File", $WaitScript) + $stepArgs)
} else {
    $stepArgs = @(
        "-SignalOnly",
        "-Repeat", "$SignalRepeat",
        "-MinAdcSpan", "$MinAdcSpan"
    ) + $commonCheckArgs
    Invoke-Step -Label "Run RX ADC signal-only preflight" `
        -Exe "powershell" `
        -ArgList (@("-ExecutionPolicy", "Bypass", "-File", $CheckScript) + $stepArgs)
}

Write-Host "INFO: two-board external-link flow completed."
