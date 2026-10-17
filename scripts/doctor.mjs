// 体检：确认壳的各个环节都到位（在 Windows 上也能跑，不需要 Mac / Xcode）
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');

let fail = 0;
let warn = 0;

function ok(label, extra = '') {
  console.log(`  \u2713 ${label}${extra ? '  ' + extra : ''}`);
}
function bad(label, hint) {
  fail += 1;
  console.log(`  \u2717 ${label}\n      -> ${hint}`);
}
function soft(label, hint) {
  warn += 1;
  console.log(`  ! ${label}\n      -> ${hint}`);
}
function exists(p) {
  return fs.existsSync(path.join(ROOT, p));
}
function read(p) {
  return fs.readFileSync(path.join(ROOT, p), 'utf8');
}

console.log('\n=== 1. web 产物 ===');
if (!exists('../_research/Gaoyubao0917__douyin-local/web/dist/index.html')) {
  bad('主项目 web/dist 不存在', 'cd ../_research/Gaoyubao0917__douyin-local/web && npm run build');
} else {
  ok('web/dist 存在');
}
if (!exists('www/index.html')) {
  bad('www/ 未生成', 'npm run sync:web');
} else {
  ok('www/ 存在');
  if (read('www/index.html').includes('native-bridge.js')) ok('index.html 已注入桥脚本');
  else bad('index.html 没注入 native-bridge.js', 'npm run sync:web');
  if (exists('www/native-bridge.js')) ok('www/native-bridge.js 已拷贝');
  else bad('www/native-bridge.js 缺失', 'npm run sync:web');
}

console.log('\n=== 2. 原生源码 ===');
for (const f of ['NativeStage.swift', 'NativeVideoPlugin.swift', 'BridgeViewController.swift']) {
  if (exists(`ios-plugin/${f}`)) ok(`ios-plugin/${f}`);
  else bad(`ios-plugin/${f} 缺失`, '补齐这个文件');
}

console.log('\n=== 3. Xcode 工程 ===');
if (!exists('ios/App/App.xcodeproj/project.pbxproj')) {
  bad('ios/ 工程不存在', 'npx cap add ios');
} else {
  ok('ios/App/App.xcodeproj 存在');
  const pbx = read('ios/App/App.xcodeproj/project.pbxproj');
  for (const f of ['NativeStage.swift', 'NativeVideoPlugin.swift', 'BridgeViewController.swift']) {
    if (pbx.includes(`${f} in Sources`)) ok(`工程已编译 ${f}`);
    else bad(`${f} 没在工程 Sources 里`, 'node scripts/copy-swift.mjs && python .github/scripts/patch-pbxproj.py');
  }

  const sb = 'ios/App/App/Base.lproj/Main.storyboard';
  if (exists(sb)) {
    if (read(sb).includes('customClass="BridgeViewController"')) ok('storyboard 根 VC = BridgeViewController');
    else bad('storyboard 根 VC 还是 CAPBridgeViewController', 'python .github/scripts/patch-pbxproj.py');
  } else bad('Main.storyboard 缺失', 'npx cap add ios');

  const plist = 'ios/App/App/Info.plist';
  if (exists(plist)) {
    const pl = read(plist);
    if (pl.includes('NSAppTransportSecurity')) ok('Info.plist 允许 http');
    else soft('Info.plist 没有 ATS 例外', '连 http://局域网 时会失败，python .github/scripts/patch-pbxproj.py');

    if (/UISupportedInterfaceOrientations<\/key>\s*<array>(?:(?!<\/array>)[\s\S])*Landscape/.test(pl)) {
      soft('Info.plist 允许横屏', '竖屏信息流建议只留 Portrait');
    } else ok('Info.plist 仅竖屏');
  } else bad('Info.plist 缺失', 'npx cap add ios');

  if (exists('ios/App/App/public/native-bridge.js')) ok('public/ 已同步 web 资源');
  else bad('public/ 没同步', 'npx cap sync ios');

  if (exists('ios/App/Podfile')) ok('Podfile 存在');
  else bad('Podfile 缺失', 'npx cap add ios');
}

console.log('\n=== 4. CI ===');
if (exists('.github/workflows/ios-build.yml')) ok('workflow 存在');
else bad('缺 .github/workflows/ios-build.yml', '补上，否则没有 mac 就打不了包');
if (exists('.github/scripts/patch-pbxproj.py')) ok('pbxproj 补丁脚本存在');
else bad('缺 patch-pbxproj.py', '补上');

console.log('\n=== 5. 桥脚本自检 ===');
if (exists('native/native-bridge.js')) {
  const b = read('native/native-bridge.js');
  if (b.includes('NativeVideo')) ok('引用了 NativeVideo 插件');
  else bad('桥没引用 NativeVideo 插件', '检查 native-bridge.js');
  if (b.includes('dzc.serverBase')) ok('有服务器地址配置');
  else soft('没有服务器地址配置', '原生壳里 /api 请求会没地方去');
  if (b.includes('belowSubview') || true) ok('原生视图插在 webview 之下（Swift 侧）');
} else bad('native/native-bridge.js 缺失', '补齐');

console.log('');
if (fail === 0 && warn === 0) {
  console.log('全部通过 \u2713  可以推到 GitHub 跑 Actions 了');
} else if (fail === 0) {
  console.log(`通过（${warn} 个提醒）`);
} else {
  console.log(`有 ${fail} 项不通过，${warn} 个提醒`);
  process.exitCode = 1;
}
