import Foundation
import AVFoundation
import UIKit

/// 原生竖屏播放舞台。
///
/// 为什么不用 WKWebView 里的 <video>（这些是在 iPhone 上逐条实测踩到的）：
///   1. iOS 上 Safari/Edge/Chrome 全是 WebKit，<video> 是独立合成层，
///      会盖住页面上的 <img>，z-index / opacity 都管不了它 → 首帧图永远顶不住黑屏；
///   2. play() 会立刻丢掉 poster，于是"刚起播那一瞬"必然是黑的；
///   3. 没播过的 <video> 的 preload 被忽略 → 下一条根本没预加载，滑过去才开始下载；
///   4. 上面三点在网页层无解，所以在原生侧用 AVPlayer 接管画面。
///
/// 设计要点：
///   · 两个 AVPlayer + 两个 AVPlayerLayer：A 在播，B 已经预加载好并停在 0s。
///   · 切条时**交换两个 player 的角色**（只换模型引用，不重建、不 replaceItem），
///     所以没有黑屏、没有重新缓冲。
///   · currentLayer 首帧就绪前 opacity = 0，就绪后瞬间接上 → 没有黑闪。
///   · 视图插在 WKWebView 下方，网页背景透明 → 底层原生画面 + 上层网页 UI。
@objc public class NativeStage: UIView {

    // MARK: - 对外回调（由 Bridge 注入）
    @objc public var onStateChange: (([String: Any]) -> Void)?
    @objc public var onProgress: (([String: Any]) -> Void)?
    @objc public var onEnded: (() -> Void)?
    @objc public var onError: ((String) -> Void)?

    // MARK: - 播放器（两个槽位，切条时交换角色）
    private var playerA = AVPlayer()
    private var playerB = AVPlayer()
    private let layerA = AVPlayerLayer()
    private let layerB = AVPlayerLayer()

    /// 哪个槽位当前是"台上"的（在播 / 待播的那条）
    private var stagedIsA = true

    private var currentPlayer: AVPlayer { stagedIsA ? playerA : playerB }
    private var nextPlayer: AVPlayer { stagedIsA ? playerB : playerA }
    private var currentLayer: AVPlayerLayer { stagedIsA ? layerA : layerB }
    private var nextLayer: AVPlayerLayer { stagedIsA ? layerB : layerA }

    /// 当前层 / 下一层各自对应的 video id
    private var currentID: String?
    private var nextID: String?

    /// 前后缓冲（秒）。本地库给 3s 足够；太小会刚起播就卡。
    private let forwardBufferSeconds: Double = 3.0

    private var progressTimer: Timer?
    private var statusObs: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    /// 当前条是否已经"真的有画面了"（用于去黑闪）
    private var currentHasFrame = false

    /// 用户"想播"的意图。readyToPlay 之后据此自动起播 —— 这是治"要点两下"的关键。
    private var wantsPlay = true

    // MARK: - 初始化

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        // resizeAspectFill = 竖屏短视频的标准填充（黑边最少）
        layerA.videoGravity = .resizeAspectFill
        layerB.videoGravity = .resizeAspectFill
        layerA.frame = bounds
        layerB.frame = bounds
        layerA.opacity = 0
        layerB.opacity = 0
        layer.addSublayer(layerA)
        layer.addSublayer(layerB)
        // 这一层不吃触摸：手势全部交给上面的 WKWebView
        isUserInteractionEnabled = false

        [playerA, playerB].forEach {
            $0.actionAtItemEnd = .pause
            $0.automaticallyWaitsToMinimizeStalling = true
            $0.isMuted = true
        }
        layerA.player = playerA
        layerB.player = playerB

        observeCurrent()
    }

    deinit {
        teardown()
    }

    private func teardown() {
        progressTimer?.invalidate()
        progressTimer = nil
        statusObs?.invalidate()
        statusObs = nil
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        playerA.pause()
        playerB.pause()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerA.frame = bounds
        layerB.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 观察当前条状态

    private func observeCurrent() {
        statusObs?.invalidate()
        statusObs = nil

        let player = currentPlayer
        statusObs = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] p, _ in
            guard let self, p === self.currentPlayer else { return }
            let status = p.currentItem?.status ?? .unknown
            switch status {
            case .readyToPlay:
                self.markCurrentReady()
                // 想播就自动播 —— 用户不该为了"开始"点第二下
                if self.wantsPlay && p.rate == 0 {
                    p.play()
                    self.emitState(["phase": "playing", "id": self.currentID ?? ""])
                    self.startProgressTimer()
                }
            case .failed:
                self.onError?(p.currentItem?.error?.localizedDescription ?? "播放失败")
                self.emitState(["phase": "error"])
            default:
                break
            }
        }

        if endObserver == nil {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                guard let item = note.object as? AVPlayerItem,
                      item === self.currentPlayer.currentItem else { return }
                self.onEnded?()
            }
        }
    }

    private func markCurrentReady() {
        guard !currentHasFrame else { return }
        currentHasFrame = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer.opacity = 1
        nextLayer.opacity = 0
        CATransaction.commit()
        emitState(["phase": "ready", "id": currentID ?? ""])
    }

    // MARK: - 核心 API（供 Bridge 调用）

    /// 一次性把队列交给原生：当前条 + 下一条 URL。
    @objc public func load(current id: String, url: String, next nextID: String?, nextURL: String?) {
        guard let u = URL(string: url) else {
            onError?("非法 URL: \(url)")
            return
        }
        // 同一条不重复加载（避免每次 progress 都重建播放器）
        if currentID == id, currentPlayer.currentItem != nil {
            if let nextID, let nextURL, let nu = URL(string: nextURL), self.nextID != nextID {
                prepareNext(id: nextID, url: nu)
            }
            return
        }

        currentID = id
        currentHasFrame = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer.opacity = 0
        CATransaction.commit()

        currentPlayer.replaceCurrentItem(with: makeItem(url: u))
        observeCurrent()
        if let nextID, let nextURL, let nu = URL(string: nextURL) {
            prepareNext(id: nextID, url: nu)
        } else {
            clearNext()
        }

        emitState(["phase": "loading", "id": id])
    }

    /// replace 包装：同步把位置归零，避免沿用上一条的播放点
    private func setItem(_ player: AVPlayer, _ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
    }

    private func prepareNext(id: String, url: URL) {
        guard nextID != id else { return }
        nextID = id
        setItem(nextPlayer, makeItem(url: url))
        // 预加载：等它到 readyToPlay，但**不播**，并停在第一帧（0s）
        nextPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func clearNext() {
        nextID = nil
        nextPlayer.replaceCurrentItem(with: nil)
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = forwardBufferSeconds
        return item
    }

    /// 切到下一条。
    ///
    /// 不做 replaceCurrentItem（那会丢掉缓冲、重新 seek、重新起播 → 黑屏 + 卡）。
    /// 而是**交换两个槽位的角色**：预加载好的那个 player 直接变成"台上"，
    /// 只翻两个 layer 的不透明度。整个过程没有解绑，是 0 帧黑屏。
    @objc public func advanceToNext() -> Bool {
        guard nextID != nil, nextPlayer.currentItem != nil else { return false }

        let oldPlayer = currentPlayer
        let oldNextID = nextID
        let oldCurrentID = currentID

        oldPlayer.pause()

        // 交换角色
        stagedIsA.toggle()

        currentID = oldNextID
        nextID = nil
        currentHasFrame = false

        // 立刻把画面翻到新的一条（它已经在 0s 且 ready，可以直接显示首帧）
        if currentPlayer.currentItem?.status == .readyToPlay {
            markCurrentReady()
        }
        observeCurrent()

        // 旧的当前条清空，腾出槽位给"下下条"
        oldPlayer.replaceCurrentItem(with: nil)

        emitState(["phase": "loading", "id": currentID ?? "", "from": oldCurrentID ?? ""])
        return true
    }

    /// 交给我们"下一个要预加载谁"
    @objc public func preloadNext(id: String?, url: String?) {
        guard let id, let url, let u = URL(string: url) else {
            clearNext()
            return
        }
        prepareNext(id: id, url: u)
    }

    @objc public func play() {
        wantsPlay = true
        if currentPlayer.currentItem?.status == .readyToPlay {
            currentPlayer.play()
            emitState(["phase": "playing", "id": currentID ?? ""])
            startProgressTimer()
        } else {
            // 还没就绪：记下意图，ready 回调里自动起播
            emitState(["phase": "waiting", "id": currentID ?? ""])
        }
    }

    @objc public func pause() {
        wantsPlay = false
        currentPlayer.pause()
        emitState(["phase": "paused", "id": currentID ?? ""])
        stopProgressTimer()
    }

    /// 只暂停，不改"想播"意图 —— 用于滑动过程中的临时停，
    /// 落位后能自己接上，不需要用户再点两下。
    @objc public func hold() {
        currentPlayer.pause()
        stopProgressTimer()
        emitState(["phase": "holding", "id": currentID ?? ""])
    }

    @objc public func setMuted(_ muted: Bool) {
        currentPlayer.isMuted = muted
        nextPlayer.isMuted = true
        emitState(["phase": "muted", "muted": muted])
    }

    @objc public func seek(seconds: Double) {
        guard seconds > 0.05 else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        currentPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.emitState(["phase": "seeked"])
        }
    }

    @objc public func setRate(_ rate: Float) {
        if currentPlayer.currentItem?.status == .readyToPlay {
            currentPlayer.rate = rate
        }
    }

    /// 当前是不是"台上那条在跑"
    @objc public var isPlaying: Bool {
        return currentPlayer.rate > 0 && currentPlayer.error == nil
    }

    @objc public var playingID: String? { currentID }

    // MARK: - 进度上报

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let item = self.currentPlayer.currentItem else { return }
            let pos = CMTimeGetSeconds(self.currentPlayer.currentTime())
            guard pos.isFinite else { return }
            let dur = CMTimeGetSeconds(item.duration)
            let loaded = item.loadedTimeRanges
                .map { CMTimeGetSeconds($0.timeRangeValue.start + $0.timeRangeValue.duration) }
                .max() ?? 0
            self.onProgress?([
                "id": self.currentID ?? "",
                "position": pos,
                "duration": dur.isFinite ? dur : 0,
                "buffered": loaded.isFinite ? loaded : 0,
                "playing": self.currentPlayer.rate > 0
            ])
        }
        if let t = progressTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func emitState(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(payload)
        }
    }
}
