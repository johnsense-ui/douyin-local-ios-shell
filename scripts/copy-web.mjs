// 把主项目的 web/dist 拷进本壳的 www/，作为 Capacitor 的 webDir。
// 这样主项目不用改依赖，壳只是"消费"它的构建产物。
//
// 注入三个脚本，顺序不能换：
//   1. boot-early.js   —— 同步、最先：标记 __IS_SHELL__、history→hash、弹服务器地址框
//   2. net-patch.js    —— 同步：把 /api/xxx 改写成绝对地址
//   3. native-bridge.js —— DOMContentLoaded 后：把画面交接给原生播放器
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

// ---------------------------------------------------------------- 拷贝壳内脚本
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

// ---------------------------------------------------------------- 注入 index.html
const indexFile = path.join(DEST, 'index.html');
if (fs.existsSync(indexFile)) {
  let html = fs.readFileSync(indexFile, 'utf8');

  // 【关键】把绝对路径 /assets/xxx 改成相对 ./assets/xxx。
  // Vite 默认 base='/'，产出的是绝对路径。在 capacitor://localhost 下
  // 绝对路径能不能命中 webDir 依赖 Capacitor 的 asset handler，
  // 一旦算错就是整页白屏（真机上遇到的就是这个）。相对路径永远对。
  html = html.replace(/(\s(?:src|href)=")\/assets\//g, '$1./assets/');

  if (!html.includes('boot-early.js')) {
    const tags = present.map((n) => `  <script src="./${n}"></script>`).join('\n');
    html = html.replace('</head>', tags + '\n</head>');
  }
  fs.writeFileSync(indexFile, html, 'utf8');
}

// ---------------------------------------------------------------- 检查资源引用
if (fs.existsSync(indexFile)) {
  const html = fs.readFileSync(indexFile, 'utf8');
  const absRefs = html.match(/(?:src|href)="\/(?!\/)/g) || [];
  if (absRefs.length) {
    console.warn(`[copy-web] 警告：还有 ${absRefs.length} 个绝对路径引用，壳里可能白屏`);
  } else {
    console.log('[copy-web] 资源引用全部为相对路径 ✓');
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
console.log(`        注入: ${present.join(', ')}`);
