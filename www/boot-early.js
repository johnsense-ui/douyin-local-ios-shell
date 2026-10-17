/**
 * 壳内早期引导。**页面里第一个执行的脚本**（同步、非 module）。
 *
 * 【职责变了】不再改路由。
 *   旧版靠运行时把 history 改成 hash，结果第一次能开、第二次白屏 ——
 *   App 内跳转时 vue-router 的 createWebHistory 又把真实路径写回去
 *   （capacitor://localhost/collections），Capacitor 的 asset handler 找不到文件就空白。
 *   现在路由在**构建期**就切成 createWebHashHistory（见 scripts/copy-web.mjs），
 *   这个脚本只管三件事：
 *     1. 打 window.__IS_SHELL__ 标记（net-patch / native-bridge 靠它判断要不要接管）
 *     2. 没填服务器地址 → 立刻弹输入框（挡住白屏）
 *     3. 屏上诊断浮层（Windows 上没有 Safari 远程调试，这是唯一能看到错误的通道）
 */
(function () {
  'use strict';

  var proto = String(location.protocol || '').toLowerCase();
  var isCapacitor = proto.indexOf('capacitor:') === 0 || proto.indexOf('ionic:') === 0;
  var isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());

  // 也可以用 ?shell=1 在普通浏览器里强制开启（调试用）
  var forced = /[?&]shell=1/.test(location.search);
  if (!isCapacitor && !isNative && !forced) return;

  window.__IS_SHELL__ = true;
  window.__SHELL_PROTO__ = proto;

  // ---------------------------------------------------------------- 诊断浮层
  var lines = [];
  function showDiag() {
    if (!document.body || document.getElementById('dzc-diag')) return;
    var box = document.createElement('div');
    box.id = 'dzc-diag';
    box.style.cssText =
      'position:fixed;left:0;right:0;bottom:0;max-height:45%;overflow:auto;z-index:2147483647;' +
      'background:rgba(0,0,0,.9);color:#0f0;font:11px/1.5 ui-monospace,Menlo,monospace;' +
      'padding:8px 10px;white-space:pre-wrap;word-break:break-all;border-top:1px solid #333;';
    box.textContent = lines.join('\n');
    box.addEventListener('click', function () {
      box.remove();
    });
    document.body.appendChild(box);
  }
  window.__DZC_LOG__ = function (msg) {
    lines.push(msg);
    if (lines.length > 50) lines.shift();
    var box = document.getElementById('dzc-diag');
    if (box) box.textContent = lines.join('\n');
  };
  window.addEventListener('error', function (e) {
    window.__DZC_LOG__('[error] ' + (e.message || '') + ' @ ' + String(e.filename || '').split('/').pop() + ':' + e.lineno);
    showDiag();
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    window.__DZC_LOG__('[reject] ' + ((r && (r.message || r)) || 'unknown'));
    showDiag();
  });
  window.__DZC_LOG__('boot proto=' + proto + ' native=' + isNative + ' hash=' + location.hash);

  // ---------------------------------------------------------------- 服务器地址
  var SERVER_KEY = 'dzc.serverBase';

  function base() {
    return String(localStorage.getItem(SERVER_KEY) || '').replace(/\/+$/, '');
  }

  function askServer() {
    if (document.getElementById('dzc-server-setup')) return;
    var shell = document.createElement('div');
    shell.id = 'dzc-server-setup';
    shell.innerHTML =
      '<div style="position:fixed;inset:0;z-index:2147483646;background:#111;color:#eee;' +
      'display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;' +
      'font:15px -apple-system,sans-serif;padding:24px;box-sizing:border-box;">' +
      '<div style="font-size:19px;font-weight:600;">填写服务器地址</div>' +
      '<div style="color:#9aa;font-size:13px;line-height:1.7;text-align:center;max-width:320px;">' +
      '例如 <b>http://192.168.1.10:6688</b><br>或你的 Tailscale 地址<br>（必须带 http:// 或 https://）' +
      '</div>' +
      '<input id="dzc-server-input" placeholder="http://..." autocomplete="off" ' +
      'autocapitalize="off" autocorrect="off" spellcheck="false" inputmode="url" ' +
      'style="width:100%;max-width:320px;padding:14px;border-radius:10px;border:1px solid #333;' +
      'background:#1b1b1f;color:#eee;font-size:16px;box-sizing:border-box;" />' +
      '<button id="dzc-server-ok" style="width:100%;max-width:320px;padding:14px;border-radius:10px;' +
      'border:none;background:#fe2c55;color:#fff;font-size:16px;box-sizing:border-box;">保存并继续</button>' +
      '<div id="dzc-server-err" style="color:#f55;font-size:13px;height:18px;"></div>' +
      '<div style="color:#555;font-size:11px;margin-top:8px;">' + proto + '//' + location.host + '</div>' +
      '</div>';
    document.body.appendChild(shell);

    document.getElementById('dzc-server-ok').addEventListener('click', function () {
      var v = (document.getElementById('dzc-server-input').value || '').trim();
      if (!/^https?:\/\/.+/i.test(v)) {
        document.getElementById('dzc-server-err').textContent = '需要以 http:// 或 https:// 开头';
        return;
      }
      localStorage.setItem(SERVER_KEY, v.replace(/\/+$/, ''));
      location.reload();
    });
  }

  if (!base()) {
    if (document.body) askServer();
    else document.addEventListener('DOMContentLoaded', askServer);
    window.__DZC_LOG__('等待填写服务器地址');
    return;
  }

  // ---------------------------------------------------------------- 启动自检
  // 2.5s 后 #app 还是空 → 弹诊断。带上 hash 和路由信息，一眼能看出是哪层挂了。
  setTimeout(function () {
    var app = document.getElementById('app');
    var kids = app ? app.children.length : -1;
    window.__DZC_LOG__('check #app children=' + kids + ' hash=' + location.hash + ' path=' + location.pathname);
    if (!app || kids === 0) {
      window.__DZC_LOG__('没渲染出内容 —— 上面就是全部线索（点一下可关闭）');
      showDiag();
    }
  }, 2500);
})();
