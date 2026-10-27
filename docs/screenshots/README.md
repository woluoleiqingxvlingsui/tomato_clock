# 截图

README 顶部「截图」一节引用的图都在这里。前六张由**无头 Edge 从 `www/` 真实渲染**截取
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
| `stats-backup.png` | 备份与恢复卡片 + 导出数据弹层（JSON 内容） | 480×1000 |
| `notification-card.png` | **真机**通知栏计时卡（已裁掉状态栏） | 1200×300 |

## 重新生成已有截图

界面改了就重跑一次，脚本会把上面 6 张（`notification-card.png` 除外，它是真机截图）全部重出：

```
python docs/screenshots/regenerate.py
```

需要 Windows + Python 3 + Edge（或 Chrome，脚本会自动找）。想先出到别处看看：

```
python docs/screenshots/regenerate.py %TEMP%\shots
```

脚本干的事（`regenerate.py` 里都有注释）：

1. 复制 `www/index.html` 为 `www/__shot.html`
2. 在 `<script src="chart.umd.js">` **之前**插入注入示例数据的脚本
   （必须在主脚本之前，否则主脚本读不到数据）
3. 在 `</body>` 前插入切换界面的脚本（点 Tab、开弹层、隐藏上面的卡片等）
4. 起本地服务（端口 8907），用无头 Edge 按 `?s=<界面>` 截图
5. **删掉 `www/__shot.html`**

两个踩过的坑（脚本里已处理，别改回去）：

- **无头模式下不要用滚动定位**。`.card` / `.ov` / `#tabbar` 都用了 `backdrop-filter`，
  一旦页面滚动，headless 截图会把这些区域合成成**整片空白**。想让某张卡片到顶部，
  改成把上面的卡片 `display:none`，不要 `scrollIntoView`。
- **弹层的 `.25s` 过渡不会被虚拟时钟捕捉**，截图会拍到 `opacity:0` 的弹层。
  点击后直接给遮罩写内联 `opacity:1; visibility:visible; transition:none`。

另外，示例数据里的事项名是从真实场景里挑的。早期版本的颜色是「12 个固定色取模」，
名字撞了就同色（`科研` 和 `改代码` 都落在那个灰色上），饼图上分不出两瓣；
现在配色改成按名字哈希在连续色相上取色，不会再撞，所以示例数据不用再避讳什么了。
