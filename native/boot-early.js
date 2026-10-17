/**
 * 壳内早期引导。**必须是页面里第一个执行的脚本**（同步、非 module）。
 *
 * 干三件事：
 *   1. 识别「我在 Capacitor 壳里」，打上 window.__IS_SHELL__
 *   2. 没填过服务器地址 → 立刻弹输入框（挡住后面的白屏，用户不会以为 App 坏了）
 *   3. 把 history 路由改写成 hash 路由
 *
 * 为什么第 3 件必须有：
 *   主项目路由用 createWebHistory()。Capacitor 的实际地址是
 *     capacitor://localhost/        ← scheme + hostname，**注意是两斜杠**
 *   在这个 origin 下 pushState/replaceState 不可靠，vue-router 会拿不到路径，
 *   兜底路由虽然重定向到 /grid，但动态 import 的 chunk 走的是 /assets/xxx，
 *   一旦相对/绝对路径算错就整页空白 —— 也就是真机上看到的「白屏」。
 *   改成 hash 模式后，路径全在 # 后面，html5-history 完全不参与。
 *
 * 注意：协议判断**不能用** /^(capacitor|ionic):$/（带 $ 会匹配不上
 * capacitor://localhost，因为 : 后面还有 //），这是个很容易踩的坑。
 */
(function () {
  'use strict';

  var proto = String(location.protocol || '').toLowerCase();
  var isCapacitor = proto.indexOf('capacitor:') === 0 || proto.indexOf('ionic:') === 0;
  var isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());

  if (!isCapacitor && !isNative) return; // 浏览器里什么都不做

  window.__IS_SHELL__ = true;
  window.__SHELL_PROTO__ = proto;

  // ---------------------------------------------------------------- 诊断浮层
  // 没有 Mac / Safari 的时候，这是唯一能看到错误的通道。
  // 页面跑起来后自动隐藏；出问题就停在那儿。
  var lines = [];
  function showDiag() {
    if (document.getElementById('dzc-diag')) return;
    var box = document.createElement('div');
    box.id = 'dzc-diag';
    box.style.cssText =
      'position:fixed;left:0;right:0;bottom:0;max-height:45%;overflow:auto;z-index:2147483647;' +
      'background:rgba(0,0,0,.88);color:#0f0;font:11px/1.5 ui-monospace,Menlo,monospace;' +
      'padding:8px 10px;white-space:pre-wrap;word-break:break-all;border-top:1px solid #333;';
    box.textContent = lines.join('\n');
    document.body.appendChild(box);
  }
  window.__DZC_LOG__ = function (msg) {
    lines.push(msg);
    if (lines.length > 40) lines.shift();
    var box = document.getElementById('dzc-diag');
    if (box) box.textContent = lines.join('\n');
  };
  window.addEventListener('error', function (e) {
    window.__DZC_LOG__('[error] ' + (e.message || '') + ' @ ' + (e.filename || '').split('/').pop() + ':' + e.lineno);
    if (document.body) showDiag();
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    window.__DZC_LOG__('[reject] ' + ((r && (r.message || r)) || 'unknown'));
    if (document.body) showDiag();
  });
  window.__DZC_LOG__('boot: proto=' + proto + ' native=' + isNative);

  // ---------------------------------------------------------------- 服务器地址
  var SERVER_KEY = 'dzc.serverBase';

  function base() {
    var v = localStorage.getItem(SERVER_KEY) || '';
    return String(v).replace(/\/+$/, '');
  }

  if (!base()) {
    // 还没填地址：先把 UI 挡住，别让用户看到白屏以为坏了
    function askServer() {
      if (document.getElementById('dzc-server-setup')) return;
      var shell = document.createElement('div');
      shell.id = 'dzc-server-setup';
      shell.innerHTML =
        '<div style="position:fixed;inset:0;z-index:2147483647;background:#111;color:#eee;' +
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
        '<div style="color:#555;font-size:11px;margin-top:8px;">当前页面协议：' + proto + '</div>' +
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

    if (document.body) askServer();
    else document.addEventListener('DOMContentLoaded', askServer);
    // 地址没填就别去做路由改写，避免 reload 循环
    return;
  }

  // ---------------------------------------------------------------- 路由改写
  // capacitor://localhost/ 这种 origin 下 html5 history 不可靠，统一改 hash。
  // 已经在 # 里就什么都不做（幂等，不会 reload 循环）。
  if (!location.hash || location.hash === '#') {
    var p = location.pathname || '/';
    var s = location.search || '';
    // pathname 在 capacitor 下通常就是 '/'，补成默认首页
    if (p === '/' || p === '') p = '/grid';
    var target = location.origin + '/#' + p + s;
    window.__DZC_LOG__('route: ' + proto + '//' + location.host + p + s + '  ->  #' + p);
    try {
      location.replace(target);
    } catch (e) {
      window.__DZC_LOG__('[route] replace 失败: ' + (e && e.message));
    }
  } else {
    window.__DZC_LOG__('route: hash 已是 ' + location.hash);
  }

  // ---------------------------------------------------------------- 启动后自检
  // 1.5s 后如果 #app 还是空的，把诊断浮层弹出来，并把当时的地址打上去
  setTimeout(function () {
    var app = document.getElementById('app');
    var kids = app ? app.children.length : -1;
    window.__DZC_LOG__('check: #app children=' + kids + '  hash=' + location.hash);
    if (!app || kids === 0) {
      showDiag();
      window.__DZC_LOG__('页面没有渲染出内容 —— 上面就是全部线索');
    }
  }, 1500);
})();
