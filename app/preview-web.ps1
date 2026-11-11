# 番茄钟 —— 在电脑上预览网页版（起本地服务 + 自动开浏览器，F12 切手机视口）
# 用法：
#   powershell -ExecutionPolicy Bypass -File app\preview-web.ps1
#   或直接双击仓库根目录的 preview-web.bat
# 没有 Python 时会退化成「直接用浏览器打开 www\index.html」（也能用，只是部分浏览器对 file:// 的限制更多）。
# 关掉本窗口 / Ctrl+C 即停止服务。

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $AppRoot
$WwwDir = Join-Path $RepoRoot 'www'
$Index = Join-Path $WwwDir 'index.html'

if (-not (Test-Path $Index)) { throw "找不到 $Index" }

function Find-Python {
  foreach ($c in @('python', 'python3', 'py')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if (-not $cmd -or -not $cmd.Source) { continue }
    # Windows Store 的 python.exe 别名虽然存在，却不能运行模块；必须逐个实际探测。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $probe = (& $cmd.Source -c 'import http.server; print("HTTP_SERVER_OK")' 2>$null) -join ''
    $probeExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($probeExit -eq 0 -and $probe -match 'HTTP_SERVER_OK') { return $cmd.Source }
    Write-Host "  跳过不可用的 Python：$($cmd.Source)" -ForegroundColor Yellow
  }
  return $null
}
function Test-PortInUse($p) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $p)
    $c.Close()
    return $true
  } catch { return $false }
}

$py = Find-Python
if (-not $py) {
  Write-Host '没有找到 Python，直接用默认浏览器打开 www\index.html。' -ForegroundColor Yellow
  Write-Host '（想要 http 服务 + F12 手机视口，装个 Python 再跑本脚本即可）'
  Start-Process $Index
  return
}

# 起始端口刻意避开 8899：那个是拾穗集 tools\serve-apk.mjs 长期占着的端口
$port = 8848
while ((Test-PortInUse $port) -and $port -lt 8898) { $port++ }
if ($port -ge 8898) { throw '8848~8897 端口都被占用了，请先关掉占用端口的程序' }
$url = "http://127.0.0.1:$port/"

Write-Host "`n==> 番茄钟 网页预览" -ForegroundColor Cyan
Write-Host "  $url"
Write-Host "  服务目录：$WwwDir"
Write-Host "  浏览器按 F12 → Ctrl+Shift+M 切手机视口；统计页要切底部「统计」Tab 才有内容。"
Write-Host "  停止服务：在此窗口按 Ctrl+C，或直接关掉本窗口。`n"

$server = $null
try {
  $server = Start-Process -FilePath $py -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1') `
    -WorkingDirectory $WwwDir -PassThru -WindowStyle Hidden
  $ready = $false
  for ($i = 0; $i -lt 50; $i++) {
    if ($server.HasExited) { throw "Python http.server 启动失败（退出码 $($server.ExitCode)）" }
    if (Test-PortInUse $port) { $ready = $true; break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $ready) { throw 'Python http.server 未在 5 秒内监听回环端口' }

  # 只有服务已确认可连接才打开浏览器；浏览器启动失败也会走 finally 清理服务。
  Start-Process $url
  Wait-Process -Id $server.Id
} finally {
  if ($server -and -not $server.HasExited) {
    try { $server.Kill(); $server.WaitForExit() } catch {}
  }
}
