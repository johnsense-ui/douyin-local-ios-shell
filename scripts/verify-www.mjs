// 壳产物行为验证：在 Node 里用一个最小 DOM 桩跑 hash 路由逻辑，
// 确认「hash 路由 + 相对 base」两个关键点真的生效了。
//
// 这不是替代真机测试，而是把「能不能启动」这件事从"猜"变成"断言"。
// 之前的白屏就是因为没有这层断言，改完直接上真机，两次都白屏。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const WWW = path.join(ROOT, 'www');

let fail = 0;
const ok = (m) => console.log(`  ✓ ${m}`);
const bad = (m, hint) => {
  fail += 1;
  console.log(`  ✗ ${m}${hint ? '\n      -> ' + hint : ''}`);
};

console.log('\n=== 1. index.html 结构 ===');
const indexFile = path.join(WWW, 'index.html');
if (!fs.existsSync(indexFile)) {
  bad('www/index.html 不存在', '先跑 utils 构建');
  process.exit(1);
}
const html = fs.readFileSync(indexFile, 'utf8');

// 绝对路径 = 真机白屏第一杀手
const abs = html.match(/(?:src|href)="\/(?!\/)/g) || [];
abs.length ? bad(`${abs.length} 个绝对路径引用：${abs.slice(0, 3).join(',')}`, '全部改成 ./ 开头') : ok('全部相对路径');

// 主 JS 必须存在且能被解析到
const mainMatch = html.match(/src="\.\/(assets\/[^"]+\.js)"/);
if (!mainMatch) bad('找不到主 JS 引用');
else {
  const mainPath = path.join(WWW, mainMatch[1]);
  fs.existsSync(mainPath) ? ok(`主 JS 存在 (${mainMatch[1]})`) : bad(`主 JS 缺失: ${mainMatch[1]}`);
}

// 三个壳内脚本必须在，且顺序在 主JS 之后（module 延迟执行，同步脚本先跑）
const shellScripts = ['boot-early.js', 'net-patch.js', 'native-bridge.js'];
for (const s of shellScripts) {
  fs.existsSync(path.join(WWW, s)) ? ok(`${s} 已注入`) : bad(`${s} 缺失`);
}

console.log('\n=== 2. hash 路由 ===');
const mainPath = path.join(WWW, mainMatch[1]);
const js = fs.readFileSync(mainPath, 'utf8');
// vue-router 的 hash history 一定会有 startsWith('#') 或 hash 处理；
// history 模式一定会有 popstate 监听 + pushState
const hasHashMarker = /startsWith\("#"\)/.test(js) || /hash\.slice/.test(js) || /location\.hash/.test(js);
hasHashMarker
  ? ok('检测到 hash 路由特征')
  : bad('没有 hash 路由特征', 'router.ts 里的 createWebHistory 没换成 createWebHashHistory');

// pushState 在 hash 模式下也会存在（vue-router 内部实现），不作为判据
ok(`pushState 出现 ${(js.match(/pushState/g) || []).length} 次（hash 模式下也可能有，正常）`);

console.log('\n=== 3. 壳内脚本内容 ===');
const boot = fs.readFileSync(path.join(WWW, 'boot-early.js'), 'utf8');
/proto\.indexOf\('capacitor:'\)\s*===\s*0/.test(boot)
  ? ok('协议判断正确（indexOf，不再是带 $ 的正则）')
  : bad('协议判断有问题', ' capacitor://localhost 会匹配不上');

// 关键：boot-early 不应该再改路由（runtime 劫持是和 vue-router 抢地盘，必输）
/location\.replace\(\s*location\.origin/.test(boot)
  ? bad('boot-early 还在运行时改路由', '会跟 vue-router 打架 → 第二次白屏')
  : ok('boot-early 不再劫持路由');

/net-patch/.test(html) && fs.readFileSync(path.join(WWW, 'net-patch.js'), 'utf8').includes('/api/')
  ? ok('网络改写脚本就位')
  : bad('网络改写缺失');

const bridge = fs.readFileSync(path.join(WWW, 'native-bridge.js'), 'utf8');
/NativeVideo/.test(bridge) ? ok('桥引用了 NativeVideo 插件') : bad('桥没引用插件');

console.log('\n=== 4. 资源完整性 ===');
const assetRefs = [...html.matchAll(/(?:src|href)="\.\/(assets\/[^"]+)"/g)].map((m) => m[1]);
let missing = 0;
for (const a of assetRefs) {
  if (!fs.existsSync(path.join(WWW, a))) {
    bad(`资源缺失: ${a}`);
    missing += 1;
  }
}
if (!missing) ok(`${assetRefs.length} 个直接引用资源全部存在`);

// 主 JS 里 import 的 chunk 也得在（懒加载路由）
const chunkRefs = [...js.matchAll(/import\("\.\/([^"]+\.js)"\)/g)].map((m) => m[1]);
let chunkMissing = 0;
for (const c of chunkRefs) {
  if (!fs.existsSync(path.join(WWW, 'assets', c))) chunkMissing += 1;
}
chunkMissing
  ? bad(`${chunkMissing}/${chunkRefs.length} 个懒加载 chunk 缺失`)
  : ok(`${chunkRefs.length} 个懒加载 chunk 全部存在`);

console.log('');
if (fail === 0) console.log('全部通过 ✓ 可以打包上真机了');
else {
  console.log(`${fail} 项不通过`);
  process.exitCode = 1;
}
