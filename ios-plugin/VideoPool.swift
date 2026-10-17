import AVFoundation
import UIKit

/// 视频播放池（第 3 步：双槽位，AVPlayer）。
///
/// ═══════════════════════════════════════════════════════════════
/// 为什么是「双槽位」而不是「三槽位」
/// ───────────────────────────────────────────────────────────────
///   抖音用三槽（上一条/当前/下一条）是为了支持回滑也有画面。
///   但先用两条把链路跑通：当前 + 下一条。
///   少一个槽位就少一份出错可能，跑通了再加第三条很快。
///
/// ═══════════════════════════════════════════════════════════════
/// 核心策略（这几条决定了流畅度）
/// ───────────────────────────────────────────────────────────────
///   1. 只用两个 AVPlayer，不随 cell 创建销毁 —— cell 复用不影响播放器
///   2. 切条 = 交换两个槽的角色，不 replaceCurrentItem（不重新缓冲）
///   3. 画面就绪（isReadyForDisplay）才让 layer 不透明 → 不黑屏
///   4. 快速滑动时 pause，停稳 200ms 才 play → 不在滑动中浪费解码
///   5. layer 由 VC 挂到 cell 上，池子只管播放器本身
/// ═══════════════════════════════════════════════════════════════
final class VideoPool {

    /// 一个槽位
    final class Slot {
        let player = AVPlayer()
        let layer = AVPlayerLayer()
        var videoID: Int?
        var url: String?
        var statusObs: NSKeyValueObservation?
        var readyObs: NSKeyValueObservation?

        init() {
            layer.videoGravity = .resizeAspect
            layer.opacity = 0
            layer.backgroundColor = UIColor.clear.cgColor
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = true
            layer.player = player
        }

        func reset() {
            statusObs?.invalidate(); statusObs = nil
            readyObs?.invalidate(); readyObs = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            videoID = nil
            url = nil
            layer.opacity = 0
        }
    }

    private var a = Slot()
    private var b = Slot()
    /// true 表示 a 在台上
    private var usingA = true

    var current: Slot { usingA ? a : b }
    var standby: Slot { usingA ? b : a }

    private(set) var wantsPlay = true
    private(set) var isScrubbing = false
    private var playWork: DispatchWorkItem?

    /// 缓冲：本地库给 2s 就够（太大反而让起播变慢）
    private let bufferSeconds: Double = 2.0

    var onReady: ((Int) -> Void)?      // 画面可显示
    var onPlaying: ((Int) -> Void)?    // 开始播
    var onPaused: ((Int) -> Void)?     // 暂停
    var onError: ((Int, String) -> Void)?

    // MARK: - 装载

    func set(current id: Int, url: URL, next: (Int, URL)?) {
        // 同一条不重建
        if current.videoID != id {
            current.reset()
            current.videoID = id
            current.url = url.absoluteString
            let item = makeItem(url: url)
            current.player.replaceCurrentItem(with: item)
            observe(current)
            // 停在 0s，让首帧能解出来
            current.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if let next {
            if standby.videoID != next.0 {
                standby.reset()
                standby.videoID = next.0
                standby.url = next.1.absoluteString
                let item = makeItem(url: next.1)
                standby.player.replaceCurrentItem(with: item)
                // 预加载条也停在 0s，切过去立刻有画面
                standby.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else if standby.videoID != nil {
            standby.reset()
        }

        if wantsPlay, !isScrubbing {
            schedulePlay(after: 0)
        }
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = bufferSeconds
        return item
    }

    private func observe(_ slot: Slot) {
        slot.statusObs?.invalidate()
        slot.readyObs?.invalidate()

        let id = slot.videoID

        slot.statusObs = slot.player.observe(\.currentItem?.status, options: [.new]) { [weak self, weak slot] p, _ in
            guard let self, let slot, slot === self.current, slot.videoID == id else { return }
            switch p.currentItem?.status {
            case .readyToPlay:
                if self.wantsPlay, !self.isScrubbing { self.startNow() }
            case .failed:
                let msg = p.currentItem?.error?.localizedDescription ?? "播放失败"
                DispatchQueue.main.async { self.onError?(id ?? -1, msg) }
            default:
                break
            }
        }

        // 画面真的解出来了才显示 —— 这是不黑屏的关键
        slot.readyObs = slot.layer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self, weak slot] l, _ in
            guard let self, let slot, slot === self.current, slot.videoID == id else { return }
            guard l.isReadyForDisplay else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.current.layer.opacity = 1
            self.standby.layer.opacity = 0
            CATransaction.commit()
            DispatchQueue.main.async { self.onReady?(id ?? -1) }
        }
    }

    // MARK: - 播放控制

    private func startNow() {
        guard current.player.currentItem?.status == .readyToPlay else { return }
        if current.player.rate == 0 {
            current.player.play()
            let id = current.videoID ?? -1
            DispatchQueue.main.async { self.onPlaying?(id) }
        }
    }

    private func schedulePlay(after delay: TimeInterval) {
        playWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.wantsPlay, !self.isScrubbing else { return }
            self.startNow()
        }
        playWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// 快速滑动中：只暂停，不改意图
    func setScrubbing(_ v: Bool) {
        isScrubbing = v
        if v {
            playWork?.cancel(); playWork = nil
            current.player.pause()
            let id = current.videoID ?? -1
            DispatchQueue.main.async { self.onPaused?(id) }
        } else {
            schedulePlay(after: 0.2)
        }
    }

    func play() {
        wantsPlay = true
        startNow()
    }

    func pause() {
        wantsPlay = false
        playWork?.cancel()
        current.player.pause()
        let id = current.videoID ?? -1
        DispatchQueue.main.async { self.onPaused?(id) }
    }

    func toggle() {
        if current.player.rate > 0 { pause() } else { play() }
    }

    func setMuted(_ m: Bool) {
        current.player.isMuted = m
        standby.player.isMuted = true
    }

    func replay() {
        current.player.seek(to: .zero) { [weak self] _ in self?.play() }
    }

    // MARK: - 切条

    /// 切到下一条。交换两个槽的角色，**不重建播放器**。
    func advance() {
        guard standby.videoID != nil else { return }
        current.player.pause()

        // 交换
        usingA.toggle()

        // 新台的画面如果已经就绪，立刻显示
        if current.layer.isReadyForDisplay {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            current.layer.opacity = 1
            standby.layer.opacity = 0
            CATransaction.commit()
        }
        observe(current)

        if isScrubbing { return }
        schedulePlay(after: 0.05)
    }

    /// 回到上一条（目前只在池里还留着时有效）
    func rewind() {
        // 双槽位下，standby 里就是"上一个" —— 但需要外部重新 set
        usingA.toggle()
        observe(current)
        if !isScrubbing { schedulePlay(after: 0.05) }
    }

    // MARK: - 诊断

    func debugInfo() -> String {
        let c = current
        let s = standby
        let cs = statusText(c.player.currentItem?.status)
        let ss = statusText(s.player.currentItem?.status)
        return "当前 id=\(c.videoID ?? -1) \(cs) op=\(String(format: "%.0f", c.layer.opacity)) rate=\(String(format: "%.1f", c.player.rate))"
            + "\n备用 id=\(s.videoID ?? -1) \(ss)"
            + "\nscrubbing=\(isScrubbing) wantsPlay=\(wantsPlay)"
    }

    private func statusText(_ s: AVPlayerItem.Status?) -> String {
        switch s {
        case .readyToPlay: return "ready"
        case .failed: return "failed"
        case .unknown: return "unknown"
        default: return "none"
        }
    }
}
