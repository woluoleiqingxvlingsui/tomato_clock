#!/usr/bin/env node
/* 番茄钟 —— 真实浏览器回归测试
 *
 *   node tools/regression/browser-tests.js
 *
 * 跑的是真浏览器（Chrome / Edge 无头模式），不是内存模拟：
 *   - 页面从 127.0.0.1 上的本地服务加载 www/index.html（和用户预览时同源）
 *   - 两个页面在【同一个浏览器、同一个来源】里打开，共享同一份 localStorage，
 *     用来验"多个页面互相覆盖记录"这类问题
 *   - 所有数据都是脚本造的合成数据，不碰任何真实记录
 *
 * 覆盖：
 *   A. 计时与分段：跨零点 1200 毫秒、跨日暂停、零时长分段、整次不足 1 秒
 *   B. 结束记账：历史写盘失败后可恢复、重试幂等、ongoing 清理失败后重开不重复记账
 *   C. 跨日编辑：超范围拒绝（字段全不变）、按占比分配（时间与日期不变）、取整边界、24 小时上限
 *   D. 导入校验：非法日期 / 越界时间戳 / 非法区间被跳过，合法记录照常合并
 *   E. 同源多页面：交错新增不丢、删除不被复活、编辑冲突有提示、进行中会话不被覆盖
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
const WWW = path.join(REPO, 'www');
const BROWSERS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'
];
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.md': 'text/plain; charset=utf-8'
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

/* ---------------------------------------------------------------- 小测试框架 */
let pass = 0, fail = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  [PASS] ' + name); }
  else {
    fail++; failures.push(name + (detail ? ' :: ' + detail : ''));
    console.log('  [FAIL] ' + name + (detail ? '  -> ' + detail : ''));
  }
}
function section(t) { console.log('\n==> ' + t); }

/* ---------------------------------------------------------------- 静态服务（只绑回环） */
function startServer() {
  return new Promise(resolve => {
    const srv = http.createServer((req, res) => {
      const rel = decodeURIComponent(req.url.split('?')[0]);
      const file = path.join(WWW, rel === '/' ? 'index.html' : rel);
      if (!file.startsWith(WWW)) { res.writeHead(403); res.end(); return; }
      fs.readFile(file, (err, buf) => {
        if (err) { res.writeHead(404); res.end('not found'); return; }
        res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
        res.end(buf);
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });
}

/* ---------------------------------------------------------------- 极简 CDP 客户端 */
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    ws.onmessage = ev => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
      }
    };
  }
  static connect(url) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.onerror = e => reject(new Error('websocket error: ' + url));
      ws.onopen = () => resolve(new CDP(ws));
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    this.ws.send(JSON.stringify(msg));
    return new Promise((res, rej) => this.pending.set(id, { res, rej }));
  }
  close() { try { this.ws.close(); } catch (e) {} }
}

/* ---------------------------------------------------------------- 浏览器 + 页面 */
function findBrowser() {
  for (const p of BROWSERS) if (fs.existsSync(p)) return p;
  throw new Error('找不到 Chrome / Edge');
}
async function launch() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'tc-chrome-'));
  const exe = findBrowser();
  const proc = spawn(exe, [
    '--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + profile,
    '--no-first-run', '--no-default-browser-check', '--disable-gpu',
    '--disable-background-networking', '--disable-sync', '--window-size=480,900',
    'about:blank'
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  const portFile = path.join(profile, 'DevToolsActivePort');
  let port = null;
  for (let i = 0; i < 150; i++) {
    if (fs.existsSync(portFile)) {
      const t = fs.readFileSync(portFile, 'utf8').split('\n');
      if (t[0] && t[0].trim()) { port = t[0].trim(); break; }
    }
    await sleep(100);
  }
  if (!port) { proc.kill(); throw new Error('Chrome 调试端口没起来'); }
  const ver = await new Promise((resolve, reject) => {
    http.get('http://127.0.0.1:' + port + '/json/version', res => {
      let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(JSON.parse(b)));
    }).on('error', reject);
  });
  const browser = await CDP.connect(ver.webSocketDebuggerUrl);
  return { browser, proc, profile, port };
}

async function newPage(browser, url, opts = {}) {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  await browser.send('Page.enable', {}, sessionId);
  await browser.send('Runtime.enable', {}, sessionId);
  if (opts.initScript) {
    // 必须在页面脚本跑之前注入：用来模拟"这个环境没有 Web Locks"
    await browser.send('Page.addScriptToEvaluateOnNewDocument', { source: opts.initScript }, sessionId);
  }
  const page = {
    sessionId, targetId,
    async eval(expr) {
      const r = await browser.send('Runtime.evaluate', {
        expression: '(function(){' + expr + '})()',
        awaitPromise: true, returnByValue: true
      }, sessionId);
      if (r.exceptionDetails) {
        throw new Error('页面内异常: ' + JSON.stringify(r.exceptionDetails.exception && r.exceptionDetails.exception.description || r.exceptionDetails.text));
      }
      return r.result.value;
    },
    async goto(u) {
      await browser.send('Page.navigate', { url: u }, sessionId);
      await page.waitFor('return document.readyState === "complete" && !!window.TomatoInternals');
    },
    async reload() {
      await browser.send('Page.reload', { ignoreCache: true }, sessionId);
      await page.waitFor('return document.readyState === "complete" && !!window.TomatoInternals');
    },
    async waitFor(expr, timeout = 8000) {
      const t0 = Date.now();
      for (;;) {
        try { if (await page.eval(expr)) return true; } catch (e) {}
        if (Date.now() - t0 > timeout) throw new Error('等待超时: ' + expr);
        await sleep(60);
      }
    },
    /* 页面脚本运行前注入（用来模拟"这个环境没有 Web Locks"、注入存储故障） */
    async addInitScript(source) {
      const r = await browser.send('Page.addScriptToEvaluateOnNewDocument', { source }, sessionId);
      return r.identifier;
    },
    async removeInitScript(identifier) {
      await browser.send('Page.removeScriptToEvaluateOnNewDocument', { identifier }, sessionId);
    },
    async close() {
      await browser.send('Target.closeTarget', { targetId });
    }
  };
  await page.goto(url);
  return page;
}

/* ---------------------------------------------------------------- 页面内的常用操作 */
const P = {
  /* 造一条"进行中"的会话并刷新页面，让 App 走真实的恢复流程 */
  async seedOngoing(page, { task = '测试', startTs, endTs, pauseLog = [], sessionId = 'seed-1' }) {
    await page.eval(`
      localStorage.clear();
      localStorage.setItem('tomato.sessions','[]');
      localStorage.setItem('tomato.migratedV2','true');
      localStorage.setItem('tomato.ongoing',JSON.stringify({
        taskName:${JSON.stringify(task)},startTs:${startTs},pausedAccumMs:0,
        pausedAt:${endTs},pauseLog:${JSON.stringify(pauseLog)},sessionId:${JSON.stringify(sessionId)}
      }));
      return true;
    `);
    await page.reload();
  },
  sessions: page => page.eval('return JSON.parse(localStorage.getItem("tomato.sessions")||"[]")'),
  ongoing: page => page.eval('return JSON.parse(localStorage.getItem("tomato.ongoing")||"null")'),
  toast: page => page.eval('return document.querySelector("#toast").textContent||""'),
  async finish(page) {
    await page.eval('document.querySelector("#btn-end").click(); return true');
    await page.eval('document.querySelector("#btn-finish").click(); return true');
    await sleep(500);
  },
  /* 走真实界面流程记一条：开始 -> 等一会儿 -> 暂停（把时长定住）-> 结束。
     暂停之后 elapsed 不再增长，所以时长是确定的（>= 1 秒才会生成记录）。 */
  async startPauseFinish(page, name, waitMs = 1200) {
    await page.eval(`
      document.querySelector('#btn-start').click();
      document.querySelector('#task-input').value=${JSON.stringify(name)};
      document.querySelector('#btn-go').click();
      return true;
    `);
    await sleep(waitMs);
    await page.eval('document.querySelector("#btn-pause").click(); return true');
    await sleep(150);
    await page.eval('document.querySelector("#btn-end").click(); document.querySelector("#btn-finish").click(); return true');
    await sleep(600);
  },
  /* 造一段跨零点的本地时间戳（页面所在时区） */
  async midnight(page) {
    return page.eval(`
      const n=new Date();
      return new Date(n.getFullYear(),n.getMonth(),n.getDate()).getTime();
    `);
  }
};

/* ================================================================= 套件 */
async function run() {
  const { srv, port } = await startServer();
  const url = 'http://127.0.0.1:' + port + '/index.html';
  console.log('[server] ' + url + '（只绑 127.0.0.1）');
  const { browser, proc, profile } = await launch();
  console.log('[browser] 已启动无头浏览器');

  const A = await newPage(browser, url);
  const B = await newPage(browser, url);   // 同一个浏览器、同一个来源 -> 共享 localStorage

  try {
    /* ---------------- A. 分段与计时守恒 ---------------- */
    section('A. 跨零点分段与时长守恒');
    const mid = await P.midnight(A);
    // 23:59:59.400 -> 次日 00:00:00.600，共 1200 毫秒
    await P.seedOngoing(A, { startTs: mid - 600, endTs: mid + 600 });
    await P.finish(A);
    let s = await P.sessions(A);
    check('1200 毫秒的跨零点专注产生 2 条记录', s.length === 2, '实际 ' + s.length + ' 条');
    check('两段时长分别是 600 / 600 毫秒', s.length === 2 && s[0].durationMs === 600 && s[1].durationMs === 600,
      JSON.stringify(s.map(x => x.durationMs)));
    check('两段之和 = 净专注时长 1200 毫秒', s.length === 2 && s[0].durationMs + s[1].durationMs === 1200);
    check('两段的时间区间首尾相接（23:59:59.400-00:00:00.000 / 00:00:00.000-00:00:00.600）',
      s.length === 2 && s[0].startTs === mid - 600 && s[0].endTs === mid && s[1].startTs === mid && s[1].endTs === mid + 600);
    check('两段的 date 归属分别是昨天 / 今天',
      s.length === 2 && s[0].date !== s[1].date, JSON.stringify(s.map(x => x.date)));
    check('不足 1 秒的分段显示得出来（不是 0 秒）', s.length === 2 && await A.eval('return window.TomatoInternals.fmtDur(600)') === '0.6秒',
      await A.eval('return window.TomatoInternals.fmtDur(600)'));

    // 整次不足 1 秒：不生成记录
    await P.seedOngoing(A, { startTs: mid, endTs: mid + 500, sessionId: 'seed-tiny' });
    await P.finish(A);
    s = await P.sessions(A);
    check('整次净时长不足 1 秒时不生成记录', s.length === 0, '实际 ' + s.length + ' 条');
    check('并给出"没有产生记录"的提示', (await P.toast(A)).includes('没有产生记录'), await P.toast(A));

    // 跨日暂停：昨天那 1 小时里暂停 30 分钟
    await P.seedOngoing(A, {
      startTs: mid - 3600000, endTs: mid + 3600000,
      pauseLog: [{ from: mid - 2700000, to: mid - 900000 }], sessionId: 'seed-pause'
    });
    await P.finish(A);
    s = await P.sessions(A);
    const sum = s.reduce((a, x) => a + x.durationMs, 0);
    check('跨日暂停：分成 2 段', s.length === 2, '实际 ' + s.length);
    check('跨日暂停：段时长之和 = 净专注时长 5400000 毫秒', sum === 5400000, '实际 ' + sum);
    check('跨日暂停：昨天那段扣掉了段内的 30 分钟暂停',
      s.length === 2 && s[0].durationMs === 1800000 && s[1].durationMs === 3600000,
      JSON.stringify(s.map(x => x.durationMs)));

    // 零时长分段：整段都在暂停里 -> 这段不记，另一段照记
    await P.seedOngoing(A, {
      startTs: mid - 3600000, endTs: mid + 3600000,
      pauseLog: [{ from: mid - 3600000, to: mid }], sessionId: 'seed-zero'
    });
    await P.finish(A);
    s = await P.sessions(A);
    check('整段被暂停覆盖时不产生 0 时长记录', s.length === 1 && s[0].durationMs === 3600000,
      JSON.stringify(s.map(x => [x.durationMs, x.startTs, x.endTs])));
    check('零时长场景总时长仍守恒', s.reduce((a, x) => a + x.durationMs, 0) === 3600000);

    /* ---------------- B. 结束记账的失败与幂等 ---------------- */
    section('B. 结束专注：保存失败可恢复、重试不重复记账');
    await P.seedOngoing(A, { startTs: mid, endTs: mid + 5000, sessionId: 'seed-fail' });
    // 让历史写入失败（模拟配额满 / 存储被禁用）
    await A.eval(`
      window.__origSet=Storage.prototype.setItem;
      Storage.prototype.setItem=function(k,v){ if(k==='tomato.sessions') throw new Error('QuotaExceededError'); return window.__origSet.call(this,k,v); };
      return true;
    `);
    await P.finish(A);
    const failedToast = await P.toast(A);
    s = await P.sessions(A);
    const stillOngoing = await P.ongoing(A);
    check('历史写盘失败时提示明确', failedToast.includes('保存失败'), failedToast);
    check('历史写盘失败时没有产生记录', s.length === 0, '实际 ' + s.length + ' 条');
    check('历史写盘失败时"进行中"的状态还留在盘上（可恢复）', !!stillOngoing && stillOngoing.sessionId === 'seed-fail');
    await A.eval('Storage.prototype.setItem=window.__origSet; return true');
    await P.finish(A);
    s = await P.sessions(A);
    check('恢复后重试成功记上账', s.length === 1 && s[0].durationMs === 5000, JSON.stringify(s));
    check('重试没有把这次专注记两遍', s.filter(x => x.durationMs === 5000).length === 1, '共 ' + s.length + ' 条');

    // 重复点击结束
    await P.seedOngoing(A, { startTs: mid, endTs: mid + 3000, sessionId: 'seed-double' });
    await A.eval('document.querySelector("#btn-end").click(); document.querySelector("#btn-finish").click(); document.querySelector("#btn-finish").click(); return true');
    await sleep(600);
    s = await P.sessions(A);
    check('连点两次结束只记一条', s.filter(x => x.durationMs === 3000).length === 1, '共 ' + s.length + ' 条');

    // 历史已保存、但"进行中"状态清不掉 -> 重开不能重复记账
    await P.seedOngoing(A, { startTs: mid, endTs: mid + 4000, sessionId: 'seed-stuck' });
    await A.eval(`
      window.__origRem=Storage.prototype.removeItem;
      Storage.prototype.removeItem=function(k){ if(k==='tomato.ongoing') throw new Error('remove blocked'); return window.__origRem.call(this,k); };
      return true;
    `);
    await P.finish(A);
    s = await P.sessions(A);
    check('清理失败但历史已经记上账', s.length === 1 && s[0].durationMs === 4000, JSON.stringify(s.map(x => x.durationMs)));
    const stuck = await P.ongoing(A);
    check('清理失败时"进行中"状态还留在盘上', !!stuck && stuck.sessionId === 'seed-stuck');
    await A.eval('Storage.prototype.removeItem=window.__origRem; return true');
    await A.reload();
    s = await P.sessions(A);
    const afterReload = await P.ongoing(A);
    check('重开后没有重复记账（还是 1 条）', s.length === 1 && s[0].durationMs === 4000, '共 ' + s.length + ' 条');
    check('重开后自动认领并清掉那条"进行中"状态', !afterReload, JSON.stringify(afterReload));

    /* ---------------- C. 跨日编辑 ---------------- */
    section('C. 跨日编辑规则');
    const seedGroup = `
      localStorage.clear();
      localStorage.setItem('tomato.migratedV2','true');
      localStorage.setItem('tomato.sessions',JSON.stringify([
        {id:'g1a',gid:'g1',taskName:'科研',startTs:${'${MID}'} - 3600000,endTs:${'${MID}'},durationMs:3600000,date:'${'${D0}'}'},
        {id:'g1b',gid:'g1',taskName:'科研',startTs:${'${MID}'},endTs:${'${MID}'} + 3600000,durationMs:3600000,date:'${'${D1}'}'}
      ]));
      localStorage.removeItem('tomato.ongoing');
      return true;
    `;
    const dates = await A.eval(`
      const n=new Date();
      const p=x=>x.getFullYear()+'-'+String(x.getMonth()+1).padStart(2,'0')+'-'+String(x.getDate()).padStart(2,'0');
      const m=new Date(n.getFullYear(),n.getMonth(),n.getDate()).getTime();
      return JSON.stringify({mid:m,d0:p(new Date(n.getFullYear(),n.getMonth(),n.getDate()-1)),d1:p(n)});
    `);
    const D = JSON.parse(dates);
    await A.eval(seedGroup.replace(/\$\{MID\}/g, D.mid).replace(/\$\{D0\}/g, D.d0).replace(/\$\{D1\}/g, D.d1));
    await A.reload();
    await A.eval('switchTab("stats"); return true');

    const before = await P.sessions(A);
    const snapshot = JSON.stringify(before);
    // 打开编辑弹窗 -> 改成 6 小时 -> 必须整次拒绝，所有字段不变
    // （模拟真实用户改时长：赋值 + 派发 input 事件，App 靠这个判定"用户动过时长栏"）
    await A.eval(`
      const s=sessions.find(x=>x.id==='g1a');
      openEdit(s);
      const inp=document.querySelector('#edit-dur-input');
      inp.value='6:00:00';
      inp.dispatchEvent(new Event('input',{bubbles:true}));
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(400);
    const toast6h = await P.toast(A);
    let after = await P.sessions(A);
    check('整组改成 6 小时被拒绝（提示）', toast6h.includes('改不了'), toast6h);
    check('整组改成 6 小时后所有字段原封不动',
      JSON.stringify(after) === snapshot, JSON.stringify(after));

    // 改成 90 分钟 -> 成功，时间与日期不动
    await A.eval(`
      const s=sessions.find(x=>x.id==='g1a');
      openEdit(s);
      document.querySelector('#edit-name').value='写论文';
      const inp=document.querySelector('#edit-dur-input');
      inp.value='1:30:00';
      inp.dispatchEvent(new Event('input',{bubbles:true}));
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(400);
    after = await P.sessions(A);
    const total = after.reduce((a, x) => a + x.durationMs, 0);
    check('整组改成 90 分钟成功', (await P.toast(A)).includes('已保存'), await P.toast(A));
    check('两段之和精确等于 90 分钟（5400000 毫秒）', total === 5400000, '实际 ' + total);
    check('按原占比分配：每段 45 分钟',
      after.length === 2 && after[0].durationMs === 2700000 && after[1].durationMs === 2700000,
      JSON.stringify(after.map(x => x.durationMs)));
    check('startTs / endTs / date 全部保持原样',
      after[0].startTs === before[0].startTs && after[0].endTs === before[0].endTs &&
      after[1].startTs === before[1].startTs && after[1].endTs === before[1].endTs &&
      after[0].date === before[0].date && after[1].date === before[1].date);
    check('名称改了，组内两条一起改', after.every(x => x.taskName === '写论文'), JSON.stringify(after.map(x => x.taskName)));

    // 24 小时上限：越界时名称也不落盘
    const beforeLimit = JSON.stringify(await P.sessions(A));
    await A.eval(`
      const s=sessions.find(x=>x.id==='g1a');
      openEdit(s);
      document.querySelector('#edit-name').value='不该被保存';
      const inp=document.querySelector('#edit-dur-input');
      inp.value='25:00:00';
      inp.dispatchEvent(new Event('input',{bubbles:true}));
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(400);
    check('超过 24 小时被拦下', (await P.toast(A)).includes('24 小时'), await P.toast(A));
    check('越界时名称和时长都没有落盘', JSON.stringify(await P.sessions(A)) === beforeLimit);

    // 取整边界：毫秒级的零头分配（直接验分配函数）
    const alloc = await A.eval(`
      const T=window.TomatoInternals;
      const a=T.allocateGroupDurations([{id:'a',durationMs:1,startTs:0,endTs:1000},{id:'b',durationMs:999,startTs:1000,endTs:2000}],999);
      const b=T.allocateGroupDurations([{id:'a',durationMs:1000,startTs:0,endTs:1000},{id:'b',durationMs:1000,startTs:1000,endTs:2000}],2001);
      const c=T.allocateGroupDurations([{id:'a',durationMs:1000,startTs:0,endTs:1000},{id:'b',durationMs:1000,startTs:1000,endTs:2000}],2000);
      return JSON.stringify({
        a:a.ok?a.values:null, aSum:a.ok?a.values.a+a.values.b:null,
        bOk:b.ok, bMsg:b.msg, cOk:c.ok, cSum:c.ok?c.values.a+c.values.b:null
      });
    `);
    const AL = JSON.parse(alloc);
    check('取整边界：999 毫秒按占比分下来仍然精确等于 999',
      AL.aOk !== false && AL.aSum === 999 && AL.a.a === 1 && AL.a.b === 998, alloc);
    check('超出各段容量时整次拒绝', AL.bOk === false, alloc);
    check('刚好等于各段容量之和时接受且总数精确', AL.cOk === true && AL.cSum === 2000, alloc);

    /* ---------------- D. 导入校验 ---------------- */
    section('D. 导入校验');
    const importRes = await A.eval(`
      const t=document.querySelector('#import-text');
      const good={id:'imp-1',taskName:'合法',startTs:1700000000000,endTs:1700003600000,durationMs:3600000,date:'2023-11-15'};
      const noDate={id:'imp-2',taskName:'缺日期',startTs:1700000000000,endTs:1700000600000,durationMs:600000};
      const badDate={id:'imp-3',taskName:'假日期',startTs:1700000000000,endTs:1700000600000,durationMs:600000,date:'2026-02-30'};
      const badTs={id:'imp-4',taskName:'越界',startTs:1e18,endTs:1e18+1000,durationMs:1000};
      const badRange={id:'imp-5',taskName:'倒挂',startTs:1700000600000,endTs:1700000000000,durationMs:1000};
      const badDur={id:'imp-6',taskName:'超区间',startTs:1700000000000,endTs:1700000600000,durationMs:999999};
      t.value=JSON.stringify({app:'tomato-clock',format:1,sessions:[good,noDate,badDate,badTs,badRange,badDur]});
      document.querySelector('#btn-import-ok').click();
      return true;
    `);
    await sleep(500);
    const impToast = await P.toast(A);
    const imported = await P.sessions(A);
    const ids = imported.map(x => x.id);
    check('非法记录被跳过并报告数量', impToast.includes('跳过 4 条'), impToast);
    check('合法记录合并进来了', ids.includes('imp-1') && ids.includes('imp-2'), JSON.stringify(ids));
    check('假日期 / 越界时间戳 / 倒挂区间 / 超区间时长 都没进来',
      !ids.includes('imp-3') && !ids.includes('imp-4') && !ids.includes('imp-5') && !ids.includes('imp-6'), JSON.stringify(ids));
    const g1 = imported.find(x => x.id === 'imp-1');
    const g2 = imported.find(x => x.id === 'imp-2');
    check('已有的合法 date 原样保留（没被当前时区改写）', g1 && g1.date === '2023-11-15', g1 && g1.date);
    check('缺日期的从合法 startTs 补齐', !!g2 && /^\d{4}-\d{2}-\d{2}$/.test(g2.date), g2 && g2.date);

    // 合法备份往返：毫秒精度不丢（逐条比对语义字段）
    const roundTrip = await A.eval(`
      const T=window.TomatoInternals;
      const src=JSON.parse(localStorage.getItem('tomato.sessions'));
      const keys=['id','gid','taskName','startTs','endTs','durationMs','date'];
      let same=true, detail='';
      for(const s of src){
        const r=T.normalizeSession(s);
        if(!r){same=false;detail='normalizeSession 丢了 '+s.id;break}
        for(const k of keys){
          const a=(s[k]===undefined)?null:s[k], b=(r[k]===undefined)?null:r[k];
          if(a!==b){same=false;detail=s.id+'.'+k+': '+a+' != '+b;break}
        }
        if(!same)break;
      }
      return JSON.stringify({same,detail,n:src.length});
    `);
    const RT = JSON.parse(roundTrip);
    check('导出再导入不丢毫秒精度（逐条等价）', RT.same === true, roundTrip);

    /* ---------------- E. 同源多页面 ---------------- */
    section('E. 同源多页面交错（两个真实页面共享同一份 localStorage）');
    await A.eval(`localStorage.clear(); localStorage.setItem('tomato.migratedV2','true'); localStorage.removeItem('tomato.ongoing'); return true`);
    await B.reload();

    // E1：两个页面各记一条，都要保住
    await P.startPauseFinish(A, '页面A');
    await P.startPauseFinish(B, '页面B');
    let both = await P.sessions(A);
    const names = both.map(x => x.taskName);
    check('两个页面产生的记录都保留', names.includes('页面A') && names.includes('页面B'), JSON.stringify(names));

    // E2：删除不能被"旧页面"复活。
    // 前提要成立：旧快照必须在【删除之前】取，并且确实包含被删的那条。
    const targetId = both.find(x => x.taskName === '页面B').id;
    await B.eval('window.__stale=sessions.slice(); return true');
    const staleHas = await B.eval(`return window.__stale.some(x=>x.id===${JSON.stringify(targetId)})`);
    check('测试前提：B 在删除前取的旧快照确实包含目标记录', staleHas === true, 'staleHas=' + staleHas);
    await A.eval(`
      switchTab('stats');
      document.querySelector('.rec-del[data-id="${targetId}"]').click();
      document.querySelector('#btn-del-yes').click();
      return true;
    `);
    await sleep(500);
    let afterDel = await P.sessions(A);
    check('页面 A 删掉了页面 B 的那条', !afterDel.some(x => x.id === targetId), JSON.stringify(afterDel.map(x => x.id)));
    // 把 B 的内存换回删除前那份旧快照（里面还留着被删的记录），再让 B 写一次
    await B.eval(`
      sessions=window.__stale;                      // 模拟没收到 storage 事件的旧页面
      const still=window.__stale.some(x=>x.id===${JSON.stringify(targetId)});
      return still;
    `).then(v => check('旧页面此刻确实还持有被删记录的那份快照', v === true));
    await P.startPauseFinish(B, '页面B再记一条');
    afterDel = await P.sessions(A);
    check('旧页面写入后，被删掉的记录没有被复活',
      !afterDel.some(x => x.id === targetId), JSON.stringify(afterDel.map(x => x.id + ':' + x.taskName)));
    check('旧页面的新记录照样保存下来了', afterDel.some(x => x.taskName === '页面B再记一条'), JSON.stringify(afterDel.map(x => x.taskName)));

    // E3：编辑冲突 —— B 先打开编辑弹窗，A 再改同一条，B 随后保存
    // （改名称来触发冲突：按新规则，时长不能改到原时间区间之外）
    const editId = afterDel.find(x => x.taskName === '页面A').id;
    await B.eval(`
      switchTab('stats');
      const s=sessions.find(x=>x.id===${JSON.stringify(editId)});
      openEdit(s);
      return true;
    `);
    await A.eval(`
      switchTab('stats');
      const s=sessions.find(x=>x.id===${JSON.stringify(editId)});
      openEdit(s);
      document.querySelector('#edit-name').value='A改的名字';
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(500);
    await B.eval(`
      document.querySelector('#edit-name').value='B改的名字';
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(600);
    const conflictToast = await P.toast(B);
    const afterConflict = await P.sessions(A);
    const conflictRec = afterConflict.find(x => x.id === editId);
    check('旧页面的编辑被挡下来并提示冲突', conflictToast.includes('另一个页面'), conflictToast);
    check('冲突时没有静默覆盖（还是页面 A 写的名字）',
      conflictRec && conflictRec.taskName === 'A改的名字', conflictRec && conflictRec.taskName);

    // E4：进行中的会话不能被第二个页面无提示覆盖
    await A.eval(`
      localStorage.removeItem('tomato.ongoing');
      document.querySelector('#btn-start').click();
      document.querySelector('#task-input').value='A的专注';
      document.querySelector('#btn-go').click();
      return true;
    `);
    await sleep(500);
    const ongBefore = await P.ongoing(A);
    check('页面 A 已经开始了进行中的专注', !!ongBefore && ongBefore.taskName === 'A的专注', JSON.stringify(ongBefore));

    // B 通过 storage 事件看到同一个会话（同一 origin 一致）
    await sleep(400);
    const bSees = await B.eval('return !!(document.querySelector("#focus-running") && !document.querySelector("#focus-running").classList.contains("hidden"))');
    check('另一个页面也能看到同一个进行中的会话', bSees === true);

    // 模拟"还没收到通知的旧页面"：把 B 的内存状态退回没有会话，再点开始
    await B.eval('ongoing=null; return true');
    await B.eval(`
      document.querySelector('#btn-start').click();
      document.querySelector('#task-input').value='B想覆盖';
      document.querySelector('#btn-go').click();
      return true;
    `);
    await sleep(700);
    const ongAfter = await P.ongoing(A);
    const bToast = await P.toast(B);
    check('第二个页面不能覆盖第一个页面的进行中会话',
      !!ongBefore && !!ongAfter && ongAfter.sessionId === ongBefore.sessionId && ongAfter.taskName === 'A的专注',
      JSON.stringify(ongAfter));
    check('第二个页面给出了明确提示', bToast.includes('另一个标签页'), bToast);

    /* ---------------- F. 没有 Web Locks 的环境 ---------------- */
    section('F. 没有 Web Locks 时：写权限唯一（真实浏览器，启动前禁用 navigator.locks）');
    const noLocks = `
      try{Object.defineProperty(Navigator.prototype,'locks',{configurable:true,get:function(){return undefined}});}catch(e){}
      try{Object.defineProperty(navigator,'locks',{configurable:true,value:undefined});}catch(e){}
    `;
    // 清掉上一段留下的"进行中"会话，免得干扰这一段
    await A.eval('localStorage.removeItem("tomato.ongoing"); return true');
    const F1 = await newPage(browser, url, { initScript: noLocks });
    const F2 = await newPage(browser, url, { initScript: noLocks });    await F1.waitFor('return window.TomatoInternals.writerState().role!=="pending"', 20000);
    await F2.waitFor('return window.TomatoInternals.writerState().role!=="pending"', 20000);
    const w1 = await F1.eval('return window.TomatoInternals.writerState()');
    const w2 = await F2.eval('return window.TomatoInternals.writerState()');
    check('无 Web Locks：应用仍能正常启动（没崩）', !!w1 && !!w2, JSON.stringify([w1, w2]));
    check('无 Web Locks：确实检测到没有 Web Locks',
      (await F1.eval('return window.TomatoInternals.hasWebLocks')) === false);
    const owners = [w1, w2].filter(w => w.role === 'owner').length;
    const followers = [w1, w2].filter(w => w.role === 'follower').length;
    check('两个页面竞争写权限：只有一个拿到写权限', owners === 1, JSON.stringify([w1, w2]));
    check('另一个页面进入只读', followers === 1, JSON.stringify([w1, w2]));
    const owner = w1.role === 'owner' ? F1 : F2;
    const follower = w1.role === 'owner' ? F2 : F1;
    await P.startPauseFinish(owner, '独占页面的记录');
    const beforeRO = await P.sessions(owner);
    check('拿到写权限的页面能正常写记录', beforeRO.some(x => x.taskName === '独占页面的记录'),
      JSON.stringify(beforeRO.map(x => x.taskName)));
    await follower.eval(`
      document.querySelector('#btn-start').click();
      document.querySelector('#task-input').value='只读页面想写';
      document.querySelector('#btn-go').click();
      return true;
    `);
    await sleep(800);
    const roToast = await follower.eval('return document.querySelector("#toast").textContent||""');
    check('只读页面的写入被挡下并明确提示', roToast.includes('只读'), roToast);
    const afterRO = await P.sessions(owner);
    check('只读页面没有写进任何记录', !afterRO.some(x => x.taskName === '只读页面想写'),
      JSON.stringify(afterRO.map(x => x.taskName)));
    check('只读页面的写入没有影响写权限页面的数据', afterRO.some(x => x.taskName === '独占页面的记录'),
      JSON.stringify(afterRO.map(x => x.taskName)));
    check('只读页面仍然能读到写权限页面的数据',
      (await follower.eval('return JSON.parse(localStorage.getItem("tomato.sessions")||"[]").some(x=>x.taskName==="独占页面的记录")')) === true);
    // 写权限的页面关掉后，只读页面要能接手（不能永久卡在只读）
    await owner.close();
    await follower.waitFor('return window.TomatoInternals.writerState().role==="owner"', 25000);
    check('【普通关页接管】写权限页面关掉后，只读页面能接手写权限', true);
    await P.startPauseFinish(follower, '接手后的记录');
    const afterTakeover = await P.sessions(follower);
    check('【普通关页接管】接手后能正常写入', afterTakeover.some(x => x.taskName === '接手后的记录'),
      JSON.stringify(afterTakeover.map(x => x.taskName)));
    // 把这一组页面关掉，后面要单独测"冻结后接管"，不能有别的页面占着写权限
    await follower.close();
    await sleep(300);

    /* ---- F2. 冻结 → 接管 → 恢复：旧 owner 不能凭缓存身份写盘 ---- */
    section('F2. 页面被冻结后由别人接管，旧 owner 恢复时必须写不进去（真实浏览器 + CDP 冻结）');
    // 上一组页面的租约还在盘上（关页后租约最多再活一个 TTL），
    // 这里先清掉，让这一组从零开始竞选，避免读到上一组的残留 owner
    await A.eval('localStorage.removeItem("tomato.lock.writer"); return true');
    await sleep(200);
    const K1 = await newPage(browser, url, { initScript: noLocks });
    const K2 = await newPage(browser, url, { initScript: noLocks });
    // 等到其中一页真的拿到写权限（"follower" 也算定下角色，所以要轮询 owner）
    let k1 = null, k2 = null;
    for (let i = 0; i < 80; i++) {
      k1 = await K1.eval('return window.TomatoInternals.writerState()');
      k2 = await K2.eval('return window.TomatoInternals.writerState()');
      if (k1.role === 'owner' || k2.role === 'owner') break;
      await sleep(200);
    }
    check('冻结场景前置：K1/K2 里恰好一页拿到写权限',
      (k1.role === 'owner' ? 1 : 0) + (k2.role === 'owner' ? 1 : 0) === 1,
      JSON.stringify([k1, k2]));
    const Kowner = k1.role === 'owner' ? K1 : K2;
    const Kother = k1.role === 'owner' ? K2 : K1;
    // 先让写权限页产生一条正常数据，稍后用来核对"接管方的数据完整"
    await P.startPauseFinish(Kowner, '接管前的记录');
    const beforeFreeze = await P.sessions(Kowner);
    check('冻结前：写权限页有数据', beforeFreeze.some(x => x.taskName === '接管前的记录'),
      JSON.stringify(beforeFreeze.map(x => x.taskName)));

    // 在写权限页里排队一个"合成记录"写入，但把队列挂起 —— 等冻结、接管、恢复之后才真正执行
    await Kowner.eval(`
      window.__gate=new Promise(res=>{document.addEventListener('resume',()=>res(),{once:true});});
      localQueue=window.__gate.then(()=>Promise.resolve());
      window.__pending=mutateSessions(cur=>{
        cur.push({id:'frozen-synth',taskName:'冻结前排队的合成记录',
                  startTs:1700000000000,endTs:1700003600000,durationMs:3600000,date:'2023-11-15'});
      });
      return true;
    `);
    // 冻结写权限页：定时器与事件都停掉，租约会自然过期
    await browser.send('Page.setWebLifecycleState', { state: 'frozen' }, Kowner.sessionId);
    // 另一边接管写权限
    await Kother.waitFor('return window.TomatoInternals.writerState().role==="owner"', 30000);
    const kOwnerNow = await Kother.eval('return window.TomatoInternals.writerState()');
    check('冻结后：另一个页面接管了写权限', kOwnerNow.role === 'owner', JSON.stringify(kOwnerNow));
    // 恢复写权限页：它内存里的角色还是 owner（旧缓存），但盘上已经不是它了
    await browser.send('Page.setWebLifecycleState', { state: 'active' }, Kowner.sessionId);
    await sleep(1500);
    const pending = await Kowner.eval('return window.__pending.then(r=>JSON.stringify(r)).catch(e=>"ERR:"+e.message)');
    check('冻结前排队的写入被拒绝（没有 ok:true）', !/ok":true/.test(pending), pending);
    const afterResume = await P.sessions(Kother);
    check('冻结前排队的合成记录没有落盘', !afterResume.some(x => x.taskName === '冻结前排队的合成记录'),
      JSON.stringify(afterResume.map(x => x.taskName)));
    check('接管方的数据完整（原有记录一条没少）',
      afterResume.some(x => x.taskName === '接管前的记录') && afterResume.length === beforeFreeze.length,
      JSON.stringify(afterResume.map(x => x.taskName)) + ' / before=' + beforeFreeze.length);
    const kOld = await Kowner.eval('return window.TomatoInternals.writerState()');
    check('恢复后的旧 owner 已被降级（盘上判定为已被接管）', kOld.disk !== 'valid' && kOld.canWrite === false,
      JSON.stringify(kOld));
    // 接管方仍然能正常写
    await P.startPauseFinish(Kother, '接管后写的记录');
    const afterK = await P.sessions(Kother);
    check('接管方仍然能正常写入', afterK.some(x => x.taskName === '接管后写的记录'),
      JSON.stringify(afterK.map(x => x.taskName)));
    check('旧 owner 恢复后也写不进去（canWrite=false）',
      (await Kowner.eval('return window.TomatoInternals.writerState().canWrite')) === false,
      JSON.stringify(await Kowner.eval('return window.TomatoInternals.writerState()')));
    await Kowner.close(); await Kother.close();

    /* ---------------- G. 只改名称保留毫秒 ---------------- */
    section('G. 只改名称必须逐毫秒保留原时长');
    await A.eval(`
      localStorage.clear();
      localStorage.setItem('tomato.migratedV2','true');
      localStorage.setItem('tomato.sessions',JSON.stringify([
        {id:'ms-1750',taskName:'毫秒一',startTs:1700000000000,endTs:1700000001750,durationMs:1750,date:'2023-11-15'},
        {id:'ms-1250',taskName:'毫秒二',startTs:1700000000000,endTs:1700000001250,durationMs:1250,date:'2023-11-15'}
      ]));
      localStorage.removeItem('tomato.ongoing');
      return true;
    `);
    await A.reload();
    await A.eval('switchTab("stats"); return true');
    for (const [id, want, label] of [['ms-1750', 1750, '1750'], ['ms-1250', 1250, '1250']]) {
      await A.eval(`
        const s=sessions.find(x=>x.id===${JSON.stringify(id)});
        openEdit(s);
        document.querySelector('#edit-name').value='只改了名字';
        document.querySelector('#btn-edit-yes').click();
        return true;
      `);
      await sleep(450);
      const rec = (await P.sessions(A)).find(x => x.id === id);
      check(label + ' 毫秒的记录只改名称后时长不变', rec && rec.durationMs === want, rec && String(rec.durationMs));
      check(label + ' 毫秒的记录改名成功', rec && rec.taskName === '只改了名字', rec && rec.taskName);
    }
    // 明确改了时长：仍然走容量限制，整次拒绝
    const beforeTouch = JSON.stringify(await P.sessions(A));
    await A.eval(`
      const s=sessions.find(x=>x.id==='ms-1750');
      openEdit(s);
      const inp=document.querySelector('#edit-dur-input');
      inp.value='0:00:03';
      inp.dispatchEvent(new Event('input',{bubbles:true}));
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(450);
    check('明确把时长改到超出原区间时被拒绝', (await P.toast(A)).includes('改不了'), await P.toast(A));
    check('被拒绝时字段一个都没变', JSON.stringify(await P.sessions(A)) === beforeTouch);
    // 跨日整组（各段带毫秒）改名：每段毫秒都要原样保留
    const mid2 = await P.midnight(A);
    const dts = await A.eval(`
      const n=new Date();
      const p=x=>x.getFullYear()+'-'+String(x.getMonth()+1).padStart(2,'0')+'-'+String(x.getDate()).padStart(2,'0');
      return JSON.stringify({d0:p(new Date(n.getFullYear(),n.getMonth(),n.getDate()-1)),d1:p(n)});
    `);
    const D2 = JSON.parse(dts);
    await A.eval(`
      localStorage.setItem('tomato.sessions',JSON.stringify([
        {id:'gm-a',gid:'gm',taskName:'跨日组',startTs:${mid2 - 1750},endTs:${mid2},durationMs:1750,date:${JSON.stringify(D2.d0)}},
        {id:'gm-b',gid:'gm',taskName:'跨日组',startTs:${mid2},endTs:${mid2 + 1250},durationMs:1250,date:${JSON.stringify(D2.d1)}}
      ]));
      return true;
    `);
    await A.reload();
    await A.eval('switchTab("stats"); return true');
    await A.eval(`
      const s=sessions.find(x=>x.id==='gm-a');
      openEdit(s);
      document.querySelector('#edit-name').value='整组改名';
      document.querySelector('#btn-edit-yes').click();
      return true;
    `);
    await sleep(450);
    const grp = (await P.sessions(A)).filter(x => x.gid === 'gm').sort((a, b) => a.startTs - b.startTs);
    check('跨日整组只改名：两段时长分别还是 1750 / 1250 毫秒',
      grp.length === 2 && grp[0].durationMs === 1750 && grp[1].durationMs === 1250, JSON.stringify(grp.map(x => x.durationMs)));
    check('跨日整组只改名：两段名称都改了', grp.length === 2 && grp.every(x => x.taskName === '整组改名'), JSON.stringify(grp.map(x => x.taskName)));
    check('跨日整组只改名：起止时间与日期没动',
      grp.length === 2 && grp[0].startTs === mid2 - 1750 && grp[1].endTs === mid2 + 1250 &&
      grp[0].date === D2.d0 && grp[1].date === D2.d1);

    /* ---------------- H. 旧数据迁移：并发安全 + 失败可重试 ---------------- */
    section('H. 旧数据迁移：并发安全 + 失败可重试');
    await A.eval(`
      localStorage.clear();
      localStorage.setItem('tomato.records',JSON.stringify([
        {type:'work',id:'legacy-1',minutes:25,ts:1700000000000,taskName:'旧专注'}
      ]));
      localStorage.removeItem('tomato.migratedV2');
      localStorage.removeItem('tomato.sessions');
      localStorage.removeItem('tomato.ongoing');
      return true;
    `);
    // 先占住 sessions 写锁，让两个新页面的迁移排队
    await A.eval(`
      window.__hold=navigator.locks.request('tomato.lock.sessions',()=>new Promise(r=>setTimeout(r,3000)));
      return true;
    `);
    const H1 = await newPage(browser, url);
    const H2 = await newPage(browser, url);
    await sleep(4200);          // 等锁释放、排队中的迁移依次执行
    await sleep(800);
    const mig = await P.sessions(A);
    const migOld = mig.filter(x => x.taskName === '旧专注');
    check('两个页面同时启动迁移：只迁出一条（不是两条）', migOld.length === 1,
      JSON.stringify(mig.map(x => x.id + ':' + x.taskName)));
    check('迁移后的时长是 25 分钟（1500000 毫秒）', migOld.length === 1 && migOld[0].durationMs === 1500000,
      JSON.stringify(migOld.map(x => x.durationMs)));
    check('迁移后的记录 id 唯一，没有同 id 重复', new Set(mig.map(x => x.id)).size === mig.length,
      JSON.stringify(mig.map(x => x.id)));
    check('原始旧数据没有被删除',
      (await A.eval('return (JSON.parse(localStorage.getItem("tomato.records")||"[]")).length')) === 1);
    check('迁移完成后写上了标记', (await A.eval('return localStorage.getItem("tomato.migratedV2")')) !== null);

    // 写盘失败：不能标"迁移完成"，刷新后要能重试
    await A.eval(`
      localStorage.removeItem('tomato.migratedV2');
      localStorage.removeItem('tomato.sessions');
      return true;
    `);
    const faultId = await A.addInitScript(`
      (function(){
        const orig=Storage.prototype.setItem;
        Storage.prototype.setItem=function(k,v){ if(k==='tomato.sessions') throw new Error('QuotaExceededError'); return orig.call(this,k,v); };
      })();
    `);
    await A.reload();
    await sleep(900);
    check('迁移写盘失败时不会标记"迁移完成"',
      (await A.eval('return localStorage.getItem("tomato.migratedV2")')) === null,
      'flag=' + (await A.eval('return localStorage.getItem("tomato.migratedV2")')));
    check('迁移写盘失败时不产生记录', (await P.sessions(A)).length === 0,
      JSON.stringify((await P.sessions(A)).map(x => x.id)));
    await A.removeInitScript(faultId);
    await A.reload();
    await sleep(900);
    const mig2 = await P.sessions(A);
    check('去掉故障后刷新：迁移重试成功，且仍然只有一条',
      mig2.filter(x => x.taskName === '旧专注').length === 1, JSON.stringify(mig2.map(x => x.id + ':' + x.taskName)));
    check('重试成功后标记了迁移完成',
      (await A.eval('return localStorage.getItem("tomato.migratedV2")')) !== null);
    check('重试没有覆盖或删除已有的新记录：旧数据仍在',
      (await A.eval('return (JSON.parse(localStorage.getItem("tomato.records")||"[]")).length')) === 1);
  } finally {
    try { browser.close(); } catch (e) {}
    try { proc.kill(); } catch (e) {}
    try { srv.close(); } catch (e) {}
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {}
  }

  console.log('\n通过 ' + pass + ' 项，失败 ' + fail + ' 项');
  if (fail) {
    console.log('失败项：');
    failures.forEach(f => console.log('  - ' + f));
    process.exit(1);
  }
}

run().catch(e => { console.error('测试脚本自身出错：', e); process.exit(2); });
