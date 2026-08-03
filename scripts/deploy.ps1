#Requires -Version 5.1
<#
.SYNOPSIS
  Physics Knowledge Base Site - One-Click Deploy Script
.DESCRIPTION
  Flow: Env Check -> VPN/GitHub Connectivity Test (with retries) -> Git pull/commit/push -> Local Build
        -> 3-layer success feedback (colored terminal + Windows Toast + System Beep)
.PARAMETER CommitMessage
  Custom git commit message. Defaults to auto-generated timestamp message.
.PARAMETER SkipBuild
  Skip local npm run build validation (to save time when you only want to push git commit).
.PARAMETER SkipCheck
  Skip tsc type check + Prettier format check (still runs build).
.PARAMETER SkipPush
  Only local commit, no push to remote (for offline authoring).
.PARAMETER NoToast
  Disable Windows Toast desktop notification (for headless / pure terminal usage).
.PARAMETER Force
  Continue full pipeline even when no git changes detected (useful for build-only validation).
.EXAMPLE
  .\deploy.ps1
    Default mode: auto commit message + full pipeline (network -> git -> build -> feedback)
.EXAMPLE
  .\deploy.ps1 -CommitMessage "feat: add conveyor-belt 3 variants to Newton laws section"
    Custom commit message (recommended to keep good git history)
.EXAMPLE
  .\deploy.ps1 -SkipBuild
    Time-saver mode: only git commit & push, skip local build (GitHub Actions will rebuild on cloud).
.NOTES
  Companion launcher: run "一键部署.bat" directly (double-click) to bypass ExecutionPolicy.
  Compatible: Windows 10 1809+ / Windows 11 + PowerShell 5.1 or PowerShell 7+.
#>

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

# ============================================================
# 0. Global Config (change these values to match YOUR repo/site)
# ============================================================
$Config = @{
  GitHubRepo         = "origin"
  LiveWebsiteUrl     = ""
  OpenActionsOnPush  = $true
  NetworkRetries     = 3
  NetworkRetryDelay  = 3
  BuildOutputDir     = "public"
  MinNodeVersion     = [version]"22.0.0"
  MinNpmVersion      = [version]"10.9.2"
}

# --- Color output helpers ---
function Write-Color  ($Text, $Color = "White") { Write-Host $Text -ForegroundColor $Color -NoNewline }
function Write-Line   ($Text, $Color = "White") { Write-Host $Text -ForegroundColor $Color }
function Write-OK     ($Text = "OK") { Write-Color "  [OK] " "Green"; Write-Line $Text "White" }
function Write-Warn   ($Text)        { Write-Color "  [WARN] " "Yellow"; Write-Line $Text "Yellow" }
function Write-Err    ($Text)        { Write-Color "  [ERR] " "Red"; Write-Line $Text "Red" }
function Write-Step   ($Text)        { Write-Host ""; Write-Color ">> " "Cyan"; Write-Line $Text "Cyan"; Write-Line ("-" * 70) "Gray" }
function Write-Banner ($Text) {
  $width = 72
  Write-Line ""
  Write-Line ("+" + ("-" * ($width-2)) + "+") "DarkCyan"
  Write-Line ("| " + ("$Text".PadRight($width-3)) + "|") "Cyan"
  Write-Line ("+" + ("-" * ($width-2)) + "+") "DarkCyan"
  Write-Line ""
}

# ============================================================
# 1. Environment Check
# ============================================================
function Test-Environment {
  Write-Step "Step 1/5 : Environment & Dependency Check"

  # 1.1 Auto-locate project root (handles case when launched from subfolder)
  $script:RootDir = $PSScriptRoot
  if (-not (Test-Path (Join-Path $script:RootDir "package.json")) -or
      -not (Test-Path (Join-Path $script:RootDir ".git"))) {
    $candidate = Split-Path $script:RootDir -Parent
    while ($candidate) {
      if ((Test-Path (Join-Path $candidate "package.json")) -and (Test-Path (Join-Path $candidate ".git"))) {
        $script:RootDir = $candidate
        break
      }
      $candidate = Split-Path $candidate -Parent
    }
    if (-not $candidate) {
      Write-Err "Project root not found (missing package.json or .git folder). Place this script under knowledge-site\scripts\"
      return $false
    }
  }
  Set-Location $script:RootDir
  Write-OK "Project root: $RootDir"

  # --- Helper: prepend a folder to current-session PATH if folder exists (TEMPORARY, does not touch user/system PATH) ---
  function Add-ToPathIfExists {
    param([string]$Folder)
    if ($Folder -and (Test-Path -LiteralPath $Folder)) {
      $env:PATH = "$Folder;$env:PATH"
      return $true
    }
    return $false
  }

  # 1.2 Git - PATH search + registry read + custom drive scan so even users who install to weird drives (E:/D:...) work on first run.
  #           We build a candidate list IN ORDER:
  #             a) explicit uninstaller registry GitForWindows InstallPath (most accurate)
  #             b) DisplayName=Git Uninstall InstallLocation (winget / outdated installers)
  #             c) all fixed drives root-level Git folder (common user pattern: E:\Git)
  #             d) Program Files / LOCALAPPDATA per-user defaults + package manager (scoop/choco) shims
  $gitCandidates = New-Object System.Collections.Generic.List[string]
  # (a) registry GitForWindows
  $regKeys = @("HKLM:\SOFTWARE\GitForWindows","HKCU:\SOFTWARE\GitForWindows","HKLM:\SOFTWARE\WOW6432Node\GitForWindows","HKCU:\SOFTWARE\WOW6432Node\GitForWindows")
  foreach ($rk in $regKeys) {
    if (Test-Path $rk) {
      try {
        $ip = (Get-ItemProperty $rk -ErrorAction Stop).InstallPath
        if ($ip) {
          $gitCandidates.Add((Join-Path $ip "cmd"))
          $gitCandidates.Add((Join-Path $ip "bin"))
        }
      } catch {}
    }
  }
  # (b) Uninstall entries where DisplayName contains Git
  $uninsPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  foreach ($up in $uninsPaths) {
    try {
      Get-ItemProperty $up -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "\bGit\b" -and $_.InstallLocation } | ForEach-Object {
        $gitCandidates.Add((Join-Path $_.InstallLocation "cmd"))
        $gitCandidates.Add((Join-Path $_.InstallLocation "bin"))
      }
    } catch {}
  }
  # (c) custom drive scan - every fixed drive, try <Drive>:\Git\cmd and <Drive>:\Git\bin
  try {
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Fixed" -and $_.IsReady }
    foreach ($d in $drives) {
      $root = $d.Name.TrimEnd('\')
      if ($root) {
        $gitCandidates.Add("$root\Git\cmd")
        $gitCandidates.Add("$root\Git\bin")
      }
    }
  } catch {}
  # (d) default Program Files + package manager shims
  $defaults = @(
    (Join-Path $env:ProgramFiles "Git\cmd"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\cmd"),
    (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd"),
    (Join-Path $env:LOCALAPPDATA "Programs\Git\bin"),
    (Join-Path $env:ProgramFiles "Git\bin"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin"),
    (Join-Path $env:USERPROFILE "scoop\shims"),
    "C:\ProgramData\chocolatey\bin"
  )
  foreach ($d in $defaults) { $gitCandidates.Add($d) }

  # dedupe preserving order, then try to prepend to PATH for current session
  $seen = @{}
  $script:GitProbed = New-Object System.Collections.Generic.List[string]
  foreach ($c in $gitCandidates) {
    if (-not $c -or $seen.ContainsKey($c)) { continue }
    $seen[$c] = $true
    [void]$script:GitProbed.Add($c)
    [void](Add-ToPathIfExists $c)
  }
  # bonus: if where.exe git finds it, do nothing (already in PATH); otherwise remember for debug output
  try { $whereGit = cmd.exe /c "where git 2>nul" } catch { $whereGit = $null }
  $script:GitFoundByWhere = if ($whereGit) { ($whereGit -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) } else { $null }
  try {
    $gitVer = (git --version) -replace "[^0-9.]", ""
    if ([version]$gitVer -ge [version]"2.20") { Write-OK "Git version $gitVer" } else { Write-Warn "Git old version: $gitVer (recommend >= 2.20)" }
  } catch {
    Write-Err "Git not found on PATH and no Git install detected in default/registry/custom-drive locations."
    Write-Warn "TIP: You said Git was installed - scroll up. We probed these locations:"
    # Print the probed list grouped by EXIST / MISSING so user can see exactly where we found/not found.
    $exists = New-Object System.Collections.Generic.List[string]
    $miss   = New-Object System.Collections.Generic.List[string]
    foreach ($c in $script:GitProbed) {
      if (Test-Path -LiteralPath $c) { $exists.Add($c) } else { $miss.Add($c) }
    }
    if ($exists.Count -gt 0) {
      Write-Warn "  **************** FOUND Git folders (but maybe no git.exe in them?):"
      $exists | Select-Object -First 10 | ForEach-Object { Write-Warn ("   EXISTS -> " + $_) }
      # If we found Git in some folder we can just hint the user
    } else {
      Write-Warn "  (no Git folder found at all common locations)"
    }
    if ($script:GitFoundByWhere) { Write-Warn ("   where.exe reports git at -> " + $script:GitFoundByWhere) }
    Write-Warn "  Quick fix (permanent - do this ONCE in an Admin PowerShell):"
    Write-Warn "    [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','Machine') + ';E:\Git\cmd', 'Machine')"
    Write-Warn "    (replace E:\Git\cmd with wherever your Git\cmd folder is - we just found E:\Git on your system)"
    Write-Warn "  After setting PATH permanently: CLOSE + RE-OPEN this launcher."
    Write-Warn "  Install link (if you really need to reinstall): https://git-scm.com/download/win"
    return $false
  }

  # 1.3 Node / npm - PATH search + registry read + custom drive scan (same thorough algorithm as Git)
  $nodeCandidates = New-Object System.Collections.Generic.List[string]
  # (a) registry Node.js install locations (x64 / x86 / per-user)
  $nodeReg = @(
    "HKLM:\SOFTWARE\Node.js",
    "HKCU:\SOFTWARE\Node.js",
    "HKLM:\SOFTWARE\WOW6432Node\Node.js",
    "HKCU:\SOFTWARE\WOW6432Node\Node.js"
  )
  foreach ($rk in $nodeReg) {
    if (Test-Path $rk) {
      try {
        $prop = Get-ItemProperty $rk -ErrorAction Stop
        if ($prop.InstallPath) { $nodeCandidates.Add($prop.InstallPath) }
        if ($prop.'InstallPath') { $nodeCandidates.Add($prop.'InstallPath') }
      } catch {}
    }
  }
  # (b) Uninstall entries where DisplayName contains Node.js
  foreach ($up in $uninsPaths) {
    try {
      Get-ItemProperty $up -ErrorAction SilentlyContinue |
        Where-Object { ($_.DisplayName -match "Node\.js" -or $_.DisplayName -like "*node*") -and $_.InstallLocation } |
        ForEach-Object { $nodeCandidates.Add($_.InstallLocation) }
    } catch {}
  }
  # (c) every fixed drive root-level nodejs
  try {
    foreach ($d in $drives) {
      $root = $d.Name.TrimEnd('\')
      if ($root) {
        $nodeCandidates.Add("$root\nodejs")
        $nodeCandidates.Add("$root\node")
      }
    }
  } catch {}
  # (d) default Program Files + %APPDATA% npm + package manager shims
  $nodeDefaults = @(
    (Join-Path $env:ProgramFiles "nodejs"),
    (Join-Path ${env:ProgramFiles(x86)} "nodejs"),
    (Join-Path $env:LOCALAPPDATA "Programs\nodejs"),
    (Join-Path $env:APPDATA "npm"),
    (Join-Path $env:USERPROFILE "scoop\shims"),
    "C:\ProgramData\chocolatey\bin"
  )
  foreach ($d in $nodeDefaults) { $nodeCandidates.Add($d) }
  $seenNode = @{}
  foreach ($c in $nodeCandidates) {
    if (-not $c -or $seenNode.ContainsKey($c)) { continue }
    $seenNode[$c] = $true
    [void](Add-ToPathIfExists $c)
  }
  try {
    $nodeVer = [version]((node --version) -replace "^v", "")
    $npmVer  = [version]((npm --version))
    if ($nodeVer -lt $Config.MinNodeVersion) {
      Write-Err "Node too old: current v$nodeVer, need >= v$($Config.MinNodeVersion). Update from https://nodejs.org/"
      return $false
    }
    if ($npmVer -lt $Config.MinNpmVersion) {
      Write-Warn "npm slightly old: current v$npmVer, recommended >= v$($Config.MinNpmVersion) (run: npm i -g npm)"
    }
    Write-OK "Node v$nodeVer + npm v$npmVer"
  } catch {
    Write-Err "Node.js not detected. Install LTS (>= 22.x) from https://nodejs.org/ (after install, close + re-open launcher)."
    return $false
  }

  # 1.4 Remote configured?
  if (-not $SkipPush) {
    $remote = git remote get-url $Config.GitHubRepo 2>$null
    if (-not $remote) {
      Write-Err "Git remote '$($Config.GitHubRepo)' not configured. Run:  git remote add origin [your-GitHub-repo-URL]"
      return $false
    }
    Write-OK "Remote: $remote"
    $script:RemoteUrl = $remote
  } else {
    Write-Warn "-SkipPush enabled; remote not checked"
  }
  return $true
}

# ============================================================
# 2. VPN / GitHub Connectivity Test (3 retries + diagnostics)
# ============================================================
function Test-GitHubConnection {
  param([int]$Retries = $Config.NetworkRetries, [int]$DelaySec = $Config.NetworkRetryDelay)

  Write-Step "Step 2/5 : VPN / GitHub Connectivity Test ($Retries retries)"

  if ($SkipPush) { Write-Warn "-SkipPush enabled; skipping network test"; return $true }

  $attempt = 0
  while ($attempt -lt $Retries) {
    $attempt++
    Write-Color "  Trial $attempt/$Retries : probing github.com:443 ... " "Gray"

    # 2.1 TCP-layer 443 reachability (2s timeout)
    try {
      $tcp = Test-NetConnection -ComputerName "github.com" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
    } catch { $tcp = $false }

    if (-not $tcp) {
      Write-Line "TCP FAIL" "Red"
      if ($attempt -lt $Retries) { Start-Sleep $DelaySec; continue }
      break
    }

    # 2.2 App-layer: git ls-remote actually works (validates auth/proxy/SSH key)
    Write-Color "TCP OK  | verifying Git auth ... " "Gray"
    $gitOk = $true
    $null = git ls-remote --exit-code --heads $Config.GitHubRepo 2>&1
    if ($LASTEXITCODE -ne 0) { $gitOk = $false }

    if ($gitOk) {
      Write-Line "Git auth PASS" "Green"
      Write-OK "GitHub connection stable (succeeded on attempt $attempt)"
      return $true
    }

    Write-Line "Git auth FAIL (exit=$LASTEXITCODE)" "Red"
    if ($attempt -lt $Retries) { Start-Sleep $DelaySec; continue }
    break
  }

  # --- All $Retries failed: diagnostics checklist ---
  Write-Err "Failed $Retries consecutive GitHub connection attempts. Follow checklist below:"
  Write-Line ""
  Write-Line "  TROUBLESHOOT CHECKLIST (most likely first):" "Yellow"
  Write-Line "  1) VPN/proxy ON? Mainland China direct GitHub is often unstable -> turn on your VPN/Clash/V2Ray" "White"
  Write-Line "  2) Git proxy config? Run:  git config --global --get http.proxy" "White"
  Write-Line "      Empty = no proxy configured (if you run Clash on 7890 set: git config --global http.proxy http://127.0.0.1:7890)" "Gray"
  Write-Line "  3) SSH key added to GitHub? Run  ssh -T git@github.com   expected: Hi [your-ID]!" "White"
  Write-Line "  4) Switch SSH -> HTTPS: change remote from git@github.com:xxx/yyy.git to https://github.com/xxx/yyy.git" "White"
  Write-Line "  5) Mirror workaround: use ghproxy.com / mirror.ghproxy.com for acceleration (temporary)" "White"
  Write-Line ""
  Write-Warn "Want to skip network check? Add -SkipPush flag to commit locally; push later when network ready."
  return $false
}

# ============================================================
# 3. Git Sync (pull rebase -> add -> commit -> push)
# ============================================================
function Invoke-GitSync {
  Write-Step "Step 3/5 : Git Local Commit + Remote Sync"

  # 3.1 Any local changes?
  $status = git status --porcelain
  if (-not $status -and -not $Force) {
    Write-Warn "No file changes detected!"
    $ans = Read-Host "  Continue anyway for build validation? (Y/n)  default=Y"
    if ($ans -match "^[nN]") { Write-Line "  Aborted."; return $false }
    $script:NoChanges = $true
  } else {
    $script:NoChanges = $false
    $addCount    = (@($status -match "^A|^\?\?")).Count
    $modifyCount = (@($status -match "^M")).Count
    $delCount    = (@($status -match "^D")).Count
    Write-Color "  Pending stats: " "Gray"
    if ($addCount)    { Write-Color " NEW+$addCount " "Green" }
    if ($modifyCount) { Write-Color " MOD~$modifyCount " "Yellow" }
    if ($delCount)    { Write-Color " DEL-$delCount " "Red" }
    Write-Line " file(s)" "Gray"
  }

  # 3.2 pull --rebase first (avoid conflict on push)
  if (-not $SkipPush -and -not $script:NoChanges) {
    Write-Color "  Pulling remote latest (git pull --rebase) ... " "Gray"
    git pull --rebase $Config.GitHubRepo ((git rev-parse --abbrev-ref HEAD)) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Line "CONFLICT !" "Red"
      Write-Warn "Merge conflicts occurred! Manually resolve (look for <<<<<<< in VSCode), then run:"
      Write-Line "      git add [conflict-files] ; git rebase --continue" "Cyan"
      Read-Host "  After resolved, press ENTER to resume script..." | Out-Null
    } else {
      Write-Line "OK" "Green"
    }
  }

  if ($script:NoChanges) { return $true }

  # 3.3 git add -A
  git add -A
  if ($LASTEXITCODE -ne 0) { Write-Err "git add failed"; return $false }

  # 3.4 commit message
  if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $CommitMessage = "Update content - $stamp"
  }
  git commit -m $CommitMessage 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Err "git commit failed (maybe no changes?)"; return $false }
  $shortHash = (git rev-parse --short HEAD)
  Write-OK "Committed: $shortHash | $CommitMessage"

  # 3.5 Push
  if (-not $SkipPush) {
    Write-Color "  Pushing to remote ... " "Gray"
    $pushOut = git push 2>&1
    $pushExit = $LASTEXITCODE
    if ($pushExit -ne 0) {
      Write-Line "FAIL" "Red"
      Write-Err "Push error details:"
      Write-Line ($pushOut -join "`n") "DarkGray"
      $script:PushVerified = $false
      $script:PushNote     = "git push exit=$pushExit : $($pushOut | Select-Object -Last 3)"
      return $false
    }
    Write-Line "OK" "Green"

    # ============================================================
    # 3.5b 二次验证：fetch 后看 ahead 是否=0（唯一可信的"推送真的到远端了"信号）
    # ============================================================
    Write-Color "  Post-push verification (ahead count) ... " "Gray"
    git fetch --quiet $Config.GitHubRepo 2>$null | Out-Null
    $upstream = "@{u}"   # short for HEAD@{upstream}
    try {
      $aheadBehind = (git rev-list --left-right --count HEAD...$upstream 2>$null) -split "\s+"
      if ($aheadBehind.Count -eq 2) {
        [int]$ahead  = $aheadBehind[0]
        [int]$behind = $aheadBehind[1]
        if ($ahead -eq 0) {
          Write-Line "VERIFIED PASS (ahead=0, behind=$behind)" "Green"
          Write-OK "Push success AND verified by remote tracking branch!"
          $script:PushVerified = $true
          $script:PushNote     = "ahead=$ahead, behind=$behind"
        } else {
          Write-Line "VERIFY FAIL: ahead=$ahead" "Red"
          Write-Warn "git push returned OK but HEAD is still $ahead commit(s) ahead of remote!"
          Write-Warn "Possible causes: 1) push was dry-run / --porcelain  2) remote branch diverged  3) network reset halfway"
          Write-Warn "Fix: run  git status  then  git push -f (if sure) or  git pull --rebase then re-run script"
          $script:PushVerified = $false
          $script:PushNote     = "push ok but ahead=$ahead ! manual check needed"
        }
      } else {
        # no upstream branch configured (first push)
        Write-Line "no upstream tracked yet (first push?)" "Yellow"
        $script:PushVerified = $true
        $script:PushNote     = "first push; skipped ahead/behind verification"
      }
    } catch {
      Write-Line "verify skipped" "Yellow"
      $script:PushVerified = $null
      $script:PushNote     = "verify exception: $($_.Exception.Message)"
    }
  } else {
    Write-Warn "-SkipPush enabled: only local commit done, not pushed."
    $script:PushVerified = $null
    $script:PushNote     = "skipped (-SkipPush)"
  }
  return $true
}

# ============================================================
# 4. Local Build Validation (tsc + prettier + build)
# ============================================================
function Invoke-Build {
  Write-Step "Step 4/5 : Local Build Validation (format -> typecheck -> build)"

  if ($SkipBuild) { Write-Warn "-SkipBuild enabled; skipping build"; return $true }

  # 4.1 Dependencies installed?
  if (-not (Test-Path (Join-Path $RootDir "node_modules"))) {
    Write-Warn "node_modules missing; running npm install first (1~3 min first time)..."
    npm install --omit=optional
    if ($LASTEXITCODE -ne 0) { Write-Err "npm install failed"; return $false }
    Write-OK "Dependencies installed"
  }

  # 4.2 Format + TypeScript check (--check = no-write, just verify)
  if (-not $SkipCheck) {
    Write-Color "  npm run check (Prettier + TSC) ... " "Gray"
    $checkOut = npm run check 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Line "FAILED" "Red"
      Write-Warn "If Prettier issue: run  npm run format  auto-fix 80% formatting errors"
      Write-Line (($checkOut | Select-Object -Last 20) -join "`n") "DarkGray"
      $ans = Read-Host "  Check failed, still build? (y/N)  default=N"
      if ($ans -notmatch "^[yY]") { return $false }
    } else {
      Write-Line "PASS" "Green"
    }
  }

  # 4.3 Actual Quartz build
  Write-Color "  npm run build (Quartz building, first run ~1-2min) ... " "Gray"
  $buildOut = npm run build 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Line "BUILD FAILED" "Red"
    Write-Err "Build error (last 40 lines):"
    Write-Line (($buildOut | Select-Object -Last 40) -join "`n") "DarkRed"
    return $false
  }
  Write-Line "BUILD OK" "Green"

  # 4.4 Output stats
  $buildDir = Join-Path $RootDir $Config.BuildOutputDir
  if (Test-Path $buildDir) {
    $files  = (Get-ChildItem $buildDir -Recurse -File | Measure-Object).Count
    $sizeMB = [math]::Round(((Get-ChildItem $buildDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 2)
    Write-OK "Artifacts: $files files | Total ${sizeMB} MB -> $buildDir"
    $script:BuildStats = "$files files / ${sizeMB} MB"
  }
  return $true
}

# ============================================================
# 5. Triple Success Feedback (terminal summary + toast + beep)
# ============================================================
function Invoke-SuccessFeedback {
  param([bool]$BuildOk, [bool]$PushOk)

  Write-Step "Step 5/5 : Summary & Success Feedback"

  # 5.1 Color terminal summary
  Write-Banner "     DEPLOY PIPELINE FINISHED     "
  $lines = @()
  $lines += if ($PushOk -and -not $SkipPush) { "[Git Push]     PASS success" } elseif ($SkipPush) { "[Git Commit]   PASS local only (not pushed)" } else { "[Git Push]     FAILED" }
  $lines += if ($BuildOk  -and -not $SkipBuild) { "[Local Build]  PASS success ($script:BuildStats)" } elseif ($SkipBuild) { "[Local Build]  SKIPPED" } else { "[Local Build]  FAILED (see above)" }
  $lines | ForEach-Object { Write-Line ("     " + $_) "Cyan" }
  Write-Line ""
  Write-Line "  Completed at : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Gray"

  if (-not $SkipPush -and $PushOk -and $script:RemoteUrl -match "github\.com[:/](?<org>[^/]+)/(?<repo>[^/\.]+)") {
    $org  = $Matches.org; $repo = $Matches.repo -replace "\.git$", ""
    $actionsUrl = "https://github.com/$org/$repo/actions"
    Write-Line "  GitHub Actions deploy progress : $actionsUrl" "Green"
    Write-Line "      (Pages/Cloudflare deploys usually go live in 1~3 minutes)" "Gray"
    if ($Config.OpenActionsOnPush) { try { Start-Process $actionsUrl } catch {} }
  }
  if (-not [string]::IsNullOrWhiteSpace($Config.LiveWebsiteUrl) -and $BuildOk) {
    Write-Line "  Live website                   : $($Config.LiveWebsiteUrl)" "Green"
    try { Start-Process $Config.LiveWebsiteUrl } catch {}
  }

  # 5.2 System beep (Win32 API, zero dependencies)
  try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinSound {
  [DllImport("user32.dll")] public static extern bool MessageBeep(uint uType);
}
"@ -ErrorAction SilentlyContinue | Out-Null
    [WinSound]::MessageBeep(0) | Out-Null
  } catch { <# ignore #> }

  # 5.3 Windows Toast (BurntToast module; silent skip if absent)
  if (-not $NoToast) {
    $toastModule = Get-Module -ListAvailable BurntToast
    if ($toastModule) {
      $title  = "Physics KB Deploy Complete"
      $parts  = @()
      $parts += if ($PushOk -and -not $SkipPush) { "PASS: GitHub push succeeded" } else { "INFO: Local commit only" }
      $parts += if ($BuildOk  -and -not $SkipBuild) { "PASS: Local build OK ($script:BuildStats)" } elseif (-not $SkipBuild) { "FAIL: Build failed (details in terminal)" } else { "SKIP: Build skipped" }
      try {
        $logoPath = Join-Path $PSScriptRoot "logo.png" -ErrorAction SilentlyContinue
        if (Test-Path $logoPath) {
          New-BurntToastNotification -AppLogo $logoPath -Text $title, ($parts -join "`n") -Sound "Default" -ErrorAction SilentlyContinue | Out-Null
        } else {
          New-BurntToastNotification -Text $title, ($parts -join "`n") -Sound "Default" -ErrorAction SilentlyContinue | Out-Null
        }
      } catch { <# silent ignore #> }
    } else {
      Write-Verbose "BurntToast not installed. For toast notifications run: Install-Module BurntToast -Scope CurrentUser"
    }
  }

  Write-Line ""
  Write-Line ("-" * 70) "Gray"
  Write-Line "  Tip: Next time just double-click  一键部署.bat  for zero-typing launch." "DarkCyan"
  Write-Line ""
}

# ============================================================
# Main entry point
# ============================================================
function Write-DeployLog {
  param([string]$Level, [string]$Message)
  try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE "Desktop" }
    $logPath = Join-Path $desktop "部署结果日志.log"
    $time    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line    = "[$time] [$Level] $Message"
    Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    $script:LastLogFile = $logPath
  } catch { <# silent ignore logging failures #> }
}

# ---- Init result globals (so every exit path writes consistent results) ----
$script:PushVerified = $null
$script:PushNote     = "not run"
$script:BuildStats   = "not available"
$script:LastLogFile  = $null
$script:ExitCode     = 999

# ---- Plain PS5 try/catch/finally (lexically consecutive) so finally ALWAYS binds correctly ----
#      We NEVER write: do { try { } catch { } } while ($false) <newline> finally { }
#      because the while-closing }} while($false) terminates the try/catch scope, causing PS5 to see
#      "finally" as a standalone statement -> "finally not recognized as cmdlet" trap re-entry bug.
$ErrorActionPreference = "Stop"

try {
  $allArgs = @($RemainingArgs) + @($Args)
  if ($allArgs -contains "--help" -or $allArgs -contains "-h" -or $allArgs -contains "-help" -or $allArgs -contains "?") {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    $script:ExitCode = 0
    return
  }

  Write-Banner "  Physics Knowledge Base - One-Click Deploy v1.0  "

  # ---- Step 1/5: Environment check - no throw; show install guide + return so pause still runs ----
  $envOK = Test-Environment
  if (-not $envOK) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Red
    Write-Host "  Environment check FAILED - install missing tools then re-run:" -ForegroundColor Red
    Write-Host ("=" * 70) -ForegroundColor Red
    Write-Host "   [1] Git for Windows (required for git commit/push):" -ForegroundColor Yellow
    Write-Host "       Download -> https://git-scm.com/download/win  (use default install options)" -ForegroundColor Cyan
    Write-Host "       IMPORTANT: After install, CLOSE this window and open a NEW one so PATH refreshes." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   [2] Node.js v22+ (required for npm run build/check):" -ForegroundColor Yellow
    Write-Host "       Download -> https://nodejs.org/  (choose LTS x64 Windows Installer)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   Verify after install (NEW terminal):" -ForegroundColor Yellow
    Write-Host "       git --version    (expect: git version 2.x)" -ForegroundColor Cyan
    Write-Host "       node -v          (expect: v22.x or newer)" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Red
    try { Write-DeployLog -Level "FATAL" -Message "Environment check did not pass (Git/Node missing - see install links in terminal)" } catch {}
    $script:ExitCode = 10
    # Environment fail EXTRA pause: guarantee pause even if finally block somehow fails.
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host "  [ENV FAIL] Window will NOW wait for you to press a key." -ForegroundColor Yellow
    Write-Host "  (You will see '请按任意键继续...' / 'Press any key to continue...' shortly)" -ForegroundColor DarkGray
    Write-Host ("=" * 60) -ForegroundColor Yellow
    try {
      $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
      & $comSpec /c pause
    } catch {
      try { [void][System.Console]::ReadKey($true) } catch { try { $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null } catch { Start-Sleep -Seconds 86400 } }
    }
    return
  }

  # ---- Step 2/5: Network / VPN check ----
  $netOK = Test-GitHubConnection
  if (-not $netOK -and -not $SkipPush) {
    $ans = Read-Host "  Network test failed. Switch to -SkipPush local commit only? (Y/n) default=Y"
    if ($ans -notmatch "^[nN]") { $SkipPush = $true } else {
      try { Write-DeployLog -Level "FATAL" -Message "User aborted due to network test failure (GitHub not reachable, VPN off?)" } catch {}
      $script:ExitCode = 11
      return
    }
  }

  # ---- Step 3/5: Git sync ----
  $gitOK = Invoke-GitSync
  if (-not $gitOK) {
    try { Write-DeployLog -Level "ERROR" -Message "Git sync failed | push_verified=$PushVerified | note=$PushNote" } catch {}
    Write-Err "Git sync step failed (scroll up - usually VPN / auth / merge conflict)"
    $script:ExitCode = 12
    return
  }

  # ---- Step 4/5: Build (failure intentional non-throw so FAIL feedback still runs) ----
  $buildOK = Invoke-Build

  # ---- Log aggregated final result to Desktop log ----
  $pushWord = if ($SkipPush) { "SKIPPED" } elseif ($PushVerified -eq $true) { "VERIFIED_PASS" } elseif ($PushVerified -eq $false) { "VERIFIED_FAIL" } else { "UNKNOWN" }
  $buildWord = if ($SkipBuild) { "SKIPPED" } elseif ($buildOK) { "PASS" } else { "FAIL" }
  $hash      = try { git rev-parse --short HEAD 2>$null } catch { "no-commit" }
  try { Write-DeployLog -Level "INFO" -Message "Run done | commit=$hash | push=$pushWord ($PushNote) | build=$buildWord ($BuildStats)" } catch {}

  # ---- Final push banner (instant visual before pause) ----
  Write-Host ""
  if (-not $SkipPush) {
    if ($PushVerified -eq $true) {
      Write-Host ("=" * 70) -ForegroundColor Green
      Write-Host "   >>>  GITHUB PUSH:  SUCCESS  <<<   Verified ahead=0" -ForegroundColor Green
      Write-Host ("=" * 70) -ForegroundColor Green
    } elseif ($PushVerified -eq $false) {
      Write-Host ("=" * 70) -ForegroundColor Red
      Write-Host "   !!!  GITHUB PUSH:  FAILED / NOT VERIFIED  !!!" -ForegroundColor Red
      Write-Host "   Details: $PushNote" -ForegroundColor Yellow
      Write-Host ("=" * 70) -ForegroundColor Red
    } else {
      Write-Host ("=" * 70) -ForegroundColor Yellow
      Write-Host "   ???  GITHUB PUSH:  UNKNOWN (could not verify ahead count)  ???" -ForegroundColor Yellow
      Write-Host ("=" * 70) -ForegroundColor Yellow
    }
  }

  Invoke-SuccessFeedback -BuildOk $buildOK -PushOk $gitOK

  if ($LastLogFile) {
    Write-Line "  Desktop log written to:" "DarkCyan"
    Write-Line "     $LastLogFile" "Cyan"
  }

  if ($script:ExitCode -eq 999) { $script:ExitCode = 0 }
} catch {
  Write-Line ""
  Write-Line ("=" * 70) "Red"
  Write-Err "Script halted with exception: $($_.Exception.Message)"
  Write-Line ("  Location: " + $_.InvocationInfo.PositionMessage) "DarkGray"
  Write-Line ""
  Write-Warn "If flaky network -> just re-run script (idempotent; no duplicate commits)"
  Write-Warn "If deps issue   -> delete node_modules then re-run npm install"
  try {
    $hash = try { git rev-parse --short HEAD 2>$null } catch { "no-commit" }
    Write-DeployLog -Level "FATAL" -Message "Script catch | commit=$hash | error=$($_.Exception.Message) | push_note=$PushNote | build=$BuildStats"
  } catch {}
  if ($LastLogFile) {
    Write-Line "  Desktop log written to:" "DarkCyan"
    Write-Line "     $LastLogFile" "Cyan"
  }
  if ($script:ExitCode -eq 999) { $script:ExitCode = 1 }
} finally {
  # IMPORTANT: This finally block is LEXICALLY RIGHT AFTER the catch's closing brace,
  #            with zero other statements / braces between. PS5 parser will bind correctly.
  Write-Host ""
  Write-Host ("=" * 64) -ForegroundColor Cyan
  Write-Host "  Pause (deploy.ps1 finally) - Window kept open." -ForegroundColor Cyan
  Write-Host "  Window will NOW wait for keypress - you should see prompt below." -ForegroundColor DarkGray
  Write-Host ("=" * 64) -ForegroundColor Cyan
  Write-Host ""
  $pauseOk = $false
  # Order prioritizes interactive-read methods FIRST (no child process spawn = avoids rare ProcessStartInfo
  # hang / "seems like it is not pausing" illusion on some Windows hosts).
  # 1/5: RawUI.ReadKey (most PowerShell-native console read)
  try {
    Write-Host "  [Pause 1/5] Press ANY key to continue (RawUI) ..." -ForegroundColor DarkGray
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    $pauseOk = $true
  } catch {}
  # 2/5: .NET Console.ReadKey
  if (-not $pauseOk) {
    try {
      Write-Host "  [Pause 2/5] Press ANY key to continue (Console.ReadKey) ..." -ForegroundColor DarkGray
      [void][System.Console]::ReadKey($true)
      $pauseOk = $true
    } catch {}
  }
  # 3/5: cmd /c pause via &  (prints '请按任意键继续' Chinese prompt, familiar on Chinese Windows)
  if (-not $pauseOk) {
    try {
      $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
      & $comSpec /c pause
      $pauseOk = $true
    } catch {}
  }
  # 4/5: cmd pause via ProcessStartInfo (no redirections, true attach to current console)
  if (-not $pauseOk) {
    try {
      Write-Host "  [Pause 4/5] Starting cmd.exe /c pause ..." -ForegroundColor DarkGray
      $comSpec = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $comSpec; $psi.Arguments = "/c pause"
      $psi.UseShellExecute = $false
      $psi.RedirectStandardInput = $false; $psi.RedirectStandardOutput = $false; $psi.RedirectStandardError = $false
      $proc = [System.Diagnostics.Process]::Start($psi)
      if ($proc) { $proc.WaitForExit(); $pauseOk = $true }
    } catch {}
  }
  # 5/5: Failsafe 24h sleep so window never auto-closes no matter what
  if (-not $pauseOk) {
    Write-Host "  [Pause 5/5 FALLBACK] No pause method worked - waiting 24h so window never auto-closes." -ForegroundColor Yellow
    Write-Host "                         You can just close the window when done reading." -ForegroundColor Yellow
    Start-Sleep -Seconds 86400
  }
}

# Real exit ONLY AFTER finally+pause fully completes
if (-not $script:ExitCode -or $script:ExitCode -eq 999) { $script:ExitCode = 1 }
exit [int]$script:ExitCode
