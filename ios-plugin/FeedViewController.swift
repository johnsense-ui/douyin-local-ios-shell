import UIKit

/// 原生竖屏 feed（第 2 步：接真实数据，显示首帧图 + 作者 + 文案）。
///
/// 这一版**不含播放器**，专门验证：
///   · 能不能拉到服务器的数据
///   · 能不能显示首帧图
///   · 翻页顺不顺
/// 播放器是第 3 步，单独加，出问题好定位。
final class FeedViewController: UIViewController {

    private var items: [VideoItem] = []
    private var isLoading = false
    private var reachedEnd = false
    private var seed: Int = Int(Date().timeIntervalSince1970)

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.isPagingEnabled = true
        cv.showsVerticalScrollIndicator = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.backgroundColor = .black
        cv.dataSource = self
        cv.delegate = self
        cv.register(FeedCardCell.self, forCellWithReuseIdentifier: "card")
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let setupButton = UIButton(type: .custom)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()

        if FeedService.shared.hasBase {
            loadMore()
        } else {
            showSetup()
        }
    }

    // MARK: - UI

    private func buildUI() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        statusLabel.text = "正在加载…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        setupButton.setTitle("设置服务器地址", for: .normal)
        setupButton.setTitleColor(.white, for: .normal)
        setupButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        setupButton.backgroundColor = UIColor(red: 0.996, green: 0.173, blue: 0.333, alpha: 1)
        setupButton.layer.cornerRadius = 10
        setupButton.isHidden = true
        setupButton.translatesAutoresizingMaskIntoConstraints = false
        setupButton.addTarget(self, action: #selector(openSetup), for: .touchUpInside)
        view.addSubview(setupButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 44),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            setupButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            setupButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 44),
            setupButton.widthAnchor.constraint(equalToConstant: 200),
            setupButton.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func setStatus(_ text: String, showSpinner: Bool = false, showButton: Bool = false) {
        statusLabel.text = text
        statusLabel.isHidden = false
        setupButton.isHidden = !showButton
        if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !showSpinner
    }

    private func clearStatus() {
        statusLabel.isHidden = true
        setupButton.isHidden = true
        spinner.stopAnimating()
        spinner.isHidden = true
    }

    // MARK: - 设置地址

    private func showSetup() {
        setStatus("需要先设置服务器地址\n例如 http://192.168.1.10:6688\n或 https://locvid-pc.tail83739b.ts.net:8445", showSpinner: false, showButton: true)
    }

    @objc private func openSetup() {
        let alert = UIAlertController(title: "服务器地址",
                                      message: "必须带 http:// 或 https://",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "http://..."
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.text = FeedService.shared.base
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.hasPrefix("http://") || v.hasPrefix("https://") else { return }
            FeedService.shared.base = v
            self.setStatus("正在加载…", showSpinner: true)
            self.loadMore()
        })
        present(alert, animated: true)
    }

    // MARK: - 数据

    private func loadMore() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        if items.isEmpty { setStatus("正在加载…", showSpinner: true) }

        FeedService.shared.fetchPage(offset: items.count, limit: 20, sort: "random") { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(let page):
                if page.isEmpty {
                    self.reachedEnd = true
                    if self.items.isEmpty { self.setStatus("服务器没有返回视频", showSpinner: false) }
                    return
                }
                let start = self.items.count
                self.items.append(contentsOf: page)
                self.clearStatus()
                if start == 0 {
                    self.collectionView.reloadData()
                } else {
                    self.collectionView.reloadData()
                }
                FeedService.shared.prefetchFirstFrames(Array(page.prefix(6)))
            case .failure(let err):
                self.setStatus("加载失败\n\(err.localizedDescription)", showSpinner: false, showButton: true)
            }
        }
    }
}

extension FeedViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as? FeedCardCell else {
            return UICollectionViewCell()
        }
        guard indexPath.item < items.count else { return cell }
        cell.bind(items[indexPath.item], base: FeedService.shared.base)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let s = collectionView.bounds.size
        if s.width < 1 || s.height < 1 {
            let v = view.bounds.size
            return v.width > 1 ? v : CGSize(width: 320, height: 568)
        }
        return s
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !items.isEmpty else { return }
        let h = max(scrollView.bounds.height, 1)
        let idx = Int((scrollView.contentOffset.y / h).rounded())
        if idx + 3 >= items.count { loadMore() }
    }
}
