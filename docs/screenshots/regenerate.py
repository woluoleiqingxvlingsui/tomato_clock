# -*- coding: utf-8 -*-
"""
重新生成 docs/screenshots/ 里的示例数据截图。

    python docs/screenshots/regenerate.py            # 写到 docs/screenshots/
    python docs/screenshots/regenerate.py <输出目录>   # 先写到别处看看

做法（就是 docs/screenshots/README.md 记的那套，只是脚本化了）：
  1) 复制 www/index.html -> www/__shot.html
  2) 在 <script src="chart.umd.js"> 之前插入「注入示例数据」的脚本
     （必须在主脚本之前，否则主脚本读不到数据）
  3) 在 </body> 之前插入「切换到目标界面」的脚本
  4) 起本地服务，用无头 Edge 按 ?s=<界面> 截图
  5) 删掉 www/__shot.html

两个踩过的坑（别改回去）：
  - 无头模式下不要用滚动定位。.card / .ov / #tabbar 都用了 backdrop-filter，
    一旦页面滚动，headless 截图会把这些区域合成成整片空白。想让某张卡片到顶部，
    改成把上面的卡片 display:none，不要 scrollIntoView。
  - 弹层的 .25s 过渡不会被虚拟时钟捕捉，截图会拍到 opacity:0 的弹层。
    点击后直接给遮罩写内联 opacity:1; visibility:visible; transition:none。
"""
import io
import os
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
WWW = os.path.join(ROOT, "www")
SHOTS = os.path.join(ROOT, "docs", "screenshots")
PORT = 8907
EDGE_CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
]

# ---------------------------------------------------------------- 示例数据
SEED_JS = r"""
<script>
/* ===== 截图用示例数据（脚本生成，不是真实使用记录）===== */
(function(){
  var TASKS=["组会准备","科研","英语","改代码","读文献","写论文"];
  /* 这几天故意没有记录，让趋势图有缺口更像真实使用 */
  var SKIP={3:1,7:1,11:1,14:1,18:1,22:1,25:1,28:1,29:1};
  var seed=20261027;
  function rnd(){seed=(seed*1103515245+12345)&0x7fffffff;return seed/0x7fffffff}
  function ri(a,b){return a+Math.floor(rnd()*(b-a+1))}
  function pick(a){return a[Math.floor(rnd()*a.length)]}
  function pad2(n){return n<10?"0"+n:String(n)}
  function ds(d){return d.getFullYear()+"-"+pad2(d.getMonth()+1)+"-"+pad2(d.getDate())}
  var now=new Date();
  var today=new Date(now.getFullYear(),now.getMonth(),now.getDate());
  var S=[],n=0;
  function push(task,st,min){
    S.push({id:"s"+(n++),taskName:task,startTs:st.getTime(),endTs:st.getTime()+min*60000,
            durationMs:min*60000,date:ds(st)});
  }
  for(var i=29;i>=0;i--){
    if(SKIP[i])continue;
    var day=new Date(today.getFullYear(),today.getMonth(),today.getDate()-i);
    var cnt=1+ri(0,2);
    if(i===0)cnt=2;          /* 今天 2 条 */
    if(i===1)cnt=3;          /* 昨天 3 条 */
    for(var j=0;j<cnt;j++){
      var task=pick(TASKS);
      var st;
      if(i===0){
        /* 今天的开始时间必须已经在过去，否则会看到「未来」的记录 */
        var maxMs=now.getTime()-40*60000;
        var minMs=Math.max(day.getTime()+8*3600000,maxMs-3*3600000);
        if(minMs>maxMs)minMs=maxMs;
        st=new Date(minMs+Math.floor(rnd()*(maxMs-minMs)));
        st=new Date(st.getFullYear(),st.getMonth(),st.getDate(),st.getHours(),st.getMinutes(),0,0);
      }else{
        st=new Date(day.getFullYear(),day.getMonth(),day.getDate(),ri(9,20),ri(0,59),0,0);
      }
      push(task,st,ri(25,95));
    }
  }
  S.sort(function(a,b){return b.startTs-a.startTs});
  localStorage.setItem("tomato.sessions",JSON.stringify(S));
  localStorage.setItem("tomato.recentTasks",JSON.stringify(["写论文","读文献","科研","改代码"]));
  localStorage.setItem("tomato.migratedV2","true");
  /* running 界面需要一条「进行中」的专注；其余界面不要 */
  var s=new URLSearchParams(location.search).get("s");
  if(s==="running"){
    localStorage.setItem("tomato.ongoing",JSON.stringify({
      taskName:"写论文",
      startTs:now.getTime()-27*60000-12000,
      pausedAccumMs:0,pausedAt:null,pauseLog:[]
    }));
  }else{
    localStorage.removeItem("tomato.ongoing");
  }
})();
</script>
"""

# ---------------------------------------------------------------- 切界面
SWITCH_JS = r"""
<script>
/* ===== 切到目标界面 ===== */
(function(){
  var s=new URLSearchParams(location.search).get("s")||"idle";
  function openOverlay(id){
    var ov=document.getElementById(id);
    ov.classList.add("open");
    /* 过渡动画在虚拟时钟下捕捉不到，直接写内联样式让它立刻可见 */
    ov.style.opacity="1";ov.style.visibility="visible";ov.style.transition="none";
    var sh=ov.querySelector(".sheet");
    if(sh){sh.style.transform="none";sh.style.transition="none"}
  }
  function hideCards(idx){
    var cards=document.getElementById("page-stats").querySelectorAll(".card");
    for(var i=0;i<idx.length;i++)cards[idx[i]].style.display="none";
  }
  if(s==="sheet"){
    renderRecentChips();
    openOverlay("sheet");
  }
  if(s==="stats"||s==="trend"||s==="backup"){
    switchTab("stats");
  }
  if(s==="trend"){
    /* 不滚动定位：backdrop-filter 一滚动就整片空白。改成把上面的卡片 display:none */
    document.getElementById("ov-grid").style.display="none";
    hideCards([0]);            /* 事项分布 */
  }
  if(s==="backup"){
    document.getElementById("ov-grid").style.display="none";
    hideCards([0,1,2]);        /* 事项分布 / 专注趋势 / 专注记录 */
    openExport();              /* 填 JSON、打开弹层 */
    var ov=document.getElementById("dlg-export");
    ov.style.opacity="1";ov.style.visibility="visible";ov.style.transition="none";
  }
})();
</script>
"""

# ---------------------------------------------------------------- 界面 -> (宽, 高)
SHOTS_PLAN = [
    ("focus-idle", "idle", 480, 1000),
    ("focus-running", "running", 480, 1000),
    ("sheet-task", "sheet", 480, 1000),
    ("stats-overview", "stats", 480, 1500),
    ("stats-trend", "trend", 480, 1150),
    ("stats-backup", "backup", 480, 1000),
]


def find_browser():
    for p in EDGE_CANDIDATES:
        if os.path.exists(p):
            return p
    raise SystemExit("找不到 Edge / Chrome，请改脚本里的 EDGE_CANDIDATES")


def build_shot_html():
    with io.open(os.path.join(WWW, "index.html"), encoding="utf-8") as f:
        html = f.read()
    anchor = '<script src="chart.umd.js"></script>'
    assert anchor in html, "找不到 chart.umd.js 锚点"
    html = html.replace(anchor, SEED_JS + "\n" + anchor, 1)
    assert "</body>" in html, "找不到 </body>"
    html = html.replace("</body>", SWITCH_JS + "\n</body>", 1)
    with io.open(os.path.join(WWW, "__shot.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print("[build] www/__shot.html 生成完毕")


def start_server():
    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"],
        cwd=WWW, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(40):
        time.sleep(0.25)
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/index.html" % PORT, timeout=2).read()
            return proc
        except Exception:
            continue
    proc.kill()
    raise SystemExit("本地服务起不来")


def shoot(browser, name, iface, w, h, outdir):
    out = os.path.join(outdir, name + ".png")
    if os.path.exists(out):
        os.remove(out)
    url = "http://127.0.0.1:%d/__shot.html?s=%s" % (PORT, iface)
    cmd = [
        browser, "--headless=new", "--hide-scrollbars",
        "--window-size=%d,%d" % (w, h),
        "--virtual-time-budget=9000",
        "--screenshot=" + out,
        url,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    ok = os.path.exists(out) and os.path.getsize(out) > 1000
    print("[shot] %-16s %-8s %dx%d  %s" % (name, iface, w, h, "OK" if ok else "失败"))
    if not ok:
        print("        stderr:", (r.stderr or "")[:600])
    return ok


def main():
    outdir = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else SHOTS
    os.makedirs(outdir, exist_ok=True)
    browser = find_browser()
    print("[browser]", browser)
    build_shot_html()
    proc = start_server()
    try:
        allok = True
        for name, iface, w, h in SHOTS_PLAN:
            allok = shoot(browser, name, iface, w, h, outdir) and allok
        print("[done] 全部成功" if allok else "[done] 有失败")
        return 0 if allok else 1
    finally:
        proc.kill()
        tmp = os.path.join(WWW, "__shot.html")
        if os.path.exists(tmp):
            os.remove(tmp)
            print("[clean] 已删除 www/__shot.html")


if __name__ == "__main__":
    sys.exit(main())
