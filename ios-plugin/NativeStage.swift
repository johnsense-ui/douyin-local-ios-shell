import Foundation
import AVFoundation
import UIKit

/// 原生竖屏播放舞台（第三版，彻底重写）。
///
/// ═══════════════════════════════════════════════════════════════════
/// 为什么网页层的 <video> 在 iPhone 上永远修不好
/// ───────────────────────────────────────────────────────────────────
///   1. WebKit 里 <video> 是独立合成层，永远画在 DOM 之上 ——
///      poster、<img>、z-index、opacity、transform 全都盖不住它；
///   2. play() 会立刻丢掉 poster，起播那一瞬必然黑；
///   3. 没播过的元素，preload 被直接忽略，load() 也不保证真下载；
///   4. 上面三条在 JS 层无解，所以画面必须交给 native。
///
/// ═══════════════════════════════════════════════════════════════════
/// 这一版的设计（吸取前两版所有失败教训）
/// ───────────────────────────────────────────────────────────────────
///   · **三槽位环形**：prev / current / next 各一个 AVPlayer + layer。
///     前两版只有两个槽位，滑动时"下下条"没地方预加载，一旦快速连滑就必然黑屏。
///   · **交换 player 引用而不是 replaceCurrentItem**：
///     replaceCurrentItem 会丢掉已缓冲的数据、重新 seek、重新起播 → 黑屏 + 卡。
///     交换引用 = 0 帧黑屏，因为 layer 上挂的东西根本没变。
///   · **首帧就绪才上台**：currentLayer.opacity 从 0 到 1 由
///     `isReadyForDisplay` 的 KVO 驱动，不是 status==ready 就切。
///     status==ready 只代表"能播"，画面还没解出来。
///   · **wantsPlay 意图机**：用户想播但数据没到 → 记住意图，
///     数据一到自动播。彻底治"要点两下""停住不动"。
///   · **错误自愈**：播放失败自动重载一次，连续失败才报错给 JS。
///
///   画面层级：本视图插在 WKWebView **下方**（plugin 里做），
///   网页整体透明 → 底层原生画面 + 上层网页 UI，两边都不牺牲。
/// ═══════════════════════════════════════════════════════════════════
@objc public class NativeStage: UIView {

    // MARK: - 对外回调
    @objc public var onStateChange: (([String: Any]) -> Void)?
    @objc public var onProgress: (([String: Any]) -> Void)?
    @objc public var onEnded: (() -> Void)?
    @objc public var onError: ((String) -> Void)?

    // MARK: - 三个槽位
    //
    // 【必须是 class】struct 是值类型，`slots[i].layer.opacity = x` 会作用在副本上，
    // 改动丢失 → 画面永远不出来。这个坑在前两版里没踩是因为当时用的是私有属性。
    private final class Slot {
        let player = AVPlayer()
        let layer = AVPlayerLayer()
        var videoID: String?
        var url: String?
        var statusObs: NSKeyValueObservation?
        var readyObs: NSKeyValueObservation?

        init() {
            layer.videoGravity = .resizeAspectFill
            layer.opacity = 0
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = true
            player.isMuted = true
            layer.player = player
        }
    }

    private var slots: [Slot] = [Slot(), Slot(), Slot()]
    /// 哪个槽位在台上（0/1/2 保持轮转）
    private var currentIndex = 0
    /// 下一条预留给哪个槽
    private var nextIndex = 1
    /// 上一条留在哪个槽
    private var prevIndex = 2

    // 【命名注意】不能叫 next / prev —— UIResponder 已经有 `next: UIResponder?`，
    // 会报 "property 'next' cannot override a property with type 'UIResponder?'"。
    private var curSlot: Slot { slots[currentIndex] }
    private var nextSlot: Slot { slots[nextIndex] }
    private var prevSlot: Slot { slots[prevIndex] }

    /// 前后缓冲（秒）。本地库给 5s：起播前缓冲足够，滑过去不会立刻 waiting。
    private let forwardBufferSeconds: Double = 5.0

    private var progressTimer: Timer?
    private var endObserver: NSObjectProtocol?

    /// 用户"想播"的意图。ready 之后据此自动起播 —— 治"要点两下"。
    private var wantsPlay = true
    /// 当前条连续失败次数（自愈用）
    private var currentLoadFailures = 0

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
        // 这一层不吃触摸：手势全部交给上面的 WKWebView
        isUserInteractionEnabled = false

        for i in slots.indices {
            let s = slots[i]
            s.layer.frame = bounds
            layer.addSublayer(s.layer)
            observe(slotAt: i)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let item = note.object as? AVPlayerItem,
                  item === self.curSlot.player.currentItem else { return }
            self.onEnded?()
        }
    }

    deinit {
        progressTimer?.invalidate()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        for s in slots {
            s.statusObs?.invalidate()
            s.readyObs?.invalidate()
            s.player.pause()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in slots { s.layer.frame = bounds }
        CATransaction.commit()
    }

    // MARK: - 槽位观察

    private func observe(slotAt i: Int) {
        let s = slots[i]
        s.statusObs?.invalidate()
        s.readyObs?.invalidate()

        // 【注意】槽位是环形轮转的，i 会换角色。
        // 所以闭包里不能只信 i，必须用「这个槽位现在的 videoID 是不是台上的那条」来判断，
        // 否则轮转瞬间旧观察者会误判，把不该显示的画面推上去。
        //
        // 捕获 list 用 [weak s]：Slot 持有 obs，obs 又捕获 Slot 会形成 cycle。
        s.statusObs = s.player.observe(\.currentItem?.status, options: [.new]) { [weak self, weak s] p, _ in
            guard let self, let s else { return }
            guard self.isOnStage(i, id: s.videoID) else { return }
            switch p.currentItem?.status {
            case .readyToPlay:
                self.currentLoadFailures = 0
                // 想播就播。此时 layer 可能还没画面，readyObs 负责切不透明度。
                self.tryAutoStart()
            case .failed:
                self.currentLoadFailures += 1
                let msg = p.currentItem?.error?.localizedDescription ?? "播放失败"
                if self.currentLoadFailures <= 2, let u = s.url, let url = URL(string: u) {
                    self.emitState(["phase": "retry", "id": s.videoID ?? "", "attempt": self.currentLoadFailures])
                    s.player.replaceCurrentItem(with: self.makeItem(url: url))
                    self.observe(slotAt: self.currentIndex)
                } else {
                    self.onError?(msg)
                    self.emitState(["phase": "error", "id": s.videoID ?? "", "message": msg])
                }
            default:
                break
            }
        }

        // 真正"有画面了"的信号：AVPlayerLayer.isReadyForDisplay
        // status==readyToPlay 只说明能播，画面未必解出来了。
        s.readyObs = s.layer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self, weak s] l, _ in
            guard let self, let s else { return }
            guard l.isReadyForDisplay else { return }
            guard self.isOnStage(i, id: s.videoID) else { return }
            self.revealCurrent()
        }
    }

    /// 这个槽位此刻是不是「台上的当前条」
    private func isOnStage(_ index: Int, id: String?) -> Bool {
        guard index == currentIndex else { return false }
        guard let id else { return false }
        return slots[currentIndex].videoID == id
    }

    private func revealCurrent() {
        guard slots[currentIndex].layer.opacity != 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, s) in slots.enumerated() {
            s.layer.opacity = (i == currentIndex) ? 1 : 0
        }
        CATransaction.commit()
        emitState(["phase": "ready", "id": curSlot.videoID ?? ""])
    }

    private func tryAutoStart() {
        guard wantsPlay else { return }
        guard curSlot.player.currentItem?.status == .readyToPlay else { return }
        if curSlot.player.rate == 0 {
            curSlot.player.play()
            emitState(["phase": "playing", "id": curSlot.videoID ?? ""])
            startProgressTimer()
        }
    }

    // MARK: - 构造 item

    private func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)
        // 关键：本地库单条几十 MB，缓冲给足，别让起播就 waiting
        item.preferredForwardBufferDuration = forwardBufferSeconds
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    private func setItem(_ slot: Slot, url: URL, id: String) {
        slot.videoID = id
        slot.url = url.absoluteString
        slot.layer.opacity = 0
        slot.player.replaceCurrentItem(with: makeItem(url: url))
        // 预加载的槽也要停在 0s 并解出首帧，这样提上来立刻有画面
        slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 核心 API

    /// 一次性把队列交给原生：当前条 + 下一条（+ 上一条用于回滑）。
    @objc public func load(current id: String, url: String, next nextID: String?, nextURL: String?, prev prevID: String?, prevURL: String?) {
        guard let u = URL(string: url) else {
            onError?("非法 URL: \(url)")
            return
        }

        // 同一条不重建（避免每次同步都重载）
        if curSlot.videoID == id, curSlot.player.currentItem != nil {
            if let nextID, let nextURL, let nu = URL(string: nextURL), nextSlot.videoID != nextID {
                setItem(nextSlot, url: nu, id: nextID)
            }
            if let prevID, let prevURL, let pu = URL(string: prevURL), prevSlot.videoID != prevID {
                setItem(prevSlot, url: pu, id: prevID)
            }
            return
        }

        currentLoadFailures = 0
        setItem(current, url: u, id: id)
        observe(slotAt: currentIndex)

        if let nextID, let nextURL, let nu = URL(string: nextURL) {
            setItem(nextSlot, url: nu, id: nextID)
        } else if nextSlot.videoID != nil {
            clear(nextSlot)
        }

        if let prevID, let prevURL, let pu = URL(string: prevURL) {
            setItem(prevSlot, url: pu, id: prevID)
        } else if prevSlot.videoID != nil {
            clear(prevSlot)
        }

        emitState(["phase": "loading", "id": id])
        tryAutoStart()
    }

    private func clear(_ slot: Slot) {
        slot.videoID = nil
        slot.url = nil
        slot.layer.opacity = 0
        slot.player.replaceCurrentItem(with: nil)
    }

    /// 往下滑一条：preloaded 的 next 直接上台，**不重建、不 rebuffer**。
    ///
    /// 做法是轮转三个槽位的角色，而不是搬运 item：
    ///   旧 prev → 还给池子（清空）
    ///   旧 current → 成为新 prev
    ///   旧 next → 成为新 current（它已经 ready 且画面解好了）
    ///   池子 → 成为新 next（等 JS 告诉它下一条是谁）
    @objc public func advanceDown() -> Bool {
        guard nextSlot.videoID != nil else { return false }

        curSlot.player.pause()

        // 轮转
        let oldPrev = prevIndex
        prevIndex = currentIndex
        currentIndex = nextIndex
        nextIndex = oldPrev

        clear(slots[nextIndex])   // 腾出槽位给"下下条"
        currentLoadFailures = 0

        // 新 current 如果画面已就绪，立刻上台（0 帧黑屏）；
        // 否则等 readyObs 回调。
        observe(slotAt: currentIndex)
        if slots[currentIndex].layer.isReadyForDisplay {
            revealCurrent()
        }
        tryAutoStart()

        emitState(["phase": "advanced", "id": curSlot.videoID ?? "", "dir": "down"])
        return true
    }

    /// 往上滑一条：preloaded 的 prev 上台（复用同一套轮转）。
    @objc public func advanceUp() -> Bool {
        guard prevSlot.videoID != nil else { return false }

        curSlot.player.pause()

        let oldNext = nextIndex
        nextIndex = currentIndex
        currentIndex = prevIndex
        prevIndex = oldNext

        clear(slots[prevIndex])
        currentLoadFailures = 0

        observe(slotAt: currentIndex)
        if slots[currentIndex].layer.isReadyForDisplay {
            revealCurrent()
        }
        tryAutoStart()

        emitState(["phase": "advanced", "id": curSlot.videoID ?? "", "dir": "up"])
        return true
    }

    /// 滑动过程中临时停一下，但**不改变 wantsPlay 意图** ——
    /// 落位后自己会接上，不需要用户再点。
    @objc public func hold() {
        curSlot.player.pause()
        stopProgressTimer()
        emitState(["phase": "holding", "id": curSlot.videoID ?? ""])
    }

    @objc public func play() {
        wantsPlay = true
        if curSlot.player.currentItem?.status == .readyToPlay {
            curSlot.player.play()
            emitState(["phase": "playing", "id": curSlot.videoID ?? ""])
            startProgressTimer()
        } else {
            // 数据没到：记住意图，ready 后自动播（这就是"不用点第二下"的关键）
            emitState(["phase": "wantplay", "id": curSlot.videoID ?? ""])
        }
    }

    @objc public func pause() {
        wantsPlay = false
        curSlot.player.pause()
        emitState(["phase": "paused", "id": curSlot.videoID ?? ""])
        stopProgressTimer()
    }

    @objc public func setMuted(_ muted: Bool) {
        curSlot.player.isMuted = muted
        nextSlot.player.isMuted = true
        prevSlot.player.isMuted = true
        emitState(["phase": "muted", "muted": muted])
    }

    @objc public func seek(seconds: Double) {
        guard seconds > 0.05 else { return }
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        curSlot.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.emitState(["phase": "seeked"])
        }
    }

    @objc public func replay() {
        curSlot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.play()
        }
    }

    @objc public var currentVideoID: String? { curSlot.videoID }
    @objc public var isPlaying: Bool { curSlot.player.rate > 0 && curSlot.player.error == nil }

    /// 诊断用：三个槽位分别是什么
    @objc public func debugSnapshot() -> [String: Any] {
        var out: [String: Any] = [
            "currentIndex": currentIndex,
            "nextIndex": nextIndex,
            "prevIndex": prevIndex,
            "wantsPlay": wantsPlay,
            "rate": Double(curSlot.player.rate)
        ]
        for (i, s) in slots.enumerated() {
            out["slot\(i)"] = [
                "id": s.videoID ?? "-",
                "opacity": Double(s.layer.opacity),
                "readyForDisplay": s.layer.isReadyForDisplay,
                "status": statusString(s.player.currentItem?.status),
                "buffered": bufferedSeconds(s.player)
            ] as [String: Any]
        }
        return out
    }

    private func statusString(_ s: AVPlayerItem.Status?) -> String {
        switch s {
        case .readyToPlay: return "ready"
        case .failed: return "failed"
        case .unknown: return "unknown"
        default: return "none"
        }
    }

    private func bufferedSeconds(_ p: AVPlayer) -> Double {
        guard let item = p.currentItem else { return 0 }
        let pos = CMTimeGetSeconds(p.currentTime())
        let end = item.loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.start + $0.timeRangeValue.duration) }
            .max() ?? 0
        let v = end - pos
        return v.isFinite && v > 0 ? v : 0
    }

    // MARK: - 进度

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let item = self.curSlot.player.currentItem else { return }
            let pos = CMTimeGetSeconds(self.curSlot.player.currentTime())
            guard pos.isFinite else { return }
            let dur = CMTimeGetSeconds(item.duration)
            self.onProgress?([
                "id": self.curSlot.videoID ?? "",
                "position": pos,
                "duration": dur.isFinite ? dur : 0,
                "buffered": self.bufferedSeconds(self.curSlot.player),
                "playing": self.curSlot.player.rate > 0
            ])
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
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
