// 把 ios-plugin/*.swift 拷进 ios/App/App/NativeStage/（Xcode 工程引用的位置）
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.join(ROOT, 'ios-plugin');
const DEST = path.join(ROOT, 'ios', 'App', 'App', 'NativeStage');

if (!fs.existsSync(path.join(ROOT, 'ios', 'App'))) {
  console.error('[copy-swift] 还没有 ios/ 工程，先跑: npx cap add ios');
  process.exit(1);
}

fs.mkdirSync(DEST, { recursive: true });

const files = fs.readdirSync(SRC).filter((f) => f.endsWith('.swift'));
for (const f of files) {
  fs.copyFileSync(path.join(SRC, f), path.join(DEST, f));
  console.log(`[copy-swift] ${f}`);
}
console.log(`[copy-swift] -> ${DEST}  (${files.length} 个文件)`);
