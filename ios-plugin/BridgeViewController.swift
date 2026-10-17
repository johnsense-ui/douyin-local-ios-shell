import UIKit
import Capacitor
import WebKit

/// 应用入口。
///
/// 默认进**原生竖屏 feed**（学抖音，滑动和播放同一 runloop）。
/// URL 带 `?web=1` 时留在网页壳。
///
/// ═══════════════════════════════════════════════════════════════
/// 闪退排查原则（没有 Mac / Xcode 调试器时）
/// ───────────────────────────────────────────────────────────────
///   · 每一条启动路径都用显式判断，不用 `!` 强制解包
///   · 原生 feed 单独做成一个可失败的步骤：挂了就留在网页壳，
///     屏幕上弹红条显示原因，而不是让 App 消失
///   · 所有异常都写进 UserDefaults["dzc.lastCrash"]，下次启动能读
/// ═══════════════════════════════════════════════════════════════
class BridgeViewController: CAPBridgeViewController {

    private var nativeFeed: FeedViewController?
    private var didAttemptNativeFeed = false
    private var errorBanner: UILabel?

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

        // 上次崩溃记录留在屏幕上（有的话）
        if let last = UserDefaults.standard.string(forKey: "dzc.lastCrash"), !last.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showErrorBanner("上次崩溃：\n" + last)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !didAttemptNativeFeed else { return }
        didAttemptNativeFeed = true

        let url = webView?.url?.absoluteString ?? ""
        guard !url.contains("web=1") else { return }

        mountNativeFeed()
    }

    // MARK: - 挂载原生 feed（每一步都可失败，失败就留在网页壳）

    private func mountNativeFeed() {
        // 先检查必要前提，任何一条不满足就不挂
        guard view.window != nil else {
            logCrash("mount", "view 不在 window 上")
            return
        }

        let feed = FeedViewController()

        // 【顺序很重要】先 addChild，再碰 feed.view。
        // 在 addChild 前访问 .view 会提前触发 loadView，
        // 此时 VC 还没进正常 appearance 生命周期 → 状态不一致 → 闪退。
        addChild(feed)

        guard let fv = feed.view else {
            logCrash("mount", "FeedViewController.view 为 nil")
            feed.removeFromParent()
            return
        }

        fv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fv)
        NSLayoutConstraint.activate([
            fv.topAnchor.constraint(equalTo: view.topAnchor),
            fv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        feed.didMove(toParent: self)
        nativeFeed = feed
    }

    // MARK: - 错误条

    private func showErrorBanner(_ text: String) {
        guard errorBanner == nil else { return }
        let label = UILabel()
        label.numberOfLines = 0
        label.text = text
        label.textColor = .white
        label.font = UIFont(name: "Menlo", size: 11) ?? .systemFont(ofSize: 11)
        label.backgroundColor = UIColor(red: 0.7, green: 0.05, blue: 0.15, alpha: 0.95)
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissBanner)))
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        errorBanner = label
    }

    @objc private func dismissBanner() {
        errorBanner?.removeFromSuperview()
        errorBanner = nil
    }

    private func logCrash(_ where_: String, _ msg: String) {
        let s = "[\(where_)] \(msg)"
        UserDefaults.standard.set(s, forKey: "dzc.lastCrash")
        print("[dzc] \(s)")
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
