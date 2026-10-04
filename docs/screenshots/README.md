# 截图

README 顶部「截图」一节引用的图都在这里。前五张由**无头 Edge 从 `www/` 真实渲染**截取
（起本地服务 → 注入示例数据到 localStorage → 切到目标界面 → 截图），
**不是设计稿，也不是伪造的示意图**。数据是脚本生成的示例数据，不是真实使用记录。

`notification-card.png` 则不同：它是**真机截图**，因为通知栏属于系统 UI 层，网页渲染不出来。

## 已有

| 文件名 | 内容 | 尺寸 |
|---|---|---|
| `focus-idle.png` | 专注页空闲态 | 480×1000 |
| `focus-running.png` | 专注进行中（事项胶囊 + 走秒 + 暂停/结束） | 480×1000 |
| `sheet-task.png` | 「这次专注什么？」弹层 + 最近事项 chip | 480×1000 |
| `stats-overview.png` | 统计页整页：概览 + 环形饼图 + 趋势 + 记录列表 | 480×1500 |
| `stats-trend.png` | 专注趋势（事项筛选 chip + 折线）与记录列表 | 480×1150 |
| `notification-card.png` | **真机**通知栏计时卡（已裁掉状态栏） | 1200×300 |

## 重新生成已有截图的做法

1. 复制 `www/index.html` 为 `www/__shot.html`
2. 在 `<script src="chart.umd.js">` **之前**插入注入示例数据的脚本
   （必须在主脚本之前，否则主脚本读不到数据）
3. 在 `</body>` 前插入切换界面的脚本（点 Tab、开弹层等）
4. `python -m http.server <端口> --directory www`（**端口避开 8899**，那是拾穗集 `serve-apk.mjs` 占着的）
5. `msedge --headless=new --hide-scrollbars --window-size=480,<高> --virtual-time-budget=9000 --screenshot=<输出> "http://127.0.0.1:<端口>/__shot.html?s=<界面>"`
6. **删掉 `www/__shot.html`**

两个踩过的坑：

- **无头模式下不要用滚动定位**。`.card` / `.ov` / `#tabbar` 都用了 `backdrop-filter`，
  一旦页面滚动，headless 截图会把这些区域合成成**整片空白**。想让某张卡片到顶部，
  改成把上面的卡片 `display:none`，不要 `scrollIntoView`。
- **弹层的 `.25s` 过渡不会被虚拟时钟捕捉**，截图会拍到 `opacity:0` 的弹层。
  点击后直接给遮罩写内联 `opacity:1; visibility:visible; transition:none`。
