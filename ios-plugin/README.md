# iOS 工程里要做的三件事

> **好消息**：这三步已经全部脚本化了，`npm run ios:all` 一条命令做完，不需要 Xcode GUI。
> 这里只是把它们讲清楚，方便出问题时对照。

## 0. 一条命令

```bash
cd _ios-shell
npm run ios:all
npm run doctor      # 全绿才算好
```

它依次做：

1. `npm run build:web` — 构建主项目 web
2. `npm run sync:web` — `web/dist` → `www/`，注入 `native-bridge.js`
3. `npx cap add ios` — 生成 `ios/`
4. `npm run copy:swift` — `ios-plugin/*.swift` → `ios/App/App/NativeStage/`
5. `npm run patch:proj` — 改 `project.pbxproj` + `Main.storyboard` + `Info.plist`
6. `npx cap sync ios` — 同步 web 资源

## 1. 把 Swift 文件加进编译（脚本自动做）

`cap add ios` 生成的 `App.xcodeproj` 只认识模板文件。我们写的三个 Swift 不手工
Add Files 就不会被编译，网页侧 `Capacitor.Plugins.NativeVideo` 会是 `undefined`。

`patch-pbxproj.py` 干的事：

- 在 `PBXFileReference` 段加三条引用（id 用文件名哈希，稳定可重跑）
- 在 `PBXBuildFile` 段加三条编译项
- 挂进 `App` group 的 `children`
- 挂进 `App` target 的 `Sources` build phase

**幂等**：重复跑不会重复添加。

## 2. 换根视图控制器（脚本自动做，最容易漏）

Capacitor 6 **不会**自动发现项目里的 `CAPBridgedPlugin`。必须让
`CAPBridgeViewController` 的子类去 `registerPluginInstance`：

```swift
class BridgeViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativeVideoPlugin())
    }
    ...
}
```

然后把 `Main.storyboard` 里那个 viewController 的 `customClass` 从
`CAPBridgeViewController` 改成 `BridgeViewController`：

```xml
<viewController id="BYZ-38-t0r"
                customClass="BridgeViewController"
                customModule="App"
                customModuleProvider="target"
                sceneMemberID="viewController"/>
```

漏了这一步的现象：**画面完全不接管，跟浏览器里一模一样**（因为桥脚本检测到
没有插件就直接 return 了）。

## 3. Info.plist（脚本自动补）

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
<key>UISupportedInterfaceOrientations</key>
<array><string>UIInterfaceOrientationPortrait</string></array>
```

- ATS：你的服务是 http（局域网 6688），不放开连不上
- 后台音频：锁屏/切后台不掐断
- 只留竖屏：信息流不需要横屏

---

# 文件说明

| 文件 | 作用 |
| --- | --- |
| `NativeStage.swift` | AVPlayer 舞台：双 player 双 layer，首帧就绪才 opacity=1，切条只换角色不重建 |
| `NativeVideoPlugin.swift` | Capacitor 插件，`jsName = "NativeVideo"`；舞台插到 WKWebView **下方** |
| `BridgeViewController.swift` | `CAPBridgeViewController` 子类，注册插件 + webview 透明 + 布局后重置层级 |
| `../native/native-bridge.js` | 网页侧桥：自动找当前 `<video>`、隐藏它、驱动原生；浏览器里自动失效 |
| `../scripts/copy-web.mjs` | `web/dist` → `www/` + 注入桥 |
| `../scripts/copy-swift.mjs` | `ios-plugin/*.swift` → `ios/App/App/NativeStage/` |
| `../scripts/doctor.mjs` | 本机体检 |
| `../.github/scripts/patch-pbxproj.py` | 改 pbxproj / storyboard / Info.plist（幂等） |
| `../.github/workflows/ios-build.yml` | macOS runner 出未签名 `.ipa` |

# 排错速查

| 现象 | 查这里 |
| --- | --- |
| 画面完全没接管，跟 Safari 一样 | `BridgeViewController` 有没有被 cap 注册 / storyboard customClass 改没改 |
| UI 被黑屏挡住 | 舞台是不是插到了 webview 上面（应该 `belowSubview`）+ 网页背景有没有透明 |
| 能播但没声 | `setMuted` 传的是不是 `false`；`UIBackgroundModes` 有没有 audio |
| 首帧还是黑 | `markCurrentReady` 有没有被调到；`currentLayer.opacity` 是不是 0 |
| 切条黑一下 | `advanceToNext` 里是不是还在 `replaceCurrentItem` |
