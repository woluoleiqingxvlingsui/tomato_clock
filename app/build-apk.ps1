# 番茄钟 —— Windows 一键装工具并打 Android 包（默认 debug）
# 用法（仓库根目录或 app/ 下都行）：
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1            # debug 包
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Release   # release 包（首次自动生成签名）
#   powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Install   # 打完直接装到已连线的手机
# 幂等：已有 Node/JDK/SDK/Gradle 会复用（工具统一装在 %USERPROFILE%\tools\下），缺什么补什么。
# 产物：会复制一份到仓库根 _out\apk\ 下（带版本号的文件名），原始产物仍在
#   app\android\app\build\outputs\apk\debug\app-debug.apk 或 ...\release\app-release.apk
# 国内网络默认走镜像（Node 淘宝 / Gradle 腾讯 / Maven 阿里）。
# 装完手机后请按 docs\ACCEPTANCE.md 逐条验收。

param([switch]$Release, [switch]$Install)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $AppRoot
$AndroidDir = Join-Path $AppRoot 'android'
$ToolsRoot = Join-Path $env:USERPROFILE 'tools'
$JdkDir = Join-Path $ToolsRoot 'jdk-21'
$SdkDir = Join-Path $ToolsRoot 'android-sdk'
$GradleDir = Join-Path $ToolsRoot 'gradle-8.11.1'
$InitGradle = Join-Path $env:USERPROFILE '.gradle\init.gradle'
$OutDir = Join-Path $RepoRoot '_out\apk'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Get-File($url, $dest) {
  Write-Host "  download $url"
  curl.exe -L --retry 3 --connect-timeout 30 -o $dest $url
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dest)) { throw "download failed: $url" }
}
function Get-FileOrNull($url, $dest, $minBytes) {
  # 镜像可能返回 HTML 错误页，按体积卡一道
  try {
    Get-File $url $dest
    if ((Get-Item $dest).Length -gt $minBytes) { return $true }
    Write-Warn2 "too small, treat as fail: $url"
  } catch { Write-Warn2 "mirror fail: $url" }
  return $false
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
    $got = $false
    foreach ($u in @(
        "https://npmmirror.com/mirrors/node/$NodeVer/node-$NodeVer-win-x64.zip",
        "https://nodejs.org/dist/$NodeVer/node-$NodeVer-win-x64.zip")) {
      if (Get-FileOrNull $u $zip 20MB) { $got = $true; break }
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
  Get-File 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse' $zip
  $tmp = Join-Path $ToolsRoot 'jdk-extract'
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $dir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'jdk*' } | Select-Object -First 1
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
  Get-File 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' $zip
  $tmp = Join-Path $SdkDir 'cmdline-tools-temp'
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $SdkDir 'cmdline-tools') | Out-Null
  Move-Item (Join-Path $tmp 'cmdline-tools') (Join-Path $SdkDir 'cmdline-tools\latest')
  Remove-Item $tmp -Recurse -Force
  Remove-Item $zip -Force
}
$env:ANDROID_HOME = $SdkDir
1..30 | ForEach-Object { 'y' } | & $sdkm --sdk_root=$SdkDir --licenses | Out-Null
& $sdkm --sdk_root=$SdkDir 'platform-tools' 'platforms;android-35' 'build-tools;35.0.0' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'sdkmanager install failed' }

# ---------------------------------------------------------------- Gradle
Write-Step 'Prepare Gradle 8.11.1'
$gradleBin = Join-Path $GradleDir 'bin\gradle.bat'
if (Test-Path $gradleBin) {
  Write-Host "  reuse $GradleDir"
} else {
  $zip = Join-Path $ToolsRoot 'gradle-8.11.1-all.zip'
  $mirrors = @(
    'https://mirrors.cloud.tencent.com/gradle/gradle-8.11.1-all.zip',
    'https://mirrors.huaweicloud.com/gradle/gradle-8.11.1-all.zip',
    'https://services.gradle.org/distributions/gradle-8.11.1-all.zip'
  )
  $got = $false
  foreach ($u in $mirrors) {
    if (Get-FileOrNull $u $zip 10MB) { $got = $true; break }
  }
  if (-not $got) { throw 'all Gradle mirrors failed' }
  Expand-Archive -Path $zip -DestinationPath $ToolsRoot -Force
  Remove-Item $zip -Force
}

# ---------------------------------------------------------------- mirrors + local.properties
Write-Step 'Write Gradle mirrors init.gradle and local.properties'
New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE '.gradle') | Out-Null
$init = @"
// CN mirrors for Gradle deps
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
# init.gradle 是【全局生效】的：改它会连带影响本机所有 Gradle 工程
# （拾穗集，以及以后装的第三个项目）。所以内容不一致时先备份，绝不静默冲掉别人的配置。
if (Test-Path $InitGradle) {
  $cur = ([IO.File]::ReadAllText($InitGradle) -replace "`r`n", "`n").Trim()
  if ($cur -ne $init.Trim()) {
    $bak = "$InitGradle.bak"
    if (Test-Path $bak) { $bak = "$InitGradle.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    Copy-Item $InitGradle $bak
    Write-Warn2 "已有的 $InitGradle 内容不同，已备份为 $(Split-Path -Leaf $bak) 后再覆盖"
  }
}
[IO.File]::WriteAllText($InitGradle, $init, [Text.UTF8Encoding]::new($false))
$sdkProp = $SdkDir.Replace('\', '\\')
[IO.File]::WriteAllText((Join-Path $AndroidDir 'local.properties'), "sdk.dir=$sdkProp`n", [Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------- release keystore
if ($Release) {
  Write-Step 'Prepare release keystore'
  $ksFile = Join-Path $AndroidDir 'tomato-release.keystore'
  $ksProps = Join-Path $AndroidDir 'keystore.properties'
  if (-not (Test-Path $ksFile)) {
    # 首次：随机口令生成签名密钥；只留本机，丢了就无法覆盖安装升级
    $keytool = Join-Path $JdkDir 'bin\keytool.exe'
    $ksPwd = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    & $keytool -genkeypair -v -keystore $ksFile -alias tomato -keyalg RSA -keysize 2048 -validity 10950 `
      -storepass $ksPwd -keypass $ksPwd -dname 'CN=TomatoClock, OU=Home, O=Tomato, L=Local, C=CN'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ksFile)) { throw 'keytool genkeypair failed' }
    $props = @(
      'storeFile=tomato-release.keystore',
      "storePassword=$ksPwd",
      'keyAlias=tomato',
      "keyPassword=$ksPwd"
    ) -join "`n"
    [IO.File]::WriteAllText($ksProps, "$props`n", [Text.UTF8Encoding]::new($false))
    Write-Host '  keystore 已生成；口令在 app\android\keystore.properties（请自行备份，两个文件都别提交）'
  } elseif (-not (Test-Path $ksProps)) {
    throw "找到 $ksFile 但缺 keystore.properties（含口令），无法签名；请恢复该文件或删掉 $ksFile 重新生成"
  } else {
    Write-Host "  reuse $ksFile"
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
    if (Test-Path $pkgLock) {
      npm ci
      if ($LASTEXITCODE -ne 0) {
        Write-Warn2 'npm ci 失败，回退 npm install（lockfile 可能与 package.json 不同步）'
        npm install
      }
    } else {
      npm install
    }
    if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
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
  & $gradleBin $gradleTask --no-daemon
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

if ($Install) {
  & (Join-Path $AppRoot 'install-to-phone.ps1') -Apk $outApk
} else {
  Write-Host "`n装到手机：把上面这个 APK 传过去点击安装（首次需允许「未知来源」），"
  Write-Host "或手机开了 USB 调试后执行： powershell -ExecutionPolicy Bypass -File app\install-to-phone.ps1"
  Write-Host "或打包时直接加 -Install 一条龙。"
}
Write-Host "`n装完请按 docs\ACCEPTANCE.md 逐条验收（build-apk.ps1 末尾引用了这份清单）。"
