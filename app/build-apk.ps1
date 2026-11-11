# 番茄钟 —— Windows 一键装工具并打 Android 包（默认 debug）
# 用法（仓库根目录或 app/ 下都行）：
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1            # debug 包
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Release   # release 包（复用已有签名）
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Install   # 打完直接装到已连线的手机
# 签名（release）：
#   默认【复用】已有的 app\android\tomato-release.keystore + keystore.properties。
#   两个文件必须成对存在：只剩一个就停下让你从备份恢复（脚本不会删、不会重生成、不会换钥匙）。
#   两个都不存在时，只有显式加 -CreateSigningKey 才会创建（仅用于首次自行签发）：
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Release -CreateSigningKey
#   创建后请把这两个文件备份到【仓库之外】；脚本不打印口令，也不会把密钥上传到任何地方。
# 幂等：已有 Node/JDK/SDK/Gradle 会复用（工具统一装在 %USERPROFILE%\tools\下），缺什么补什么。
# 产物：会复制一份到仓库根 _out\apk\ 下（带版本号的文件名），原始产物仍在
#   app\android\app\build\outputs\apk\debug\app-debug.apk 或 ...\release\app-release.apk
# 国内网络默认走镜像（Node 淘宝 / Gradle 腾讯 / Maven 阿里）。
# 装完手机后请按 docs\ACCEPTANCE.md 逐条验收。

param([switch]$Release, [switch]$Install, [switch]$CreateSigningKey, [switch]$RunTests)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $AppRoot
$AndroidDir = Join-Path $AppRoot 'android'
$ToolsRoot = Join-Path $env:USERPROFILE 'tools'
$JdkDir = Join-Path $ToolsRoot 'jdk-21'
$SdkDir = Join-Path $ToolsRoot 'android-sdk'
$GradleDir = Join-Path $ToolsRoot 'gradle-8.11.1'
$MirrorInit = Join-Path $AndroidDir 'mirrors.init.gradle'
$OutDir = Join-Path $RepoRoot '_out\apk'

# 工具目录先建出来：以前 Node 那一步是"先下载再创建目录"，
# 全新机器上 tools\ 还不存在时 curl 直接失败（目标目录不存在），一步都走不下去。

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 签名状态（纯函数）
# 签名是"能不能覆盖安装"的唯一凭据：换一把钥匙，用户手机上的旧包就盖不住，
# 系统会直接拒绝安装，只能卸载重装 —— 而专注记录全在 localStorage 里，卸载一次就没了。
# 所以这里只有三种结局：复用 / 首次显式创建 / 停下要求恢复备份。没有"顺手重建一把"这条路。
function Get-SigningState {
  param([string]$KeystorePath, [string]$PropsPath)
  $hasKs = [bool](Test-Path $KeystorePath)
  $hasPr = [bool](Test-Path $PropsPath)
  if ($hasKs -and $hasPr) { return 'both' }
  if ($hasKs) { return 'keystore-only' }
  if ($hasPr) { return 'props-only' }
  return 'none'
}
function Get-SigningDecision {
  param([string]$State, [bool]$CreateRequested)
  switch ($State) {
    'both' { return 'reuse' }
    'none' {
      if ($CreateRequested) { return 'create' }
      return 'block'
    }
    default { return 'block' }   # 只剩一半：给不给 -CreateSigningKey 都停下
  }
}
if ($Release) {
  $earlyState = Get-SigningState -KeystorePath (Join-Path $AndroidDir 'tomato-release.keystore') -PropsPath (Join-Path $AndroidDir 'keystore.properties')
  if ((Get-SigningDecision -State $earlyState -CreateRequested ([bool]$CreateSigningKey)) -eq 'block') {
    throw '签名文件缺失或不成对，请先从备份恢复原文件。只有首次自行签发、两个文件都不存在时，才可显式使用 -CreateSigningKey。尚未下载工具或构建。'
  }
}
New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
# Java .properties 的值转义：逐字符处理，顺序不能错。
#   反斜杠 -> \\   冒号 -> \:   非 ASCII 字符 -> \uXXXX
# 为什么非 ASCII 要转成 \uXXXX：.properties 文件按 ISO-8859-1 读，
# 直接写 UTF-8 的中文路径会被读成乱码，Gradle 就找不到 SDK 了。
# 转成 \uXXXX 之后文件里全是 ASCII，两种读取方式都正确。
# 例：C:\Users\张三\AppData\Local\Android\Sdk
#     -> C\:\\Users\\u5f20\\u4e09\\AppData\\Local\\Android\\Sdk
function ConvertTo-PropertiesValue([string]$Value) {
  if ($null -eq $Value) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $Value.ToCharArray()) {
    $code = [int][char]$ch
    if ($ch -eq '\') { $null = $sb.Append('\\') }
    elseif ($ch -eq ':') { $null = $sb.Append('\:') }
    elseif ($code -gt 127) { $null = $sb.Append(('\u{0:x4}' -f $code)) }
    else { $null = $sb.Append($ch) }
  }
  return $sb.ToString()
}
function Get-File($url, $dest) {
  Write-Host "  download $url"
  curl.exe -L --retry 3 --connect-timeout 30 -o $dest $url
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dest)) { throw "download failed: $url" }
}
function Get-FileOrNull($url, $dest, $minBytes, $sha256) {
  # 所有工具压缩包都必须绑定权威 SHA-256；体积只能挡错误页，不能替代完整性校验。
  if ($sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "missing/invalid SHA-256 for $url" }
  try {
    Get-File $url $dest
    if ((Get-Item $dest).Length -le $minBytes) {
      Write-Warn2 "too small, treat as fail: $url"
      return $false
    }
    $actual = (Get-FileHash $dest -Algorithm SHA256).Hash
    if ($actual -ne $sha256) {
      Write-Warn2 "SHA-256 mismatch, reject download: $url"
      return $false
    }
    Write-Host "  SHA-256 verified: $($actual.ToLowerInvariant())"
    return $true
  } catch { Write-Warn2 "mirror fail: $url" }
  return $false
}

# ---------------------------------------------------------------- version consistency
# package.json 的 version 决定 APK 文件名，build.gradle 的 versionName/versionCode 决定
# 手机上显示的版本。三处不一致会打出「文件名 1.4.0、装上却显示 1.3.0」的包，这里提前拦住。
$verPkg = Join-Path $AppRoot 'package.json'
$verLock = Join-Path $AppRoot 'package-lock.json'
$verGradle = Join-Path $AndroidDir 'app\build.gradle'
if ((Test-Path $verPkg) -and (Test-Path $verGradle)) {
  $pkgVersion = (Get-Content $verPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version
  $gradleText = Get-Content $verGradle -Raw -Encoding UTF8
  $nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')
  $codeMatch = [regex]::Match($gradleText, 'versionCode\s+(\d+)')
  if (-not $nameMatch.Success -or -not $codeMatch.Success) {
    throw 'app\android\app\build.gradle 里找不到 versionName / versionCode，无法校验版本号'
  }
  $gradleVersion = $nameMatch.Groups[1].Value
  if ($gradleVersion -ne $pkgVersion) {
    throw "版本号不一致：app\package.json = $pkgVersion，build.gradle versionName = $gradleVersion。改一致后再打包。"
  }
  # lockfile 顶层 version 与 packages[""].version 都是项目版本，必须同时跟上。
  if (Test-Path $verLock) {
    # PS 5.1 的 ConvertFrom-Json 拒绝空字符串键；仅把 packages 的根键临时改成哨兵再解析。
    $lockText = Get-Content $verLock -Raw -Encoding UTF8
    $lockNormalized = [regex]::Replace($lockText, '(?m)("packages"\s*:\s*\{\s*)""(\s*:)', '$1"__tomato_root_package__"$2')
    $lock = $lockNormalized | ConvertFrom-Json
    $lockVersion = $lock.version
    $lockRootVersion = if ($lock.packages) { $lock.packages.__tomato_root_package__.version } else { $null }
    if (-not $lockVersion -or -not $lockRootVersion) {
      throw 'app\package-lock.json 缺少顶层 version 或 packages[""].version，无法校验版本号'
    }
    if ($lockVersion -ne $pkgVersion -or $lockRootVersion -ne $pkgVersion) {
      throw "版本号不一致：app\package.json = $pkgVersion，package-lock.json 顶层 = $lockVersion，packages root = $lockRootVersion。同步后再打包。"
    }
  }
  Write-Host "  version $pkgVersion (versionCode $($codeMatch.Groups[1].Value))"
} else {
  Write-Warn2 '跳过版本号校验（找不到 package.json 或 build.gradle）'
}

# ---------------------------------------------------------------- Node.js
# 以前这一步完全靠系统自带 Node，新机器上最容易卡住；这里缺就自动装。
Write-Step 'Prepare Node.js (Capacitor CLI needs >= v20)'
$NodeVer = 'v22.20.0'
$NodeDir = Join-Path $ToolsRoot "node\$NodeVer"
$nodeOK = $false
$sysNode = Get-Command node -ErrorAction SilentlyContinue
if ($sysNode) {
  $v = (& node -v) 2>$null
  if ($v -match '^v(\d+)\.' -and [int]$Matches[1] -ge 20) {
    Write-Host "  reuse system node $v"; $nodeOK = $true
  } else {
    Write-Warn2 "system node ($v) too old, need >= v20"
  }
}
if (-not $nodeOK) {
  if (Test-Path (Join-Path $NodeDir 'node.exe')) {
    Write-Host "  reuse $NodeDir"
  } else {
    $zip = Join-Path $ToolsRoot "node-$NodeVer.zip"
    # 官方来源：https://nodejs.org/dist/v22.20.0/SHASUMS256.txt
    # 镜像与官方是同一文件，因此复用同一个哈希。
    $nodeSha256 = 'bb819d6eb8f5bfda294bbc83a7e4ec6539da67c4233d54b0d655b9248b15e29d'
    $got = $false
    foreach ($u in @(
        "https://npmmirror.com/mirrors/node/$NodeVer/node-$NodeVer-win-x64.zip",
        "https://nodejs.org/dist/$NodeVer/node-$NodeVer-win-x64.zip")) {
      if (Get-FileOrNull $u $zip 20MB $nodeSha256) { $got = $true; break }
    }
    if (-not $got) { throw 'all Node mirrors failed' }
    $tmp = Join-Path $ToolsRoot 'node-extract'
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $src) { throw "unexpected node zip layout: $zip" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NodeDir) | Out-Null
    if (Test-Path $NodeDir) { Remove-Item $NodeDir -Recurse -Force }
    Move-Item $src.FullName $NodeDir
    Remove-Item $tmp -Recurse -Force
    Remove-Item $zip -Force
    Write-Host "  installed -> $NodeDir"
  }
  $env:PATH = "$NodeDir;$env:PATH"
  $nodeOK = $true
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'node still not found after install step' }

# ---------------------------------------------------------------- JDK 21
Write-Step 'Prepare JDK 21'
if (Test-Path (Join-Path $JdkDir 'bin\java.exe')) {
  Write-Host "  reuse $JdkDir"
} else {
  New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
  $zip = Join-Path $ToolsRoot 'temurin21.zip'
  # 国内优先、官方兜底。所有候选都是固定版本，并绑定各自发布方给出的 SHA-256。
  # 不使用 Adoptium latest：动态目标没有可复现的固定哈希。
  # 华为：https://mirrors.huaweicloud.com/openjdk/21/openjdk-21_windows-x64_bin.zip.sha256
  #      https://mirrors.huaweicloud.com/openjdk/21.0.2/openjdk-21.0.2_windows-x64_bin.zip.sha256
  # Adoptium 固定 release 校验值：
  # https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip.sha256.txt
  # 下载链接同样固定为 jdk-21.0.13+9，不从动态 API 决定构建输入。
  $jdkSources = @(
    @{ Url = 'https://mirrors.huaweicloud.com/openjdk/21/openjdk-21_windows-x64_bin.zip'
       Sha256 = '5434faaf029e66e7ce6e75770ca384de476750984a7d2881ef7686894c4b4944' },
    @{ Url = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip'
       Sha256 = 'a4dbaa05fca4bd89d84584e58c459bd732efebb1722af80ab13c6516832004f9' },
    @{ Url = 'https://mirrors.huaweicloud.com/openjdk/21.0.2/openjdk-21.0.2_windows-x64_bin.zip'
       Sha256 = 'b6c17e747ae78cdd6de4d7532b3164b277daee97c007d3eaa2b39cca99882664' }
  )
  $gotJdk = $false
  foreach ($source in $jdkSources) {
    if (Get-FileOrNull $source.Url $zip 150MB $source.Sha256) { $gotJdk = $true; break }
  }
  if (-not $gotJdk) { throw 'all JDK mirrors failed' }
  $tmp = Join-Path $ToolsRoot 'jdk-extract'
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $dir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'jdk*' } | Select-Object -First 1
  if (-not $dir) { throw "unexpected JDK zip layout: $zip" }
  if (Test-Path $JdkDir) { Remove-Item $JdkDir -Recurse -Force }
  Move-Item $dir.FullName $JdkDir
  Remove-Item $tmp -Recurse -Force
  Remove-Item $zip -Force
}
$env:JAVA_HOME = $JdkDir

# ---------------------------------------------------------------- Android SDK
Write-Step 'Prepare Android SDK (cmdline-tools + platform 35 + build-tools)'
$sdkm = Join-Path $SdkDir 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path $sdkm)) {
  New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
  $zip = Join-Path $ToolsRoot 'cmdline-tools.zip'
  # 同理：dl.google.com 国内经常连不上，先试腾讯的 AndroidSDK 镜像，再回落官方。
  # Google repository2-3.xml 只公布此包的 SHA-1；SHA-256 来源为 Qt 官方仓库中同一 Google 下载件：
  # https://code.qt.io/cgit/qt-creator/qt-creator.git/tree/share/qtcreator/android/sdk_definitions.json
  $cmdSha256 = '4d6931209eebb1bfb7c7e8b240a6a3cb3ab24479ea294f3539429574b1eec862'
  $cmdSources = @(
    'https://mirrors.cloud.tencent.com/AndroidSDK/commandlinetools-win-11076708_latest.zip',
    'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'
  )
  $gotCmd = $false
  foreach ($u in $cmdSources) {
    if (Get-FileOrNull $u $zip 100MB $cmdSha256) { $gotCmd = $true; break }
  }
  if (-not $gotCmd) { throw 'all cmdline-tools mirrors failed' }
  $tmp = Join-Path $SdkDir 'cmdline-tools-temp'
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $SdkDir 'cmdline-tools') | Out-Null
  Move-Item (Join-Path $tmp 'cmdline-tools') (Join-Path $SdkDir 'cmdline-tools\latest')
  Remove-Item $tmp -Recurse -Force
  Remove-Item $zip -Force
}
$env:ANDROID_HOME = $SdkDir
$sdkReady = (Test-Path (Join-Path $SdkDir 'platform-tools\adb.exe')) -and
  (Test-Path (Join-Path $SdkDir 'platforms\android-35\android.jar')) -and
  (Test-Path (Join-Path $SdkDir 'build-tools\35.0.0\aapt2.exe')) -and
  (Test-Path (Join-Path $SdkDir 'build-tools\35.0.0\apksigner.bat'))
if ($sdkReady) {
  Write-Host '  reuse installed Android platform 35 / build-tools 35 / platform-tools'
} else {
  1..30 | ForEach-Object { 'y' } | & $sdkm --sdk_root=$SdkDir --licenses | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'sdkmanager license acceptance failed' }
  & $sdkm --sdk_root=$SdkDir 'platform-tools' 'platforms;android-35' 'build-tools;35.0.0' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'sdkmanager install failed' }
}

# ---------------------------------------------------------------- Gradle
Write-Step 'Prepare Gradle 8.11.1'
$gradleBin = Join-Path $GradleDir 'bin\gradle.bat'
if (Test-Path $gradleBin) {
  Write-Host "  reuse $GradleDir"
} else {
  $zip = Join-Path $ToolsRoot 'gradle-8.11.1-all.zip'
  # 官方来源：https://services.gradle.org/distributions/gradle-8.11.1-all.zip.sha256
  $gradleSha256 = '89d4e70e4e84e2d2dfbb63e4daa53e21b25017cc70c37e4eea31ee51fb15098a'
  $mirrors = @(
    'https://mirrors.cloud.tencent.com/gradle/gradle-8.11.1-all.zip',
    'https://mirrors.huaweicloud.com/gradle/gradle-8.11.1-all.zip',
    'https://services.gradle.org/distributions/gradle-8.11.1-all.zip'
  )
  $got = $false
  foreach ($u in $mirrors) {
    if (Get-FileOrNull $u $zip 10MB $gradleSha256) { $got = $true; break }
  }
  if (-not $got) { throw 'all Gradle mirrors failed' }
  Expand-Archive -Path $zip -DestinationPath $ToolsRoot -Force
  Remove-Item $zip -Force
}

# ---------------------------------------------------------------- mirrors + local.properties
Write-Step 'Write project Gradle mirror config and local.properties'
# 镜像配置写成【本项目专用】的 init 脚本，构建时用 --init-script 显式加载，只对这一次构建生效。
# 以前是写 %USERPROFILE%\.gradle\init.gradle —— 那是全局配置，对本机所有 Gradle 工程生效，
# 覆盖它会顺手改掉别的项目的仓库设置。现在不再碰用户的全局配置。
$init = @"
// CN mirrors for Gradle deps —— 仅用于本项目这一次构建（--init-script 显式加载）
allprojects {
  buildscript {
    repositories {
      maven { url 'https://maven.aliyun.com/repository/google' }
      maven { url 'https://maven.aliyun.com/repository/public' }
      maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
    }
  }
  repositories {
    maven { url 'https://maven.aliyun.com/repository/google' }
    maven { url 'https://maven.aliyun.com/repository/public' }
    maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
  }
}
"@
[IO.File]::WriteAllText($MirrorInit, $init, [Text.UTF8Encoding]::new($false))
Write-Host "  $MirrorInit"

# local.properties 是 Java .properties 格式：反斜杠和冒号必须转义，
# 否则 Gradle 读出来是一串乱码（路径里有空格或中文时必炸）。
$sdkProp = ConvertTo-PropertiesValue $SdkDir
[IO.File]::WriteAllText((Join-Path $AndroidDir 'local.properties'), "sdk.dir=$sdkProp`n", [Text.UTF8Encoding]::new($false))
Write-Host "  sdk.dir=$sdkProp"

# ---------------------------------------------------------------- release keystore
$signMode = 'debug'
if ($CreateSigningKey -and -not $Release) {
  Write-Warn2 '-CreateSigningKey 只对 -Release 有意义（debug 包不需要签名），本次忽略。'
}
if ($Release) {
  Write-Step 'Prepare release keystore'
  $ksFile = Join-Path $AndroidDir 'tomato-release.keystore'
  $ksProps = Join-Path $AndroidDir 'keystore.properties'
  $ksState = Get-SigningState -KeystorePath $ksFile -PropsPath $ksProps
  $ksDecision = Get-SigningDecision -State $ksState -CreateRequested ([bool]$CreateSigningKey)
  if ($ksDecision -eq 'block') {
    if ($ksState -eq 'none') {
      throw ("找不到签名文件：{0} / {1}" -f $ksFile, $ksProps) +
            "`n  · 以前签过、文件弄丢了：从你的备份把这两个文件恢复回来再跑（不要重新生成一把新的）。" +
            "`n  · 第一次自己签发：显式加 -CreateSigningKey 再跑一次（仅此一次；之后一直复用同一把钥匙）。"
    }
    throw ("签名文件只剩一半：{0} 与 {1} 必须成对存在" -f $ksFile, $ksProps) +
          "`n  · 请从备份恢复缺的那个文件后重试。" +
          "`n  · 不要删掉已经存在的那一个来凑成对：删了就等于换了一把新钥匙，手机上的旧包盖不住，" +
          "只能卸载重装，专注记录会一起没。" +
          "`n  · 这种情况下 -CreateSigningKey 也会被拒绝：它只用于两个文件都不存在时的首次自签。"
  }
  if ($ksDecision -eq 'create') {
    # 首次自行签发：只在用户显式要求时创建，只留本机，脚本不打印口令、也不上传
    $keytool = Join-Path $JdkDir 'bin\keytool.exe'
    if (-not (Test-Path $keytool)) { throw "找不到 keytool：$keytool（JDK 是不是没装好？）" }
    $ksPwd = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $env:TOMATO_KS_PASS = $ksPwd
    $genCode = 1
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # keytool 的 stderr 不应该把脚本打断
    try {
      # 优先 -storepass:env：口令不落在命令行参数里（本机其它进程看不到进程命令行）
      & $keytool -genkeypair -v -keystore $ksFile -alias tomato -keyalg RSA -keysize 2048 -validity 10950 `
        -storepass:env TOMATO_KS_PASS -keypass:env TOMATO_KS_PASS -dname 'CN=TomatoClock, OU=Home, O=Tomato, L=Local, C=CN'
      $genCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $prevEap
      Remove-Item Env:\TOMATO_KS_PASS -ErrorAction SilentlyContinue
    }
    if ($genCode -ne 0 -or -not (Test-Path $ksFile)) { throw 'keytool genkeypair failed（签名密钥没有生成成功）' }
    $props = @(
      'storeFile=tomato-release.keystore',
      "storePassword=$ksPwd",
      'keyAlias=tomato',
      "keyPassword=$ksPwd"
    ) -join "`n"
    [IO.File]::WriteAllText($ksProps, "$props`n", [Text.UTF8Encoding]::new($false))
    Write-Host ''
    Write-Host '  已创建新的签名密钥 —— 这是你自己签的包，' -ForegroundColor Yellow
    Write-Host '  和作者发布的包不是同一把钥匙，两边不能互相覆盖安装。' -ForegroundColor Yellow
    Write-Host "  密钥文件：$ksFile"
    Write-Host "  口令文件：$ksProps（口令只写在这里，脚本不会打印它）"
    Write-Host '  ⚠ 请马上把这两个文件复制到【仓库之外】备份（网盘 / 移动硬盘都行）。' -ForegroundColor Yellow
    Write-Host '  ⚠ 别放进仓库、别上传到 GitHub —— 泄漏了等于别人能签出你的包。' -ForegroundColor Yellow
    Write-Host '  ⚠ 丢了就等于换了一把新钥匙：旧包盖不住，只能卸载重装，专注记录会一起没。' -ForegroundColor Yellow
    $signMode = 'create'
  } else {
    $signMode = 'reuse'
    Write-Host "  reuse $ksFile（复用同一把钥匙，手机上的旧包可以直接覆盖升级）"
  }

  # build.gradle 只在 keystore.properties 存在时才声明 signingConfig，
  # 少一个字段就会静默退回未签名包 —— 这里先替 Gradle 查一遍，早失败好过装到手机上才发现
  $kv = @{}
  Get-Content $ksProps -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*([^=]+)=(.*)$') { $kv[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
  foreach ($need in @('storeFile', 'storePassword', 'keyAlias', 'keyPassword')) {
    if (-not $kv.ContainsKey($need) -or -not $kv[$need]) { throw "keystore.properties 缺少字段：$need" }
  }
  if (-not (Test-Path (Join-Path $AndroidDir $kv['storeFile']))) {
    throw "keystore.properties 指向的密钥文件不存在：$($kv['storeFile'])"
  }
  Write-Host '  keystore.properties 校验通过'
}

# ---------------------------------------------------------------- npm deps
# 以前只看 node_modules 在不在，package.json 改了也不会重装；现在按 lockfile 指纹判断。
Write-Step 'Install app dependencies'
$pkgJson = Join-Path $AppRoot 'package.json'
$pkgLock = Join-Path $AppRoot 'package-lock.json'
$stamp = Join-Path $AppRoot 'node_modules\.deps-stamp'
$hash = ''
if ((Test-Path $pkgJson) -and (Test-Path $pkgLock)) {
  $hash = (Get-FileHash $pkgJson -Algorithm SHA256).Hash + ':' + (Get-FileHash $pkgLock -Algorithm SHA256).Hash
}
$needDeps = $true
if (Test-Path $stamp) {
  if ((Get-Content $stamp -Raw -Encoding UTF8).Trim() -eq $hash) {
    Write-Host '  依赖已是最新（package.json / lockfile 未变动）'; $needDeps = $false
  }
}
if ($needDeps) {
  Push-Location $AppRoot
  try {
    # registry 也要兜底：脚本原来完全依赖用户全局的 ~/.npmrc。
    # 全新机器上没有这个文件时，npm 会直连 registry.npmjs.org（慢 / 超时）。
    # 这里用 --registry 显式指定，【不改】用户的全局 npm 配置，也不往仓库里塞 .npmrc。
    # 先试国内镜像，再回落官方源；两个都试过还不行才退到 npm install。
    $registries = @('https://registry.npmmirror.com', 'https://registry.npmjs.org')
    $installed = $false
    foreach ($reg in $registries) {
      $regArgs = @('--no-audit', '--no-fund', '--fetch-retries=3', '--fetch-timeout=120000', "--registry=$reg")
      $regLabel = $reg
      if (Test-Path $pkgLock) {
        npm ci @regArgs
        if ($LASTEXITCODE -eq 0) { $installed = $true; break }
        Write-Warn2 "npm ci 失败（registry=$regLabel）"
      } else {
        npm install @regArgs
        if ($LASTEXITCODE -eq 0) { $installed = $true; break }
      }
    }
    if (-not $installed) {
      Write-Warn2 'npm ci 全部失败，回退 npm install（lockfile 可能与 package.json 不同步）'
      npm install --no-audit --no-fund --fetch-retries=3 --fetch-timeout=120000 --registry=https://registry.npmjs.org
      if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
    }
  } finally { Pop-Location }
  New-Item -ItemType Directory -Force -Path (Join-Path $AppRoot 'node_modules') | Out-Null
  [IO.File]::WriteAllText($stamp, "$hash`n", [Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------- build
$gradleTask = if ($Release) { 'assembleRelease' } else { 'assembleDebug' }
Write-Step "Capacitor sync + $gradleTask"
Push-Location $AppRoot
try {
  npx cap sync android
  if ($LASTEXITCODE -ne 0) { throw 'cap sync failed' }
} finally { Pop-Location }

Push-Location $AndroidDir
try {
  # --init-script 只对这一次构建生效，不会改用户全局的 Gradle 配置
  $gradleTasks = @($gradleTask)
  if ($RunTests) { $gradleTasks = @(':app:testDebugUnitTest') + $gradleTasks }
  & $gradleBin @gradleTasks --no-daemon --init-script $MirrorInit
  if ($LASTEXITCODE -ne 0) { throw "$gradleTask failed ($LASTEXITCODE)" }
} finally { Pop-Location }

# ---------------------------------------------------------------- collect output
$apkDir = if ($Release) {
  Join-Path $AndroidDir 'app\build\outputs\apk\release'
} else {
  Join-Path $AndroidDir 'app\build\outputs\apk\debug'
}
$built = @(Get-ChildItem $apkDir -Filter '*.apk' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if (-not $built.Count) { throw "APK not found in $apkDir" }
$srcApk = $built[0]
if ($Release -and $srcApk.Name -like '*-unsigned*') {
  throw "Gradle 只产出了未签名包 $($srcApk.Name)：签名配置没生效，请检查 app\android\keystore.properties"
}

$appVer = '1.0.0'
# 必须显式 UTF-8：package.json 无 BOM，PS 5.1 的 Get-Content 会按 GBK 读，
# 中文 description 被读坏后整个 JSON 解析失败
if (Test-Path $pkgJson) { $appVer = (Get-Content $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).version }
$flavor = if ($Release) { 'release' } else { 'debug' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outApk = Join-Path $OutDir "tomato-clock-$appVer-$flavor.apk"
Copy-Item $srcApk.FullName $outApk -Force

Write-Step 'Done'
Write-Host "APK    : $outApk" -ForegroundColor Green
Write-Host "原始产物: $($srcApk.FullName)"
Write-Host "大小   : $([math]::Round((Get-Item $outApk).Length / 1MB, 2)) MB"
if ($signMode -eq 'create') {
  Write-Host '签名   : 本次新建（自签包，与作者发布的包不能互相覆盖安装）' -ForegroundColor Yellow
} elseif ($signMode -eq 'reuse') {
  Write-Host '签名   : 复用已有签名（与之前打的 release 包同一把钥匙）'
} else {
  Write-Host '签名   : debug 包（未使用 release 签名）'
}

if ($Install) {
  & (Join-Path $AppRoot 'install-to-phone.ps1') -Apk $outApk
} else {
  Write-Host "`n装到手机：把上面这个 APK 传过去点击安装（首次需允许「未知来源」），"
  Write-Host "或手机开了 USB 调试后执行： powershell -ExecutionPolicy Bypass -File app\install-to-phone.ps1"
  Write-Host "或打包时直接加 -Install 一条龙。"
}
Write-Host "`n装完请按 docs\ACCEPTANCE.md 逐条验收（build-apk.ps1 末尾引用了这份清单）。"
