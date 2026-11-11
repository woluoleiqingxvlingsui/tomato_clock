# 番茄钟 —— 构建脚本的回归检查（PowerShell 5.1 兼容）
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\regression\test-build-scripts.ps1
# 检查内容：
#   1. app\*.ps1 的语法（用 PowerShell 自带的解析器，不执行脚本）
#   2. local.properties 的 sdk.dir 转义：含空格、中文的路径写进去再读回来必须一模一样
#   3. "没有合格 Node、tools 目录也不存在" 的场景：目录必须先建再下载
#   4. 脚本不再写用户全局的 %USERPROFILE%\.gradle\init.gradle
#   5. package.json / package-lock.json / build.gradle 三处版本号一致
#   6. 大件下载都有国内镜像回退、npm 有 registry 兜底且不改用户全局配置
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
  # 无 Java 时使用的 .properties 解码器：按字符处理，避免把字面量 "\\uXXXX" 误解码。
  function ConvertFrom-PropertiesValue([string]$Value) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i++) {
      if ($Value[$i] -ne '\') { $null = $sb.Append($Value[$i]); continue }
      if (++$i -ge $Value.Length) { $null = $sb.Append('\'); break }
      $esc = $Value[$i]
      switch ($esc) {
        'u' {
          if ($i + 4 -ge $Value.Length) { throw '截断的 Java Properties Unicode 转义' }
          $hex = $Value.Substring($i + 1, 4)
          if ($hex -notmatch '^[0-9a-fA-F]{4}$') { throw "非法的 Java Properties Unicode 转义：$hex" }
          $null = $sb.Append([char][Convert]::ToInt32($hex, 16))
          $i += 4
        }
        't' { $null = $sb.Append("`t") }
        'n' { $null = $sb.Append("`n") }
        'r' { $null = $sb.Append("`r") }
        'f' { $null = $sb.Append("`f") }
        default { $null = $sb.Append($esc) }
      }
    }
    return $sb.ToString()
  }
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
      # 无论机器上是否有 Java，都先验证内置回退能正确还原 \uXXXX（含中文）。
      $encoded = ($raw -replace '^sdk\.dir=', '') -replace '\r?\n$', ''
      $back = ConvertFrom-PropertiesValue $encoded
      if ($back -ceq $p) { Ok "转义往返一致（内置 Properties 解码）：$p  ->  $escaped" }
      else { Bad "内置 Properties 解码不一致" "期望 $p，实际 $back" }

      # 有 Java 时再用真正的 Properties 语义交叉验证（java 单文件模式直接跑）。
      # 期望值写进 UTF-8 文件再读，避免控制台代码页吃掉中文造成假失败。
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
        $verdict = (& $javaCmd.Source $javaSrc $propsFile $expectFile 2>$null) -join ''
        $javaCode2 = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($javaCode2 -ne 0) { Bad "Java 解析 $p 失败" '' }
        elseif ($verdict -eq 'MATCH') { Ok "转义往返一致（Java Properties 读回）：$p  ->  $escaped" }
        else { Bad "Java Properties 读回不一致" "期望 $p，Java 判定 $verdict" }
      }
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
      if ($code1 -ne 0 -and -not (Test-Path $missingOut) -and $code2 -eq 0 -and $size2 -eq 1MB) {
        Ok "目录不存在时下载写不进去（curl 退出码 $code1），而目录建好后同一个地址下载成功且恰好 1 MiB（退出码 $code2，$size2 字节）"
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
# PS 5.1 的 ConvertFrom-Json 拒绝空字符串键；仅把 packages 的根键临时改成哨兵再解析。
$lockNormalized = [regex]::Replace($lockText, '(?m)("packages"\s*:\s*\{\s*)""(\s*:)', '$1"__tomato_root_package__"$2')
$lock = $lockNormalized | ConvertFrom-Json
$lockVersion = $lock.version
$lockRootVersion = if ($lock.packages) { $lock.packages.__tomato_root_package__.version } else { $null }
$gradleText = Get-Content (Join-Path $AppRoot 'android\app\build.gradle') -Raw -Encoding UTF8
$nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')
$codeMatch = [regex]::Match($gradleText, 'versionCode\s+(\d+)')
if ($pkg.version -and $pkg.version -eq $lockVersion -and $pkg.version -eq $lockRootVersion -and $pkg.version -eq $nameMatch.Groups[1].Value) {
  Ok "package.json / lockfile 顶层 / packages root / build.gradle 版本一致：$($pkg.version)（versionCode $($codeMatch.Groups[1].Value)）"
} else {
  Bad '版本号不一致或 lockfile 项目版本缺失' "package.json=$($pkg.version) lockfile 顶层=$lockVersion packages root=$lockRootVersion versionName=$($nameMatch.Groups[1].Value)"
}

# ---------------------------------------------------------------- 6. 国内镜像回退
Section '6. 大件下载都有国内镜像回退（不靠单一源）'
# 背景：JDK 与 cmdline-tools 原来各只有一个源（JDK 走 api.adoptium.net，
# 实际会 302 到 GitHub 的 release 资产；cmdline-tools 走 dl.google.com）——
# 这两个地址在国内经常连不上，一失败整个构建就停在第一步。
# 现在每个大件都有「国内镜像优先 + 官方兜底」的候选列表。
function Get-CandidateUrls([string]$varName) {
  $m = [regex]::Match($buildSrc, "(?ms)\`$$varName\s*=\s*@\((.*?)\)")
  if (-not $m.Success) { return $null }
  return [regex]::Matches($m.Groups[1].Value, 'https?://[^''"\s]+') | ForEach-Object { $_.Value }
}
$sourceSpecs = @(
  @{ name = 'JDK 21';        var = 'jdkSources';  min = 2 },
  @{ name = 'cmdline-tools'; var = 'cmdSources';  min = 2 }
)
foreach ($spec in $sourceSpecs) {
  $urls = Get-CandidateUrls $spec.var
  if (-not $urls) {
    Bad "$($spec.name) 找不到候选源列表（变量 `$($spec.var)）" ''
  } elseif ($urls.Count -ge $spec.min) {
    $cn = @($urls | Where-Object { $_ -match 'huaweicloud|tencent|npmmirror|tuna|ustc|aliyun' }).Count
    Ok "  $($spec.name) 有 $($urls.Count) 个候选源（其中 $cn 个国内镜像）"
  } else {
    Bad "$($spec.name) 的候选源少于 $($spec.min) 个" ($urls -join ', ')
  }
}
# npm 必须有 registry 回退，而且不能偷偷改用户的全局配置。
# 只看真正的代码：先把整行注释和行尾注释去掉 —— 否则「不往仓库里塞 .npmrc」
# 这种说明文字会被当成违规，结论是假的（跟第 4 组同一个道理）。
$buildCode = ($buildSrc -split "`r?`n" | ForEach-Object { ($_ -replace '#.*$', '') }) -join "`n"
if ($buildCode -match 'registry\.npmmirror\.com') { Ok 'npm 安装有国内 registry 兜底（npmmirror）' }
else { Bad 'npm 安装没有 registry 兜底' '' }
if ($buildCode -match '--registry=') { Ok 'npm 用 --registry 参数临时指定 registry' }
else { Bad 'npm 没有用 --registry 参数指定 registry' }
if ($buildCode -match 'npm\s+config\s+set' -or $buildCode -match '\.npmrc') {
  Bad '脚本会改 npm 配置' '应当只用 --registry 参数，不碰用户全局 ~/.npmrc，也不往仓库塞 .npmrc'
} else {
  Ok '脚本不改 npm 配置（不写 ~/.npmrc、不塞仓库内的 .npmrc）'
}
# 大件下载必须用 Get-FileOrNull（带体积下限），避免把镜像的 HTML 错误页当包解压
foreach ($varName in @('jdkSources', 'cmdSources')) {
  $m = [regex]::Match($buildCode, "(?ms)\`$$varName\s*=\s*@\((.*?)\n\s*\)")
  if (-not $m.Success) { continue }
  $after = $buildCode.Substring($m.Index + $m.Length, [Math]::Min(600, $buildCode.Length - $m.Index - $m.Length))
  if ($after -match 'Get-FileOrNull') { Ok "$varName 的下载走了 Get-FileOrNull（有体积下限，能挡住 HTML 错误页）" }
  else { Bad "$varName 的下载没有体积下限校验" '' }
}

Section '7. 工具链 SHA-256 与脚本安全边界'
$expectedHashes = @(
  'bb819d6eb8f5bfda294bbc83a7e4ec6539da67c4233d54b0d655b9248b15e29d', # Node v22.20.0 win-x64
  '5434faaf029e66e7ce6e75770ca384de476750984a7d2881ef7686894c4b4944', # OpenJDK 21
  'a4dbaa05fca4bd89d84584e58c459bd732efebb1722af80ab13c6516832004f9', # Temurin 21.0.13+9
  'b6c17e747ae78cdd6de4d7532b3164b277daee97c007d3eaa2b39cca99882664', # OpenJDK 21.0.2
  '4d6931209eebb1bfb7c7e8b240a6a3cb3ab24479ea294f3539429574b1eec862', # cmdline-tools
  '89d4e70e4e84e2d2dfbb63e4daa53e21b25017cc70c37e4eea31ee51fb15098a'  # Gradle all
)
foreach ($hash in $expectedHashes) {
  if ($buildCode -match "'$hash'") { Ok "已固定 SHA-256：$($hash.Substring(0, 16))…" }
  else { Bad "缺少固定 SHA-256：$hash" '' }
}
$gradleHashMatch = [regex]::Match($buildCode, '\$gradleSha256\s*=\s*''([0-9a-fA-F]{64})''')
$wrapperPath = Join-Path $AppRoot 'android\gradle\wrapper\gradle-wrapper.properties'
$wrapperText = if (Test-Path $wrapperPath) { Get-Content $wrapperPath -Raw -Encoding UTF8 } else { '' }
$wrapperHashMatch = [regex]::Match($wrapperText, '(?m)^distributionSha256Sum=([0-9a-fA-F]{64})\s*$')
if ($gradleHashMatch.Success -and $wrapperHashMatch.Success -and $gradleHashMatch.Groups[1].Value -eq $wrapperHashMatch.Groups[1].Value) {
  Ok 'Gradle wrapper 与 build-apk.ps1 使用同一个官方 distribution SHA-256'
} else {
  Bad 'Gradle wrapper 哈希缺失或与 build-apk.ps1 不一致' "build=$($gradleHashMatch.Groups[1].Value) wrapper=$($wrapperHashMatch.Groups[1].Value)"
}
if ($buildCode -match 'Get-FileHash\s+\$dest\s+-Algorithm\s+SHA256' -and $buildCode -match '\$actual\s+-ne\s+\$sha256') {
  Ok 'Get-FileOrNull 在返回成功前强制计算并比对 SHA-256'
} else { Bad '下载 helper 没有在成功前强制 SHA-256 校验' '' }
$downloadCalls = [regex]::Matches($buildCode, 'Get-FileOrNull\s+[^\r\n]+')
$unsafeCalls = @($downloadCalls | Where-Object { $_.Value -notmatch 'Get-FileOrNull\s+\S+\s+\S+\s+\S+\s+\$[A-Za-z0-9_.]+' })
if ($downloadCalls.Count -eq 4 -and $unsafeCalls.Count -eq 0) {
  Ok 'Node / JDK / cmdline-tools / Gradle 的 4 类下载调用都传入预期 SHA-256'
} else {
  Bad '存在未绑定 SHA-256 的工具下载调用' ($unsafeCalls | ForEach-Object { $_.Value } | Out-String).Trim()
}
if ($buildCode -match 'api\.adoptium\.net/.*/latest/') { Bad 'Adoptium 仍使用动态 latest 下载' '' }
else { Ok 'Adoptium 使用固定 release，未把 latest 当作固定哈希下载件' }

$registryMatch = [regex]::Match($buildCode, '(?ms)\$registries\s*=\s*@\((.*?)\)')
if ($registryMatch.Success -and $registryMatch.Groups[1].Value -match 'registry\.npmmirror\.com' -and $registryMatch.Groups[1].Value -match 'registry\.npmjs\.org') {
  Ok 'npm 第二回退显式使用 https://registry.npmjs.org'
} else { Bad 'npm 第二回退未显式固定官方 registry' '' }
if ($buildCode -match 'npm\s+install\s+--no-audit\s+--no-fund\s+--fetch-retries=3\s+--fetch-timeout=120000\s+--registry=https://registry\.npmjs\.org') {
  Ok '最终 npm install 兜底同样显式使用官方 registry'
} else { Bad '最终 npm install 兜底仍可能继承全局 registry' '' }

$secretsSrc = Get-Content (Join-Path $AppRoot 'setup-release-secrets.ps1') -Raw -Encoding UTF8
$secretsCode = ($secretsSrc -split "`r?`n" | ForEach-Object { ($_ -replace '#.*$', '') }) -join "`n"
if ($secretsCode.Contains('$kv[''storePassword''] | & $gh.Source secret set KEYSTORE_PASSWORD') -and
    $secretsCode.Contains('$kv[''keyPassword''] | & $gh.Source secret set KEY_PASSWORD') -and
    $secretsCode -notmatch 'secret\s+set\s+(KEYSTORE_PASSWORD|KEY_PASSWORD)\s+--body') {
  Ok '两个签名口令均通过 stdin 传递，不出现在 gh 命令行参数'
} else { Bad '签名口令仍可能通过 --body 出现在命令行参数' '' }
if ($secretsCode -match 'repo\s+view\s+\$Repo\s+--json\s+nameWithOwner' -and $secretsCode.Contains('$answer -cne "UPLOAD $Repo"')) {
  Ok '上传前校验目标 owner/name，并要求输入完整 UPLOAD owner/name'
} else { Bad '上传前目标校验或完整强确认缺失' '' }
if ($secretsCode -notmatch 'v1\.4\.0|git\s+push\s+origin|自动打包并挂到') {
  Ok 'secrets 脚本不再包含硬编码版本或推 tag 自动发布说明'
} else { Bad 'secrets 脚本仍含过期发布说明' '' }

$previewSrc = Get-Content (Join-Path $AppRoot 'preview-web.ps1') -Raw -Encoding UTF8
if ($previewSrc -match "import http\.server; print" -and $previewSrc -match 'foreach \(\$c in @\(''python'', ''python3'', ''py''\)\)') {
  Ok '预览脚本逐个实际验证 python / python3 / py 的 http.server 支持'
} else { Bad '预览脚本未完整验证 Python 候选' '' }
$serverStartIdx = $previewSrc.IndexOf('$server = Start-Process')
$readyIdx = $previewSrc.IndexOf('if (-not $ready)')
$browserIdx = $previewSrc.IndexOf('Start-Process $url')
$killIdx = $previewSrc.IndexOf('$server.Kill()')
if ($serverStartIdx -ge 0 -and $readyIdx -gt $serverStartIdx -and $browserIdx -gt $readyIdx -and $killIdx -gt $browserIdx) {
  Ok '预览先启动并确认端口，再开浏览器，finally 中清理服务'
} else { Bad '预览启动、端口确认、浏览器或清理顺序不正确' '' }

# ---------------------------------------------------------------- 8. 签名保护
Section '8. 签名保护：默认复用 / 缺失即停 / 首次必须显式开关（离线、临时目录）'
$prepareSrc = Get-Content (Join-Path $AppRoot 'prepare-release.ps1') -Raw -Encoding UTF8
$prepareCode = ($prepareSrc -split "`r?`n" | ForEach-Object { ($_ -replace '#.*$', '') }) -join "`n"

# 从脚本源码里抽出纯函数，在临时目录上验证它的【行为】，
# 不调用真实 keytool / Gradle / 签名工具，也不碰任何真实密钥。
function Get-FunctionText {
  param([string]$Source, [string]$Name)
  $m = [regex]::Match($Source, "(?ms)^function\s+$([regex]::Escape($Name))\b.*?^}")
  if (-not $m.Success) { return $null }
  return $m.Value
}
function New-ScopedInvoker {
  param([string]$FunctionText, [string]$Name)
  if (-not $FunctionText) { return $null }
  return [scriptblock]::Create(($FunctionText + "`n" + $Name + ' @args'))
}

$buildStateText = Get-FunctionText $buildSrc 'Get-SigningState'
$buildDecText = Get-FunctionText $buildSrc 'Get-SigningDecision'
$prepStateText = Get-FunctionText $prepareSrc 'Get-SigningState'
$prepDecText = Get-FunctionText $prepareSrc 'Get-SigningDecision'
if (-not ($buildStateText -and $buildDecText -and $prepStateText -and $prepDecText)) {
  Bad '找不到签名判定函数（build-apk.ps1 / prepare-release.ps1）' ''
} else {
  $invState = New-ScopedInvoker $buildStateText 'Get-SigningState'
  $invDec = New-ScopedInvoker $buildDecText 'Get-SigningDecision'
  $prepState = New-ScopedInvoker $prepStateText 'Get-SigningState'
  $prepDec = New-ScopedInvoker $prepDecText 'Get-SigningDecision'
  $tmpSign = Join-Path $env:TEMP ("tc-sign-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmpSign | Out-Null
  try {
    $ks = Join-Path $tmpSign 'tomato-release.keystore'
    $pr = Join-Path $tmpSign 'keystore.properties'

    $st = $invState.Invoke($ks, $pr)
    if ($st -eq 'none') { Ok '两个签名文件都不存在 -> 状态 none' } else { Bad '两个都不存在时状态不对' "实际=$st" }
    if ($invDec.Invoke('none', $false) -eq 'block') {
      Ok '两个都不存在 + 未给 -CreateSigningKey -> 停下（不会自动生成签名）'
    } else { Bad '未给开关时不该生成签名' '' }
    if ($invDec.Invoke('none', $true) -eq 'create') {
      Ok '两个都不存在 + 显式 -CreateSigningKey -> 允许首次自签'
    } else { Bad '显式开关后仍不允许首次自签' '' }

    New-Item -ItemType File -Path $ks -Force | Out-Null
    $st = $invState.Invoke($ks, $pr)
    if ($st -eq 'keystore-only') { Ok '只剩密钥文件 -> 状态 keystore-only' } else { Bad '只剩密钥文件时状态不对' "实际=$st" }
    if ($invDec.Invoke('keystore-only', $false) -eq 'block') { Ok '只剩密钥文件 -> 停下' } else { Bad '只剩一半时不该放行' '' }
    if ($invDec.Invoke('keystore-only', $true) -eq 'block') {
      Ok '只剩密钥文件 + -CreateSigningKey -> 仍然停下（部分缺失不接受创建）'
    } else { Bad '部分缺失时不该接受创建开关' '' }

    Remove-Item $ks -Force
    New-Item -ItemType File -Path $pr -Force | Out-Null
    $st = $invState.Invoke($ks, $pr)
    if ($st -eq 'props-only') { Ok '只剩口令文件 -> 状态 props-only' } else { Bad '只剩口令文件时状态不对' "实际=$st" }
    if ($invDec.Invoke('props-only', $true) -eq 'block') {
      Ok '只剩口令文件 + -CreateSigningKey -> 仍然停下'
    } else { Bad '部分缺失时不该接受创建开关' '' }

    New-Item -ItemType File -Path $ks -Force | Out-Null
    $st = $invState.Invoke($ks, $pr)
    if ($st -eq 'both') { Ok '两个都在 -> 状态 both' } else { Bad '两个都在时状态不对' "实际=$st" }
    if ($invDec.Invoke('both', $false) -eq 'reuse' -and $invDec.Invoke('both', $true) -eq 'reuse') {
      Ok '两个都在 -> 复用签名（即使给了 -CreateSigningKey 也不换签名）'
    } else { Bad '已有签名时不该被更换' '' }

    # prepare-release.ps1 里那份判定必须和 build-apk.ps1 一致（防止两份实现漂移）
    $same = $true
    $detail = ''
    foreach ($state in @('none', 'both', 'keystore-only', 'props-only')) {
      foreach ($flag in @($true, $false)) {
        $a = $invState.Invoke($ks, $pr)
        $b = $prepState.Invoke($ks, $pr)
        if ($a -ne $b) { $same = $false; $detail = "state 判定不一致：$a / $b"; break }
        $da = $invDec.Invoke($state, $flag)
        $db = $prepDec.Invoke($state, $flag)
        if ($da -ne $db) { $same = $false; $detail = "decision 不一致：$state + $flag -> $da / $db"; break }
      }
      if (-not $same) { break }
    }
    if ($same) { Ok 'build-apk.ps1 与 prepare-release.ps1 的签名判定完全一致' }
    else { Bad '两个脚本的签名判定不一致' $detail }
  } finally {
    Remove-Item $tmpSign -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# 口令不得出现在任何输出里
$printHits = @()
foreach ($line in ($buildSrc -split "`r?`n")) {
  if ($line -match 'Write-(Host|Output|Verbose|Warning)' -and $line -match '\$ksPwd|\$ksPass|storePassword|keyPassword') {
    $printHits += $line.Trim()
  }
}
if ($printHits.Count -eq 0) { Ok '生成的口令不会被打印到控制台' }
else { Bad '口令被打印了' ($printHits -join ' | ') }

# 不得再出现"删掉密钥重新生成"这类排错建议
if ($buildCode -match '删掉[^\r\n]{0,60}(keystore|密钥)[^\r\n]{0,30}(重新|再)生成') {
  Bad 'build-apk.ps1 里仍有"删掉密钥重新生成"的建议' ''
} else {
  Ok 'build-apk.ps1 不再建议删掉密钥重新生成'
}
if ($buildCode -match '恢复' -and $buildCode -match '备份') {
  Ok '缺签名时给出的指引是"从备份恢复"'
} else { Bad '缺签名时没有给出恢复备份的指引' '' }
if ($buildSrc -match '-CreateSigningKey') { Ok 'build-apk.ps1 有显式的 -CreateSigningKey 首次开关' }
else { Bad 'build-apk.ps1 缺少 -CreateSigningKey 开关' '' }

# ---------------------------------------------------------------- 9. 发布准备脚本
Section '9. prepare-release.ps1：真机验收记录 / 步骤闸门 / 报告（离线、临时目录）'
$devText = Get-FunctionText $prepareSrc 'Test-DeviceAcceptance'
$stepText = Get-FunctionText $prepareSrc 'Assert-StepSucceeded'
$shaText = Get-FunctionText $prepareSrc 'Write-Sha256File'
$repText = Get-FunctionText $prepareSrc 'New-PrepareReport'
if (-not ($devText -and $stepText -and $shaText -and $repText)) {
  Bad 'prepare-release.ps1 里找不到要验证的纯函数' ''
} else {
  $invDev = New-ScopedInvoker $devText 'Test-DeviceAcceptance'
  $invStep = New-ScopedInvoker $stepText 'Assert-StepSucceeded'
  $invSha = New-ScopedInvoker $shaText 'Write-Sha256File'
  $invRep = New-ScopedInvoker $repText 'New-PrepareReport'

  # --- 步骤闸门：非零退出必须停 ---
  $ok = $true
  try { $invStep.Invoke('browser-tests.js', 0) | Out-Null } catch { $ok = $false }
  if ($ok) { Ok '步骤退出码 0 -> 放行' } else { Bad '退出码 0 不该被拦下' '' }
  $stopped = $false
  $msg = ''
  try { $invStep.Invoke('browser-tests.js', 3) | Out-Null } catch { $stopped = $true; $msg = $_.Exception.Message }
  if ($stopped -and $msg -match '3') {
    Ok '步骤退出码非 0 -> 抛错停止（消息里带退出码）'
  } else { Bad '非 0 退出码没有拦住' $msg }
  $stopped = $false
  try { $invStep.Invoke('x', $null) | Out-Null } catch { $stopped = $true }
  if ($stopped) { Ok '步骤没跑起来（退出码为空）也按失败处理' } else { Bad '空退出码被当成了成功' '' }

  # --- 真机验收记录：各种不通过情形 ---
  $tmpDev = Join-Path $env:TEMP ("tc-dev-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmpDev | Out-Null
  try {
    $ver = '9.9.9'
    $hash = ('a' * 64)
    $good = @{
      status = 'passed'; version = $ver; apkSha256 = $hash
      device = @{ model = 'TestPhone'; androidVersion = '14' }
      date = '2026-11-20'
      checks = @{
        notificationAllow = $true; notificationDeny = $true; backgroundRestore = $true
        safSaveCancelImport = $true; sameSignatureUpgrade = $true
      }
    }
    $goodFile = Join-Path $tmpDev 'good.json'
    [IO.File]::WriteAllText($goodFile, ($good | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    $r = $invDev.Invoke('', $ver, $hash)
    if (-not $r.Passed -and $r.Status -eq 'missing-record') {
      Ok '没有提供验收记录 -> 不算通过（绝不默认声称真机通过）'
    } else { Bad '缺记录时的判定不对' ("passed=$($r.Passed) status=$($r.Status)") }

    $r = $invDev.Invoke((Join-Path $tmpDev 'nope.json'), $ver, $hash)
    if (-not $r.Passed) { Ok '验收记录文件不存在 -> 不算通过' } else { Bad '文件不存在却算通过' '' }

    $badFile = Join-Path $tmpDev 'bad.json'
    [IO.File]::WriteAllText($badFile, 'not json at all', [Text.UTF8Encoding]::new($false))
    $r = $invDev.Invoke($badFile, $ver, $hash)
    if (-not $r.Passed -and $r.Status -eq 'invalid-record') { Ok '验收记录不是合法 JSON -> 不算通过' }
    else { Bad '非法 JSON 的判定不对' ("passed=$($r.Passed) status=$($r.Status)") }

    $r = $invDev.Invoke($goodFile, $ver, $hash)
    if ($r.Passed -and $r.Status -eq 'passed') {
      Ok '记录齐全且 status=passed、版本/哈希一致 -> 算通过'
    } else { Bad '合格记录没被判为通过' ("passed=$($r.Passed) status=$($r.Status) reasons=$($r.Reasons -join ';')") }

    $notPassed = $good.Clone(); $notPassed.status = 'failed'
    $f = Join-Path $tmpDev 'notpassed.json'
    [IO.File]::WriteAllText($f, ($notPassed | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $r = $invDev.Invoke($f, $ver, $hash)
    if ((-not $r.Passed) -and (($r.Reasons -join ';') -match 'status')) {
      Ok 'status 不是 passed -> 不算通过，并说明原因'
    } else { Bad 'status 判定不对' ("passed=$($r.Passed) reasons=$($r.Reasons -join ';')") }

    $r = $invDev.Invoke($goodFile, '1.0.0', $hash)
    if ((-not $r.Passed) -and (($r.Reasons -join ';') -match '版本不匹配')) {
      Ok '版本不匹配 -> 不算通过'
    } else { Bad '版本不匹配的判定不对' ("passed=$($r.Passed) reasons=$($r.Reasons -join ';')") }

    $r = $invDev.Invoke($goodFile, $ver, ('b' * 64))
    if ((-not $r.Passed) -and (($r.Reasons -join ';') -match 'SHA-256')) {
      Ok 'APK SHA-256 不匹配 -> 不算通过'
    } else { Bad '哈希不匹配的判定不对' ("passed=$($r.Passed) reasons=$($r.Reasons -join ';')") }

    $noCheck = $good.Clone(); $noCheck.checks = @{ notificationAllow = $true }
    $f2 = Join-Path $tmpDev 'nocheck.json'
    [IO.File]::WriteAllText($f2, ($noCheck | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $r = $invDev.Invoke($f2, $ver, $hash)
    if ((-not $r.Passed) -and (($r.Reasons -join ';') -match 'checks\.') ) {
      Ok '五项检查缺一 -> 不算通过，并点名缺哪一项'
    } else { Bad '缺检查项的判定不对' ("passed=$($r.Passed) reasons=$($r.Reasons -join ';')") }

    $falseCheck = $good.Clone(); $falseCheck.checks = $good.checks.Clone(); $falseCheck.checks.sameSignatureUpgrade = $false
    $f3 = Join-Path $tmpDev 'falsecheck.json'
    [IO.File]::WriteAllText($f3, ($falseCheck | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $r = $invDev.Invoke($f3, $ver, $hash)
    if ((-not $r.Passed) -and (($r.Reasons -join ';') -match 'sameSignatureUpgrade')) {
      Ok '检查项为 false -> 不算通过'
    } else { Bad 'false 检查项的判定不对' ("passed=$($r.Passed) reasons=$($r.Reasons -join ';')") }

    $stringCheck = $good.Clone(); $stringCheck.checks = $good.checks.Clone(); $stringCheck.checks.sameSignatureUpgrade = 'true'
    $stringFile = Join-Path $tmpDev 'string-check.json'
    [IO.File]::WriteAllText($stringFile, ($stringCheck | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $r = $invDev.Invoke($stringFile, $ver, $hash)
    if (-not $r.Passed) { Ok '检查项字符串 true 不能冒充布尔通过' } else { Bad '字符串 true 被误判为通过' '' }
    $invalidDate = $good.Clone(); $invalidDate.date = '2026-02-30'
    $dateFile = Join-Path $tmpDev 'date-check.json'
    [IO.File]::WriteAllText($dateFile, ($invalidDate | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $r = $invDev.Invoke($dateFile, $ver, $hash)
    if (-not $r.Passed) { Ok '不存在的验收日期不能通过' } else { Bad '不存在的日期被误判为通过' '' }

    # --- sha256 文件格式 ---
    $fakeApk = Join-Path $tmpDev 'tomato-clock-9.9.9-release.apk'
    [IO.File]::WriteAllText($fakeApk, 'fake apk bytes', [Text.UTF8Encoding]::new($false))
    $realHash = (Get-FileHash $fakeApk -Algorithm SHA256).Hash.ToLowerInvariant()
    $shaOut = Join-Path $tmpDev 'out.sha256'
    $invSha.Invoke($fakeApk, $realHash, $shaOut) | Out-Null
    $line = (Get-Content $shaOut -Raw -Encoding UTF8).Trim()
    $expected = "$realHash  tomato-clock-9.9.9-release.apk"
    if ($line -eq $expected) { Ok 'sha256 文件内容是 sha256sum 兼容格式（哈希 + 两个空格 + 文件名）' }
    else { Bad 'sha256 文件格式不对' "实际=$line 期望=$expected" }

    # --- 报告内容 ---
    $deviceFail = $invDev.Invoke('', $ver, $hash)
    $auto = @{ browserRegression = 'passed'; buildScriptChecks = 'passed'; releaseBuild = 'passed' }
    $rep = $invRep.Invoke($ver, $fakeApk, $realHash, $shaOut, $auto, 'reuse', $deviceFail)
    if ($rep.releaseReady -eq $false) { Ok '真机未通过 -> 报告里 releaseReady=false' }
    else { Bad '真机未通过却标成发布就绪' '' }
    $repJson = $rep | ConvertTo-Json -Depth 8
    if ($repJson -match 'version' -and $repJson -match 'sha256' -and $repJson -match 'automatedChecks' -and $repJson -match 'deviceAcceptance') {
      Ok '报告含版本 / APK / hash / 自动检查结果 / 真机验收状态'
    } else { Bad '报告字段不全' '' }
    if ($repJson -notmatch 'storePassword|keyPassword|Password=') { Ok '报告里不含任何口令字段' }
    else { Bad '报告里出现了口令字段' '' }

    $devicePass = $invDev.Invoke($goodFile, $ver, $hash)
    $rep2 = $invRep.Invoke($ver, $fakeApk, $realHash, $shaOut, $auto, 'reuse', $devicePass)
    if ($rep2.releaseReady -eq $true) { Ok '自动检查通过 + 真机通过 -> releaseReady=true' }
    else { Bad '全部通过却没标成发布就绪' '' }
  } finally {
    Remove-Item $tmpDev -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- 版本号一致性：临时目录里的三份文件 ---
$verText = Get-FunctionText $prepareSrc 'Get-ProjectVersion'
if (-not $verText) {
  Bad 'prepare-release.ps1 里找不到 Get-ProjectVersion' ''
} else {
  $invVer = New-ScopedInvoker $verText 'Get-ProjectVersion'
  $tmpVer = Join-Path $env:TEMP ("tc-ver-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmpVer | Out-Null
  try {
    $pj = Join-Path $tmpVer 'package.json'
    $lk = Join-Path $tmpVer 'package-lock.json'
    $gr = Join-Path $tmpVer 'build.gradle'
    [IO.File]::WriteAllText($pj, '{"version":"9.9.9"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($lk, '{"version":"9.9.9","packages":{"":{"version":"9.9.9"}}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($gr, ('versionCode 42' + "`n" + 'versionName "9.9.9"'), [Text.UTF8Encoding]::new($false))
    $v = $invVer.Invoke($pj, $lk, $gr)
    if ($v.Version -eq '9.9.9' -and $v.VersionCode -eq '42') {
      Ok '三处版本号一致 -> 通过并取出 version / versionCode'
    } else { Bad '版本号一致时的返回值不对' ($v | ConvertTo-Json -Depth 3) }

    [IO.File]::WriteAllText($lk, '{"version":"9.9.9","packages":{"":{"version":"1.0.0"}}}', [Text.UTF8Encoding]::new($false))
    $threw = $false
    try { $invVer.Invoke($pj, $lk, $gr) | Out-Null } catch { $threw = $true }
    if ($threw) { Ok 'lockfile 版本不一致 -> 抛错中止' } else { Bad 'lockfile 版本不一致没有拦住' '' }

    [IO.File]::WriteAllText($lk, '{"version":"9.9.9","packages":{"":{"version":"9.9.9"}}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($gr, ('versionCode 42' + "`n" + 'versionName "1.0.0"'), [Text.UTF8Encoding]::new($false))
    $threw = $false
    try { $invVer.Invoke($pj, $lk, $gr) | Out-Null } catch { $threw = $true }
    if ($threw) { Ok 'build.gradle 版本不一致 -> 抛错中止' } else { Bad 'build.gradle 版本不一致没有拦住' '' }
    $threw = $false
    try { $invVer.Invoke($pj, (Join-Path $tmpVer 'missing-lock.json'), $gr) | Out-Null } catch { $threw = $true }
    if ($threw) { Ok '缺少 lockfile -> 中止准备' } else { Bad '缺少 lockfile 仍被放行' '' }
    [IO.File]::WriteAllText($gr, 'versionName "9.9.9"', [Text.UTF8Encoding]::new($false))
    $threw = $false
    try { $invVer.Invoke($pj, $lk, $gr) | Out-Null } catch { $threw = $true }
    if ($threw) { Ok '缺少 versionCode -> 中止准备' } else { Bad '缺少 versionCode 仍被放行' '' }
  } finally {
    Remove-Item $tmpVer -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# prepare-release.ps1 的结构约束（补充检查）
if ($prepareCode -match "Push-Location\s+\`$RepoRoot" -and $prepareCode -match "browser-tests\.js") {
  Ok 'prepare-release.ps1 在仓库根目录里跑回归脚本'
} else { Bad 'prepare-release.ps1 没有在仓库根目录跑回归脚本' '' }
$gateCount = ([regex]::Matches($prepareCode, 'Assert-StepSucceeded\s+-StepName')).Count
if ($gateCount -ge 3) { Ok "prepare-release.ps1 对 3 个子步骤都做了非零退出即停（$gateCount 处）" }
else { Bad 'prepare-release.ps1 的步骤闸门不够' "只有 $gateCount 处" }
if ($prepareCode -match '找不到目标 APK') { Ok 'prepare-release.ps1 会校验目标 APK 存在' }
else { Bad 'prepare-release.ps1 没有校验 APK 存在' '' }
if ($prepareCode -match '_out\\release') { Ok '产物与报告落在 _out\release\<版本>\（已 gitignore）' }
else { Bad 'prepare-release.ps1 的产物目录不是 _out\release' '' }
if ($prepareCode -match '(WriteAllText|Set-Content|Out-File|Add-Content)[^\r\n]*\$DeviceAcceptance') {
  Bad 'prepare-release.ps1 会写验收记录文件（应该只读）' ''
} else {
  Ok 'prepare-release.ps1 只读验收记录，不会替人伪造一份记录'
}
$prepareTokens = $null; $prepareErrors = $null
$prepareAst = [System.Management.Automation.Language.Parser]::ParseInput($prepareSrc, [ref]$prepareTokens, [ref]$prepareErrors)
$publishCommands = @($prepareAst.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('git','gh')}, $true))
if ($publishCommands.Count -gt 0) {
  Bad 'prepare-release.ps1 含有 git / 发布动作' ''
} else {
  Ok 'prepare-release.ps1 不做 commit / push / 上传 Release'
}

Write-Host ""
if ($script:Fail -eq 0) {
  Write-Host "全部通过：$($script:Pass) 项" -ForegroundColor Green
  exit 0
} else {
  Write-Host "通过 $script:Pass 项，失败 $script:Fail 项" -ForegroundColor Red
  exit 1
}
