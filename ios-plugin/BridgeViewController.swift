import UIKit
import Capacitor
import WebKit

/// 应用入口 —— 最小验证版。
///
/// 目的：先确认「原生 VC 能挂上、能分页」这条链路通不通。
/// 不注册任何自定义插件，不接播放器，不接数据。
/// 左上角绿点表示原生 feed 已挂载，右下角按钮在原生/网页之间切换。
class BridgeViewController: CAPBridgeViewController {

    private var nativeFeed: FeedViewController?
    private var badge: UILabel?
    private var switchButton: UIButton?
    private var didSetupUI = false

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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        addControls()
        mountNativeFeed()
    }

    private func addControls() {
        let b = UIButton(type: .custom)
        b.setTitle("切网页", for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        b.backgroundColor = UIColor(white: 0, alpha: 0.6)
        b.layer.cornerRadius = 15
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(toggleFeed), for: .touchUpInside)
        view.addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            b.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            b.widthAnchor.constraint(equalToConstant: 76),
            b.heightAnchor.constraint(equalToConstant: 32),
        ])
        switchButton = b

        let dot = UILabel()
        dot.text = "原生已挂载"
        dot.textColor = .white
        dot.font = .systemFont(ofSize: 11)
        dot.backgroundColor = UIColor(red: 0, green: 0.55, blue: 0.2, alpha: 0.9)
        dot.textAlignment = .center
        dot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            dot.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            dot.widthAnchor.constraint(equalToConstant: 90),
            dot.heightAnchor.constraint(equalToConstant: 20),
        ])
        badge = dot
    }

    @objc private func toggleFeed() {
        if nativeFeed != nil {
            removeNativeFeed()
        } else {
            mountNativeFeed()
        }
    }

    private func mountNativeFeed() {
        guard nativeFeed == nil, view.window != nil else { return }

        let feed = FeedViewController()
        addChild(feed)                    // 先 addChild
        guard let fv = feed.view else {   // 再取 view
            feed.removeFromParent()
            return
        }
        fv.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(fv, at: 0)
        NSLayoutConstraint.activate([
            fv.topAnchor.constraint(equalTo: view.topAnchor),
            fv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        feed.didMove(toParent: self)
        nativeFeed = feed
        badge?.text = "原生已挂载"
        badge?.backgroundColor = UIColor(red: 0, green: 0.55, blue: 0.2, alpha: 0.9)
        switchButton?.setTitle("切网页", for: .normal)
    }

    private func removeNativeFeed() {
        guard let feed = nativeFeed else { return }
        feed.willMove(toParent: nil)
        feed.view.removeFromSuperview()
        feed.removeFromParent()
        nativeFeed = nil
        badge?.text = "网页模式"
        badge?.backgroundColor = UIColor(white: 0.3, alpha: 0.9)
        switchButton?.setTitle("切原生", for: .normal)
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
