import AVFoundation
import UIKit

/// 竖屏 feed 主容器（抖音同款结构）。
///
/// ═══════════════════════════════════════════════════════════════
/// 为什么这样搭
/// ───────────────────────────────────────────────────────────────
///   之前：网页 UIScrollView 滑动 + AVPlayer 播放，靠 JS 每 80ms 轮询对齐。
///         结果就是「手指动了画面没动」的脱节感，快滑还会黑屏。
///
///   现在：UICollectionView 竖向分页 + 播放器池共用。
///         拖动时 cell 跟着滚，AVPlayerLayer 就挂在 cell 里 ——
///         手指和画面在**同一次 layout 里**移动，物理上不可能脱节。
///
///   抖音的关键细节都在 scrollViewDidScroll 里：
///     · |velocity| 大 → setScrubbing(true) → 池子只出首帧、绝不解码
///     · 滚动停止（targetContentOffset 定下来）→ setScrubbing(false)
///     · 停稳 150ms 后才 play()，避免吸附动画中反复启停
/// ═══════════════════════════════════════════════════════════════
final class FeedViewController: UIViewController {

    // MARK: - 数据

    private var items: [VideoItem] = []
    private var isLoading = false
    private var reachedEnd = false
    private let pageSize = 20

    // MARK: - 视图

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
        cv.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.reuseID)
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    private let pool = PlaybackPool()
    private let service = FeedService.shared
    private var currentIndex = 0

    private let emptyLabel = UILabel()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let setupButton = UIButton(type: .system)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        wirePool()

        if !service.hasBase {
            showSetupPrompt()
        } else {
            loadMore(reset: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if service.hasBase, items.isEmpty, !isLoading {
            loadMore(reset: true)
        }
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - UI

    private func setupViews() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        emptyLabel.text = "还没有视频"
        emptyLabel.textColor = .white
        emptyLabel.font = .systemFont(ofSize: 16)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        loadingSpinner.color = .white
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingSpinner)

        setupButton.setTitle("设置服务器地址", for: .normal)
        setupButton.setTitleColor(.white, for: .normal)
        setupButton.backgroundColor = UIColor(red: 0.996, green: 0.173, blue: 0.333, alpha: 1)
        setupButton.layer.cornerRadius = 10
        setupButton.isHidden = true
        setupButton.translatesAutoresizingMaskIntoConstraints = false
        setupButton.addTarget(self, action: #selector(openSetup), for: .touchUpInside)
        view.addSubview(setupButton)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            setupButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            setupButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 40),
            setupButton.widthAnchor.constraint(equalToConstant: 200),
            setupButton.heightAnchor.constraint(equalToConstant: 46),
        ])

        // 单击暂停/播放
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        collectionView.addGestureRecognizer(tap)
    }

    private func wirePool() {
        pool.onState = { [weak self] phase, id in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handlePoolState(phase, id)
            }
        }
    }

    private func handlePoolState(_ phase: String, _ id: Int?) {
        guard let cell = visibleCell() else { return }
        switch phase {
        case "ready":
            cell.setNativeVisible(true)
        case "playing":
            cell.setPlaying(true)
            cell.setNativeVisible(true)
        case "paused", "scrubbing", "primed":
            cell.setPlaying(false)
        default:
            break
        }
    }

    private func visibleCell() -> FeedCell? {
        let centerY = collectionView.contentOffset.y + view.bounds.height / 2
        var best: FeedCell?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for case let cell as FeedCell in collectionView.visibleCells {
            let d = abs(cell.center.y - centerY)
            if d < bestDist {
                bestDist = d
                best = cell
            }
        }
        return best
    }

    // MARK: - 数据

    private func loadMore(reset: Bool = false) {
        guard !isLoading else { return }
        if reset {
            service.resetSeed()
            reachedEnd = false
            items.removeAll()
            currentIndex = 0
        }
        guard !reachedEnd else { return }

        isLoading = true
        loadingSpinner.startAnimating()

        let offset = items.count
        service.fetchPage(offset: offset, limit: pageSize) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            self.loadingSpinner.stopAnimating()
            switch result {
            case .success(let page):
                if page.isEmpty {
                    self.reachedEnd = true
                } else {
                    let start = self.items.count
                    self.items.append(contentsOf: page)
                    self.service.prefetchFirstFrames(Array(page.prefix(6)))
                    if reset {
                        self.collectionView.reloadData()
                        DispatchQueue.main.async {
                            self.collectionView.layoutIfNeeded()
                            self.syncPlayerToIndex(0, priming: false)
                        }
                    } else if start <= self.currentIndex + 1 {
                        // 新数据填进邻条
                        self.fillNeighbors()
                    }
                }
                self.emptyLabel.isHidden = !self.items.isEmpty
                if self.items.isEmpty { self.showSetupPromptIfNeeded() }
            case .failure(let err):
                self.emptyLabel.text = "加载失败：\(err.localizedDescription)"
                self.emptyLabel.isHidden = false
                if !self.service.hasBase { self.showSetupPrompt() }
            }
        }
    }

    private func showSetupPromptIfNeeded() {
        if !service.hasBase { showSetupPrompt() }
    }

    private func showSetupPrompt() {
        emptyLabel.text = "需要先设置服务器地址"
        emptyLabel.isHidden = false
        setupButton.isHidden = false
    }

    @objc private func openSetup() {
        let alert = UIAlertController(
            title: "服务器地址",
            message: "例如 http://192.168.1.10:6688\n或你的 Tailscale 地址（必须带 http:// 或 https://）",
            preferredStyle: .alert
        )
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
            self.service.base = v
            self.emptyLabel.isHidden = true
            self.setupButton.isHidden = true
            self.loadMore(reset: true)
        })
        present(alert, animated: true)
    }

    // MARK: - 播放器同步（核心）

    /// 把播放器池对准第 index 条
    private func syncPlayerToIndex(_ index: Int, priming: Bool) {
        guard index >= 0, index < items.count else { return }
        guard service.hasBase else { return }
        let base = service.base
        let cur = items[index]
        guard let curURL = cur.streamURL(base: base) else { return }

        var nextPair: (Int, URL)?
        if index + 1 < items.count, let u = items[index + 1].streamURL(base: base) {
            nextPair = (items[index + 1].id, u)
        }
        var prevPair: (Int, URL)?
        if index - 1 >= 0, let u = items[index - 1].streamURL(base: base) {
            prevPair = (items[index - 1].id, u)
        }

        pool.setCurrent(id: cur.id, url: curURL, next: nextPair, prev: prevPair, priming: priming)

        // 图层挂到 cell 上
        DispatchQueue.main.async {
            self.attachLayers()
        }
        // 提前拉后面几条的首帧图
        let ahead = Array(items[index..<min(index + 5, items.count)])
        service.prefetchFirstFrames(ahead)
        // 提前拉下一页数据
        if index + 3 >= items.count { loadMore() }
    }

    private func fillNeighbors() {
        guard currentIndex < items.count else { return }
        syncPlayerToIndex(currentIndex, priming: false)
    }

    /// 三个槽位的 layer 分别挂到对应 cell
    private func attachLayers() {
        let ids = collectionView.indexPathsForVisibleItems.compactMap { $0.item }
        for idx in ids {
            guard idx < items.count else { continue }
            guard let cell = collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? FeedCell else { continue }
            let vid = items[idx].id
            var matched: AVPlayerLayer?
            if pool.current.videoID == vid { matched = pool.current.layer }
            else if pool.next.videoID == vid { matched = pool.next.layer }
            else if pool.prev.videoID == vid { matched = pool.prev.layer }
            if let l = matched {
                cell.attach(l)
                cell.layoutPlayerLayer(l)
                cell.setNativeVisible(l.opacity > 0.5 && l.isReadyForDisplay)
            }
        }
    }

    // MARK: - 手势

    @objc private func handleTap() {
        pool.togglePlay()
    }
}

// MARK: - UICollectionViewDataSource

extension FeedViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FeedCell.reuseID, for: indexPath) as! FeedCell
        guard indexPath.item < items.count else { return cell }
        let item = items[indexPath.item]
        cell.bind(item, base: service.base)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        attachLayers()

        let h = max(scrollView.bounds.height, 1)
        let raw = scrollView.contentOffset.y / h
        let idx = Int(raw.rounded())
        guard idx >= 0, idx < items.count else { return }

        // 快速滑动判定：|velocity| 超过阈值就认为在"刷"，只出首帧
        let fast = abs(scrollView.panGestureRecognizer.velocity(in: scrollView).y) > 900
        if fast, !pool.isScrubbing {
            pool.setScrubbing(true)
        }

        if idx != currentIndex {
            let dir = idx > currentIndex ? "down" : "up"
            currentIndex = idx
            _ = dir
            syncPlayerToIndex(idx, priming: fast)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settle()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    private func settle() {
        let h = max(collectionView.bounds.height, 1)
        let idx = Int((collectionView.contentOffset.y / h).rounded())
        guard idx >= 0, idx < items.count else { return }
        if idx != currentIndex {
            currentIndex = idx
            syncPlayerToIndex(idx, priming: false)
        }
        // 停稳：取消 scrubbing，池子会在 150ms 后起播
        if pool.isScrubbing {
            pool.setScrubbing(false)
        } else {
            pool.play()
        }
    }
}
