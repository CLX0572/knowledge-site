#Requires -Version 5.1
$ErrorActionPreference = "Stop"
[string]$ROOT  = "E:\TRAE SOLO CN\app\knowledge-site"
[string]$VAULT = "E:\Obisian\Notes\轨向的物理笔记"
function Write-Step($t)  { Write-Host ""; Write-Host (">>>>>>  $t  <<<<<") -ForegroundColor Cyan }
function Write-OK($t)   { Write-Host ("[OK]   " + $t) -ForegroundColor Green }
function Done-Pause()   { Write-Host ""; Write-Host "----- 结束，按任意键关闭 -----"; try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Start-Sleep 3600 } }

Write-Host ""
Write-Host "=== 物理知识库 GitHub 推送（极简版） ===" -ForegroundColor Magenta
Set-Location -LiteralPath $ROOT

# 同步：Vault 每个子目录 -> content 对应子目录（/PURGE 保持一致）
$subdirs = @("初中物理知识库", "待处理", "高中物理知识库")
$content = Join-Path $ROOT "content"
if (-not (Test-Path -LiteralPath $content)) { New-Item -ItemType Directory -Path $content -Force | Out-Null }

Write-Step "Step 1/5 同步 md 文件"
foreach ($sd in $subdirs) {
  $src = Join-Path $VAULT $sd
  $dst = Join-Path $content $sd
  if (-not (Test-Path -LiteralPath $src)) { Write-Host "  [SKIP] $sd (源不存在)"; continue }
  if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
  $rargs = @($src, $dst, "*.md", "/E", "/COPY:DAT", "/DCOPY:DAT", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/PURGE")
  foreach ($ext in @("*.png","*.jpg","*.jpeg","*.gif","*.svg","*.webp","*.pdf")) { $rargs += $ext }
  $null = & robocopy @rargs
}
Write-OK "同步完成"

# git 流程
Write-Step "Step 2/5 查看变更"
$stat = @(git status --porcelain)
Write-Host "  变更: $($stat.Count)"
if ($stat.Count -eq 0) { Write-Host "  无变更，跳过"; Done-Pause; exit 0 }

Write-Step "Step 3/5 git add + commit"
git add . | Out-Null
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
git commit -m "update content - $ts" | Out-Null

Write-Step "Step 4/5 git pull --rebase"
git pull --rebase | Out-Null

Write-Step "Step 5/5 git push"
$ok = 0
for ($i = 1; $i -le 3; $i++) {
  Write-Host "  第 $i/3 次..."
  git push | Out-Null
  if ($LASTEXITCODE -eq 0) { $ok = 1; break }
  Start-Sleep 3
}
if (-not $ok) { Write-Host "  推送失败" -ForegroundColor Red; Done-Pause; exit 5 }
Write-OK "PUSH 成功！"
$c = (& git rev-parse --short HEAD | Out-String).Trim()
Write-Host "  commit: $c"
Write-Host "  Vercel 1-2min 后 Ctrl+Shift+R 刷新"
Done-Pause
exit 0