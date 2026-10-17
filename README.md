# 本地视频 · iOS 原生壳

给 `douyin-local` 做的 iOS 播放壳：**画面交给 AVPlayer，网页只画 UI**。

针对的是在 iPhone 上反复验证过、网页层修不掉的一组问题：

- 首帧图顶不住黑屏（WebKit 里 `<video>` 是独立合成层，永远画在 DOM 之上）
- 起播瞬间必黑一下（`play()` 会立刻丢掉 `poster`）
- 下一条没预加载（没播过的 `<video>`，`preload` 被忽略）
- 滑过去黑一下、再黑一下、然后卡死
- 要点两下才播

Android / Edge 不受影响——那边继续用原来的 Web 版（Chromium 的媒体栈没有这些问题）。

---

## 架构

```
┌──────────────────────────────────────────┐
│  WKWebView（透明背景）                    │
│    ├─ 顶栏「关注 推荐」                    │
│    ├─ 右侧点赞/收藏/评论                   │
│    ├─ 底部文案                            │
│    └─ <video> 全部 visibility:hidden      │
├──────────────────────────────────────────┤
│  NativeStage（UIView，AVPlayerLayer × 2） │
│    ├─ current  正在播，首帧就绪才 opacity=1│
│    └─ next     预加载停在 0s，画面已就绪    │
└──────────────────────────────────────────┘
```

- 原生视图插在 WKWebView **下方**（`insertSubview(_:belowSubview:)`），网页整体透明
  → 底层原生画面 + 上层网页 UI，两边都不牺牲。
- 切条时**交换两个 player 的角色**（`stagedIsA.toggle()`），不 `replaceCurrentItem`
  → 没有重新缓冲、没有黑屏。
- `wantsPlay` 记录"用户想播"，`readyToPlay` 回调里自动 `play()` → 治"要点两下"。
- 网页代码**零改动**，靠三个注入脚本接管。

### 注入的三个脚本（顺序不能换）

| 脚本 | 时机 | 干什么 |
| --- | --- | --- |
| 内联 `shell-boot` | 同步、最先 | 打 `__IS_SHELL__`；把 history 路由 `/xxx` 改写成 `/#/xxx`（Capacitor 的 origin 不是 http，history 路由在里面不工作） |
| `net-patch.js` | 同步 | 把 `/api/xxx` 改写成 `http://你的服务器/api/xxx`，挂在 `fetch` / `XHR.open` / `HTMLMediaElement.src` setter 上 |
| `native-bridge.js` | DOMContentLoaded 后 | 找当前 `<video>`、交接给原生播放器、首启弹服务器地址输入框 |

> 不改主项目的构建（`base` / `define`）：主项目还要在 6688 上正常跑，
> 改构建配置等于给 Android / 桌面版埋雷。改写放在壳的运行时，主项目产物一个字节不动。

---

## 没有 Mac 怎么装到 iPhone

### 步骤 1 · 本地准备

```powershell
cd F:\新建文件夹\_ios-shell
npm install
npm run ios:all     # 构 web → 拷 www → 拷 swift → 打工程补丁 → cap sync
npm run doctor      # 体检，全绿再往下走
```

### 步骤 2 · 推到 GitHub

```powershell
cd F:\新建文件夹\_ios-shell
git init
git add .
git commit -m "iOS 原生壳：AVPlayer 舞台 + Capacitor 桥"
git branch -M main
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

> 仓库规模约 0.5 MB（`www/` 是 web 构建产物，只有 0.3 MB，直接提交）。
> 公开仓库的 macOS runner **不限时长**；私有仓库每月 2000 分钟，macOS 按 10 倍计费
> ≈ 200 分钟，够跑 10 次左右。

### 步骤 3 · 让 Actions 打包

仓库页 → **Actions** → 左侧 `ios-build` → **Run workflow**

- `server_base` 可填可不填：填了 App 首启不弹输入框，
  例如 `http://192.168.1.10:6688` 或 `https://locvid-pc.tail83739b.ts.net:8445`
- 跑完在 run 页面底部 **Artifacts** 下载 `douyin-ios-unsigned-<构建号>`
- 里面是 `douyin-local-unsigned.ipa`

首次跑大约 8–15 分钟（macOS runner 要装 CocoaPods、`pod install`）。

### 步骤 4 · 在 Windows 上签名 + 装

1. 装 [Sideloadly](https://sideloadly.io/)（Windows 版）
2. 装 **iTunes**——要用 Apple 官网的经典版，微软商店版不带 Sideloadly 需要的驱动
3. iPhone 用数据线连电脑，**信任此电脑**
4. Sideloadly：IPA 选刚下载的 `.ipa`，Apple ID 填免费账号 → Start
5. 首次需要**在手机上**打开「设置 → 通用 → VPN与设备管理」信任证书
6. 手机开启「开发者模式」（设置 → 隐私与安全性 → 开发者模式）

### 步骤 5 · 免费账号的限制

| 限制 | 值 | 后果 |
| --- | --- | --- |
| 签名有效期 | **7 天** | 到期 App 打不开。重新用 Sideloadly 签一次即可，**不用重新打包** |
| 同时安装 | 3 个 App | 够用 |
| 证书数量 | 每 7 天 10 个 | 反复重签会累积，太多要等一周 |
| 2FA | **必须本机确认** | 所以签名只能在本机做，不能在 CI 里做 |

想免掉 7 天重签 → $99/年 开发者账号（1 年），或按系统版本考虑 AltStore PAL / TrollStore。

---

## 真机第一次运行

App 名「本地视频」。首启会弹输入框要服务器地址：

- 局域网：`http://192.168.x.x:6688`
- Tailscale：`https://locvid-pc.tail83739b.ts.net:8445`（手机也要登同一账号）

填完自动 reload，之后不再问。想改：

```js
window.NativeVideoBridge.setServerBase('http://192.168.1.10:6688');  // 然后刷新
```

**排错用**：Mac 上 Safari → 开发 → 你的 iPhone → 选页面看 console。
Windows 上没有 Safari，所以壳里留了事件通道：

```js
window.addEventListener('native-video-state', e => console.log('原生状态', e.detail));
window.addEventListener('native-video-progress', e => console.log('进度', e.detail));
window.addEventListener('native-video-error', e => console.log('错误', e.detail));
window.__NATIVE_VIDEO__          // { available: true/false }
window.__DZC_ABS__('/api/videos') // 看网络改写对不对
```

### 症状 → 查哪层

| 观察 | 说明 |
| --- | --- |
| 界面出来了但画面全黑 | 原生舞台没挂上 → 查 `BridgeViewController` 有没有注册插件 |
| 画面在，UI 不见了 | 舞台插到了 webview 上面 → 应该 `insertSubview(_:belowSubview:)` |
| UI 在，但视频是网页自己在播 | 桥没生效 → 看 `window.__NATIVE_VIDEO__.available` |
| 列表空 / 一直 loading | 网络没接管 → 看 `window.__DZC_ABS__('/api/videos')` 有没有补上 host |
| 能播但没声音 | 静音状态映射反了 → 看 `native-video-state` 事件的 `muted` |
| 切条还是黑一下 | `advanceToNext()` 里是不是又变成 `replaceCurrentItem` 了 |

---

## 目录

| 路径 | 作用 |
| --- | --- |
| `ios-plugin/NativeStage.swift` | AVPlayer 舞台。双 player 双 layer，切条只换角色不重建 |
| `ios-plugin/NativeVideoPlugin.swift` | Capacitor 插件，`jsName = "NativeVideo"`；舞台插到 webview 下方 |
| `ios-plugin/BridgeViewController.swift` | **关键**：`CAPBridgeViewController` 子类，`capacitorDidLoad()` 里注册插件 |
| `ios-plugin/Info.plist.template` | Info.plist 模板（ATS / 后台音频 / 竖屏锁），脚本直接覆盖 |
| `native/native-bridge.js` | 网页侧桥。浏览器里自动失效，壳里自动接管画面 |
| `native/net-patch.js` | `/api/xxx` → 绝对地址；浏览器里自动失效 |
| `scripts/copy-web.mjs` | 主项目 `web/dist` → `www/`，注入 shell-boot + 两个脚本 |
| `scripts/copy-swift.mjs` | `ios-plugin/*.swift` → `ios/App/App/NativeStage/` |
| `scripts/doctor.mjs` | 本机体检：产物 / 工程 / plist / CI 是否到位 |
| `.github/scripts/patch-pbxproj.py` | 无 Xcode GUI 时改工程：加编译文件、换根 VC、覆盖 Info.plist（幂等） |
| `.github/workflows/ios-build.yml` | macOS runner 出未签名 IPA |
| `www/` | web 构建产物 |
| `ios/` | Capacitor 生成的 Xcode 工程骨架（Pods / public / build 已 gitignore） |

---

## 改了网页代码之后

`www/` 是主项目构建产物的**拷贝**。改了 `FeedView.vue` 等：

```powershell
cd F:\新建文件夹\_ios-shell
npm run build:web     # 重新构建主项目 web
npm run sync:web      # 拷进 www/
git add www && git commit -m "更新 web 产物" && git push
```

Actions 会自动重跑 → 下载新 IPA → Sideloadly 覆盖安装（不用先删旧的）。

---

## 首次 CI 可能撞到的坑

1. `CAPBridgedPlugin` 协议字段在不同 Capacitor 6 小版本里略有差异 → 照日志补。
2. `bridge?.webView` 的可选性 → 改成 `self.webView`。
3. `preferredScreenEdgesDeferringSystemGestures` 覆写签名 → 删掉那行。
4. `pod install` 慢 → workflow 里已加 `--repo-update`。
