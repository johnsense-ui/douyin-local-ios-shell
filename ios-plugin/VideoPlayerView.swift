import AVFoundation
import UIKit

/// 竖屏播放视图。
///
/// 移植自 dks333/Tiktok-Clone 的 VideoPlayerView（★430，MIT），
/// 保留它的核心设计，去掉对 Firebase 的依赖：
///
///   · AVQueuePlayer + AVPlayerLooper —— 循环播放，切条不重建
///   · AVAssetResourceLoaderDelegate —— 边下边播，同时把数据写进磁盘缓存
///   · 缓存命中则直接读本地文件，完全不碰网络（这是"秒开"的关键）
///
/// 和原版的区别：
///   1. 不用 SnapKit / RxSwift / Lottie / MarqueeLabel 这些第三方库
///   2. 缓存换成我们自己的 VideoCache（CryptoKit 哈希，不依赖 Firebase）
///   3. 加了错误回调和状态回调，方便在手机上诊断
final class VideoPlayerView: UIView {

    // MARK: - 对外

    /// 状态变化（ready / failed / buffering）
    var onStatus: ((String) -> Void)?
    /// 出错
    var onError: ((String) -> Void)?

    // MARK: - 播放器

    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerItem: AVPlayerItem?
    private var asset: AVURLAsset?
    private var playerLayer: AVPlayerLayer?
    private var statusObs: NSKeyValueObservation?

    /// 原始地址（真实服务器）
    private(set) var remoteURL: URL?

    // MARK: - 资源加载（边下边播）

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseInfo: URLResponse?
    private var pendingRequests = [AVAssetResourceLoadingRequest]()
    private var buffer = Data()
    private var downloadDone = false

    /// 自定义 scheme，用来触发 AVAssetResourceLoaderDelegate
    private static let scheme = "dzcstream"

    // MARK: - init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        teardown()
    }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false

        // 【命名注意】不能叫 layer —— UIView 已经有 `layer: CALayer`，
        // 会报 "property 'layer' cannot override a property with type 'CALayer'"。
        let pl = AVPlayerLayer()
        pl.videoGravity = .resize
        pl.backgroundColor = UIColor.clear.cgColor
        self.layer.addSublayer(pl)
        self.playerLayer = pl

        let opQueue = OperationQueue()
        opQueue.name = "dzc.videoloader"
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: opQueue)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 配置

    /// - Parameter aspect: 视频宽高比；竖屏视频用 resizeAspectFill 铺满
    func configure(url: URL, aspect: CGFloat) {
        teardown()

        remoteURL = url
        // 竖屏内容铺满，横屏内容留黑边 —— 和抖音一致
        playerLayer?.videoGravity = aspect < 1.0 ? .resizeAspectFill : .resizeAspect

        // ① 缓存命中 → 直接读本地文件，零网络
        if let path = VideoCache.shared.cachedPath(for: url) {
            onStatus?("cache-hit")
            play(localPath: path)
            return
        }

        // ② 没缓存 → 走自定义 scheme，边下边播 + 落盘
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            onError?("地址不合法")
            return
        }
        comps.scheme = Self.scheme
        guard let redirect = comps.url else {
            onError?("地址转换失败")
            return
        }

        onStatus?("streaming")
        let a = AVURLAsset(url: redirect)
        a.resourceLoader.setDelegate(self, queue: .main)
        asset = a

        let item = AVPlayerItem(asset: a)
        playerItem = item
        observe(item)

        if let qp = queuePlayer {
            qp.replaceCurrentItem(with: item)
        } else {
            let qp = AVQueuePlayer(playerItem: item)
            queuePlayer = qp
            playerLayer?.player = qp
        }
        playerLooper = AVPlayerLooper(player: qp(), templateItem: item)
    }

    private func qp() -> AVQueuePlayer {
        if let q = queuePlayer { return q }
        let q = AVQueuePlayer()
        queuePlayer = q
        playerLayer?.player = q
        return q
    }

    private func play(localPath: String) {
        let a = AVURLAsset(url: URL(fileURLWithPath: localPath))
        asset = a
        let item = AVPlayerItem(asset: a)
        playerItem = item
        observe(item)

        if let qp = queuePlayer {
            qp.replaceCurrentItem(with: item)
        } else {
            let qp = AVQueuePlayer(playerItem: item)
            queuePlayer = qp
            playerLayer?.player = qp
        }
        playerLooper = AVPlayerLooper(player: qp(), templateItem: item)
    }

    private func observe(_ item: AVPlayerItem) {
        statusObs?.invalidate()
        statusObs = item.observe(\.status, options: [.new]) { [weak self] i, _ in
            guard let self else { return }
            switch i.status {
            case .readyToPlay:
                self.onStatus?("ready")
            case .failed:
                let e = i.error as NSError?
                self.onStatus?("failed")
                self.onError?("status failed: \(e?.domain ?? "?")#\(e?.code ?? 0) \(e?.localizedDescription ?? "")")
            default:
                break
            }
        }
    }

    // MARK: - 控制

    func play() { queuePlayer?.play() }
    func pause() { queuePlayer?.pause() }
    func replay() {
        queuePlayer?.seek(to: .zero)
        queuePlayer?.play()
    }
    var isPlaying: Bool { (queuePlayer?.rate ?? 0) > 0 }

    func setMuted(_ m: Bool) {
        queuePlayer?.isMuted = m
    }

    /// 彻底清理（cell 复用时调用）
    func teardown() {
        statusObs?.invalidate()
        statusObs = nil
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer?.replaceCurrentItem(with: nil)
        playerItem = nil
        asset?.cancelLoading()
        asset = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        let opQueue = OperationQueue()
        opQueue.name = "dzc.videoloader"
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: opQueue)
        syncQueue {
            self.pendingRequests.forEach { $0.finishLoading() }
            self.pendingRequests.removeAll()
            self.buffer.removeAll()
            self.downloadDone = false
            self.responseInfo = nil
        }
        remoteURL = nil
        playerLayer?.player = nil
    }

    /// 诊断用
    func debugText() -> String {
        let total = playerItem.map { CMTimeGetSeconds($0.duration) } ?? 0
        let loaded = playerItem?.loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.start + $0.timeRangeValue.duration) }
            .max() ?? 0
        return "rate=\(String(format: "%.1f", queuePlayer?.rate ?? 0))"
            + " buf=\(String(format: "%.1f", max(0, loaded)))s/\(String(format: "%.1f", total.isFinite ? total : 0))s"
            + " cache=\(String(format: "%.1f", Double(buffer.count) / 1024 / 1024))MB"
    }

    // MARK: - 线程安全的小工具

    private let lock = NSLock()
    private func syncQueue(_ block: () -> Void) {
        lock.lock(); block(); lock.unlock()
    }
}

// MARK: - 边下边播

extension VideoPlayerView: AVAssetResourceLoaderDelegate {

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        pendingRequests.append(loadingRequest)
        let needStart = (task == nil)
        lock.unlock()

        if needStart, let url = remoteURL {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 30
            let t = session?.dataTask(with: req)
            lock.lock(); task = t; lock.unlock()
            t?.resume()
        }
        fillPending()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        pendingRequests.removeAll { $0 == loadingRequest }
        lock.unlock()
    }

    /// 把已下载的数据喂给 AVFoundation
    private func fillPending() {
        lock.lock()
        let requests = pendingRequests
        let data = buffer
        let info = responseInfo
        lock.unlock()

        var finished = [AVAssetResourceLoadingRequest]()
        for req in requests {
            if let ci = req.contentInformationRequest, let info {
                ci.isByteRangeAccessSupported = true
                ci.contentType = info.mimeType
                ci.contentLength = info.expectedContentLength
            }
            guard let dr = req.dataRequest else { continue }
            let cur = dr.currentOffset
            if Int64(data.count) < cur { continue }
            let want = Int64(dr.requestedOffset) + Int64(dr.requestedLength) - cur
            let have = Int64(data.count) - cur
            let n = min(want, have)
            if n > 0 {
                let start = Int(cur)
                let end = start + Int(n)
                if end <= data.count {
                    dr.respond(with: data.subdata(in: start..<end))
                }
            }
            if cur >= Int64(dr.requestedOffset) + Int64(dr.requestedLength) {
                finished.append(req)
            }
        }
        if !finished.isEmpty {
            lock.lock()
            pendingRequests.removeAll { finished.contains($0) }
            lock.unlock()
            finished.forEach { $0.finishLoading() }
        }
    }
}

extension VideoPlayerView: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        responseInfo = response
        lock.unlock()
        fillPending()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
        fillPending()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onError?("下载中断: \(error.localizedDescription)")
            return
        }
        lock.lock()
        let data = buffer
        let done = downloadDone
        downloadDone = true
        lock.unlock()
        guard !done, !data.isEmpty, let url = remoteURL else { return }
        // 完整下载 → 落盘，下次秒开
        VideoCache.shared.store(data, for: url)
        onStatus?("cached")
    }
}
