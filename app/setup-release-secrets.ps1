# 番茄钟 —— 把本地签名密钥上传成 GitHub Actions secrets
# 用法（仓库根目录或 app/ 下都行）：
#   powershell -ExecutionPolicy Bypass -File app\setup-release-secrets.ps1
#   powershell -ExecutionPolicy Bypass -File app\setup-release-secrets.ps1 -Repo <owner/name>
#
# 为什么需要这一步：
#   仓库里【不放】签名密钥（.gitignore 已排除），但 GitHub Actions 打包需要它。
#   这里把 app\android\tomato-release.keystore 和 keystore.properties 里的口令
#   传成 4 个 secret，CI 打出来的包和本机 build-apk.ps1 -Release 出来的包
#   【同一个签名】—— 用户从 Release 下载的包可以直接覆盖安装。
#
# 安全边界（请先读完）：
#   传上去之后，签名密钥的副本存在 GitHub 的 servers（国内访问不到 GitHub 时
#   这一步就用不了）里，只有仓库管理员能读、且不公开。
#   任何能改这个仓库的人都能用这个密钥签出「看起来是你的 App」的包。
#   如果你不接受这个前提，就不要跑这个脚本，Release 流程保持关闭即可。
#
# 前置：本地已经跑过一次 build-apk.ps1 -Release（生成了 keystore 和口令），
#       并且装好了 GitHub CLI（gh）并已登录（gh auth login）。

param([string]$Repo)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AndroidDir = Join-Path $AppRoot 'android'
$KsFile = Join-Path $AndroidDir 'tomato-release.keystore'
$KsProps = Join-Path $AndroidDir 'keystore.properties'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

Write-Step '检查本地签名文件'
if (-not (Test-Path $KsFile)) {
  throw "找不到 $KsFile；先跑一次 build-apk.ps1 -Release 生成签名"
}
if (-not (Test-Path $KsProps)) {
  throw "找不到 $KsProps（里面是签名口令）；先跑一次 build-apk.ps1 -Release"
}

$kv = @{}
Get-Content $KsProps -Encoding UTF8 | ForEach-Object {
  if ($_ -match '^\s*([^=]+)=(.*)$') { $kv[$Matches[1].Trim()] = $Matches[2].Trim() }
}
foreach ($need in @('storePassword', 'keyAlias', 'keyPassword')) {
  if (-not $kv.ContainsKey($need) -or -not $kv[$need]) {
    throw "keystore.properties 缺少字段：$need"
  }
}
Write-Host "  密钥文件：$KsFile ($([math]::Round((Get-Item $KsFile).Length / 1KB, 1)) KB)"
Write-Host "  keyAlias ：$($kv['keyAlias'])"

# ---------------------------------------------------------------- gh
Write-Step '准备 GitHub CLI'
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
  Write-Warn2 '没找到 gh（GitHub CLI）。装好并 gh auth login 后再跑本脚本。'
  Write-Host '  下载地址：https://cli.github.com/'
  throw '缺少 gh，无法自动上传 secret'
}

if (-not $Repo) {
  Write-Step '识别仓库'
  $Repo = (& $gh.Source repo view --json nameWithOwner --jq .nameWithOwner 2>$null)
  if (-not $Repo) {
    throw '无法自动确定仓库名，请用 -Repo <owner/name> 指定'
  }
}
Write-Host "  仓库：$Repo"

# ---------------------------------------------------------------- 上传
Write-Step '上传 4 个 secret'
# 密钥用 base64 走 stdin 传：命令行长度有限，走管道最稳
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($KsFile))
$b64 | & $gh.Source secret set KEYSTORE_BASE64 --repo $Repo
if ($LASTEXITCODE -ne 0) { throw '上传 KEYSTORE_BASE64 失败' }
Write-Host '  [1/4] KEYSTORE_BASE64'

& $gh.Source secret set KEYSTORE_PASSWORD --body $kv['storePassword'] --repo $Repo
if ($LASTEXITCODE -ne 0) { throw '上传 KEYSTORE_PASSWORD 失败' }
Write-Host '  [2/4] KEYSTORE_PASSWORD'

& $gh.Source secret set KEY_ALIAS --body $kv['keyAlias'] --repo $Repo
if ($LASTEXITCODE -ne 0) { throw '上传 KEY_ALIAS 失败' }
Write-Host '  [3/4] KEY_ALIAS'

& $gh.Source secret set KEY_PASSWORD --body $kv['keyPassword'] --repo $Repo
if ($LASTEXITCODE -ne 0) { throw '上传 KEY_PASSWORD 失败' }
Write-Host '  [4/4] KEY_PASSWORD'

Write-Step '完成'
Write-Host '已上传 4 个 secret。接下来在仓库根目录执行：' -ForegroundColor Green
Write-Host ''
Write-Host '  git tag -a v1.4.0 -m "番茄钟 v1.4.0"'
Write-Host '  git push origin v1.4.0'
Write-Host ''
Write-Host '推上去后 GitHub Actions 会自动打包并挂到 Release 页面：'
Write-Host '  https://github.com/' + $Repo + '/releases'
Write-Host ''
Write-Warn2 '本地 app\android\tomato-release.keystore 和 keystore.properties 仍然要自己备份：'
Write-Warn2 'CI 里的副本丢了，本地这份还在；两份都丢就只能卸载重装（旧记录会清空）。'
