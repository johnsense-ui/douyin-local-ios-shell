import AVFoundation
import UIKit

/// 抖音式播放池。
///
/// ═══════════════════════════════════════════════════════════════
/// 和上一版的区别（这是"学抖音"的核心）
/// ───────────────────────────────────────────────────────────────
///   上一版：谁上台就 play()，快速滑动时一路解压解码，来不及就黑屏卡住。
///
///   抖音真正的做法是**「快速滑动时几乎不播放」**：
///     · 拖动过程中     → 当前条继续播（不断），下一条只准备首帧，**不启动解码**
///     · 松手开始吸附   → 目标条的第一帧已经能画出来（seekToZero + isReadyForDisplay）
///     · 吸附结束       → 目标条 play()，旧条 pause()（不释放，供回滑）
///     · 快速连滑       → 只更新首帧，绝不 play()；停稳 150ms 才真正起播
///
///   这样无论滑多快，屏幕上永远有画面（首帧），只是"不动"而已 ——
///   比黑屏好一万倍，这就是抖音在弱网/快滑下依然顺的原因。
/// ═══════════════════════════════════════════════════════════════
final class PlaybackPool {

    /// 一个槽位
    final class Slot {
        let player = AVPlayer()
        let layer = AVPlayerLayer()
        var videoID: Int?
        var url: String?
        var readyForDisplay = false
        var statusObs: NSKeyValueObservation?
        var readyObs: NSKeyValueObservation?

        init() {
            layer.videoGravity = .resizeAspect
            layer.opacity = 0
            layer.backgroundColor = UIColor.black.cgColor
            player.actionAtItemEnd = .pause
            // 关掉自动等待：我们自己决定什么时候缓冲、什么时候播
            player.automaticallyWaitsToMinimizeStalling = false
            player.isMuted = false
            layer.player = player
        }

        func teardown() {
            statusObs?.invalidate()
            readyObs?.invalidate()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    // 三槽位环形：current / next / prev
    private(set) var slots: [Slot] = [Slot(), Slot(), Slot()]
    private(set) var currentIndex = 0
    private var nextIndex = 1
    private var prevIndex = 2

    var current: Slot { slots[currentIndex] }
    var next: Slot { slots[nextIndex] }
    var prev: Slot { slots[prevIndex] }

    /// 用户意图：是否想播
    private(set) var wantsPlay = true
    /// 快速滑动中：此时绝不起播
    private(set) var isScrubbing = false
    /// 吸附停稳后的延迟起播任务
    private var playDebounce: DispatchWorkItem?

    /// 只有首帧要用小缓冲；真正播的那条给 3s
    private let bufferWhenPlaying: Double = 3.0
    private let bufferWhenIdle: Double = 1.0

    var onState: ((String, Int?) -> Void)?

    // MARK: - 加载

    /// 设置当前条 + 预取邻条首帧。
    /// - Parameters:
    ///   - priming: 是否只准备首帧（快速滑动时传 true，绝不启动解码）
    func setCurrent(id: Int, url: URL, next: (Int, URL)?, prev: (Int, URL)?, priming: Bool = false) {
        if current.videoID != id {
            // 当前条换人了：清掉旧的固定观察者，装新的
            current.teardown()
            current.videoID = id
            current.url = url.absoluteString
            current.layer.opacity = 0
            let item = makeItem(url: url, playing: !priming)
            current.player.replaceCurrentItem(with: item)
            attachObservers(to: current, index: currentIndex)
            // 停在第一帧：这样画面能立刻出来
            current.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if let next, next.0 != self.next.videoID {
            prepare(self.next, id: next.0, url: next.1)
        } else if next == nil, self.next.videoID != nil {
            clear(self.next)
        }

        if let prev, prev.0 != self.prev.videoID {
            prepare(self.prev, id: prev.0, url: prev.1)
        } else if prev == nil, self.prev.videoID != nil {
            clear(self.prev)
        }

        if priming {
            // 只准备首帧，不解码
            current.player.rate = 0
        }
        onState("loaded", id)
    }

    private func prepare(_ slot: Slot, id: Int, url: URL) {
        slot.videoID = id
        slot.url = url.absoluteString
        slot.layer.opacity = 0
        // 预加载条只要 1s 缓冲：足够解出首帧，不浪费带宽和解码器
        let item = makeItem(url: url, playing: false)
        item.preferredForwardBufferDuration = bufferWhenIdle
        slot.player.replaceCurrentItem(with: item)
        // 停在 0s 并让它解出首帧
        slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func clear(_ slot: Slot) {
        slot.teardown()
        slot.videoID = nil
        slot.url = nil
        slot.readyForDisplay = false
        slot.layer.opacity = 0
    }

    private func makeItem(url: URL, playing: Bool) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = playing ? bufferWhenPlaying : bufferWhenIdle
        return item
    }

    // MARK: - 观察

    private func attachObservers(to slot: Slot, index: Int) {
        slot.statusObs?.invalidate()
        slot.readyObs?.invalidate()

        slot.statusObs = slot.player.observe(\.currentItem?.status, options: [.new]) { [weak self, weak slot] p, _ in
            guard let self, let slot else { return }
            guard self.isOnStage(index, id: slot.videoID) else { return }
            switch p.currentItem?.status {
            case .readyToPlay:
                if self.wantsPlay, !self.isScrubbing { self.startNow() }
            case .failed:
                self.retry(slot: slot, index: index)
            default:
                break
            }
        }

        // 有画面了才显示 —— 这是"不黑屏"的关键
        slot.readyObs = slot.layer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self, weak slot] l, _ in
            guard let self, let slot else { return }
            guard l.isReadyForDisplay, self.isOnStage(index, id: slot.videoID) else { return }
            self.revealCurrent()
        }
    }

    private func isOnStage(_ index: Int, id: Int?) -> Bool {
        guard index == currentIndex, let id else { return false }
        return slots[currentIndex].videoID == id
    }

    private var retryCount = [Int: Int]()

    private func retry(slot: Slot, index: Int) {
        guard let id = slot.videoID, let u = slot.url, let url = URL(string: u) else { return }
        let n = (retryCount[id] ?? 0) + 1
        retryCount[id] = n
        if n <= 2 {
            onState("retry", id)
            slot.player.replaceCurrentItem(with: makeItem(url: url, playing: true))
            attachObservers(to: slot, index: index)
            slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            onState("error", id)
        }
    }

    private func revealCurrent() {
        guard current.layer.opacity != 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, s) in slots.enumerated() {
            s.layer.opacity = (i == currentIndex) ? 1 : 0
        }
        CATransaction.commit()
        onState("ready", current.videoID)
    }

    // MARK: - 播放控制

    private func startNow() {
        guard current.player.currentItem?.status == .readyToPlay else { return }
        if current.player.rate == 0 {
            current.player.play()
            onState("playing", current.videoID)
        }
    }

    /// 标记「正在快速滑动」：期间绝不起播，只保持首帧
    func setScrubbing(_ scrubbing: Bool) {
        isScrubbing = scrubbing
        if scrubbing {
            playDebounce?.cancel()
            playDebounce = nil
            current.player.pause()
            onState("scrubbing", current.videoID)
        } else {
            // 停稳后 150ms 才真正起播 —— 给吸附动画留时间，避免抖
            schedulePlay(after: 0.15)
        }
    }

    private func schedulePlay(after delay: TimeInterval) {
        playDebounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.wantsPlay else { return }
            self.startNow()
        }
        playDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func play() {
        wantsPlay = true
        if isScrubbing { return }
        if current.player.currentItem?.status == .readyToPlay {
            startNow()
        } else {
            onState("wantplay", current.videoID)
        }
    }

    func pause() {
        wantsPlay = false
        playDebounce?.cancel()
        current.player.pause()
        onState("paused", current.videoID)
    }

    func togglePlay() {
        if wantsPlay, current.player.rate > 0 {
            pause()
        } else {
            play()
        }
    }

    func setMuted(_ muted: Bool) {
        current.player.isMuted = muted
        next.player.isMuted = true
        prev.player.isMuted = true
    }

    func setLoop(_ loop: Bool) {
        // 循环由 VC 在播放结束通知里处理
    }

    // MARK: - 切条（核心）

    /// 用户滑到了下一条。**不重建播放器，只轮转三个槽的角色。**
    @discardableResult
    func advanceDown(priming: Bool) -> Bool {
        guard next.videoID != nil else { return false }
        current.player.pause()
        let oldPrev = prevIndex
        prevIndex = currentIndex
        currentIndex = nextIndex
        nextIndex = oldPrev
        clear(slots[nextIndex])   // 腾出来给"下下条"
        finalizeAdvance(priming: priming, dir: 1)
        return true
    }

    @discardableResult
    func advanceUp(priming: Bool) -> Bool {
        guard prev.videoID != nil else { return false }
        current.player.pause()
        let oldNext = nextIndex
        nextIndex = currentIndex
        currentIndex = prevIndex
        prevIndex = oldNext
        clear(slots[prevIndex])
        finalizeAdvance(priming: priming, dir: -1)
        return true
    }

    private func finalizeAdvance(priming: Bool, dir: Int) {
        attachObservers(to: current, index: currentIndex)
        if current.layer.isReadyForDisplay { revealCurrent() }
        if priming {
            // 快速滑动：只出首帧，绝不解码
            current.player.rate = 0
            onState("primed", current.videoID)
        } else if wantsPlay {
            schedulePlay(after: 0)
        }
        onState(dir > 0 ? "advanced_down" : "advanced_up", current.videoID)
    }

    /// 给"下下条"预填（JS/VC 拿到新数据后调用）
    func fillNeighbor(id: Int, url: URL?, isNext: Bool) {
        guard let url else { return }
        let slot = isNext ? next : prev
        if slot.videoID == id { return }
        prepare(slot, id: id, url: url)
    }

    // MARK: - 诊断

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "currentIndex": currentIndex,
            "wantsPlay": wantsPlay,
            "scrubbing": isScrubbing,
            "currentID": current.videoID ?? -1,
            "currentRate": Double(current.player.rate)
        ]
        for (i, s) in slots.enumerated() {
            out["slot\(i)"] = [
                "id": s.videoID ?? -1,
                "opacity": Double(s.layer.opacity),
                "ready": s.layer.isReadyForDisplay,
                "status": statusString(s.player.currentItem?.status),
                "buffer": buffered(s.player)
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

    private func buffered(_ p: AVPlayer) -> Double {
        guard let item = p.currentItem else { return 0 }
        let pos = CMTimeGetSeconds(p.currentTime())
        let end = item.loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.start + $0.timeRangeValue.duration) }
            .max() ?? 0
        let v = end - pos
        return v.isFinite && v > 0 ? v : 0
    }
}
