import UIKit
import Capacitor
import WebKit

/// 应用入口。
///
/// 现在默认直接进**原生竖屏 feed**（学抖音，滑动和播放同一 runloop）。
/// 网页壳保留在 `?web=1` 后面，用来对照/兜底：
///   - 早期用网页做的列表、搜索、设置这些页还能用
///   - 万一原生 feed 出问题，可以立刻切回网页验证是数据问题还是渲染问题
///
/// 为什么不再让网页当主界面：
///   UIWebView 的 UIScrollView 滑动 和 AVPlayer 画面是两个独立的时钟，
///   靠 JS 每 80ms 轮询对齐，快滑时必然脱节。抖音顺滑的本质是
///   「手势、布局、播放全在同一个 runloop」，网页做不到。
class BridgeViewController: CAPBridgeViewController {

    private var nativeFeed: FeedViewController?

    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativeVideoPlugin())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if let webView = self.webView {
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isOpaque = false
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }
        }
        NotificationCenter.default.post(name: Notification.Name("dzcWebReady"), object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 默认进原生 feed；URL 带 ?web=1 时留在网页
        let url = webView?.url?.absoluteString ?? ""
        guard !url.contains("web=1") else { return }
        guard nativeFeed == nil else { return }
        presentNativeFeed()
    }

    private func presentNativeFeed() {
        let feed = FeedViewController()
        feed.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(feed)
        view.addSubview(feed.view)
        NSLayoutConstraint.activate([
            feed.view.topAnchor.constraint(equalTo: view.topAnchor),
            feed.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            feed.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            feed.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        feed.didMove(toParent: self)
        nativeFeed = feed
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
