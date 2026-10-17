import Foundation
import CryptoKit

/// 视频磁盘缓存。
///
/// 搬自 dks333/Tiktok-Clone 的 VideoCacheManager，去掉了 Firebase 依赖。
///
/// 这是"流畅"的关键一环：视频下载完就落盘，下次直接读本地文件，
/// 不重复走网络。抖音/快手的"秒开"靠的就是这个。
final class VideoCache {

    static let shared = VideoCache()

    private let memory = NSCache<NSString, NSData>()
    private let fm = FileManager.default
    private let dir: URL
    private let queue = DispatchQueue(label: "dzc.videocache")

    private init() {
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let path = base + "/VideoCache"
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        dir = URL(fileURLWithPath: path)
        memory.countLimit = 12          // 最多缓存 12 条到内存
        memory.totalCostLimit = 200 * 1024 * 1024   // 200MB
    }

    /// 本地文件路径（存在才返回）
    func cachedPath(for url: URL) -> String? {
        let p = pathForKey(url.absoluteString)
        return fm.fileExists(atPath: p) ? p : nil
    }

    /// 完整读取（内存 → 磁盘）
    func data(for url: URL) -> Data? {
        let key = url.absoluteString as NSString
        if let d = memory.object(forKey: key) { return d as Data }
        let p = pathForKey(url.absoluteString)
        guard let d = fm.contents(atPath: p) else { return nil }
        memory.setObject(d as NSData, forKey: key)
        return d
    }

    /// 写入（内存 + 磁盘）
    func store(_ data: Data, for url: URL) {
        let key = url.absoluteString as NSString
        memory.setObject(data as NSData, forKey: key)
        queue.async { [weak self] in
            guard let self else { return }
            try? data.write(to: URL(fileURLWithPath: self.pathForKey(url.absoluteString)))
        }
    }

    /// 清空
    func clear() -> String {
        memory.removeAllObjects()
        var total: Int64 = 0
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for u in items {
                if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(s)
                }
                try? fm.removeItem(at: u)
            }
        }
        return String(format: "%.1f MB", Double(total) / 1024 / 1024)
    }

    /// 缓存已用大小
    func sizeText() -> String {
        var total: Int64 = 0
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for u in items {
                if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(s)
                }
            }
        }
        return String(format: "%.1f MB", Double(total) / 1024 / 1024)
    }

    // MARK: - 路径

    private func pathForKey(_ key: String) -> String {
        // SHA256 做文件名，避免特殊字符
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        // 我们的流地址都是 mp4，扩展名固定给 .mp4（AVFoundation 靠内容嗅探，扩展名不影响）
        return dir.appendingPathComponent(name).appendingPathExtension("mp4").path
    }
}
