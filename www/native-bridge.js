/**
 * 原生桥（第三版）。
 *
 * 只在 Capacitor 壳里生效；浏览器里直接 return，页面照旧用 <video>。
 *
 * ═══════════════════════════════════════════════════════════════
 * 和前两版的区别
 * ───────────────────────────────────────────────────────────────
 *   前两版靠『监听 DOM 事件 → 猜当前哪条』，两个致命问题：
 *     1. 事件会漏（WKWebView 里 loadedmetadata / playing 都可能不派发）；
 *     2. 滑动手势过程中的中间态会让它误判，于是来回重载 → 黑屏 + 卡。
 *
 *   这一版：
 *     · **每 80ms 主动读 DOM**（rAF 驱动，页面不可见时自动停），不依赖事件；
 *     · **用视频 id 做去重**，同一条永远不重载；
 *     · **预判方向**：touch 记录起点，滑动中就能算出会切到下一条还是上一条，
 *       提前让原生把那个槽位准备好；
 *     · **一次性把三条（prev/current/next）都交给原生**，
 *       原生三槽位环形，怎么滑都有预热好的画面。
 * ═══════════════════════════════════════════════════════════════
 */
(function () {
  'use strict';

  var Cap = window.Capacitor;
  var isNative = !!(Cap && Cap.isNativePlatform && Cap.isNativePlatform());
  var plugin = isNative && Cap.Plugins ? Cap.Plugins.NativeVideo : null;

  window.__NATIVE_VIDEO__ = { available: !!plugin, platform: Cap && Cap.getPlatform ? Cap.getPlatform() : 'web' };

  if (!window.__IS_SHELL__ || !plugin) return;
  if (window.__NATIVE_VIDEO_BOOTED__) return;
  window.__NATIVE_VIDEO_BOOTED__ = true;

  var LOG = window.__DZC_LOG__ || function () {};

  // ---------------------------------------------------------------- 工具

  function emit(name, detail) {
    try {
      window.dispatchEvent(new CustomEvent(name, { detail: detail || {} }));
    } catch (e) {}
  }

  /** /api/stream/12345?... → "12345" */
  function idOf(url) {
    var m = /\/api\/stream\/(\d+)/.exec(url || '');
    return m ? m[1] : '';
  }

  var SERVER_KEY = 'dzc.serverBase';
  function serverBase() {
    var v = localStorage.getItem(SERVER_KEY) || window.__DZC_SERVER_BASE__ || '';
    return String(v).replace(/\/+$/, '');
  }
  function absolute(url) {
    if (!url) return '';
    if (/^(https?:|blob:|data:)/i.test(url)) return url;
    var b = serverBase();
    if (!b) return url;
    return b + (url.charAt(0) === '/' ? url : '/' + url);
  }

  // ---------------------------------------------------------------- 视觉层

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
      '.feed__poster { background: #000; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(css);
  }

  // ---------------------------------------------------------------- 找视频

  /** 按垂直位置把可见的 <video> 排序 */
  function sortedVideos() {
    var list = Array.prototype.slice.call(document.querySelectorAll('video'));
    var h = window.innerHeight;
    list = list.filter(function (v) {
      var r = v.getBoundingClientRect();
      return r.bottom > -h && r.top < h * 2; // 视口上下各留一屏
    });
    list.sort(function (a, b) {
      return a.getBoundingClientRect().top - b.getBoundingClientRect().top;
    });
    return list;
  }

  function centerOf(v) {
    var r = v.getBoundingClientRect();
    return Math.abs((r.top + r.bottom) / 2 - window.innerHeight / 2);
  }

  function srcOf(v) {
    return v ? (v.currentSrc || v.getAttribute('src') || '') : '';
  }

  // ---------------------------------------------------------------- 状态

  var lastKey = '';           // 当前三元的字符串指纹，变了才下发
  var lastPlaying = null;
  var lastMuted = null;
  var recentAdvance = 0;      // 刚切过的方向，防抖
  var touchStartY = 0;
  var touchDir = 0;

  /** 收集 prev / current / next 三元组 */
  function snapshot() {
    var list = sortedVideos();
    if (!list.length) return null;

    // 当前条 = 离视口中心最近
    var best = null, bestD = Infinity;
    for (var i = 0; i < list.length; i++) {
      var d = centerOf(list[i]);
      if (d < bestD) { bestD = d; best = list[i]; }
    }
    if (!best || bestD > window.innerHeight * 0.6) return null;

    var idx = list.indexOf(best);
    var prevV = idx > 0 ? list[idx - 1] : null;
    var nextV = idx < list.length - 1 ? list[idx + 1] : null;

    return {
      cur: best,
      prev: prevV,
      next: nextV,
      curId: idOf(srcOf(best)),
      prevId: idOf(srcOf(prevV)),
      nextId: idOf(srcOf(nextV))
    };
  }

  function push() {
    var s = snapshot();
    if (!s || !s.curId) return;

    var key = s.prevId + '|' + s.curId + '|' + s.nextId;

    // 当前条变了 → 先试原生滑（预加载好的槽直接上台，0 帧黑）
    var curChanged = lastKey && key !== lastKey && s.curId !== lastKey.split('|')[1];
    if (curChanged) {
      var prevCurId = lastKey.split('|')[1];
      // 判断是往下还是往上：新 id 出现在旧三元里说明是邻条切换
      var dir = null;
      if (s.curId === lastKey.split('|')[2]) dir = 'down';
      else if (s.curId === lastKey.split('|')[0]) dir = 'up';

      if (dir) {
        var fn = dir === 'down' ? plugin.advanceDown : plugin.advanceUp;
        var now = Date.now();
        if (now - recentAdvance > 250) {
          recentAdvance = now;
          fn.call(plugin)
            .then(function (r) {
              if (!r || !r.ok) {
                // 槽位没准备好 → 退回 load（会有点黑，但不会卡死）
                doLoad(s);
              }
            })
            .catch(function () { doLoad(s); });
          LOG('switch ' + dir + ' ' + prevCurId + '->' + s.curId);
          lastKey = key;
          return;
        }
      }
      doLoad(s);
      lastKey = key;
      return;
    }

    if (key !== lastKey) {
      doLoad(s);
      lastKey = key;
      return;
    }

    // 同一组：只同步播放/静音状态
    syncPlayState(s.cur);
  }

  function doLoad(s) {
    var p = {
      id: s.curId,
      url: absolute(srcOf(s.cur)),
      nextId: s.nextId || undefined,
      nextUrl: s.nextId ? absolute(srcOf(s.next)) : undefined,
      prevId: s.prevId || undefined,
      prevUrl: s.prevId ? absolute(srcOf(s.prev)) : undefined
    };
    plugin.load(p).catch(function (e) { LOG('load fail ' + (e && e.message)); });
    LOG('load ' + s.prevId + ' <' + s.curId + '> ' + s.nextId);
    syncPlayState(s.cur);
  }

  function syncPlayState(v) {
    if (!v) return;
    var playing = !v.paused;
    if (playing !== lastPlaying) {
      lastPlaying = playing;
      (playing ? plugin.play() : plugin.pause()).catch(function () {});
    }
    var m = !!v.muted;
    if (m !== lastMuted) {
      lastMuted = m;
      plugin.setMuted({ muted: m }).catch(function () {});
    }
  }

  // ---------------------------------------------------------------- 驱动
  //
  // 不用事件驱动，用 rAF 轮询：WKWebView 的事件不可靠（会漏）。
  // 80ms 一次，开销可忽略（只读几个 getBoundingClientRect）。
  var rafId = null;
  var lastTick = 0;

  function tick(now) {
    rafId = requestAnimationFrame(tick);
    if (now - lastTick < 80) return;
    lastTick = now;
    if (document.hidden) return;
    try {
      push();
    } catch (e) {
      LOG('tick err ' + (e && e.message));
    }
  }

  function startLoop() {
    if (rafId == null) rafId = requestAnimationFrame(tick);
  }

  // ---------------------------------------------------------------- 手势预判
  //
  // 滑动还没结束时就知道要切到哪条，提前让原生把槽位准备好。
  // 这是"滑过去第一帧就在"的关键 —— 不能等落了位再判断。

  document.addEventListener(
    'touchstart',
    function (e) {
      touchStartY = e.touches && e.touches[0] ? e.touches[0].clientY : 0;
      touchDir = 0;
    },
    { passive: true, capture: true }
  );

  document.addEventListener(
    'touchmove',
    function (e) {
      if (!e.touches || !e.touches[0]) return;
      var dy = touchStartY - e.touches[0].clientY; // 正 = 往上滑 = 下一条
      var dir = dy > 30 ? 'down' : dy < -30 ? 'up' : 0;
      if (dir && dir !== touchDir) {
        touchDir = dir;
        // 只是提前 sync，真正切换等落位后 push() 判定
        try { push(); } catch (err) {}
      }
    },
    { passive: true, capture: true }
  );

  document.addEventListener('touchend', function () { touchDir = 0; }, { passive: true, capture: true });

  // 事件也留着（作为补充触发，主驱动仍是 rAF）
  ['loadedmetadata', 'play', 'pause', 'playing', 'waiting', 'emptied'].forEach(function (ev) {
    document.addEventListener(ev, function (e) {
      if (e.target && e.target.tagName === 'VIDEO') push();
    }, true);
  });

  // ---------------------------------------------------------------- 原生事件转发
  plugin.addListener('state', function (d) { emit('native-video-state', d); });
  plugin.addListener('progress', function (d) { emit('native-video-progress', d); });
  plugin.addListener('ended', function () { emit('native-video-ended', {}); });
  plugin.addListener('error', function (d) { emit('native-video-error', d); });

  // ---------------------------------------------------------------- 启动

  function boot() {
    makePageTransparent();
    plugin.attach().then(function () {
      LOG('attach ok');
      setTimeout(push, 200);
      setTimeout(push, 800);
      startLoop();
    }).catch(function (e) {
      LOG('attach fail ' + (e && e.message));
      startLoop();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // ---------------------------------------------------------------- 调试接口
  window.NativeVideoBridge = {
    refresh: push,
    debug: function () {
      return plugin.debug ? plugin.debug() : Promise.resolve(null);
    },
    snapshot: function () {
      var s = snapshot();
      return s ? { prev: s.prevId, cur: s.curId, next: s.nextId } : null;
    },
    setServerBase: function (b) {
      localStorage.setItem(SERVER_KEY, String(b || '').replace(/\/+$/, ''));
    },
    getServerBase: serverBase
  };

  LOG('bridge ready');
})();
