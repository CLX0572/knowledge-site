#Requires -Version 5.1
$ErrorActionPreference = "Stop"

[string]$ROOT  = "E:\TRAE SOLO CN\app\knowledge-site"
[string]$VAULT = "E:\Obisian\Notes"
[string]$ONLY_DIR = "轨向的物理笔记"

function Write-Step([string]$t)  { Write-Host ""; Write-Host (">>>>>>  " + $t + "  <<<<<") -ForegroundColor Cyan }
function Write-OK([string]$t)   { Write-Host ("[OK]   " + $t) -ForegroundColor Green }
function Write-ERR([string]$t)  { Write-Host ("[ERR]  " + $t) -ForegroundColor Red }
function Write-WARN([string]$t) { Write-Host ("[WARN] " + $t) -ForegroundColor Yellow }
function Done-Pause() {
  Write-Host ""
  Write-Host "-----  结束，按任意键关闭窗口  -----" -ForegroundColor Yellow
  try   { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {
    try { $null = [Console]::ReadKey($true) } catch { Start-Sleep 3600 } }
}

Write-Host ""
Write-Host "===  物理知识库 GitHub 推送（极简版）  ===" -ForegroundColor Magenta
Write-Host "Project: $ROOT"
Write-Host "同步目录: $VAULT\$ONLY_DIR  ->  content\$ONLY_DIR"
Write-Host "线上地址: https://knowledgesite.vercel.app"

# Step 1: 进入项目目录
Set-Location -LiteralPath $ROOT

# Step 2: 同步 md（最简：直接 robocopy，/PURGE 保证一致）
$srcDir = Join-Path $VAULT $ONLY_DIR
$dstDir = Join-Path $ROOT "content\$ONLY_DIR"
if (-not (Test-Path -LiteralPath $srcDir)) {
  Write-ERR ("找不到源目录: " + $srcDir); Done-Pause; exit 2
}
if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
Write-Step "Step 1/5 同步 md 文件 (robocopy /PURGE)"
$rargs = @($srcDir, $dstDir, "*.md", "/E", "/COPY:DAT", "/DCOPY:DAT", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/PURGE")
foreach ($e in @(".git", ".obsidian", ".trash", "_website", "_site")) { $rargs += @("/XD", $e) }
foreach ($ext in @("*.png","*.jpg","*.jpeg","*.gif","*.svg","*.webp","*.pdf")) { $rargs += $ext }
$null = & robocopy @rargs
Write-OK "同步完成"

# Step 3: git status
Write-Step "Step 2/5 查看 git 变更"
$stat = @(git status --porcelain)
Write-Host "  变更数: $($stat.Count)"
if ($stat.Count -eq 0) {
  Write-WARN "没有变更（md 文件与网站完全一致）"
  Done-Pause; exit 0
}

# Step 4: git add + commit + push
Write-Step "Step 3/5 git add + commit"
git add .
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
git commit -m "update content - $ts" 2>&1 | Out-Null

Write-Step "Step 4/5 git pull --rebase"
git pull --rebase 2>&1 | Out-Null

Write-Step "Step 5/5 git push"
$ok = 0
for ($i = 1; $i -le 3; $i++) {
  Write-Host "  第 $i/3 次..."
  git push 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { $ok = 1; break }
  Start-Sleep 3
}
if (-not $ok) { Write-ERR "推送失败，检查网络/VPN"; Done-Pause; exit 5 }
Write-OK "PUSH 成功！"

$c = (& git rev-parse --short HEAD 2>$null | Out-String).Trim()
Write-Host ""
Write-Host "  最新 commit: $c"
Write-Host "  线上地址: https://knowledgesite.vercel.app"
Write-Host "  Vercel 构建中，1-2 分钟后 Ctrl+Shift+R 刷新即可看到最新内容"
Done-Pause
exit 0