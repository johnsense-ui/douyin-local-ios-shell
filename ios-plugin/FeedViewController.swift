import AVFoundation
import UIKit

/// 竖屏 feed 主容器。
///
/// 移植自 dks333/Tiktok-Clone 的 HomeViewController（★430，MIT）。
/// 原版用 UITableView + isPagingEnabled + 每个 cell 自持播放器，
/// 这套结构简单且被验证能跑，所以照搬。
///
/// 关键时序（原版的设计，很重要）：
///   willDisplay      → cell.pause()     新 cell 出来先不动
///   didEndDisplaying → cell.pause()     划走的暂停
///   松手停稳后       → cell.replay()    这时才开始播
/// 这样滑动过程中不会来回启停，是顺滑的根本。
final class FeedViewController: UIViewController {

    private var items: [VideoItem] = []
    private var isLoading = false
    private var reachedEnd = false
    private var currentIndex = 0

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.backgroundColor = .black
        tv.isPagingEnabled = true
        tv.contentInsetAdjustmentBehavior = .never
        tv.showsVerticalScrollIndicator = false
        tv.separatorStyle = .none
        tv.tableFooterView = UIView()
        tv.rowHeight = 0
        tv.estimatedRowHeight = 0
        tv.dataSource = self
        tv.delegate = self
        tv.register(FeedCardCell.self, forCellReuseIdentifier: FeedCardCell.reuseID)
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let setupButton = UIButton(type: .custom)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setAudioSession()
        buildUI()
        if FeedService.shared.hasBase {
            loadMore()
        } else {
            showSetup()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visibleCell()?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visibleCell()?.pause()
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func setAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[dzc] audio session: \(error)")
        }
    }

    // MARK: - UI

    private func buildUI() {
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

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

    private func setStatus(_ t: String, spin: Bool = false, button: Bool = false) {
        statusLabel.text = t
        statusLabel.isHidden = t.isEmpty
        setupButton.isHidden = !button
        spinner.isHidden = !spin
        if spin { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    // MARK: - 数据

    private func showSetup() {
        setStatus("需要先设置服务器地址\n例如 http://192.168.1.10:6688",
                  spin: false, button: true)
    }

    @objc private func openSetup() {
        let a = UIAlertController(title: "服务器地址",
                                  message: "必须带 http:// 或 https://",
                                  preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "http://..."
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.text = FeedService.shared.base
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak a] _ in
            guard let self else { return }
            let v = (a?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.hasPrefix("http://") || v.hasPrefix("https://") else { return }
            FeedService.shared.base = v
            self.setStatus("正在加载…", spin: true)
            self.loadMore()
        })
        present(a, animated: true)
    }

    private func loadMore() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        if items.isEmpty { setStatus("正在加载…", spin: true) }

        FeedService.shared.fetchPage(offset: items.count, limit: 10, sort: "random") { [weak self] r in
            guard let self else { return }
            self.isLoading = false
            switch r {
            case .success(let page):
                if page.isEmpty {
                    self.reachedEnd = true
                    if self.items.isEmpty { self.setStatus("服务器没有返回视频") }
                    return
                }
                self.items.append(contentsOf: page)
                self.setStatus("")
                self.tableView.reloadData()
            case .failure(let e):
                self.setStatus("加载失败\n\(e.localizedDescription)", button: true)
            }
        }
    }

    // MARK: - cell

    private func visibleCell() -> FeedCardCell? {
        for c in tableView.visibleCells {
            if let cell = c as? FeedCardCell { return cell }
        }
        return nil
    }

    private func cellAt(_ row: Int) -> FeedCardCell? {
        tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? FeedCardCell
    }
}

// MARK: - UITableView

extension FeedViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: FeedCardCell.reuseID, for: indexPath) as? FeedCardCell else {
            return UITableViewCell()
        }
        guard indexPath.row < items.count else { return cell }
        cell.configure(items[indexPath.row], base: FeedService.shared.base)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let h = tableView.bounds.height
        return h > 1 ? h : max(view.bounds.height, 1)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // 原版逻辑：新 cell 出来先暂停，等松手再播
        (cell as? FeedCardCell)?.pause()
        currentIndex = indexPath.row
        if indexPath.row + 2 >= items.count { loadMore() }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? FeedCardCell)?.pause()
    }
}

// MARK: - 滚动

extension FeedViewController: UIScrollViewDelegate {

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleAndPlay() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleAndPlay()
    }

    /// 松手停稳后：回到第 0 秒重新播
    private func settleAndPlay() {
        guard !items.isEmpty else { return }
        let h = max(tableView.bounds.height, 1)
        let idx = Int((tableView.contentOffset.y / h).rounded())
        guard idx >= 0, idx < items.count else { return }
        currentIndex = idx
        if let cell = cellAt(idx) {
            cell.replay()
        } else {
            visibleCell()?.play()
        }
        let ahead = Array(items[idx..<min(idx + 3, items.count)])
        FeedService.shared.prefetchFirstFrames(ahead)
        if idx + 2 >= items.count { loadMore() }
    }
}
