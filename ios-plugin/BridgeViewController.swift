import UIKit
import Capacitor
import WebKit

/// 应用入口（第 2 步：直接进原生 feed，接真实数据）。
///
/// 网页壳留在 `?web=1` 后面，需要对照时用。
/// 左上角小字显示当前模式，右下角按钮可切换。
class BridgeViewController: CAPBridgeViewController {

    private var nativeFeed: FeedViewController?
    private var switchButton: UIButton?
    private var modeLabel: UILabel?
    private var didSetup = false

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
        guard !didSetup else { return }
        didSetup = true
        addControls()

        let url = webView?.url?.absoluteString ?? ""
        if url.contains("web=1") {
            setMode(false)
        } else {
            mountFeed()
        }
    }

    private func addControls() {
        let b = UIButton(type: .custom)
        b.setTitle("切网页", for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        b.backgroundColor = UIColor(white: 0, alpha: 0.55)
        b.layer.cornerRadius = 14
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        view.addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            b.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            b.widthAnchor.constraint(equalToConstant: 70),
            b.heightAnchor.constraint(equalToConstant: 28),
        ])
        switchButton = b

        let m = UILabel()
        m.text = "原生"
        m.textColor = .white
        m.font = .systemFont(ofSize: 10)
        m.backgroundColor = UIColor(white: 0, alpha: 0.45)
        m.textAlignment = .center
        m.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(m)
        NSLayoutConstraint.activate([
            m.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            m.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            m.widthAnchor.constraint(equalToConstant: 44),
            m.heightAnchor.constraint(equalToConstant: 18),
        ])
        modeLabel = m
    }

    @objc private func toggle() {
        if nativeFeed != nil {
            removeFeed()
            setMode(false)
        } else {
            mountFeed()
            setMode(true)
        }
    }

    private func setMode(_ native: Bool) {
        modeLabel?.text = native ? "原生" : "网页"
        switchButton?.setTitle(native ? "切网页" : "切原生", for: .normal)
    }

    private func mountFeed() {
        guard nativeFeed == nil, view.window != nil else { return }
        let feed = FeedViewController()
        addChild(feed)
        guard let fv = feed.view else {
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
    }

    private func removeFeed() {
        guard let feed = nativeFeed else { return }
        feed.willMove(toParent: nil)
        feed.view.removeFromSuperview()
        feed.removeFromParent()
        nativeFeed = nil
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}
