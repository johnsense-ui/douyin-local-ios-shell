// 构建壳专用的 web 产物：hash 路由 + 相对 base，拷进 www/，注入壳内脚本。
//
// 为什么必须在构建期做，不能运行时劫持：
//   之前用 boot-early.js 在运行时把 history 改成 hash。第一次能开，第二次必然白屏：
//   App 内跳转时 vue-router 的 createWebHistory 又把真实路径写回去
//   （capacitor://localhost/collections），Capacitor 的 asset handler 当它是个文件，
//   找不到就整页空白。运行时劫持是在和 vue-router 抢同一个东西，赢不了。
//
//   构建期把 router 换成 createWebHashHistory、vite base 换成 './'，
//   真实路径永远是 capacitor://localhost/，怎么跳、怎么杀进程重启都不白屏。
//   主项目的 dist 和源码保证还原（6688 上照旧 history 模式）。
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const WEB = path.resolve(ROOT, '..', '_research', 'Gaoyubao0917__douyin-local', 'web');
const DIST = path.join(WEB, 'dist');
const DEST = path.join(ROOT, 'www');

const ROUTER = path.join(WEB, 'src', 'router.ts');
const VITE = path.join(WEB, 'vite.config.ts');

if (!fs.existsSync(ROUTER)) {
  console.error(`[copy-web] 找不到 ${ROUTER}`);
  process.exit(1);
}

// ---------------------------------------------------------------- 1. 临时改源码
const origRouter = fs.readFileSync(ROUTER, 'utf8');
const origVite = fs.readFileSync(VITE, 'utf8');

if (!origRouter.includes('createWebHistory')) {
  console.error('[copy-web] router.ts 里找不到 createWebHistory，主项目结构变了');
  process.exit(1);
}

const patchedRouter = origRouter.replace(/\bcreateWebHistory\b/g, 'createWebHashHistory');
const patchedVite = /\bbase\s*:/.test(origVite)
  ? origVite.replace(/base\s*:\s*['"][^'"]*['"]/, "base: './'")
  : origVite.replace('plugins: [vue()],', "base: './',\n  plugins: [vue()],");

const utf8 = new TextEncoder();
const writeUtf8 = (p, s) => fs.writeFileSync(p, Buffer.from(utf8.encode(s)));

let built = false;
try {
  writeUtf8(ROUTER, patchedRouter);
  writeUtf8(VITE, patchedVite);
  console.log('[copy-web] 构建壳专用 web（hash 路由 + base "./"）…');

  execFileSync(process.execPath, [path.join(WEB, 'node_modules', 'vite', 'bin', 'vite.js'), 'build'], {
    cwd: WEB,
    stdio: 'inherit',
    env: { ...process.env, NODE_ENV: 'production' },
  });
  built = true;
} finally {
  // 无论如何都还原，主项目永远保持 history 模式
  writeUtf8(ROUTER, origRouter);
  writeUtf8(VITE, origVite);
  console.log('[copy-web] 主项目已还原（history 路由 + base "/"）');
}

if (!built) {
  console.error('[copy-web] 构建失败');
  process.exit(1);
}

// ---------------------------------------------------------------- 2. 拷贝
fs.rmSync(DEST, { recursive: true, force: true });
if (!fs.existsSync(path.join(DIST, 'index.html'))) {
  console.error(`[copy-web] 产物缺失: ${DIST}/index.html`);
  process.exit(1);
}
fs.cpSync(DIST, DEST, { recursive: true });

// ---------------------------------------------------------------- 3. 注入
const scripts = ['boot-early.js', 'net-patch.js', 'native-bridge.js'];
const present = [];
for (const name of scripts) {
  const from = path.join(ROOT, 'native', name);
  if (fs.existsSync(from)) {
    fs.copyFileSync(from, path.join(DEST, name));
    present.push(name);
  } else {
    console.warn(`[copy-web] 警告：native/${name} 不存在`);
  }
}

const indexFile = path.join(DEST, 'index.html');
let html = fs.readFileSync(indexFile, 'utf8');
html = html.replace(/(\s(?:src|href)=")\/assets\//g, '$1./assets/');
if (!html.includes('boot-early.js')) {
  const tags = present.map((n) => `  <script src="./${n}"></script>`).join('\n');
  html = html.replace('</head>', tags + '\n</head>');
}
fs.writeFileSync(indexFile, html, 'utf8');

// ---------------------------------------------------------------- 4. 断言 hash 真的生效
const mainMatch = html.match(/src="\.\/(assets\/[^"]+\.js)"/);
let verified = true;
if (!mainMatch) {
  console.error('[copy-web] ✗ 找不到主 JS');
  verified = false;
} else {
  const js = fs.readFileSync(path.join(DEST, mainMatch[1]), 'utf8');
  const hasHash = /startsWith\("#"\)/.test(js) || /hash\.slice/.test(js) || /location\.hash/.test(js);
  if (!hasHash) {
    console.error('[copy-web] ✗ 产物里没有 hash 路由特征 —— 构建没生效');
    verified = false;
  } else {
    console.log(`[copy-web] ✓ hash 路由已编入（${mainMatch[1]}）`);
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
console.log(`[copy-web] -> ${DEST}  (${count(DEST)} 个文件)  注入: ${present.join(', ')}`);
if (!verified) process.exitCode = 1;
