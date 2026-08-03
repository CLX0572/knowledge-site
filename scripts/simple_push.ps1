#Requires -Version 5.1
# Simple GitHub push script (PS5 compatible - avoids finally/trap redirection bugs)
# Hardcoded project root. Flow:
#   cd root -> resolve system npm/node ABSOLUTE paths -> sync vault md -> status ->
#   git add (ALL by DEFAULT) -> commit -> pull --rebase -> push ->
#   npm verify (npm --version) -> check (120s timeout, ABS npm path) ->
#   build (120s timeout, ABS npm path) -> pause.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1
#       -> auto commit msg, git add . (ALL files - DEFAULT)
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1 -Msg "my message"
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1 -ContentOnly
#       -> LEGACY: only git add content/ (misses root-level ts/scss/bat changes)
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\simple_push.ps1 -SkipCheck -SkipBuild
#       -> SKIP local npm entirely (md still pushed; Vercel builds server-side)

param(
  [Alias("Msg")]
  [string]$CommitMessage = "",

  [switch]$ContentOnly,   # legacy: restrict git add to content/ only. Default = add ALL files (.)
  [switch]$SkipBuild,
  [switch]$SkipCheck,
  [switch]$SkipFormat,    # skip "prettier auto-fix then recommit" step
  [switch]$SkipVaultSync  # skip robocopy Obsidian VAULT -> content/
)

$ErrorActionPreference = "Stop"

# ============ CONFIG =============
[string]$ROOT  = "E:\TRAE SOLO CN\app\knowledge-site"
[string]$VAULT = "E:\Obisian\Notes"
[int]$MAX_PUSH_ATTEMPTS    = 3
[int]$RETRY_WAIT_SECONDS   = 3
[int]$NPM_TIMEOUT_SECONDS  = 120   # hard timeout for npm check / npm build (avoid hang)
# Known system node/npm install roots (used as fallback when Get-Command fails)
[string[]]$KNOWN_NODE_DIRS = @(
  "E:\Node",
  "C:\Program Files\nodejs",
  "C:\Program Files (x86)\nodejs",
  "$env:LOCALAPPDATA\nodejs",
  "$env:APPDATA\npm"
)
# ==================================

function Write-H2([string]$t) { Write-Host ""; Write-Host ("==========  " + $t + "  ==========") -ForegroundColor Cyan }
function Write-OK([string]$t) { Write-Host ("[OK]   " + $t) -ForegroundColor Green }
function Write-ERR([string]$t){ Write-Host ("[ERR]  " + $t) -ForegroundColor Red }
function Write-WARN([string]$t){ Write-Host ("[WARN] " + $t) -ForegroundColor Yellow }

function Safe-Pause() {
  Write-Host ""
  Write-Host "-----  DONE. Press ANY key to close window  -----" -ForegroundColor Yellow
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

# -----------------------------------------------------------------------------
# Resolve system node.exe / npm.cmd to ABSOLUTE paths and FIX environment vars
# so that Process.Start(...) NEVER accidentally resolves "npm.cmd" inside the
# project directory (which, on Node 24 + npm 11, triggers NODE_PATH pollution
# that tries to load npm-cli.js from $project\node_modules and crashes).
# -----------------------------------------------------------------------------
function Resolve-ToolPaths() {
  # --- 1) node.exe ---
  [string]$script:NODE_EXE = ""
  try {
    $g = Get-Command node.exe -ErrorAction Stop
    $script:NODE_EXE = $g.Source
  } catch {}
  if ([string]::IsNullOrWhiteSpace($script:NODE_EXE)) {
    foreach ($dir in $KNOWN_NODE_DIRS) {
      $candidate = Join-Path $dir "node.exe"
      if (Test-Path -LiteralPath $candidate) { $script:NODE_EXE = $candidate; break }
    }
  }
  # --- 2) npm.cmd ---
  [string]$script:NPM_CMD = ""
  try {
    $g = Get-Command npm.cmd -ErrorAction Stop
    $script:NPM_CMD = $g.Source
  } catch {}
  if ([string]::IsNullOrWhiteSpace($script:NPM_CMD)) {
    try {
      $g = Get-Command npm -ErrorAction Stop
      if ($g.Source -like "*.cmd") { $script:NPM_CMD = $g.Source }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($script:NPM_CMD)) {
    foreach ($dir in $KNOWN_NODE_DIRS) {
      $candidate = Join-Path $dir "npm.cmd"
      if (Test-Path -LiteralPath $candidate) { $script:NPM_CMD = $candidate; break }
    }
  }
  # --- 3) Fix process PATH / NODE_PATH ---
  if (-not [string]::IsNullOrWhiteSpace($script:NODE_EXE)) {
    $nodeDir = Split-Path -Parent $script:NODE_EXE
    # Promote node install dir to the BEGINNING of PATH (highest resolution priority)
    $curPath = $env:PATH
    if ($curPath) {
      $parts = $curPath -split ';' | Where-Object { $_ -and ($_ -ne $nodeDir) }
      $env:PATH = (@($nodeDir) + $parts) -join ';'
    } else {
      $env:PATH = $nodeDir
    }
  }
  # Remove any pernicious NODE_PATH that might cause npm to resolve into project node_modules
  if ($env:NODE_PATH) { Remove-Item Env:NODE_PATH -ErrorAction SilentlyContinue }
  # Remove npm-specific env overrides that might point to project-local paths
  foreach ($k in @("NPM_CONFIG_PREFIX","NPM_CONFIG_NODEDIR","NPM_BIN")) {
    if (Test-Path "Env:$k") { Remove-Item ("Env:" + $k) -ErrorAction SilentlyContinue }
  }
  Write-Host ("  node.exe -> {0}" -f $(if ($script:NODE_EXE) { $script:NODE_EXE } else { "NOT FOUND" }))
  Write-Host ("  npm.cmd  -> {0}" -f $(if ($script:NPM_CMD)  { $script:NPM_CMD  } else { "NOT FOUND" }))
}

# Timeout wrapper for long-running native commands (fixes "stuck on tsc for 30min" bug).
# ALWAYS invoked with absolute system npm.exe path.
# Returns: exit code (int); on timeout returns [int]::MaxValue
function Run-WithTimeout {
  param(
    [Parameter(Mandatory=$true)][string]$FileName,            # ABSOLUTE PATH (e.g. $NPM_CMD)
    [Parameter(Mandatory=$false)][string]$Arguments = "",
    [Parameter(Mandatory=$false)][string]$WorkingDirectory = $ROOT,
    [Parameter(Mandatory=$false)][int]$TimeoutSeconds = $NPM_TIMEOUT_SECONDS,
    [Parameter(Mandatory=$false)][string]$DisplayName = $FileName
  )
  # Paranoia: if somehow caller passed a relative name, try to resolve
  if (-not [System.IO.Path]::IsPathRooted($FileName)) {
    try {
      $g = Get-Command $FileName -ErrorAction Stop
      $FileName = $g.Source
    } catch {
      # Leave as-is; Process.Start may still find it
    }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $FileName
  $psi.Arguments              = $Arguments
  $psi.WorkingDirectory       = $WorkingDirectory
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardOutput = $false   # stream live to host console
  $psi.RedirectStandardError  = $false
  # Force-clean process environment for npm/node (CRITICAL for Node 24 resolution bug):
  if ($psi.EnvironmentVariables.ContainsKey("NODE_PATH")) { $psi.EnvironmentVariables.Remove("NODE_PATH") | Out-Null }
  foreach ($k in @("NPM_CONFIG_PREFIX","NPM_CONFIG_NODEDIR","NPM_BIN")) {
    if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) | Out-Null }
  }
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
  # robocopy exit 0..7 = OK; >=8 = real error
  if ($LASTEXITCODE -ge 8) {
    Write-WARN ("robocopy reported warning (exit={0}); continuing anyway..." -f $LASTEXITCODE)
  } else {
    Write-OK "md + resource sync done"
  }
}

# ===========================================================
#  MAIN
# ===========================================================
Write-Host ""
Write-Host "===  Physics KB GitHub Push (Simple Mode)  ===" -ForegroundColor Magenta
Write-Host ("Project: " + $ROOT)

# ---------- Step 0: cd root + sanity checks ----------
Write-H2 "Step 0: Locate project root"
if (-not (Test-Path -LiteralPath $ROOT)) { Write-ERR ("ROOT missing: " + $ROOT); Safe-Pause; exit 2 }
try { Set-Location -LiteralPath $ROOT -ErrorAction Stop } catch { Write-ERR ("cd failed: " + $_.Exception.Message); Safe-Pause; exit 2 }
if (-not (Test-Path -LiteralPath (Join-Path $ROOT ".git"))) { Write-ERR "No .git folder. Run 'git init' + 'git remote add origin ...' first."; Safe-Pause; exit 2 }
Write-OK ("cd -> " + $ROOT)

# ---------- Step 0.25: Resolve system node/npm FIRST (fixes MODULE_NOT_FOUND in project dir) ----------
Write-H2 "Step 0.25: Resolve system node/npm (ABSOLUTE paths + PATH fix)"
Resolve-ToolPaths

# ---------- Step 0.5: FIRST sync vault md -> content/ ----------
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
[bool]$noGitChanges = ($statLines.Count -eq 0)
if ($noGitChanges) {
  Write-WARN "No git changes. Nothing to commit/push."
  Write-Host "  (Common cause: Obsidian Vault md == site content/ md byte-for-byte after sync -> nothing changed.)"
  Write-Host "  (If changes expected: save md files in Obsidian, or manually touch a file then re-run.)"
}

# ---------- Step 2: git add (DEFAULT = ALL files) ----------
Write-H2 "Step 2: git add"
if ($ContentOnly) {
  Write-Host "  git add content/  (LEGACY MODE, per -ContentOnly - misses root ts/scss/bat)"
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

# ---------- Step 3: git commit ----------
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
    Write-ERR ("git commit failed (exit={0}). Fix errors above, then re-run." -f $LASTEXITCODE)
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
      try { git fetch origin 2>$null | Out-Null } catch {}
      # NOTE: @{u} is a GIT shorthand; PowerShell would expand "@{u}" as hashtable syntax -> bug
      [int]$ahead = 0; [int]$behind = 0
      try {
        $revArgs = @('rev-list','--left-right','--count',('HEAD...' + '@{u}'))
        $cmpOut  = & git @revArgs 2>$null
        if ($cmpOut -and $cmpOut -match "^\s*(\d+)\s+(\d+)") { $ahead = [int]$matches[1]; $behind = [int]$matches[2] }
      } catch {}
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
  # --- PRE-FLIGHT: verify that the system npm actually works BEFORE entering check/format chain ---
  # (This avoids today's confusing "check failed -> auto format -> format also crashes" chain of red herrings.)
  Write-H2 "Step 6.0: Pre-flight npm health (ABS path)"
  if ([string]::IsNullOrWhiteSpace($script:NPM_CMD) -or -not (Test-Path -LiteralPath $script:NPM_CMD)) {
    Write-ERR ("npm.cmd not resolvable (NPM_CMD = {0}). Install Node.js LTS (20/22) + npm, or rerun with -SkipCheck -SkipBuild." -f $script:NPM_CMD)
    Safe-Pause; exit 50
  }
  Write-Host ("  npm.cmd (ABS): {0}" -f $script:NPM_CMD)
  $npmvExit = Run-WithTimeout -FileName $script:NPM_CMD -Arguments "--version" -DisplayName "npm --version (pre-flight)"
  if ($npmvExit -ne 0) {
    Write-ERR ("npm health check FAILED (exit={0}). Node 24.15.0 often causes MODULE_NOT_FOUND in project dirs." -f $npmvExit)
    Write-Host "  Manual fixes (choose ANY ONE, then re-run):"
    Write-Host "    1) [QUICKEST] Re-run with -SkipCheck -SkipBuild -> skip local npm. MD files still pushed, Vercel will build on server."
    Write-Host "    2) [RECOMMENDED] Uninstall Node 24.15.0, install Node.js LTS 20.x or 22.x (from nodejs.org) -> npm 10.x instead of 11."
    Write-Host "    3) [TRY] Delete project node_modules, then run: cd ROOT ; npm install --omit=optional"
    Safe-Pause; exit 51
  }
  Write-OK ("npm OK (version subprocess exit=0)")

  # auto-install node_modules if absent
  if (-not (Test-Path -LiteralPath (Join-Path $ROOT "node_modules"))) {
    Write-Host "  node_modules absent -> npm install --omit=optional (first run only)"
    $instExit = Run-WithTimeout -FileName $script:NPM_CMD -Arguments "install --omit=optional" -DisplayName "npm install" -TimeoutSeconds 900
    if ($instExit -ne 0) {
      Write-ERR ("npm install FAILED (exit={0})." -f $instExit)
      Write-Host "  Quick bypass: rerun with -SkipCheck -SkipBuild. Vercel builds server-side."
      Safe-Pause; exit 52
    }
  }

  if (-not $SkipCheck) {
    Write-Host "  -> npm run check (tsc + prettier --check)"
    $checkExit = Run-WithTimeout -FileName $script:NPM_CMD -Arguments "run check" -DisplayName "npm run check"
    if ($checkExit -eq [int]::MaxValue) { Write-ERR "npm run check TIMED OUT (tsc hang? increase NPM_TIMEOUT_SECONDS)"; Safe-Pause; exit 60 }
    if ($checkExit -ne 0 -and -not $SkipFormat) {
      Write-WARN ("check failed (exit={0}) -> auto npm run format, then RE-RUN check to verify fix" -f $checkExit)
      $fmtExit = Run-WithTimeout -FileName $script:NPM_CMD -Arguments "run format" -DisplayName "npm run format"
      if ($fmtExit -eq [int]::MaxValue) { Write-ERR "npm run format TIMED OUT"; Safe-Pause; exit 61 }
      if ($fmtExit -ne 0) {
        Write-ERR ("format command itself FAILED (exit={0}). TSC/config errors CANNOT be fixed by prettier. Fix manually first." -f $fmtExit)
        Safe-Pause; exit 6
      }
      Write-Host "  -> re-run npm run check (post-format, CONFIRM pass or STOP)"
      $checkExit2 = Run-WithTimeout -FileName $script:NPM_CMD -Arguments "run check" -DisplayName "npm run check (post-format)"
      if ($checkExit2 -eq [int]::MaxValue) { Write-ERR "npm run check (post-format) TIMED OUT"; Safe-Pause; exit 62 }
      if ($checkExit2 -ne 0) {
        Write-ERR ("npm run check STILL FAILING after format (exit={0}). This is a TSC/types error NOT prettier." -f $checkExit2)
        Write-Host "  -> scroll up, fix the TS error (example generatedFontFiles / prettyRefs / renderLegacy / CNAME args remove), then re-run."
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
          # Guard: if push exit=0, treat as success. Secondary verification failures DO NOT kill the script.
          if ($LASTEXITCODE -eq 0) {
            Write-OK "format commit: git push exit=0 -> OK (formatted files re-committed AND pushed)"
          } else {
            Write-ERR "format commit: push FAILED"; Safe-Pause; exit 66
          }
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
    $buildExit = Run-WithTimeout -FileName $script:NPM_CMD -Arguments "run build" -DisplayName "npm run build"
    if ($buildExit -eq [int]::MaxValue) { Write-ERR "npm run build TIMED OUT"; Safe-Pause; exit 80 }
    if ($buildExit -ne 0) {
      Write-ERR ("npm run build FAILED (exit={0}). Scroll up for the error." -f $buildExit)
      Write-Host "  Quick bypass: rerun with -SkipBuild. Vercel builds server-side after git push."
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
if ($noGitChanges) {
  Write-WARN "Note: This run had 0 git changes (Vault md == content/ md). The above commit is the PREVIOUS commit already on GitHub."
  Write-Host "  Quick tip to trigger re-deploy with 0 md changes: touch & save any md file (add a blank line at end) -> re-run bat."
}
Write-OK "ALL DONE."
Safe-Pause
exit 0
