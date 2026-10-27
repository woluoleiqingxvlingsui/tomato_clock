# 番茄钟 —— 把打好的 APK 装到已连线的安卓手机（adb install -r，保留已有专注记录）
# 用法：
#   powershell -ExecutionPolicy Bypass -File app\install-to-phone.ps1            # 自动挑 _out\apk 里最新的包
#   powershell -ExecutionPolicy Bypass -File app\install-to-phone.ps1 -Apk <路径> # 指定包
#   powershell -ExecutionPolicy Bypass -File app\install-to-phone.ps1 -Serial <设备号>  # 多台设备时指定
# 前置：手机「设置 → 关于手机 → 连点版本号 7 次」开开发者选项 → 打开 USB 调试，首次连线在手机上点「允许」。

param(
  [string]$Apk,
  [string]$Serial
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $AppRoot

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- locate adb
Write-Step 'Locate adb'
$adb = $null
$c = Get-Command adb -ErrorAction SilentlyContinue
if ($c) { $adb = $c.Source }
else {
  $bundled = Join-Path $env:USERPROFILE 'tools\android-sdk\platform-tools\adb.exe'
  if (Test-Path $bundled) { $adb = $bundled }
}
if (-not $adb) {
  throw "找不到 adb。先跑一次 build-apk.ps1（会装 platform-tools），或把 adb 目录加进 PATH。"
}
Write-Host "  $adb"

# ---------------------------------------------------------------- device
Write-Step 'Check device'
$raw = & $adb devices
$lines = @($raw | Select-Object -Skip 1 | Where-Object { $_.Trim() })
$devices = @()
foreach ($l in $lines) {
  $parts = $l -split '\s+'
  if ($parts.Count -ge 2) { $devices += [PSCustomObject]@{ Serial = $parts[0]; State = $parts[1] } }
}
if (-not $devices.Count) {
  Write-Host ($raw -join "`n")
  throw '没有检测到设备。用数据线连手机并确认「USB 调试」已打开、手机上点了「允许」。'
}
foreach ($d in $devices) { Write-Host "  $($d.Serial)  [$($d.State)]" }

if ($Serial) {
  if (-not ($devices | Where-Object { $_.Serial -eq $Serial })) { throw "指定设备 $Serial 不在列表里" }
}
else {
  $ready = @($devices | Where-Object { $_.State -eq 'device' })
  if ($ready.Count -eq 0) {
    $bad = ($devices | ForEach-Object { "$($_.Serial)=$($_.State)" }) -join ', '
    throw "设备状态不对（$bad）。unauthorized = 手机上还没点「允许」；offline = 重插数据线。"
  }
  if ($ready.Count -gt 1) { throw "连了多台设备，请用 -Serial <设备号> 指定其中一台" }
  $Serial = $ready[0].Serial
}

# ---------------------------------------------------------------- pick apk
Write-Step 'Pick APK'
if ($Apk) {
  if (-not (Test-Path $Apk)) { throw "APK not found: $Apk" }
  $apkPath = (Resolve-Path $Apk).Path
} else {
  $cands = @()
  $outDir = Join-Path $RepoRoot '_out\apk'
  if (Test-Path $outDir) {
    $cands += @(Get-ChildItem $outDir -Filter '*.apk' -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch 'unsigned' })
  }
  $gradleOut = Join-Path $AppRoot 'android\app\build\outputs\apk'
  if (Test-Path $gradleOut) {
    $cands += @(Get-ChildItem $gradleOut -Filter '*.apk' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch 'unsigned' })
  }
  if (-not $cands.Count) { throw '没有找到已签名的 APK（未签名包不能装），先跑 build-apk.ps1。' }
  $apkPath = ($cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
Write-Host "  $apkPath  ($([math]::Round((Get-Item $apkPath).Length / 1MB, 2)) MB)"

# ---------------------------------------------------------------- install
Write-Step 'Install'
# 必须把 adb 的输出接住：成败判断靠的是输出里的 Success / 失败码。
# 顺带 2>&1 收 stderr + 临时放开 EAP：adb 失败时写 stderr，
# 在 $ErrorActionPreference='Stop' 下会直接抛成看不懂的 NativeCommandError。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = (@(& $adb -s $Serial install -r $apkPath 2>&1) | ForEach-Object { "$_" }) -join "`n"
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($code -eq 0 -and $out -match 'Success') {
  Write-Host "`n安装成功。手机上打开「番茄钟」即可。" -ForegroundColor Green
  Write-Host '第一次点「开始专注」时会请求通知权限（Android 13+），允许后锁屏/通知栏才有计时卡。'
  Write-Host '请按 docs\ACCEPTANCE.md 逐条验收。'
} else {
  Write-Host $out -ForegroundColor Red
  if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
    Write-Warn2 '签名不一致：手机里已装的是另一种包型（debug / release），系统拒绝覆盖。'
    Write-Warn2 '解法：先在 App 统计页「备份与恢复 → 导出数据」，再卸载手机上的「番茄钟」，'
    Write-Warn2 '      然后重跑本脚本安装当前包；装好后用「导入数据」把记录恢复回来。'
  }
  throw 'adb install 失败'
}
