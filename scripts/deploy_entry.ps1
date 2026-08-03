# ============================================================
# deploy_entry.ps1 - SINGLE entry point consolidating all launch logic.
# ALL control flow lives here (safe for UTF-8 BOM).
# BAT stubs do nothing except call this file then pause.
# ============================================================
[CmdletBinding()]
param(
  [string]$CommitMessage,
  [switch]$SkipBuild,
  [switch]$SkipCheck,
  [switch]$SkipPush,
  [switch]$NoToast,
  [switch]$Force,
  [Parameter(ValueFromRemainingArguments = $true)]
  [object[]]$RemainingArgs
)
$ErrorActionPreference = "Continue"

# ------- helpers (ASCII-only output) -------
function Get-Desktop {
  $d = [Environment]::GetFolderPath("Desktop")
  if (-not $d) { $d = Join-Path $env:USERPROFILE "Desktop" }
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null }
  return $d
}
function Write-StageFile {
  param([string]$Name, [string]$Body)
  try {
    $path = Join-Path (Get-Desktop) $Name
    $Body | Out-File $path -Encoding utf8 -ErrorAction SilentlyContinue
    return $path
  } catch { return $null }
}
function Write-DeployLog {
  param([string]$Level, [string]$Message)
  try {
    $logPath = Join-Path (Get-Desktop) "部署结果日志.log"
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    $script:LastLogFile = $logPath
  } catch {}
}
function Invoke-GuaranteedPause {
  param([string]$Trailer = "", [string]$Banner = "Pause (entry) - Window kept open")
  Write-Host ""
  Write-Host ("=" * 64) -ForegroundColor Cyan
  Write-Host "  $Banner" -ForegroundColor Cyan
  Write-Host "  Press any key when done reading, or just close the window." -ForegroundColor DarkGray
  if ($Trailer) { Write-Host "  $Trailer" -ForegroundColor DarkGray }
  Write-Host ("=" * 64) -ForegroundColor Cyan
  $ok = $false
  # 1/5: run cmd.exe built-in pause directly in same console
  try {
    $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $comSpec
    $psi.Arguments = "/c pause"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($proc) {
      $proc.WaitForExit()
      $ok = $true
    }
  } catch {}
  # 2/5: cmd /c pause via & (no redirections so PS parser stays happy)
  if (-not $ok) {
    try {
      $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
      & $comSpec /c pause
      $ok = $true
    } catch {}
  }
  # 3/5: .NET Console.ReadKey
  if (-not $ok) { try { [void][System.Console]::ReadKey($true); $ok = $true } catch {} }
  # 4/5: RawUI.ReadKey
  if (-not $ok) { try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null; $ok = $true } catch {} }
  # 5/5: 24 hour hang failsafe
  if (-not $ok) { Write-Host "  [FALLBACK] wait 24h so window never auto-closes ..." -ForegroundColor Yellow; Start-Sleep -Seconds 86400 }
}

# ------- Stage 1: entry proof -------
$null = Write-StageFile "_deploy_STAGE1_entry_began.txt" (
  "STAGE1 deploy_entry.ps1 started at $(Get-Date -Format s)`n" +
  "PWD=$PWD`n" +
  "PSScriptRoot=$PSScriptRoot`n" +
  "args: -CommitMessage='$CommitMessage' -SkipBuild=$SkipBuild -SkipCheck=$SkipCheck -SkipPush=$SkipPush -NoToast=$NoToast -Force=$Force"
)

# ------- Stage 2: resolve project root (NOT %~dp0; scripts folder is 1 level deep) -------
$scriptsDir = $PSScriptRoot
$ROOT = Split-Path $scriptsDir -Parent
if (-not (Test-Path (Join-Path $ROOT "package.json"))) {
  Write-Host ""
  Write-Host ("=" * 70) -ForegroundColor Red
  Write-Host "  [FATAL] Cannot find package.json. Expected project root: $ROOT" -ForegroundColor Red
  Write-Host "  deploy_entry.ps1 must live in knowledge-site\scripts\ folder." -ForegroundColor Red
  Write-Host ("=" * 70) -ForegroundColor Red
  $null = Write-StageFile "_deploy_ROOT_FAIL.txt" "ROOT=$ROOT did not contain package.json"
  Write-DeployLog -Level "FATAL" -Message "ROOT resolve failed: $ROOT"
  $null = Write-StageFile "_deploy_STAGE5_entryPauseEntered.txt" "rc=5"
  Invoke-GuaranteedPause -Banner "FATAL: project root resolution failed"
  exit 5
}
Set-Location $ROOT
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  Physics KB Deploy - Entry (v2.0)" -ForegroundColor Green
Write-Host ("  Project root: " + $ROOT) -ForegroundColor Green
Write-Host ("  Desktop logs: " + (Get-Desktop)) -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host ""

# ------- Stage 3: parse-check deploy.ps1 first (flash-close due to syntax bug) -------
$deployPs1 = Join-Path $scriptsDir "deploy.ps1"
$null = Write-StageFile "_deploy_STAGE2_beforeParseDeploy.txt" "deploy=$deployPs1"
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($deployPs1, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
  Write-Host ""
  Write-Host ("=" * 70) -ForegroundColor Red
  Write-Host "  deploy.ps1 SYNTAX PARSE ERROR ($($errs.Count)):" -ForegroundColor Red
  Write-Host ("=" * 70) -ForegroundColor Red
  $errs | ForEach-Object {
    Write-Host ("  Line {0,4} Col {1,3}: {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message) -ForegroundColor Yellow
  }
  $errText = ($errs | ForEach-Object { "Line $($_.Extent.StartLineNumber) Col $($_.Extent.StartColumnNumber): $($_.Message)" }) -join "`n"
  $null = Write-StageFile "_deploy_PARSE_ERROR.txt" "PARSE ERROR at $(Get-Date -Format s)`n$errText"
  Write-DeployLog -Level "FATAL" -Message "deploy.ps1 parse failed ($($errs.Count) errors)"
  $null = Write-StageFile "_deploy_STAGE5_entryPauseEntered.txt" "rc=6"
  Invoke-GuaranteedPause -Banner "deploy.ps1 has SYNTAX ERROR - see _deploy_PARSE_ERROR.txt"
  exit 6
}

# ------- Stage 4: run deploy.ps1 (it has its own finally/pause) -------
$null = Write-StageFile "_deploy_STAGE3_beforeRunDeploy.txt" "about to run deploy.ps1"
Write-Host "[Entry] deploy.ps1 syntax OK. Running deployment script ..." -ForegroundColor Green

# Build a parameter array matching what deploy.ps1 expects
$params = @{}
if ($PSBoundParameters.ContainsKey('CommitMessage') -and $CommitMessage) { $params['CommitMessage'] = $CommitMessage }
if ($SkipBuild) { $params['SkipBuild'] = $true }
if ($SkipCheck) { $params['SkipCheck'] = $true }
if ($SkipPush)  { $params['SkipPush']  = $true }
if ($NoToast)   { $params['NoToast']   = $true }
if ($Force)     { $params['Force']     = $true }
if ($RemainingArgs -and $RemainingArgs.Count -gt 0) { $params['RemainingArgs'] = $RemainingArgs }

try {
  & $deployPs1 @params
  $rc = $LASTEXITCODE
} catch {
  Write-Host ("[Entry] deploy.ps1 threw unhandled exception: " + $_.Exception.Message) -ForegroundColor Red
  Write-DeployLog -Level "FATAL" -Message ("deploy.ps1 unhandled: " + $_.Exception.Message)
  $rc = 7
}
$null = Write-StageFile "_deploy_STAGE4_afterRunDeploy.txt" "deploy.ps1 exited rc=$rc"

# ------- Stage 5: always pause AFTER inner script (second insurance pause) -------
Write-Host ""
Write-Host "[Entry] deploy.ps1 finished. exit=$rc" -ForegroundColor DarkGray
if ($rc -eq 0) {
  Write-Host "[Entry] SUCCESS exit. Scroll up for the GREEN 'GITHUB PUSH: SUCCESS' banner = verified push." -ForegroundColor Green
} else {
  Write-Host "[Entry] ERROR exit. Scroll up for RED [ERR] / YELLOW [WARN]. Check Desktop\部署结果日志.log." -ForegroundColor Yellow
}
Write-DeployLog -Level "INFO" -Message "deploy_entry finished. deploy.ps1 rc=$rc"
$null = Write-StageFile "_deploy_STAGE5_entryPauseEntered.txt" "rc=$rc"

# Print desktop evidence list so user knows
$desktop = Get-Desktop
Write-Host ""
Write-Host "[Entry] Desktop evidence files (check these if window closes early):" -ForegroundColor DarkCyan
@("STAGE1","STAGE2","STAGE3","STAGE4","STAGE5") | ForEach-Object {
  $f = Join-Path $desktop ("_deploy_" + $_ + "_*.txt")
  $found = Get-Item $f -ErrorAction SilentlyContinue
  if ($found) { Write-Host ("   [PASS] " + $_.ToLower() + " : " + $found.Name + "  (modified " + $found.LastWriteTime.ToString("HH:mm:ss") + ")") -ForegroundColor DarkGreen }
  else { Write-Host ("   [FAIL] " + $_.ToLower() + " : file missing - did not reach that stage") -ForegroundColor DarkRed }
}

Invoke-GuaranteedPause -Banner "Entry Pause (2nd insurance) - window will NOT close"
exit [int]$rc
