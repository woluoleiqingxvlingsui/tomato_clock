# 🍅 番茄钟（手机端 App）v1.3.0

仿「番茄ToDo」思路打造的极简专注计时 App：只保留**正计时专注**一种模式，专注完直接记录，没有休息倒计时。基于 Capacitor 打包成安卓 APK 安装在手机上使用，也可以直接在电脑浏览器里打开预览。

**全程离线、数据只存在自己手机上**：不声明联网权限、不声明存储/位置等权限、不联网上报、不开系统云备份。

## 截图

> 截图用无头浏览器从 `www/` 真实渲染，数据为**示例数据**（注入 localStorage 生成，非真实使用记录）。

| 专注中 | 统计总览 |
|---|---|
| ![专注中](docs/screenshots/focus-running.png) | ![统计总览](docs/screenshots/stats-overview.png) |

| 开始弹层 | 专注趋势 + 记录 |
|---|---|
| ![开始弹层](docs/screenshots/sheet-task.png) | ![专注趋势](docs/screenshots/stats-trend.png) |

空闲态见 [docs/screenshots/focus-idle.png](docs/screenshots/focus-idle.png)。

下面是**真机**上的通知栏计时卡（专注进行中，事项名 + 走秒时间）：

![通知栏计时卡](docs/screenshots/notification-card.png)

> 截图已裁掉系统状态栏。多数机型锁屏上会显示同样的卡片，个别 ROM 需要手动放行，见下方排查。

## 功能

**专注页（底部左 Tab）**
- 空闲时只有一个大按钮「开始专注」
- 点击后输入这次专注的事项，或从「最近事项」一键点选（同一事项颜色永远一致）；点「管理」可删除/清空不需要的快捷事项
- 正计时走秒，支持「暂停/继续」（暂停的时间不计入专注时长）
- 点「结束」需二次确认，避免误停；**时长精确到秒**（1分46秒就记1分46秒，统计自动精确合计，不再舍弃不足1分钟的部分）
- **后台计时很稳**：时长按时间戳计算（`现在 - 开始 - 暂停累计`），切后台、锁屏甚至进程被杀，回来时间都准确；进程被杀后重开 App 会自动恢复进行中的专注

**通知栏计时卡**
- 专注期间有一条"进行中"常驻通知：事项名 + 走秒时间 + 「查看」按钮，点击回到 App（见上方真机截图）。**多数机型锁屏上也会显示同样的卡片**（与番茄ToDo 同机制），但这取决于厂商 ROM 是否放行锁屏通知，本项目无法代劳
- 暂停时时间冻结显示"已暂停"；结束卡片消失
- 首次开始专注会请求**通知权限**（Android 13+），允许后卡片才可见；不允许不影响计时本身
- 通知由 specialUse 前台服务驱动，**走字交给系统**：通知用 chronometer（起算点 = 开始时间 + 暂停累计）由 SystemUI 每秒绘制，所以本进程被后台冻结甚至回收时通知照样走秒，**不需要 WakeLock**；服务本身 60 秒一次心跳只为在进程重建或通知被系统清掉后按时间戳重算、自愈重发
- **锁屏看不到卡片？** 这是 ROM 设置问题、不是 App 的 bug，依次检查：① 启动计时后再锁屏；② 设置→通知与控制中心→锁屏通知→显示所有通知内容；③ 设置→应用→番茄钟→通知→「专注计时」渠道→锁屏=显示所有内容；④ MIUI 权限里「锁屏显示」=允许。通知栏能正常显示、只有锁屏没有时，基本就是这几处之一没开

**统计页（底部右 Tab）**
- 概览卡片：今日 / 本周 / 本月 / 累计 / 日均（精确到秒的时钟格式，如 `2:09`、`2:45:30`；日均 = 总专注时长 ÷ 有专注记录的天数，没专注的日子不会拉低平均值）
- 环形饼图：按专注事项聚合（自动合并同类项），可切换 今日 / 本月 / 今年，图下列表显示精确时长（`1分46秒`）与占比
- 趋势折线图：按日（近30天）/ 按周（近12周）/ 按月（近12月）看总时长变化，可按事项筛选（比如只看「科研」的趋势）
- 记录管理：记录列表可删除、可改名（当时选错事项名改一次即可，跨零点拆分的同组记录会一并改名），更早的记录点「加载更早」继续查看
- **跨零点的专注自动按天拆分**：结束时按本地零点拆成两条记录，各段扣除落在该段内的暂停时间（总时长秒级守恒），「今天 / 昨天」等每日统计归属正确

## 在电脑上预览

最快：双击仓库根目录的 **`preview-web.bat`** —— 自动起本地服务并打开浏览器（端口占用会自动顺延）。F12 → Ctrl+Shift+M 切手机视口。

更省事：直接双击 `www/index.html`（Chrome/Edge 可用，Safari 对 `file://` 限制多）。

手动起服务：

```
python -m http.server 8899 --directory www
# 浏览器打开 http://127.0.0.1:8899
```

> 网页预览和 App 数据不互通：网页存的是浏览器来源（origin）下的 localStorage，App 存的是 WebView 里的另一份。想在手机上验收请装 APK，见下。

## 打 APK 并装到手机

**只需要 Windows + PowerShell。** JDK 21、Android SDK、Gradle、Node.js 缺什么脚本自动装（装在 `%USERPROFILE%\tools\` 下，可重复运行，已装则复用），国内网络走镜像。Node 要求 ≥ v20。

```
powershell -ExecutionPolicy Bypass -File app\build-apk.ps1            # debug 包（日常用）
powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Release   # release 包（首次自动生成签名）
powershell -ExecutionPolicy Bypass -File app\build-apk.ps1 -Install   # 打完直接装到已连线的手机
```

产物：原始的在 `app\android\app\build\outputs\apk\...`，脚本会**再复制一份带版本号的到 `_out\apk\`**（该目录已 gitignore）：

```
_out\apk\tomato-clock-1.3.0-debug.apk
_out\apk\tomato-clock-1.3.0-release.apk
```

装到手机的两种方式：

1. 把 `_out\apk\*.apk` 传过去点击安装（首次需允许「未知来源」）；
2. 手机开 USB 调试并连线后，一条命令：
   ```
   powershell -ExecutionPolicy Bypass -File app\install-to-phone.ps1
   ```

应用 ID 为 `app.tomato.clock`，与拾穗集互不冲突。**debug 与 release 签名不同，不能互相覆盖安装**。

装完请按 **[`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md)** 逐条验收（build-apk.ps1 末尾也会提示）。

### 签名相关（重要）

- `-Release` 首次会在 `app\android\` 下生成 `tomato-release.keystore` 与 `keystore.properties`（随机 24 位口令）。
- **这两个文件都不在 git 里**（`.gitignore` 已排除），请自己另找地方备份 —— 丢了就只能卸载重装，旧记录会清空。
- `app\android\app\build.gradle` 只在 `keystore.properties` 存在时才声明签名配置；脚本会在开打前校验四个字段齐全、密钥文件在位，避免「打出来才发现没签名」。

## 从零克隆后怎么跑

`app\android\` 里有两处是 **Capacitor 生成的、不进 git** 的东西（`capacitor-cordova-android-plugins/`、`app\src\main\assets\public\`），而 gradle 配置硬引用它们。所以新克隆的仓库**不能直接用 Android Studio 打开**，需要先让 Capacitor 生成一次：

```
cd app
npm install        # 脚本里会自动做，且优先用 npm ci 严格按 lockfile 装
npx cap sync android
```

其实直接跑 `app\build-apk.ps1` 就行——它把上面这套连同工具链一起自动化了。

## 目录结构

```
tomato_clock/
├── www/                        # App 界面层（会被打进 APK）
│   ├── index.html              # 全部界面与逻辑（单文件，移动优先）
│   ├── chart.umd.js            # Chart.js 4.5.1 本地文件（离线可用）
│   └── CHART.JS-LICENSE.md     # Chart.js 的 MIT 许可原文
├── app/                        # 安卓壳（Capacitor 7）
│   ├── capacitor.config.json
│   ├── build-apk.ps1           # 一键装工具链 + 打包（debug / release / -Install）
│   ├── install-to-phone.ps1    # adb 一键装机
│   ├── preview-web.ps1         # 本地起服务预览网页版
│   ├── package.json            # Capacitor 依赖与版本号
│   └── android/                # 安卓工程（cap add 生成）
├── docs/
│   ├── ACCEPTANCE.md           # 装机验收清单 + 已知限制
│   └── screenshots/            # 截图位（见目录内说明）
├── legacy/                     # 旧桌面网页版（倒计时版），仅留档
├── preview-web.bat             # 双击预览网页版
├── LICENSE                     # MIT
└── README.md
```

## 数据与隐私

- 数据存在 App 私有的 localStorage（键：`tomato.sessions` / `tomato.ongoing` / `tomato.recentTasks`），**只在本机**，卸载 App 才会清掉
- 清单里**刻意没有** `INTERNET` 权限：Capacitor 的 `https://localhost` 由原生 scheme handler 在内存里拦截、直接从 APK 资源读文件，不监听任何端口也不发任何网络请求，所以完全不需要联网权限
- 清单里 `android:allowBackup="false"`：明确关掉系统备份，专注记录不会被传到 Google/云端。（注意删掉这行等于 true —— 官方默认值就是 true，要关必须显式写 false。Android 12+ 即便写了 false，部分厂商仍允许换机时的本机设备间迁移，那不出设备。）
- 没有账号、没有登录、没有埋点、没有任何第三方 SDK（除本地打包的 Chart.js）
- **备份 / 迁移：暂用「记录页逐条查看」+ 手机厂商自带备份**，JSON 导出 / 导入留待后续版本。这是目前最该补的缺口
- 旧桌面版（`legacy/index.html`）的倒计时记录**只有在新旧两版同源时**才会自动合并——也就是在同一个本地服务下先开 `legacy/index.html` 再开 `www/index.html`。App 装到手机上后跑的是 WebView 的 `https://localhost` 另一个来源，读不到桌面浏览器的数据，所以手机上装 App 并不会自动继承旧版记录。

## 已知限制

- JSON 导出 / 导入未实现（见上）
- 换包型（debug ↔ release）需卸载重装，会丢记录
- 通知卡可见性依赖厂商 ROM 的锁屏通知设置，MIUI 上尤其容易需要手动放行

## 相关项目

同一个人做的另一个本地单机小工具，顺手打个广告：

- 🧺 [**拾穗集**](https://github.com/woluoleiqingxvlingsui/shisuiji) —— 科研/办公备忘录：记赛博鸡蛋、论文待读已读归档与阅读笔记、网页收藏与读后要点、学习办公开销账单与体感评价。同样本地单机、Node 标准库 + Vue3 零依赖、双击即用、数据存 JSON。番茄钟的安卓打包流水线就是从它那儿沿用过来的。

## 许可

本项目代码 MIT（见 [`LICENSE`](LICENSE)）。`www/chart.umd.js` 是 Chart.js v4.5.1，MIT，许可原文在 `www/CHART.JS-LICENSE.md`。
