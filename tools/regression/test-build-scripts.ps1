# 番茄钟 —— 构建脚本的回归检查（PowerShell 5.1 兼容）
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\regression\test-build-scripts.ps1
# 检查内容：
#   1. app\*.ps1 的语法（用 PowerShell 自带的解析器，不执行脚本）
#   2. local.properties 的 sdk.dir 转义：含空格、中文的路径写进去再读回来必须一模一样
#   3. "没有合格 Node、tools 目录也不存在" 的场景：目录必须先建再下载
#   4. 脚本不再写用户全局的 %USERPROFILE%\.gradle\init.gradle
#   5. package.json / package-lock.json / build.gradle 三处版本号一致
# 只读检查，不下载、不打包、不动用户全局配置。

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$AppRoot = Join-Path $RepoRoot 'app'
$BuildScript = Join-Path $AppRoot 'build-apk.ps1'

$script:Fail = 0
$script:Pass = 0
function Ok($msg) { $script:Pass++; Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Bad($msg, $detail) {
  $script:Fail++
  Write-Host "  [FAIL] $msg" -ForegroundColor Red
  if ($detail) { Write-Host "         $detail" -ForegroundColor Yellow }
}
function Section($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. 语法
Section '1. PowerShell 语法检查'
Get-ChildItem $AppRoot -Filter '*.ps1' | ForEach-Object {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    Bad "$($_.Name) 语法错误" ($errors | ForEach-Object { $_.Message } | Select-Object -First 3 | Out-String).Trim()
  } else {
    Ok "$($_.Name) 语法正确"
  }
}

# ---------------------------------------------------------------- 2. sdk.dir 转义
Section '2. local.properties 的 sdk.dir 转义（含空格 / 中文）'
$buildSrc = Get-Content $BuildScript -Raw -Encoding UTF8
$m = [regex]::Match($buildSrc, '(?ms)^function\s+ConvertTo-PropertiesValue.*?^}')
if (-not $m.Success) {
  Bad 'build-apk.ps1 里找不到 ConvertTo-PropertiesValue 函数'
} else {
  Invoke-Expression $m.Value
  $testPaths = @(
    'C:\Users\testuser\AppData\Local\Android\Sdk',
    'C:\Program Files\Android\Android Studio\SDK',
    'C:\Users\张三\我的文档\Android SDK 备份\platform-tools'
  )
  $tmpDir = Join-Path $env:TEMP ("tc-props-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  try {
    foreach ($p in $testPaths) {
      $escaped = ConvertTo-PropertiesValue $p
      $propsFile = Join-Path $tmpDir 'local.properties'
      [IO.File]::WriteAllText($propsFile, "sdk.dir=$escaped`n", [Text.UTF8Encoding]::new($false))
      $raw = [IO.File]::ReadAllText($propsFile)
      # 用 Java 的 Properties 语义读回来（java 单文件模式直接跑）。
      # 比较交给 Java 做，并把期望值写进 UTF-8 文件再读 ——
      # 走控制台传中文会被 Windows 的代码页吃掉，测出来的"不一致"是假象。
      $javaSrc = Join-Path $tmpDir 'ReadProps.java'
      $expectFile = Join-Path $tmpDir 'expected.txt'
      # 必须写无 BOM：PS 5.1 的 Set-Content -Encoding UTF8 会带 BOM，javac 会报 '\ufeff' 非法字符
      $javaCode = @'
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
public class ReadProps {
  public static void main(String[] a) throws Exception {
    Properties p = new Properties();
    try (InputStream in = new FileInputStream(a[0])) { p.load(in); }
    String got = p.getProperty("sdk.dir", "");
    String want = new String(Files.readAllBytes(Paths.get(a[1])), StandardCharsets.UTF_8);
    if (got.equals(want)) { System.out.print("MATCH"); }
    else { System.out.print("MISMATCH len=" + got.length() + "/" + want.length()); }
  }
}
'@
      [IO.File]::WriteAllText($javaSrc, $javaCode, [Text.UTF8Encoding]::new($false))
      [IO.File]::WriteAllText($expectFile, $p, [Text.UTF8Encoding]::new($false))
      $javaCmd = (Get-Command java -ErrorAction SilentlyContinue)
      if ($javaCmd) {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $verdict = (& java $javaSrc $propsFile $expectFile 2>$null) -join ''
        $javaCode2 = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($javaCode2 -ne 0) { Bad "Java 解析 $p 失败" '' ; continue }
        if ($verdict -eq 'MATCH') { Ok "转义往返一致（Java Properties 读回）：$p  ->  $escaped" }
        else { Bad "转义后读回来不一样" "期望 $p，Java 判定 $verdict" }
        continue
      } else {
        # 没有 java 时按 Java .properties 的转义规则手工还原
        $back = $raw -replace '^sdk\.dir=', '' -replace '\\\:', ':' -replace '\\\\', '\'
        $back = $back.Trim()
      }
      if ($back -ceq $p) { Ok "转义往返一致：$p  ->  $escaped" }
      else { Bad "转义后读回来不一样" "期望 $p，实际 $back" }
    }
  } finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- 3. 首次运行的目录顺序
Section '3. 没有合格 Node、tools 目录也不存在时的顺序'
$nodeIdx = $buildSrc.IndexOf('Prepare Node.js')
$toolsCreateIdx = $buildSrc.IndexOf('New-Item -ItemType Directory -Force -Path $ToolsRoot')
$nodeDlIdx = $buildSrc.IndexOf('node-$NodeVer.zip')
if ($nodeIdx -lt 0 -or $toolsCreateIdx -lt 0 -or $nodeDlIdx -lt 0) {
  Bad '没找到 Node 准备段的关键位置' ''
} else {
  # 关键：建目录的动作必须出现在"下载 zip"之前
  if ($toolsCreateIdx -lt $nodeDlIdx) {
    Ok "tools 目录在下载 Node 之前创建（创建位置 $toolsCreateIdx < 下载位置 $nodeDlIdx）"
  } else {
    Bad 'tools 目录仍然是在下载之后才创建' "创建位置 $toolsCreateIdx >= 下载位置 $nodeDlIdx"
  }
  # 再验一次事实：同一个"能正常返回内容"的本地服务，
  # 目标目录不存在时写不进去、目录建好后就能写进去 ——
  # 这样失败原因就是目录，而不是连接不上（之前用连不上的地址，结论是假的）
  $tmp = Join-Path $env:TEMP ("tc-curl-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $srvJs = Join-Path $tmp 'srv.js'
  [IO.File]::WriteAllText($srvJs, @'
const http=require('http');
const body=Buffer.alloc(1024*1024,0x41);          // 1 MB
const s=http.createServer((q,r)=>{r.writeHead(200,{'Content-Length':body.length});r.end(body)});
s.listen(8971,'127.0.0.1');
'@, [Text.UTF8Encoding]::new($false))
  $srv = $null
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $curl -or -not $nodeCmd) {
    Write-Host '  [SKIP] 缺少 curl.exe 或 node，跳过下载失败复现' -ForegroundColor Yellow
  } else {
    $srv = Start-Process node -ArgumentList $srvJs -PassThru -WindowStyle Hidden
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
      try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 8971); $c.Close(); $ready = $true; break }
      catch { Start-Sleep -Milliseconds 150 }
    }
    if (-not $ready) {
      Bad '本地测试服务没起来' ''
    } else {
      $url = 'http://127.0.0.1:8971/payload'
      # ① 目录不存在 -> 写不进去
      $missingOut = Join-Path (Join-Path $tmp 'no-such-dir') 'payload.bin'
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      & curl.exe -sS -L -o $missingOut $url 2>$null
      $code1 = $LASTEXITCODE
      # ② 目录建好 -> 同一个地址能正常下载
      $okDir = Join-Path $tmp 'yes-dir'
      New-Item -ItemType Directory -Force -Path $okDir | Out-Null
      $okOut = Join-Path $okDir 'payload.bin'
      & curl.exe -sS -L -o $okOut $url 2>$null
      $code2 = $LASTEXITCODE
      $ErrorActionPreference = $prev
      $size2 = if (Test-Path $okOut) { (Get-Item $okOut).Length } else { 0 }
      if ($code1 -ne 0 -and -not (Test-Path $missingOut)) {
        Ok "目录不存在时下载写不进去（curl 退出码 $code1），而目录建好后同一个地址能下载成功（退出码 $code2，$size2 字节）"
      } else {
        Bad '下载失败的复现不成立' "缺目录时退出码=$code1 文件存在=$(Test-Path $missingOut)；有目录时退出码=$code2 大小=$size2"
      }
    }
    if ($srv) { try { $srv.Kill() } catch {} }
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 4. 不再动全局 init.gradle
Section '4. 不再改写用户全局的 Gradle 配置'
# 只看"真的会写"的地方：注释里提到这个路径是在说明"以后不这么干了"，不算违规
$globalWrites = @(
  '\$InitGradle\s*=',
  'WriteAllText\(\s*\$InitGradle',
  'Copy-Item\s+\$InitGradle',
  'Set-Content[^\r\n]*init\.gradle',
  'Out-File[^\r\n]*init\.gradle'
)
$hit = $null
foreach ($pat in $globalWrites) {
  $mm = [regex]::Match($buildSrc, "(?m)^.*$pat.*$")
  if ($mm.Success) { $hit = $mm.Value.Trim(); break }
}
if ($hit) { Bad 'build-apk.ps1 里仍然会写用户全局的 init.gradle' $hit }
else { Ok 'build-apk.ps1 没有任何写用户全局 init.gradle 的动作' }
if ($buildSrc -match '--init-script') { Ok '改用 --init-script 显式加载项目内的镜像配置' }
else { Bad '没有找到 --init-script，镜像配置可能没生效' }
if ($buildSrc -match 'mirrors\.init\.gradle') { Ok '镜像配置落在项目内的 mirrors.init.gradle' }
else { Bad '没找到项目内的 mirrors.init.gradle' }
$globalInit = Join-Path $env:USERPROFILE '.gradle\init.gradle'
if (Test-Path $globalInit) {
  $h = (Get-FileHash $globalInit -Algorithm SHA256).Hash
  Ok "本机全局 init.gradle 当前 SHA256 = $($h.Substring(0, 16))…（本脚本不会碰它）"
} else {
  Ok '本机没有全局 init.gradle'
}

# ---------------------------------------------------------------- 5. 三处版本号
Section '5. 版本号一致性'
$pkg = Get-Content (Join-Path $AppRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$lockText = Get-Content (Join-Path $AppRoot 'package-lock.json') -Raw -Encoding UTF8
$lockVersion = $null
if ($lockText -match '(?s)^\s*\{\s*"name"\s*:\s*"[^"]+"\s*,\s*"version"\s*:\s*"([^"]+)"') { $lockVersion = $Matches[1] }
$gradleText = Get-Content (Join-Path $AppRoot 'android\app\build.gradle') -Raw -Encoding UTF8
$nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')
$codeMatch = [regex]::Match($gradleText, 'versionCode\s+(\d+)')
if ($pkg.version -eq $lockVersion -and $pkg.version -eq $nameMatch.Groups[1].Value) {
  Ok "package.json / package-lock.json / build.gradle 版本一致：$($pkg.version)（versionCode $($codeMatch.Groups[1].Value)）"
} else {
  Bad '版本号不一致' "package.json=$($pkg.version) package-lock=$lockVersion versionName=$($nameMatch.Groups[1].Value)"
}

Write-Host ""
if ($script:Fail -eq 0) {
  Write-Host "全部通过：$($script:Pass) 项" -ForegroundColor Green
  exit 0
} else {
  Write-Host "通过 $script:Pass 项，失败 $script:Fail 项" -ForegroundColor Red
  exit 1
}
