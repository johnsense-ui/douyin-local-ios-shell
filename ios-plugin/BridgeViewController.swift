import UIKit
import Capacitor
import WebKit

/**
 * Capacitor 的 bridge view controller。
 *
 * 【关键一步】Capacitor 6 不会自动注册项目里自定义的 CAPBridgedPlugin，
 * 必须在 registerPlugins() 里手动 registerPluginInstance。
 * 少了这一步，网页侧 `Capacitor.Plugins.NativeVideo` 是 undefined，
 * native-bridge.js 会判定"没有原生插件"然后什么都不做（页面照旧用 <video>）。
 */
class BridgeViewController: CAPBridgeViewController {

    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativeVideoPlugin())
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 网页背景透明 → 底层原生播放画面能透出来
        view.backgroundColor = .black
        if let webView = self.webView {
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isOpaque = false
            // 关掉长按放大镜 / 选中，短视频体验更像原生
            webView.scrollView.bounces = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            if #available(iOS 16.4, *) {
                webView.isInspectable = true   // Safari 远程调试（真机排错用）
            }
        }

        NotificationCenter.default.post(name: Notification.Name("dzcWebReady"), object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 每次布局后确认舞台在最底层（Capacitor 有时会重排子视图）
        NotificationCenter.default.post(name: Notification.Name("dzcWebReady"), object: nil)
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
