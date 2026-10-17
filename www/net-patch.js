/**
 * 壳内网络层接管（只在 iOS 壳里生效）。
 *
 * 背景：网页里所有请求都写成相对路径 `/api/xxx`，在主项目里由 Fastify 同源提供。
 * 但在 Capacitor 壳里，页面 origin 是 `capacitor://localhost`，`/api/xxx`
 * 会打到壳自己身上 → 404 / 空白。
 *
 * 这里在 **XMLHttpRequest / fetch / <video> / <img> 的 setter 层**做统一改写，
 * 网页代码一行都不用动，也不用重新构建主项目。
 * 浏览器里 `__IS_SHELL__` 不存在，整段直接 return。
 */
(function () {
  'use strict';

  if (!window.__IS_SHELL__) return;
  if (window.__DZC_NET_PATCHED__) return;
  window.__DZC_NET_PATCHED__ = true;

  var SERVER_KEY = 'dzc.serverBase';

  function base() {
    var v = localStorage.getItem(SERVER_KEY) || window.__DZC_SERVER_BASE__ || '';
    return String(v).replace(/\/+$/, '');
  }

  /** /api/xxx → http://host:6688/api/xxx；其它协议原样返回 */
  function abs(u) {
    if (typeof u !== 'string' || !u) return u;
    if (u.charAt(0) !== '/' || u.charAt(1) === '/') return u; // 绝对地址 / 协议相对
    var b = base();
    return b ? b + u : u;
  }

  window.__DZC_ABS__ = abs;

  // ---------------------------------------------------------------- fetch
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input, init) {
      try {
        if (typeof input === 'string') {
          input = abs(input);
        } else if (input && typeof input === 'object' && input.url) {
          var rewritten = abs(input.url);
          if (rewritten !== input.url) input = new Request(rewritten, input);
        }
      } catch (e) {
        /* 保持原样 */
      }
      return origFetch.call(this, input, init);
    };
  }

  // ---------------------------------------------------------------- XHR
  var XP = XMLHttpRequest.prototype;
  var origOpen = XP.open;
  XP.open = function (method, url) {
    var args = Array.prototype.slice.call(arguments);
    args[1] = abs(url);
    return origOpen.apply(this, args);
  };

  // ---------------------------------------------------------------- <video> / <img> src
  function patchSrcSetter(proto, prop) {
    if (!proto) return;
    var d = Object.getOwnPropertyDescriptor(proto, prop);
    if (!d || !d.set) return;
    Object.defineProperty(proto, prop, {
      configurable: true,
      enumerable: d.enumerable,
      get: d.get,
      set: function (v) {
        return d.set.call(this, abs(v));
      },
    });
  }
  patchSrcSetter(window.HTMLMediaElement && HTMLMediaElement.prototype, 'src');
  patchSrcSetter(window.HTMLImageElement && HTMLImageElement.prototype, 'src');
  patchSrcSetter(window.HTMLSourceElement && HTMLSourceElement.prototype, 'src');

  // setAttribute('src', ...) 也要管（有些代码走这条路）
  var origSetAttribute = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if (typeof name === 'string' && name.toLowerCase() === 'src') value = abs(value);
    return origSetAttribute.call(this, name, value);
  };

  // ---------------------------------------------------------------- 提示
  console.log('[dzc] 网络层已接管，服务器基址 =', base() || '(未设置，首启会提示填写)');
})();
