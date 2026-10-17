/**
 * 原生桥（只在 iOS 壳里生效；在浏览器里打开时什么都不做，页面照旧用 <video>）。
 *
 * 设计原则：**网页端零改动也能用**。
 *   · 检到原生插件 → 把页面里所有 <video> 隐藏（visibility:hidden），画面交给 AVPlayer；
 *   · 页面现有的播放/暂停/切换/静音逻辑照旧跑，只是「画面」换了个地方画；
 *   · 桥从 DOM 事件推断当前该播哪条（读 video 的 src），不需要前端改代码。
 *
 * 关键坑（都是实测踩出来的）：
 *   1. <video>.muted = true 会让前端自己的静音按钮状态错乱 → 只对视频元素设 muted，
 *      但把 UI 的 muted 状态单独镜像给原生，避免"取消静音无效"。
 *   2. 快速滑动时 feed 的 transform 动画未结束，getBoundingClientRect 会抖 →
 *      用「离视口中心最近」+ 去抖（同一 id 连续两次才提交）。
 *   3. 页面 reload 后 Capacitor 插件重新注入，addListener 可能重复 → 用标记位防重。
 *
 * 事件（在 window 上派发，前端可选用）：
 *   native-video-state     { phase, id, muted }
 *   native-video-progress  { id, position, duration, buffered, playing }
 *   native-video-ended
 *   native-video-error     { message }
 */
(function () {
  'use strict';

  var Cap = window.Capacitor;
  var isNative = !!(Cap && Cap.isNativePlatform && Cap.isNativePlatform());
  var platform = Cap && Cap.getPlatform ? Cap.getPlatform() : 'web';
  var plugin = isNative && Cap.Plugins ? Cap.Plugins.NativeVideo : null;

  window.__NATIVE_VIDEO__ = {
    available: !!plugin,
    platform: platform,
  };

  if (!plugin) {
    // 浏览器环境：什么都不做，退出
    return;
  }

  if (window.__NATIVE_VIDEO_BOOTED__) return; // 防重复初始化
  window.__NATIVE_VIDEO_BOOTED__ = true;

  // ---------------------------------------------------------------- 工具

  function emit(name, detail) {
    try {
      window.dispatchEvent(new CustomEvent(name, { detail: detail || {} }));
    } catch (e) {
      /* 忽略 */
    }
  }

  /** 从任意 URL 里抠出视频 id（/api/stream/12345 → "12345"） */
  function idOf(url) {
    var m = /\/api\/stream\/(\d+)/.exec(url || '');
    return m ? m[1] : '';
  }

  /** 本机 api 基址。原生壳里 window.location 是 capacitor://localhost，
   *  所以接口必须指向真实服务器。优先 localStorage，其次构建期注入。 */
  var SERVER_KEY = 'dzc.serverBase';

  function serverBase() {
    var fromStore = localStorage.getItem(SERVER_KEY);
    if (fromStore) return fromStore.replace(/\/+$/, '');
    return String(window.__DZC_SERVER_BASE__ || '').replace(/\/+$/, '');
  }

  /** 把页面里的相对地址（/api/...）补成完整地址，供 AVPlayer 使用 */
  function absolute(url) {
    if (!url) return '';
    if (/^(https?:|blob:|data:|file:)/i.test(url)) return url;
    var base = serverBase();
    if (!base) return url;
    return base + (url.charAt(0) === '/' ? url : '/' + url);
  }

  // ---------------------------------------------------------------- 视觉层

  /**
   * 原生播放器是盖在 WKWebView「上面」的一层 UIView —— 所以网页的 UI 会被挡住。
   * 解法：把原生视图**插到 webview 下面**（plugin 里 insertSubview(s, belowSubview: webView)），
   * 再把网页容器背景设透明。这样：底层原生画面 + 上层网页 UI，两全。
   */
  function makePageTransparent() {
    if (document.getElementById('native-video-style')) return;
    var css = document.createElement('style');
    css.id = 'native-video-style';
    css.textContent = [
      'html, body, #app { background: transparent !important; }',
      '.feed, .feed__track, .feed__slide { background: transparent !important; }',
      /* 所有 <video> 隐藏：画面由原生层提供 */
      '.feed__video, video { visibility: hidden !important; }',
      /* 封面/首帧图保留：原生首帧没就绪时它顶着，避免白/黑闪 */
      '.feed__poster { background: #000; }',
    ].join('\n');
    (document.head || document.documentElement).appendChild(css);
  }

  // ---------------------------------------------------------------- 同步

  var lastSentId = '';
  var lastPlaying = null;
  var lastMuted = null;
  var pendingId = '';
  var pendingCount = 0;

  function centerDistance(v) {
    var r = v.getBoundingClientRect();
    if (r.bottom <= 0 || r.top >= window.innerHeight) return Infinity;
    return Math.abs((r.top + r.bottom) / 2 - window.innerHeight / 2);
  }

  function currentVideo() {
    var list = document.querySelectorAll('video');
    var best = null;
    var bestD = Infinity;
    for (var i = 0; i < list.length; i++) {
      var d = centerDistance(list[i]);
      if (d < bestD) {
        bestD = d;
        best = list[i];
      }
    }
    // 离中心超过 0.6 屏就不算"当前"（快速滑动的中间态）
    return bestD < window.innerHeight * 0.6 ? best : null;
  }

  function neighborVideo() {
    var list = Array.prototype.slice.call(document.querySelectorAll('video'));
    var cur = currentVideo();
    if (!cur) return null;
    var curTop = cur.getBoundingClientRect().top;
    var best = null;
    var bestDelta = Infinity;
    for (var i = 0; i < list.length; i++) {
      var v = list[i];
      if (v === cur) continue;
      var d = v.getBoundingClientRect().top - curTop;
      if (d > 0 && d < bestDelta) {
        bestDelta = d;
        best = v;
      }
    }
    return best;
  }

  function pushToNative() {
    var cur = currentVideo();
    if (!cur) return;
    var src = cur.currentSrc || cur.getAttribute('src') || '';
    var id = idOf(src);
    if (!id) return;

    // 去抖：同一 id 连续两次确认才提交，避免动画中间态误判
    if (id !== pendingId) {
      pendingId = id;
      pendingCount = 0;
      return;
    }
    pendingCount += 1;
    if (pendingCount < 2 && id !== lastSentId) return;

    var next = neighborVideo();
    var nextSrc = next ? next.currentSrc || next.getAttribute('src') || '' : '';
    var nextId = idOf(nextSrc);

    if (id !== lastSentId) {
      lastSentId = id;
      plugin
        .load({
          id: id,
          url: absolute(src),
          nextId: nextId || undefined,
          nextUrl: nextId ? absolute(nextSrc) : undefined,
        })
        .catch(function () {});
    }

    var playing = !cur.paused;
    if (playing !== lastPlaying) {
      lastPlaying = playing;
      (playing ? plugin.play() : plugin.pause()).catch(function () {});
    }

    // 网页自己的静音状态：让它只管 UI，声音由原生统一控制
    // （<video> 本身已被隐藏且不加载媒体，不会抢音频轨）
    var m = !!cur.muted;
    if (m !== lastMuted) {
      lastMuted = m;
      plugin.setMuted({ muted: m }).catch(function () {});
    }
  }

  // ---------------------------------------------------------------- 事件

  ['loadedmetadata', 'play', 'pause', 'playing', 'waiting', 'emptied', 'loadstart'].forEach(function (ev) {
    document.addEventListener(
      ev,
      function (e) {
        if (e.target && e.target.tagName === 'VIDEO') {
          pushToNative();
        }
      },
      true
    );
  });

  // 页面滚动 / 触摸切换时同步（节流）
  var syncTimer = null;
  function scheduleSync() {
    if (syncTimer) return;
    syncTimer = setTimeout(function () {
      syncTimer = null;
      pushToNative();
    }, 100);
  }
  document.addEventListener('scroll', scheduleSync, true);
  document.addEventListener('touchmove', scheduleSync, { passive: true, capture: true });
  document.addEventListener('touchend', scheduleSync, true);
  document.addEventListener('touchcancel', scheduleSync, true);

  // 原生事件 → window 事件
  plugin.addListener('state', function (d) {
    emit('native-video-state', d);
  });
  plugin.addListener('progress', function (d) {
    emit('native-video-progress', d);
  });
  plugin.addListener('ended', function () {
    emit('native-video-ended', {});
  });
  plugin.addListener('error', function (d) {
    emit('native-video-error', d);
  });

  // ---------------------------------------------------------------- 启动

  function boot() {
    makePageTransparent();
    plugin.attach().catch(function () {});
    setTimeout(pushToNative, 300);
    setTimeout(pushToNative, 900);
    setTimeout(pushToNative, 2000);
    // 兜底轮询：某些事件在 WKWebView 里会漏
    setInterval(pushToNative, 1000);
  }

  /** 首启弹框已交给 boot-early.js（它比本脚本先跑）。
   *  这里只做兜底：万一 boot-early 没执行（比如被缓存），至少填一次再继续。 */
  function promptServerIfNeeded() {
    if (serverBase()) return false;
    if (document.getElementById('dzc-server-setup')) return true; // 已经有一个了
    var shell = document.createElement('div');
    shell.id = 'dzc-server-setup';
    shell.innerHTML =
      '<div style="position:fixed;inset:0;z-index:2147483647;background:#111;color:#eee;' +
      'display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;' +
      'font:15px -apple-system,sans-serif;padding:24px;box-sizing:border-box;">' +
      '<div style="font-size:19px;font-weight:600;">填写服务器地址</div>' +
      '<div style="color:#9aa;font-size:13px;line-height:1.7;text-align:center;max-width:320px;">' +
      '例如 <b>http://192.168.1.10:6688</b><br>或你的 Tailscale 地址<br>（必须带 http:// 或 https://）</div>' +
      '<input id="dzc-server-input" placeholder="http://..." autocomplete="off" ' +
      'autocapitalize="off" autocorrect="off" spellcheck="false" inputmode="url" ' +
      'style="width:100%;max-width:320px;padding:14px;border-radius:10px;border:1px solid #333;' +
      'background:#1b1b1f;color:#eee;font-size:16px;box-sizing:border-box;" />' +
      '<button id="dzc-server-ok" style="width:100%;max-width:320px;padding:14px;border-radius:10px;' +
      'border:none;background:#fe2c55;color:#fff;font-size:16px;box-sizing:border-box;">保存并继续</button>' +
      '<div id="dzc-server-err" style="color:#f55;font-size:13px;height:18px;"></div>' +
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
    return true;
  }

  function start() {
    if (promptServerIfNeeded()) return;
    boot();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }

  // 暴露给前端（可选使用）
  window.NativeVideoBridge = {
    refresh: pushToNative,
    setServerBase: function (base) {
      localStorage.setItem(SERVER_KEY, String(base || '').replace(/\/+$/, ''));
    },
    getServerBase: serverBase,
  };
})();
