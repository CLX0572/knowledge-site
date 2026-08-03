#Requires -Version 5.1
# Simple GitHub push script (PS5 compatible - avoids finally/trap redirection bugs)
# Hardcoded project root. Flow:
#   cd root -> sync vault md -> status -> git add (ALL files by DEFAULT) ->
#   commit -> pull --rebase -> push -> npm check (120s timeout) -> npm build (120s timeout) -> pause.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1
#       -> auto commit msg, git add . (ALL files in repo - this is the DEFAULT)
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1 -Msg "my message"
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1 -ContentOnly
#       -> LEGACY mode: only git add content/ (not recommended, misses quartz.config.ts/bat/scripts)
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1 -SkipBuild -SkipCheck

param(
  [Alias("Msg")]
  [string]$CommitMessage = "",

  [switch]$ContentOnly,   # legacy: restrict git add to content/ only. Default = add ALL files (.)
  [switch]$SkipBuild,
  [switch]$SkipCheck,
  [switch]$SkipFormat,    # skip the "prettier auto-fix then recommit" step
  [switch]$SkipVaultSync  # skip robocopy from Obsidian VAULT -> content/
)

$ErrorActionPreference = "Stop"

# ============ CONFIG =============
[string]$ROOT  = "E:\TRAE SOLO CN\app\knowledge-site"
[string]$VAULT = "E:\Obisian\Notes"
[int]$MAX_PUSH_ATTEMPTS    = 3
[int]$RETRY_WAIT_SECONDS   = 3
[int]$NPM_TIMEOUT_SECONDS  = 120   # hard timeout for npm check / npm build (avoid hang)
# ==================================

function Write-H2([string]$t) { Write-Host ""; Write-Host ("==========  " + $t + "  ==========") -ForegroundColor Cyan }
function Write-OK([string]$t) { Write-Host ("[OK]   " + $t) -ForegroundColor Green }
function Write-ERR([string]$t){ Write-Host ("[ERR]  " + $t) -ForegroundColor Red }
function Write-WARN([string]$t){ Write-Host ("[WARN] " + $t) -ForegroundColor Yellow }

function Safe-Pause() {
  Write-Host ""
  Write-Host "-----  DONE. Press ANY key to close window  -----" -ForegroundColor Yellow
  # 4-level fallback. NEVER call cmd.exe (security rule blocks it on host).
  try   { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
  catch {
    try   { $null = [Console]::ReadKey($true) }
    catch {
      try   { [Threading.Thread]::Sleep(86400000) }
      catch { Start-Sleep -Seconds 3600 }
    }
  }
}

# Kill a process AND its children recursively (pure PS - no taskkill.exe). Used by Run-WithTimeout on hang.
function Stop-ProcessTree([int]$RootId) {
  try {
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $parentMap = @{}
    foreach ($p in $procs) {
      if (-not $parentMap.ContainsKey([int]$p.ParentProcessId)) { $parentMap[[int]$p.ParentProcessId] = @() }
      $parentMap[[int]$p.ParentProcessId] += [int]$p.ProcessId
    }
    $toKill = New-Object System.Collections.Generic.List[int]
    $queue  = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
      $cur = $queue.Dequeue()
      $toKill.Add($cur)
      if ($parentMap.ContainsKey($cur)) {
        foreach ($child in $parentMap[$cur]) {
          if (-not $toKill.Contains($child)) { $queue.Enqueue($child) }
        }
      }
    }
    [array]::Reverse($toKill)   # children first, parent last
    foreach ($id in $toKill) {
      try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch {
    try { Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue } catch {}
  }
  Start-Sleep -Milliseconds 400
}

# Timeout wrapper for long-running native commands (fixes "stuck on tsc for 30min" bug).
# Returns: exit code (int); on timeout returns [int]::MaxValue
function Run-WithTimeout {
  param(
    [Parameter(Mandatory=$true)][string]$FileName,
    [Parameter(Mandatory=$false)][string]$Arguments = "",
    [Parameter(Mandatory=$false)][string]$WorkingDirectory = $ROOT,
    [Parameter(Mandatory=$false)][int]$TimeoutSeconds = $NPM_TIMEOUT_SECONDS,
    [Parameter(Mandatory=$false)][string]$DisplayName = $FileName
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $FileName
  $psi.Arguments              = $Arguments
  $psi.WorkingDirectory       = $WorkingDirectory
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardOutput = $false   # stream live to host console
  $psi.RedirectStandardError  = $false
  $proc = [System.Diagnostics.Process]::Start($psi)
  try {
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      Write-Host ""
      Write-WARN ("TIMEOUT after {0}s -> killing {1} (PID {2}) and children." -f $TimeoutSeconds, $DisplayName, $proc.Id)
      Stop-ProcessTree -RootId $proc.Id
      return [int]::MaxValue
    }
    return [int]$proc.ExitCode
  } finally {
    try { if ($proc -and -not $proc.HasExited) { $proc.Dispose() } } catch {}
  }
}

# Obsidian VAULT -> website content/ mirror sync via robocopy.
# Syncs *.md + image attachments, excludes .obsidian / .git / _site etc.
function Sync-VaultToContent() {
  if ([string]::IsNullOrWhiteSpace($VAULT) -or -not (Test-Path -LiteralPath $VAULT)) {
    Write-WARN ("Obsidian VAULT not found: " + $VAULT + "  -> skip md sync")
    return
  }
  $content = Join-Path $ROOT "content"
  if (-not (Test-Path -LiteralPath $content)) {
    New-Item -ItemType Directory -Path $content -Force | Out-Null
  }
  [string[]]$robArgs = @($VAULT, $content, "*.md", "/E", "/COPY:DAT", "/DCOPY:DAT", "/R:1", "/W:1", "/NP", "/NFL", "/NDL")
  foreach ($exclude in @(".git", ".obsidian", ".trash", "_website", "_site")) {
    $robArgs += @("/XD", $exclude)
  }
  foreach ($ext in @("*.png","*.jpg","*.jpeg","*.gif","*.svg","*.webp","*.pdf")) {
    $robArgs += $ext
  }
  Write-Host "  robocopy Obsidian VAULT -> site content/  (md + attachments)"
  $null = & robocopy @robArgs
  # robocopy exit codes 0..7 = success (0=no-op, 1=files copied, ...) ; >=8 = error
  if ($LASTEXITCODE -ge 8) {
    Write-WARN ("robocopy reported warning (exit={0}); continuing anyway..." -f $LASTEXITCODE)
  } else {
    Write-OK "md + resource sync done"
  }
}

Write-Host ""
Write-Host "===  Physics KB GitHub Push (Simple Mode)  ===" -ForegroundColor Magenta
Write-Host ("Project: " + $ROOT)

# ---------- Step 0: cd root + sanity checks ----------
Write-H2 "Step 0: Locate project root"
if (-not (Test-Path -LiteralPath $ROOT)) { Write-ERR ("ROOT missing: " + $ROOT); Safe-Pause; exit 2 }
try { Set-Location -LiteralPath $ROOT -ErrorAction Stop } catch { Write-ERR ("cd failed: " + $_.Exception.Message); Safe-Pause; exit 2 }
if (-not (Test-Path -LiteralPath (Join-Path $ROOT ".git"))) { Write-ERR "No .git folder. Run git init + git remote add origin ... first."; Safe-Pause; exit 2 }
Write-OK ("cd -> " + $ROOT)

# ---------- Step 0.5: FIRST sync vault md -> content/  (so Step 1 git status reflects md changes) ----------
if ($SkipVaultSync) {
  Write-WARN "Vault sync skipped (-SkipVaultSync set)"
} else {
  Write-H2 "Step 0.5: Sync Obsidian Vault md -> content/"
  Sync-VaultToContent
}

# ---------- Step 1: git status summary ----------
Write-H2 "Step 1: Git status"
$statLines = @(git status --porcelain)
[int]$mod = ($statLines | Where-Object { $_ -match "^ ?M" }).Count
[int]$new = ($statLines | Where-Object { $_ -match "^A|\?\?" }).Count
[int]$del = ($statLines | Where-Object { $_ -match "^ ?D" }).Count
Write-Host ("  Modified : " + $mod)
Write-Host ("  New      : " + $new)
Write-Host ("  Deleted  : " + $del)
if ($statLines.Count -eq 0) {
  Write-WARN "No git changes. Nothing to commit/push."
  Write-Host "  (If changes were expected: check files were saved / VAULT files are newer than content/)"
}

# ---------- Step 2: git add (DEFAULT = ALL files. Fixes "quartz.config.ts/bat/scripts never pushed" bug) ----------
Write-H2 "Step 2: git add"
if ($ContentOnly) {
  Write-Host "  git add content/  (LEGACY MODE, per -ContentOnly - misses root-level ts/scss/bat changes)"
  if (Test-Path -LiteralPath (Join-Path $ROOT "content")) {
    git add content/
  } else {
    Write-WARN "content/ missing; fallback to git add ."
    git add .
  }
} else {
  Write-Host "  git add .  (DEFAULT = ALL files in repo - catches quartz.config.ts / bat / scripts)"
  git add .
}
Write-OK "staged"

# ---------- Step 3: git commit (skip if nothing staged) ----------
Write-H2 "Step 3: git commit"
$cachedBefore = @(git diff --cached --name-only)
[bool]$didMainCommit = $false
if ($cachedBefore.Count -eq 0) {
  Write-WARN "Nothing staged -> skip commit/pull/push."
} else {
  if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
    $CommitMessage = "update content - $ts"
  }
  Write-Host ("  message: " + $CommitMessage)
  git commit -m $CommitMessage
  if ($LASTEXITCODE -ne 0) {
    Write-ERR ("git commit failed (exit={0}). Fix errors above then re-run." -f $LASTEXITCODE)
    Safe-Pause; exit 3
  }
  $didMainCommit = $true
  Write-OK "committed"

  # ---------- Step 4: pull --rebase ----------
  Write-H2 "Step 4: git pull --rebase (avoid conflicts)"
  git pull --rebase
  if ($LASTEXITCODE -ne 0) {
    Write-ERR "git pull --rebase FAILED (merge conflict / unstaged changes?)"
    Write-Host "  Manual fix steps:"
    Write-Host "    1) Edit files with conflicts (<<<<<<<  =======  >>>>>>>)"
    Write-Host "    2) git add <files>"
    Write-Host "    3) git rebase --continue"
    Write-Host "    4) re-run this script, OR run git push manually"
    Safe-Pause; exit 4
  }
  Write-OK "pull ok"

  # ---------- Step 5: git push with retries ----------
  Write-H2 ("Step 5: git push (retries=" + $MAX_PUSH_ATTEMPTS + ")")
  [int]$attempt = 1
  [bool]$pushed  = $false
  while ($attempt -le $MAX_PUSH_ATTEMPTS -and -not $pushed) {
    Write-Host ("  attempt " + $attempt + "/" + $MAX_PUSH_ATTEMPTS + " ...")
    git push
    if ($LASTEXITCODE -eq 0) {
      # verify: after fetch, ahead must be 0
      try { git fetch origin 2>$null | Out-Null } catch {}
      $cmp = git rev-list --left-right --count HEAD...@{u} 2>$null
      [int]$ahead = 0; [int]$behind = 0
      if ($cmp -and $cmp -match "^\s*(\d+)\s+(\d+)") { $ahead = [int]$matches[1]; $behind = [int]$matches[2] }
      if ($ahead -eq 0) {
        Write-OK ("PUSH SUCCESS  verified ahead=0 behind={0}" -f $behind)
        $pushed = $true
      } else {
        Write-WARN ("git push exit 0 but ahead={0} > 0 -> not yet pushed; retry..." -f $ahead)
      }
    } else {
      Write-WARN ("push exit={0}; retry in {1}s (check VPN/Clash ON)" -f $LASTEXITCODE, $RETRY_WAIT_SECONDS)
      if ($attempt -lt $MAX_PUSH_ATTEMPTS) { Start-Sleep -Seconds $RETRY_WAIT_SECONDS }
    }
    $attempt++
  }
  if (-not $pushed) {
    Write-ERR ("push FAILED after {0} attempts." -f $MAX_PUSH_ATTEMPTS)
    Write-Host "  Common fixes:"
    Write-Host "    1) Turn ON VPN/Clash, or: git config --global http.proxy http://127.0.0.1:7890"
    Write-Host "    2) Verify origin:           git remote -v"
    Write-Host "    3) Rebase conflict? run:   git status"
    Safe-Pause; exit 5
  }
}

# ---------- Step 6: npm check + build (local validation, timeout 120s each) ----------
Write-H2 ("Step 6: npm check + build (local validation, timeout {0}s each)" -f $NPM_TIMEOUT_SECONDS)
if ($SkipBuild -and $SkipCheck) {
  Write-WARN "Skipped (both -SkipBuild and -SkipCheck set)"
} elseif (-not (Test-Path -LiteralPath (Join-Path $ROOT "package.json"))) {
  Write-WARN "package.json missing -> skip npm step"
} else {
  if (-not (Test-Path -LiteralPath (Join-Path $ROOT "node_modules"))) {
    Write-Host "  node_modules absent -> npm install --omit=optional (first run only)"
    npm install --omit=optional
  }

  if (-not $SkipCheck) {
    Write-Host "  -> npm run check (tsc + prettier --check)"
    $checkExit = Run-WithTimeout -FileName "npm.cmd" -Arguments "run check" -DisplayName "npm run check"
    if ($checkExit -eq [int]::MaxValue) { Write-ERR "npm run check TIMED OUT (tsc hang? tune NPM_TIMEOUT_SECONDS)"; Safe-Pause; exit 60 }
    if ($checkExit -ne 0 -and -not $SkipFormat) {
      Write-WARN ("check failed (exit={0}) -> auto npm run format, then RE-RUN check to verify fix" -f $checkExit)
      $fmtExit = Run-WithTimeout -FileName "npm.cmd" -Arguments "run format" -DisplayName "npm run format"
      if ($fmtExit -eq [int]::MaxValue) { Write-ERR "npm run format TIMED OUT"; Safe-Pause; exit 61 }
      if ($fmtExit -ne 0) {
        Write-ERR ("format command itself FAILED (exit={0}). TSC/config errors CANNOT be fixed by prettier. Fix manually first." -f $fmtExit)
        Safe-Pause; exit 6
      }
      Write-Host "  -> re-run npm run check (post-format, CONFIRM pass or STOP)"
      $checkExit2 = Run-WithTimeout -FileName "npm.cmd" -Arguments "run check" -DisplayName "npm run check (post-format)"
      if ($checkExit2 -eq [int]::MaxValue) { Write-ERR "npm run check (post-format) TIMED OUT"; Safe-Pause; exit 62 }
      if ($checkExit2 -ne 0) {
        # BUG FIX from past runs: format then pull/push printed OK even when tsc still failing. Now we HALT here.
        Write-ERR ("npm run check STILL FAILING after format (exit={0}). This is a TSC/types error NOT prettier." -f $checkExit2)
        Write-Host "  -> scroll up, fix the TS error (example: quartz.config.ts fontOrigin=system -> local), then re-run."
        Safe-Pause; exit 63
      }
      Write-OK "check passes post-format"
      $after = @(git status --porcelain)
      if ($after.Count -gt 0) {
        Write-Host ("  re-staging {0} files (format / baseUrl fix / etc)" -f $after.Count)
        if ($ContentOnly) { git add content/ } else { git add . }
        git commit -m "style: auto format via npm run format"
        if ($LASTEXITCODE -ne 0) { Write-ERR "format commit failed"; Safe-Pause; exit 64 }
        if ($didMainCommit) {
          git pull --rebase
          if ($LASTEXITCODE -ne 0) { Write-ERR "format commit: pull --rebase FAILED (NO fake OK)"; Safe-Pause; exit 65 }
          git push
          if ($LASTEXITCODE -ne 0) { Write-ERR "format commit: push FAILED"; Safe-Pause; exit 66 }
          Write-OK "formatted files re-committed AND pushed"
        } else {
          Write-OK "format changes committed (no earlier main commit, so no push)"
        }
      }
    } elseif ($checkExit -ne 0) {
      Write-ERR ("check FAILED (exit={0}) and -SkipFormat set -> stop" -f $checkExit)
      Safe-Pause; exit 7
    } else {
      Write-OK "check passed (tsc + prettier)"
    }
  }

  if (-not $SkipBuild) {
    Write-Host "  -> npm run build (Quartz static site -> public/)"
    $buildExit = Run-WithTimeout -FileName "npm.cmd" -Arguments "run build" -DisplayName "npm run build"
    if ($buildExit -eq [int]::MaxValue) { Write-ERR "npm run build TIMED OUT"; Safe-Pause; exit 80 }
    if ($buildExit -ne 0) {
      Write-ERR ("npm run build FAILED (exit={0}). Scroll up for the error." -f $buildExit)
      Write-Host "  Common fix: delete node_modules folder then re-run (triggers fresh npm install)"
      Safe-Pause; exit 8
    }
    Write-OK "local build finished -> public/ is up-to-date"
  } else {
    Write-WARN "build skipped (-SkipBuild). Vercel auto-builds main branch on git push."
  }
}

# ---------- FINAL SUMMARY ----------
Write-H2 "SUMMARY"
$sumRemote = $(try { git remote get-url origin 2>$null } catch {}); if (-not $sumRemote) { $sumRemote = "(not set)" }
$sumBranch = $(try { git rev-parse --abbrev-ref HEAD 2>$null } catch {}); if (-not $sumBranch) { $sumBranch = "?" }
$sumCommit = $(try { git rev-parse --short HEAD 2>$null } catch {}); if (-not $sumCommit) { $sumCommit = "?" }
Write-Host ("  Project   : " + $ROOT)
Write-Host ("  Remote    : " + $sumRemote)
Write-Host ("  Branch    : " + $sumBranch)
Write-Host ("  Commit    : " + $sumCommit)
Write-Host "  Live URL  : https://knowledgesite.vercel.app"
Write-Host "  (Vercel auto-deploys 1-2 min after git push to main -> check https://vercel.com/dashboard for progress)"
Write-OK "ALL DONE."
Safe-Pause
exit 0