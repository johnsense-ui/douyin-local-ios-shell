import AVFoundation
import UIKit

/// 原生竖屏 feed（第 3 步：接上 AVPlayer 播放）。
///
/// 结构：
///   UICollectionView（竖向分页）
///     └─ FeedCardCell（首帧图 + videoHost + 文字）
///          └─ videoHost ← VideoPool 把 AVPlayerLayer 挂进来
///
/// 关键点：
///   · 播放器在池子里，cell 只提供挂载点 —— cell 复用不影响播放
///   · 滚动时判断当前是第几条，把池子对准它
///   · 快速滑动 → setScrubbing(true)，只暂停，不解码
///   · 停稳 0.2s → 起播
final class FeedViewController: UIViewController {

    private var items: [VideoItem] = []
    private var isLoading = false
    private var reachedEnd = false

    private let pool = VideoPool()
    private var currentIndex = -1

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
    private let debugLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        wirePool()

        if FeedService.shared.hasBase {
            loadMore()
        } else {
            showSetup()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 上屏后如果已经有数据，把池子对准第 0 条
        if !items.isEmpty, pool.current.videoID == nil {
            syncPool(to: 0, scrubbing: false)
        }
        if pool.wantsPlay { pool.play() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pool.pause()
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - UI

    private func buildUI() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        spinner.color = .white
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

        // 左下角诊断：三击切换显示
        debugLabel.textColor = UIColor(red: 0.3, green: 1, blue: 0.5, alpha: 1)
        debugLabel.backgroundColor = UIColor(white: 0, alpha: 0.72)
        debugLabel.font = UIFont(name: "Menlo", size: 9) ?? .systemFont(ofSize: 9)
        debugLabel.numberOfLines = 8
        debugLabel.isHidden = true
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugLabel)

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

            debugLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            debugLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            debugLabel.widthAnchor.constraint(equalToConstant: 280),
        ])

        // 诊断按钮：放在最上层，不跟 collectionView 抢手势
        let dbgBtn = UIButton(type: .custom)
        dbgBtn.setTitle("诊断", for: .normal)
        dbgBtn.setTitleColor(.white, for: .normal)
        dbgBtn.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        dbgBtn.backgroundColor = UIColor(red: 0, green: 0.5, blue: 0.2, alpha: 0.85)
        dbgBtn.layer.cornerRadius = 11
        dbgBtn.translatesAutoresizingMaskIntoConstraints = false
        dbgBtn.addTarget(self, action: #selector(toggleDebug), for: .touchUpInside)
        view.addSubview(dbgBtn)

        // 单击暂停/播放挂在 collectionView 上（这是短视频的标准交互）
        let tap1 = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        collectionView.addGestureRecognizer(tap1)

        NSLayoutConstraint.activate([
            dbgBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            dbgBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            dbgBtn.widthAnchor.constraint(equalToConstant: 56),
            dbgBtn.heightAnchor.constraint(equalToConstant: 22),
        ])

        // 先默认显示，方便你第一眼就能看到状态
        debugLabel.isHidden = false

        // 诊断刷新
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, !self.debugLabel.isHidden else { return }
            self.debugLabel.text = self.pool.debugInfo()
        }
    }

    @objc private func handleTap() {
        pool.toggle()
        if pool.current.player.rate > 0 {
            visibleCell()?.setPlaying(true)
        } else {
            visibleCell()?.setPlaying(false)
        }
    }

    @objc private func toggleDebug() {
        debugLabel.isHidden = !debugLabel.isHidden
    }

    private func setStatus(_ text: String, showSpinner: Bool = false, showButton: Bool = false) {
        statusLabel.text = text
        statusLabel.isHidden = text.isEmpty
        setupButton.isHidden = !showButton
        spinner.isHidden = !showSpinner
        if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    // MARK: - 池子事件

    private func wirePool() {
        pool.onReady = { [weak self] id in
            guard let self, let cell = self.cellForVideo(id) else { return }
            cell.setNativeVisible(true)
            cell.clearError()
        }
        pool.onPlaying = { [weak self] id in
            self?.cellForVideo(id)?.setPlaying(true)
        }
        pool.onPaused = { [weak self] id in
            self?.cellForVideo(id)?.setPlaying(false)
        }
        pool.onError = { [weak self] id, msg in
            guard let self, let cell = self.cellForVideo(id) else { return }
            cell.showError("播放失败\n" + msg)
        }
    }

    /// 找到某条视频对应的可见 cell
    private func cellForVideo(_ id: Int) -> FeedCardCell? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? FeedCardCell
    }

    private func visibleCell() -> FeedCardCell? {
        for case let c as FeedCardCell in collectionView.visibleCells {
            if c.window != nil { return c }
        }
        return nil
    }

    // MARK: - 设置地址

    private func showSetup() {
        setStatus("需要先设置服务器地址\n例如 http://192.168.1.10:6688\n或 https://locvid-pc.tail83739b.ts.net:8445",
                  showSpinner: false, showButton: true)
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
                self.items.append(contentsOf: page)
                self.setStatus("")
                self.collectionView.reloadData()
                FeedService.shared.prefetchFirstFrames(Array(page.prefix(6)))
                // 数据到了，等一帧让 cell 上屏，再对池子
                DispatchQueue.main.async {
                    self.syncPool(to: max(0, self.currentIndex), scrubbing: false)
                }
            case .failure(let err):
                self.setStatus("加载失败\n\(err.localizedDescription)", showSpinner: false, showButton: true)
            }
        }
    }

    // MARK: - 播放器同步

    private func syncPool(to index: Int, scrubbing: Bool) {
        guard index >= 0, index < items.count else { return }
        let base = FeedService.shared.base

        // 尺寸没准备好之前不要动播放器（否则会拿到 0 尺寸的 layer）
        guard collectionView.bounds.height > 1 else { return }

        let cur = items[index]
        guard let curURL = cur.streamURL(base) else { return }

        var nextPair: (Int, URL)?
        if index + 1 < items.count, let u = items[index + 1].streamURL(base) {
            nextPair = (items[index + 1].id, u)
        }

        if pool.current.videoID == cur.id {
            // 同一条：只同步邻条
            pool.set(current: cur.id, url: curURL, next: nextPair)
        } else {
            pool.set(current: cur.id, url: curURL, next: nextPair)
        }
        pool.setScrubbing(scrubbing)

        attachLayers()
        pool.setMuted(false)

        currentIndex = index
        if index + 3 >= items.count { loadMore() }
    }

    /// 把池里的两个 layer 挂到对应 cell 上
    private func attachLayers() {
        for case let cell as FeedCardCell in collectionView.visibleCells {
            guard let ip = collectionView.indexPath(for: cell), ip.item < items.count else { continue }
            let vid = items[ip.item].id

            var target: AVPlayerLayer?
            if pool.current.videoID == vid { target = pool.current.layer }
            else if pool.standby.videoID == vid { target = pool.standby.layer }

            guard let layer = target else { continue }

            // 从原父层摘掉，避免一个 layer 同时挂在两个 cell 上
            if let old = layer.superlayer, old !== cell.videoHost.layer {
                layer.removeFromSuperlayer()
            }
            if layer.superlayer !== cell.videoHost.layer {
                cell.videoHost.layer.addSublayer(layer)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = cell.videoHost.bounds
            cell.videoHost.layoutIfNeeded()
            layer.frame = cell.videoHost.bounds
            CATransaction.commit()

            cell.setNativeVisible(layer.opacity > 0.5 && layer.isReadyForDisplay)
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
        guard idx >= 0, idx < items.count else { return }

        let fast = abs(scrollView.panGestureRecognizer.velocity(in: scrollView).y) > 800
        if fast, !pool.isScrubbing {
            pool.setScrubbing(true)
        }

        if idx != currentIndex {
            syncPool(to: idx, scrubbing: fast)
        } else {
            attachLayers()
        }

        if idx + 3 >= items.count { loadMore() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    private func settle() {
        let h = max(collectionView.bounds.height, 1)
        let idx = Int((collectionView.bounds.width > 0 ? collectionView.contentOffset.y / h : 0).rounded())
        guard idx >= 0, idx < items.count else { return }
        if idx != currentIndex { syncPool(to: idx, scrubbing: false) }
        pool.setScrubbing(false)
        pool.play()
        attachLayers()
    }
}
