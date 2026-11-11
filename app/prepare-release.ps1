# 番茄钟 —— 统一发布准备入口（Windows PowerShell 5.1 兼容）
#
# 用法（仓库根目录或 app\ 下都行）：
#   powershell -ExecutionPolicy Bypass -File app\prepare-release.ps1
#   powershell -ExecutionPolicy Bypass -File app\prepare-release.ps1 -DeviceAcceptance .\device-acceptance.json
#   powershell -ExecutionPolicy Bypass -File app\prepare-release.ps1 -CreateSigningKey      # 仅首次自行签发
#
# 它做什么（顺序固定，任何一步不通过就停）：
#   1. 前置检查：Node >= 22、Chrome/Edge、版本号四处一致、签名状态
#   2. 跑 tools\regression\browser-tests.js（真浏览器回归）
#   3. 跑 tools\regression\test-build-scripts.ps1（构建脚本静态检查）
#   4. 调 app\build-apk.ps1 -Release 打 release 包
#   5. 校验 APK 存在，算 SHA-256，写 _out\release\<版本>\ 下的 sha256 文件 + 准备结果报告
#   6. 读【人工填写】的真机验收记录（-DeviceAcceptance），核对 status / 版本 / APK SHA-256 / 五项检查
#
# 它【不】做什么：不会 git commit / push，不会创建或上传 Release，不会读手机里的其它数据，
#   不会把签名密钥或口令写进报告，也不会自动更换已有签名。
#   真机验收记录只读不写 —— 脚本永远不会替你生成一份"已通过"的记录。
#
# 退出码 0 = 自动准备完成（不代表发布就绪）；是否就绪看报告里的 releaseReady 和最后一段提示。

param(
  [switch]$CreateSigningKey,
  [string]$DeviceAcceptance
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $AppRoot
$AndroidDir = Join-Path $AppRoot 'android'
$BuildScript = Join-Path $AppRoot 'build-apk.ps1'
$BrowserTests = Join-Path $RepoRoot 'tools\regression\browser-tests.js'
$BuildTests = Join-Path $RepoRoot 'tools\regression\test-build-scripts.ps1'
$OutRoot = Join-Path $RepoRoot '_out\release'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

# ================================================================= 纯函数（可离线验证）
# ---------------------------------------------------------------- 签名状态
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
# ---------------------------------------------------------------- 步骤失败即停
function Assert-StepSucceeded {
  param([string]$StepName, $ExitCode)
  # $null 退出码 = 命令压根没跑起来，当失败处理，不能当成 0 放过去
  $code = if ($null -eq $ExitCode) { -1 } else { [int]$ExitCode }
  if ($code -ne 0) {
    throw ("步骤失败：{0}（退出码 {1}）。发布准备已中止，后面的步骤不会执行。" -f $StepName, $code)
  }
}
# ---------------------------------------------------------------- 版本号一致性
function Get-ProjectVersion {
  param([string]$PackageJsonPath, [string]$LockPath, [string]$GradlePath)
  if (-not (Test-Path $PackageJsonPath)) { throw "找不到 $PackageJsonPath" }
  if (-not (Test-Path $LockPath)) { throw "找不到 $LockPath" }
  if (-not (Test-Path $GradlePath)) { throw "找不到 $GradlePath" }
  $pkg = (Get-Content $PackageJsonPath -Raw -Encoding UTF8) | ConvertFrom-Json
  $version = [string]$pkg.version
  if (-not $version) { throw 'package.json 里没有 version' }
  $problems = New-Object System.Collections.ArrayList
  if (Test-Path $LockPath) {
    $lockText = Get-Content $LockPath -Raw -Encoding UTF8
    # PS 5.1 的 ConvertFrom-Json 拒绝空字符串键；仅把 packages 的根键临时改成哨兵再解析。
    $lockNormalized = [regex]::Replace($lockText, '(?m)("packages"\s*:\s*\{\s*)""(\s*:)', '$1"__tomato_root_package__"$2')
    $lock = $lockNormalized | ConvertFrom-Json
    $lockVersion = [string]$lock.version
    $lockRootVersion = ''
    if ($lock.packages -and $lock.packages.PSObject.Properties['__tomato_root_package__']) {
      $lockRootVersion = [string]$lock.packages.__tomato_root_package__.version
    }
    if ($lockVersion -ne $version) { [void]$problems.Add("package-lock.json 顶层 version=$lockVersion") }
    if ($lockRootVersion -ne $version) { [void]$problems.Add('package-lock.json packages[""].version=' + $lockRootVersion) }
  }
  $versionCode = ''
  if (Test-Path $GradlePath) {
    $gradleText = Get-Content $GradlePath -Raw -Encoding UTF8
    $nameMatch = [regex]::Match($gradleText, 'versionName\s+"([^"]+)"')
    $codeMatch = [regex]::Match($gradleText, 'versionCode\s+(\d+)')
    if (-not $nameMatch.Success) { [void]$problems.Add('build.gradle 里找不到 versionName') }
    elseif ($nameMatch.Groups[1].Value -ne $version) {
      [void]$problems.Add('build.gradle versionName=' + $nameMatch.Groups[1].Value)
    }
    if ($codeMatch.Success) { $versionCode = $codeMatch.Groups[1].Value }
    else { [void]$problems.Add('build.gradle 里找不到 versionCode') }
  }
  if ($problems.Count -gt 0) {
    throw ("版本号不一致（package.json = {0}）：{1}。改一致后再做发布准备。" -f $version, ($problems -join '；'))
  }
  return [pscustomobject]@{ Version = $version; VersionCode = $versionCode }
}
# ---------------------------------------------------------------- 真机验收记录
# 记录是【人工填写】的 JSON，脚本只读不写，也不会替人生成"已通过"的结论。
# 必备字段：status=passed、version、apkSha256、device.model、device.androidVersion、date、
#           checks 里五项全为 true。
function Test-DeviceAcceptance {
  param([string]$Path, [string]$ExpectedVersion, [string]$ExpectedSha256)
  $reasons = New-Object System.Collections.ArrayList
  $status = 'missing-record'
  $model = ''
  $androidVersion = ''
  $date = ''
  if ([string]::IsNullOrWhiteSpace($Path)) {
    [void]$reasons.Add('没有提供真机验收记录（-DeviceAcceptance <路径>）')
  } elseif (-not (Test-Path $Path)) {
    [void]$reasons.Add('找不到真机验收记录文件')
  } else {
    $raw = Get-Content $Path -Raw -Encoding UTF8
    $record = $null
    try { $record = $raw | ConvertFrom-Json } catch { $record = $null }
    if ($null -eq $record) {
      $status = 'invalid-record'
      [void]$reasons.Add('真机验收记录不是合法的 JSON')
    } else {
      $status = 'provided'
      if ([string]$record.status -ne 'passed') {
        [void]$reasons.Add('status 必须是 passed（当前：' + [string]$record.status + '）')
      }
      if ([string]$record.version -ne $ExpectedVersion) {
        [void]$reasons.Add('版本不匹配：记录=' + [string]$record.version + '，本次=' + $ExpectedVersion)
      }
      $recHash = ([string]$record.apkSha256).Trim().ToLowerInvariant()
      $wantHash = ([string]$ExpectedSha256).Trim().ToLowerInvariant()
      if (-not $recHash) {
        [void]$reasons.Add('缺少 apkSha256')
      } elseif ($recHash -ne $wantHash) {
        [void]$reasons.Add('APK SHA-256 不匹配：记录=' + $recHash + '，本次=' + $wantHash)
      }
      if ($record.PSObject.Properties['device']) {
        $model = [string]$record.device.model
        $androidVersion = [string]$record.device.androidVersion
      }
      if (-not $model.Trim()) { [void]$reasons.Add('缺少 device.model') }
      if (-not $androidVersion.Trim()) { [void]$reasons.Add('缺少 device.androidVersion') }
      $date = [string]$record.date
      if (-not $date.Trim()) {
        [void]$reasons.Add('缺少 date')
      } elseif ($date -notmatch '^\d{4}-\d{2}-\d{2}$') {
        [void]$reasons.Add('date 必须是 YYYY-MM-DD（当前：' + $date + '）')
      } else {
        $parsedDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
          [void]$reasons.Add('date 不是有效的日历日期')
        }
      }
      $required = @('notificationAllow', 'notificationDeny', 'backgroundRestore', 'safSaveCancelImport', 'sameSignatureUpgrade')
      $checks = $null
      if ($record.PSObject.Properties['checks']) { $checks = $record.checks }
      foreach ($c in $required) {
        if ($null -eq $checks) { [void]$reasons.Add('缺少 checks.' + $c); continue }
        $prop = $checks.PSObject.Properties[$c]
        if ($null -eq $prop) { [void]$reasons.Add('缺少 checks.' + $c); continue }
        if ($prop.Value -isnot [bool] -or $prop.Value -ne $true) { [void]$reasons.Add('checks.' + $c + ' 必须是 JSON 布尔值 true') }
      }
      if ($reasons.Count -eq 0) { $status = 'passed' } else { $status = 'failed' }
    }
  }
  return [pscustomobject]@{
    Passed = ($status -eq 'passed' -and $reasons.Count -eq 0)
    Status = $status
    Reasons = @($reasons | ForEach-Object { [string]$_ })
    RecordFile = $(if ($Path) { [IO.Path]::GetFileName($Path) } else { '' })
    Model = $model
    AndroidVersion = $androidVersion
    Date = $date
  }
}
# ---------------------------------------------------------------- 报告与 sha256 文件
function Write-Sha256File {
  param([string]$ApkPath, [string]$Sha256, [string]$OutFile)
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $name = [IO.Path]::GetFileName($ApkPath)
  $line = ("{0}  {1}" -f $Sha256.Trim().ToLowerInvariant(), $name)
  [IO.File]::WriteAllText($OutFile, "$line`n", [Text.UTF8Encoding]::new($false))
  return $OutFile
}
function New-PrepareReport {
  param(
    [string]$Version,
    [string]$ApkPath,
    [string]$ApkSha256,
    [string]$Sha256File,
    [hashtable]$AutoChecks,
    [string]$Signing,
    $DeviceResult
  )
  $autoPassed = $true
  foreach ($k in @($AutoChecks.Keys)) {
    if ([string]$AutoChecks[$k] -ne 'passed') { $autoPassed = $false }
  }
  $devicePassed = [bool]$DeviceResult.Passed
  return [pscustomobject]@{
    schema = 'tomato-clock/prepare-report@1'
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    version = $Version
    apk = [pscustomobject]@{
      path = $ApkPath
      sha256 = $ApkSha256
      sha256File = $Sha256File
    }
    signing = $Signing
    automatedChecks = $AutoChecks
    automatedChecksPassed = $autoPassed
    deviceAcceptance = [pscustomobject]@{
      passed = $devicePassed
      status = $DeviceResult.Status
      reasons = @($DeviceResult.Reasons)
      recordFile = $DeviceResult.RecordFile
      model = $DeviceResult.Model
      androidVersion = $DeviceResult.AndroidVersion
      date = $DeviceResult.Date
    }
    releaseReady = ($autoPassed -and $devicePassed)
    notes = '本报告不含签名密钥或口令。releaseReady=true 需要：自动检查全部通过 + 人工填写的真机验收记录 status=passed 且 APK SHA-256 与本报告一致。发布动作（打 tag / 上传 Release）仍需人工完成，本脚本不会代劳。'
  }
}
# ---------------------------------------------------------------- 找工具
function Find-NodeExecutable {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $toolsNode = Join-Path $env:USERPROFILE 'tools\node\v22.20.0\node.exe'
  if (Test-Path $toolsNode) { return $toolsNode }
  return $null
}
function Find-BrowserExecutable {
  $candidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}
function Get-PowerShellExecutable {
  if ($PSVersionTable.PSEdition -eq 'Core') {
    $p = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path $p) { return $p }
  }
  $p5 = Join-Path $PSHOME 'powershell.exe'
  if (Test-Path $p5) { return $p5 }
  $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# ================================================================= 主流程
$autoChecks = @{}

Write-Step '1/6 检查前置'
$nodeExe = Find-NodeExecutable
if (-not $nodeExe) {
  throw ("找不到 Node。真浏览器回归需要 Node >= 22（脚本用 Node 内置的 WebSocket，Node 20 没有）。" +
         "`n  · 先跑一次 app\build-apk.ps1（它会把 Node 装到 %USERPROFILE%\tools\ 下），或把 Node 22+ 装到 PATH 上再试。")
}
$nodeVer = (& $nodeExe -v) 2>$null
$nodeVerText = ($nodeVer | Select-Object -First 1)
$nodeMajor = 0
if ($nodeVerText -match '^v(\d+)\.') { $nodeMajor = [int]$Matches[1] }
if ($nodeMajor -lt 22) {
  throw ("Node 版本过低：{0}。真浏览器回归需要 Node >= 22（脚本用 Node 内置的 WebSocket）。" -f $nodeVerText)
}
Write-Host "  node $nodeVerText（>= 22 OK）：$nodeExe"
$browserExe = Find-BrowserExecutable
if (-not $browserExe) {
  throw ("找不到 Chrome / Edge。真浏览器回归需要其中之一（脚本自己找这两个）。")
}
Write-Host "  browser: $browserExe"

$versionInfo = Get-ProjectVersion `
  -PackageJsonPath (Join-Path $AppRoot 'package.json') `
  -LockPath (Join-Path $AppRoot 'package-lock.json') `
  -GradlePath (Join-Path $AndroidDir 'app\build.gradle')
Write-Host "  version $($versionInfo.Version) (versionCode $($versionInfo.VersionCode))：四处一致"

$ksFile = Join-Path $AndroidDir 'tomato-release.keystore'
$ksProps = Join-Path $AndroidDir 'keystore.properties'
$ksState = Get-SigningState -KeystorePath $ksFile -PropsPath $ksProps
$ksDecision = Get-SigningDecision -State $ksState -CreateRequested ([bool]$CreateSigningKey)
if ($ksDecision -eq 'block') {
  if ($ksState -eq 'none') {
    throw ("找不到签名文件（{0} / {1}）。" -f $ksFile, $ksProps) +
          "`n  · 以前签过、文件弄丢了：从备份恢复这两个文件后重试（不要重新生成一把新的）。" +
          "`n  · 第一次自己签发：显式加 -CreateSigningKey 再跑一次（仅此一次）。"
  }
  throw ("签名文件只剩一半（{0} 与 {1} 必须成对存在）。" -f $ksFile, $ksProps) +
        "`n  · 请从备份恢复缺的那个文件后重试；不要删掉已经存在的那一个来凑成对（删了就等于换钥匙）。"
}
$signing = $ksDecision
if ($ksDecision -eq 'reuse') { Write-Host "  签名：复用已有签名（$ksFile）" }
else { Write-Host '  签名：两个文件都不存在，本次按 -CreateSigningKey 首次自签（之后一直复用）' -ForegroundColor Yellow }

Write-Step '2/6 真浏览器回归（node tools\regression\browser-tests.js）'
Push-Location $RepoRoot
try {
  & $nodeExe 'tools\regression\browser-tests.js'
  Assert-StepSucceeded -StepName 'browser-tests.js' -ExitCode $LASTEXITCODE
} finally { Pop-Location }
$autoChecks['browserRegression'] = 'passed'

Write-Step '3/6 构建脚本静态检查（tools\regression\test-build-scripts.ps1）'
$psExe = Get-PowerShellExecutable
if (-not $psExe) { throw '找不到 powershell.exe / pwsh.exe，无法运行构建脚本检查' }
Push-Location $RepoRoot
try {
  & $psExe -NoProfile -ExecutionPolicy Bypass -File 'tools\regression\test-build-scripts.ps1'
  Assert-StepSucceeded -StepName 'test-build-scripts.ps1' -ExitCode $LASTEXITCODE
} finally { Pop-Location }
$autoChecks['buildScriptChecks'] = 'passed'

Write-Step '4/6 打 release 包（app\build-apk.ps1 -Release）'
$buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BuildScript, '-Release', '-RunTests')
if ($CreateSigningKey) { $buildArgs += '-CreateSigningKey' }
Push-Location $RepoRoot
try {
  & $psExe @buildArgs
  Assert-StepSucceeded -StepName 'build-apk.ps1 -Release' -ExitCode $LASTEXITCODE
} finally { Pop-Location }
$autoChecks['releaseBuild'] = 'passed'
$autoChecks['androidUnitTests'] = 'passed'

Write-Step '5/6 校验产物并生成 sha256 与准备结果报告'
$apkPath = Join-Path $RepoRoot ("_out\apk\tomato-clock-{0}-release.apk" -f $versionInfo.Version)
if (-not (Test-Path $apkPath)) {
  throw ("构建脚本说成功了，但找不到目标 APK：{0}。发布准备中止。" -f $apkPath)
}
$apkSha256 = (Get-FileHash $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$releaseDir = Join-Path $OutRoot $versionInfo.Version
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$shaFile = Join-Path $releaseDir ("tomato-clock-{0}-release.apk.sha256" -f $versionInfo.Version)
Write-Sha256File -ApkPath $apkPath -Sha256 $apkSha256 -OutFile $shaFile | Out-Null

Write-Step '6/6 核对真机验收记录'
$deviceResult = Test-DeviceAcceptance -Path $DeviceAcceptance -ExpectedVersion $versionInfo.Version -ExpectedSha256 $apkSha256
$report = New-PrepareReport `
  -Version $versionInfo.Version `
  -ApkPath $apkPath `
  -ApkSha256 $apkSha256 `
  -Sha256File $shaFile `
  -AutoChecks $autoChecks `
  -Signing $signing `
  -DeviceResult $deviceResult

$reportJson = Join-Path $releaseDir 'prepare-report.json'
$json = $report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($reportJson, "$json`n", [Text.UTF8Encoding]::new($false))
$reportMd = Join-Path $releaseDir 'prepare-report.md'
$md = New-Object System.Collections.ArrayList
[void]$md.Add('# 番茄钟 发布准备结果')
[void]$md.Add('')
[void]$md.Add(('- 版本：{0}（versionCode {1}）' -f $versionInfo.Version, $versionInfo.VersionCode))
[void]$md.Add(('- APK：{0}' -f $apkPath))
[void]$md.Add(('- SHA-256：{0}' -f $apkSha256))
$signLabel = '本次新建（自签包）'
if ($signing -eq 'reuse') { $signLabel = '复用已有签名' }
$deviceLabel = '未通过'
if ($deviceResult.Passed) { $deviceLabel = '已通过' }
$readyLabel = '否 —— 真机尚未通过，本产物未达到完整发布条件'
if ($report.releaseReady) { $readyLabel = '是' }
[void]$md.Add(('- 签名：{0}（{1}）' -f $signing, $signLabel))
[void]$md.Add(('- 自动检查：{0}' -f (($autoChecks.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Key + '=' + $_.Value }) -join '；')))
[void]$md.Add(('- 真机验收：{0}（{1}）' -f $deviceResult.Status, $deviceLabel))
if ($deviceResult.RecordFile) { [void]$md.Add(('- 验收记录文件：{0}' -f $deviceResult.RecordFile)) }
if ($deviceResult.Model) { [void]$md.Add(('- 机型 / 系统：{0} / {1}，{2}' -f $deviceResult.Model, $deviceResult.AndroidVersion, $deviceResult.Date)) }
foreach ($r in @($deviceResult.Reasons)) { [void]$md.Add(('  - {0}' -f $r)) }
[void]$md.Add('')
[void]$md.Add(('- 发布是否就绪：{0}' -f $readyLabel))
[void]$md.Add('')
[void]$md.Add('本报告不含签名密钥或口令。发布动作（打 tag / 上传 Release）仍需人工完成。')
[IO.File]::WriteAllText($reportMd, (($md -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host "APK      : $apkPath"
Write-Host "SHA-256  : $apkSha256"
Write-Host "sha256 文件: $shaFile"
Write-Host "准备报告  : $reportJson"
Write-Host "          : $reportMd"

if ($report.releaseReady) {
  Write-Host ''
  Write-Host '发布就绪：自动检查通过 + 真机验收记录 status=passed 且哈希/版本一致。' -ForegroundColor Green
  Write-Host '接下来的动作仍需人工完成：打 v<版本> 标签、把 APK 和 sha256 文件传到 Releases 页面。'
} else {
  Write-Host ''
  Write-Host '真机尚未通过，本产物未达到完整发布条件。' -ForegroundColor Red
  Write-Host '自动准备已经完成（APK / sha256 / 报告都已生成），但发布还不能算完成：'
  foreach ($r in @($deviceResult.Reasons)) { Write-Host "  - $r" -ForegroundColor Yellow }
  Write-Host '请在真机上按 docs\ACCEPTANCE.md 验收，填写验收记录后用 -DeviceAcceptance 重新核对。'
}
Write-Host ''
Write-Host '本脚本只在本机准备产物：不会提交或推送代码、不会上传发布页、不会读取手机里的其它数据。'
exit 0
