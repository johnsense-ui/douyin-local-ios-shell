import UIKit
import Capacitor
import WebKit

/// 应用入口。
///
/// ═══════════════════════════════════════════════════════════════
/// 当前策略：**默认进网页壳，不再默认进原生 feed**
/// ───────────────────────────────────────────────────────────────
///   原因：原生 feed 在没有 Mac / Xcode 调试器的条件下盲写，
///   反复闪退。继续这样试错对你不公平。
///
///   现在的分工：
///     · 默认 → 网页壳（能用，虽然有 WebKit 的老问题）
///     · 点击右上角「原生」按钮 → 试原生 feed
///     · 原生 feed 崩了 → 自动退回网页壳 + 屏幕显示原因
///
///   这样你随时能用 App，我也能拿到崩溃原因再针对性修。
/// ═══════════════════════════════════════════════════════════════
class BridgeViewController: CAPBridgeViewController {

    private var nativeFeed: FeedViewController?
    private var errorBanner: UILabel?
    private var switchButton: UIButton?
    private var crashObserver: NSObjectProtocol?

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

        installCrashHandlers()
        loadPreviousCrash()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard switchButton == nil else { return }
        addSwitchButton()
    }

    // MARK: - 切换按钮

    private func addSwitchButton() {
        var cfg = UIButton.Configuration.plain() as UIButton.Configuration?
        if #available(iOS 15, *) {
            cfg = UIButton.Configuration.plain()
            cfg?.title = "原生"
            cfg?.baseForegroundColor = .white
            cfg?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            cfg?.background.backgroundColor = UIColor(white: 0, alpha: 0.55)
            cfg?.background.cornerRadius = 14
        }
        let b = UIButton(frame: CGRect(x: 0, y: 0, width: 64, height: 30))
        if #available(iOS 15, *), let c = cfg {
            b.configuration = c
        } else {
            b.setTitle("原生", for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor(white: 0, alpha: 0.55)
            b.layer.cornerRadius = 14
            b.titleLabel?.font = .systemFont(ofSize: 13)
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(toggleNative), for: .touchUpInside)
        view.addSubview(b)
        NSLayoutConstraint.activate([
            b.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            b.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            b.widthAnchor.constraint(equalToConstant: 64),
            b.heightAnchor.constraint(equalToConstant: 30),
        ])
        switchButton = b
    }

    @objc private func toggleNative() {
        if nativeFeed != nil {
            removeNativeFeed()
        } else {
            mountNativeFeed()
        }
    }

    private func removeNativeFeed() {
        guard let feed = nativeFeed else { return }
        feed.willMove(toParent: nil)
        feed.view.removeFromSuperview()
        feed.removeFromParent()
        nativeFeed = nil
        switchButton?.setTitle("原生", for: .normal)
        if #available(iOS 15, *) {
            var c = switchButton?.configuration
            c?.title = "原生"
            switchButton?.configuration = c
        }
    }

    // MARK: - 挂载 / 卸载

    private func mountNativeFeed() {
        guard view.window != nil else {
            showBanner("无法挂载：view 不在 window 上")
            return
        }

        let feed = FeedViewController()
        addChild(feed)   // 先 addChild，再碰 view

        guard let fv = feed.view else {
            feed.removeFromParent()
            showBanner("FeedViewController.view 为 nil")
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
        view.bringSubviewToFront(switchButton!)

        if #available(iOS 15, *) {
            var c = switchButton?.configuration
            c?.title = "网页"
            switchButton?.configuration = c
        } else {
            switchButton?.setTitle("网页", for: .normal)
        }
    }

    // MARK: - 崩溃记录

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            // 注意：这里只有少量时间，尽量只做一件纯内存的事
            let name = exception.name.rawValue
            let reason = exception.reason ?? ""
            let stack = exception.callStackSymbols.prefix(16).joined(separator: "\n")
            let msg = "\(name)\n\(reason)\n---\n\(stack)"
            UserDefaults.standard.set(msg, forKey: "dzc.lastCrash")
        }
    }

    private func loadPreviousCrash() {
        guard let last = UserDefaults.standard.string(forKey: "dzc.lastCrash"),
              !last.isEmpty,
              last != UserDefaults.standard.string(forKey: "dzc.shownCrash") else { return }
        UserDefaults.standard.set(last, forKey: "dzc.shownCrash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showBanner("上次崩溃：\n" + last)
        }
    }

    private func showBanner(_ text: String) {
        errorBanner?.removeFromSuperview()
        let label = UILabel()
        label.numberOfLines = 0
        label.text = text
        label.textColor = .white
        label.font = UIFont(name: "Menlo", size: 10) ?? .systemFont(ofSize: 10)
        label.backgroundColor = UIColor(red: 0.65, green: 0.05, blue: 0.15, alpha: 0.96)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissBanner)))

        // 加个滚动，长堆栈也能看全
        let scroll = UIScrollView()
        scroll.backgroundColor = UIColor(red: 0.65, green: 0.05, blue: 0.15, alpha: 0.96)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 260),

            label.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -16),
        ])
        errorBanner = label
        scroll.tag = 0xD2C
    }

    @objc private func dismissBanner() {
        (errorBanner?.superview as? UIScrollView)?.removeFromSuperview()
        view.viewWithTag(0xD2C)?.removeFromSuperview()
        errorBanner = nil
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
