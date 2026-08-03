# Stage-0 wrapper: 100% English, ASCII-safe output. Force pause EVEN IF inner script has exit bug.
$ErrorActionPreference = "Continue"

$real = Join-Path $PSScriptRoot "deploy.ps1"

# ---- Helper: resolve desktop path (CHS/ENG systems both OK) ----
function Get-Desktop {
  $d = [Environment]::GetFolderPath("Desktop")
  if (-not $d) { $d = Join-Path $env:USERPROFILE "Desktop" }
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null }
  return $d
}

# ---- Helper: guaranteed pause (ASCII only) ----
function Invoke-GuaranteedPause {
  param([string]$Trailer = "")
  Write-Host ""
  Write-Host "================ Pause (wrapper) ================" -ForegroundColor Cyan
  Write-Host "  Window kept open. Press any key OR just close the window." -ForegroundColor DarkGray
  if ($Trailer) { Write-Host "  Last note: $Trailer" -ForegroundColor DarkGray }
  Write-Host "=================================================" -ForegroundColor Cyan
  $ok = $false
  try {
    $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $comSpec; $psi.Arguments = "/c pause"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $false; $psi.RedirectStandardOutput = $false; $psi.RedirectStandardError = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($proc) { $proc.WaitForExit(); $ok = $true }
  } catch {}
  if (-not $ok) {
    try {
      $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
      & $comSpec /c pause
      $ok = $true
    } catch {}
  }
  if (-not $ok) { try { [void][System.Console]::ReadKey($true); $ok = $true } catch {} }
  if (-not $ok) { try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null; $ok = $true } catch {} }
  if (-not $ok) { Start-Sleep -Seconds 86400 }
}

# ---- Desktop marker files (so user can debug even if they cannot read terminal) ----
$desktop = Get-Desktop
$stage1 = Join-Path $desktop "_deploy_STAGE1_began.txt"
$stage2 = Join-Path $desktop "_deploy_STAGE2_beforeRunRealScript.txt"
$stage3 = Join-Path $desktop "_deploy_STAGE3_afterRunRealScript.txt"
$stage4 = Join-Path $desktop "_deploy_STAGE4_wrapperPauseEntered.txt"
try {
  "STAGE1 wrapper.ps1 started at $(Get-Date -Format s)`nPWD=$PWD`nPSScriptRoot=$PSScriptRoot`nrealScript=$real" | Out-File $stage1 -Encoding utf8 -ErrorAction SilentlyContinue
} catch {}

# ---- Step 1: syntax-parse real script FIRST (this catches parse errors that would flash-close) ----
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($real, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
  Write-Host ""
  Write-Host ("=" * 70) -ForegroundColor Red
  Write-Host "  deploy.ps1 SYNTAX PARSE ERROR ($($errs.Count) errors):" -ForegroundColor Red
  Write-Host ("=" * 70) -ForegroundColor Red
  $errs | ForEach-Object {
    Write-Host ("  Line {0,4} Col {1,3}: {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message) -ForegroundColor Yellow
  }
  try {
    $errText = ($errs | ForEach-Object { "Line $($_.Extent.StartLineNumber) Col $($_.Extent.StartColumnNumber): $($_.Message)" }) -join "`n"
    "PARSE ERROR at $(Get-Date -Format s)`n$errText" | Out-File (Join-Path $desktop "_deploy_PARSE_ERROR.txt") -Encoding utf8 -ErrorAction SilentlyContinue
  } catch {}
  try { "STAGE2 parse failed at $(Get-Date -Format s)" | Out-File $stage2 -Encoding utf8 -ErrorAction SilentlyContinue } catch {}
  "Pause entered (parse error) at $(Get-Date -Format s)" | Out-File $stage4 -Encoding utf8 -ErrorAction SilentlyContinue
  Invoke-GuaranteedPause -Trailer "Parse error detected. Check _deploy_PARSE_ERROR.txt on Desktop."
  exit 98
}

try { "STAGE2 parse OK. About to run real script at $(Get-Date -Format s)" | Out-File $stage2 -Encoding utf8 -ErrorAction SilentlyContinue } catch {}

# ---- Step 2: run real script ----
Write-Host ""
Write-Host "[Wrapper] deploy.ps1 parse OK. Running real script now ..." -ForegroundColor Green
& $real @args
$rc = $LASTEXITCODE
try { "STAGE3 real script exited with code=$rc at $(Get-Date -Format s)" | Out-File $stage3 -Encoding utf8 -ErrorAction SilentlyContinue } catch {}

# ---- Step 3: ALWAYS pause AFTER real script, regardless of inner finally (double insurance) ----
Write-Host ""
Write-Host "[Wrapper] deploy.ps1 finished. exit=$rc" -ForegroundColor DarkGray
if ($rc -ne 0) {
  Write-Host "[Wrapper] ERROR exit. Scroll up for red [ERR] lines; check Desktop\部署结果日志.log" -ForegroundColor Yellow
} else {
  Write-Host "[Wrapper] SUCCESS exit. Green banner above = verified GitHub push." -ForegroundColor Green
}

"Pause entered (rc=$rc) at $(Get-Date -Format s)" | Out-File $stage4 -Encoding utf8 -ErrorAction SilentlyContinue
Invoke-GuaranteedPause -Trailer "desktop markers: _deploy_STAGE1/2/3/4 .txt"
exit [int]$rc
