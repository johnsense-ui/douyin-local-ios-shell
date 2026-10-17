// 把主项目的 web/dist 拷进本壳的 www/，作为 Capacitor 的 webDir。
// 这样主项目完全不用改依赖，壳只是"消费"它的构建产物。
//
// 注入两个脚本（顺序很重要）：
//   1. shell-boot.js  —— 立即执行：标记 __IS_SHELL__、把历史路由 /xxx 改写成 /#/xxx
//   2. native-bridge.js —— 等 DOM 后执行：接管画面、做首启服务器地址提示
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.resolve(ROOT, '..', '_research', 'Gaoyubao0917__douyin-local', 'web', 'dist');
const DEST = path.join(ROOT, 'www');

if (!fs.existsSync(SRC)) {
  console.error(`[copy-web] 找不到 web 构建产物: ${SRC}`);
  console.error('           先跑: npm run build:web');
  process.exit(1);
}

fs.rmSync(DEST, { recursive: true, force: true });
fs.cpSync(SRC, DEST, { recursive: true });

// ---------------------------------------------------------------- 路由改写
// 主项目用 createWebHistory（HTML5 history），但 Capacitor 的 capacitor://localhost
// 不是 http(s) origin，history 路由在里面不工作。这里在路由插件加载**之前**
// 把 location 改成 hash 形式，vue-router 的 createWebHistory 会自动降级。
const SHELL_BOOT = `/* 由 _ios-shell/scripts/copy-web.mjs 注入：壳内引导（必须最先执行） */
(function () {
  if (!/^(capacitor|ionic):$/.test(location.protocol)) return; // 只壳内生效
  window.__IS_SHELL__ = true;
  var p = location.pathname || '/';
  var s = location.search || '';
  var h = location.hash || '';
  // history 路由 -> hash 路由（只改这一次，改完连 reload 都不会丢）
  if (!h) {
    location.replace(location.origin + '/#' + p + s);
  }
})();`;

// ---------------------------------------------------------------- 网络接管
const netPatch = path.join(ROOT, 'native', 'net-patch.js');
if (fs.existsSync(netPatch)) {
  fs.copyFileSync(netPatch, path.join(DEST, 'net-patch.js'));
}

// ---------------------------------------------------------------- 原生桥
const bridgeSrc = path.join(ROOT, 'native', 'native-bridge.js');
if (fs.existsSync(bridgeSrc)) {
  fs.copyFileSync(bridgeSrc, path.join(DEST, 'native-bridge.js'));
}

// ---------------------------------------------------------------- 注入 index.html
const indexFile = path.join(DEST, 'index.html');
if (fs.existsSync(indexFile)) {
  let html = fs.readFileSync(indexFile, 'utf8');
  if (!html.includes('shell-boot')) {
    const tags = [
      `  <script>${SHELL_BOOT}</script>`,
      '  <script src="./net-patch.js"></script>',
      '  <script src="./native-bridge.js"></script>',
    ].join('\n');
    html = html.replace('</head>', tags + '\n</head>');
    fs.writeFileSync(indexFile, html, 'utf8');
  }
}

const count = (p) => {
  let n = 0;
  for (const e of fs.readdirSync(p, { withFileTypes: true })) {
    if (e.isDirectory()) n += count(path.join(p, e.name));
    else n += 1;
  }
  return n;
};

console.log(`[copy-web] ${SRC}`);
console.log(`        -> ${DEST}  (${count(DEST)} 个文件)`);
