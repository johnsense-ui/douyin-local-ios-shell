import Foundation

/// 一条视频（对应服务端 /api/videos 的 items[]）
struct VideoItem: Decodable, Equatable {
    let id: Int
    let title: String?
    let caption: String?
    let collection: String?
    let duration: Double?
    let width: Int?
    let height: Int?
    let aspectRatio: Double?
    let digg: Int?
    let authorName: String?
    let audioName: String?
    let favorite: Bool?
    let liked: Bool?
    let hasPoster: Bool?
    let playCount: Int?

    /// 视频流地址（由 serverBase + id 拼）
    func streamURL(base: String) -> URL? {
        URL(string: "\(base)/api/stream/\(id)")
    }
    /// 首帧图（服务端用 ffmpeg 抽的第一帧，和视频开头像素一致）
    func firstFrameURL(base: String) -> URL? {
        URL(string: "\(base)/api/firstframe/\(id)")
    }
    /// 封面
    func posterURL(base: String) -> URL? {
        URL(string: "\(base)/api/poster/\(id)")
    }

    var displayAuthor: String { authorName?.isEmpty == false ? authorName! : "未知作者" }
    var displayCaption: String {
        let c = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? (title ?? "") : c
    }
    var displayAudio: String { audioName ?? "" }
    var diggText: String {
        let n = digg ?? 0
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        if n > 0 { return "\(n)" }
        return "点赞"
    }
    var aspect: CGFloat {
        if let a = aspectRatio, a > 0.1, a < 10 { return CGFloat(a) }
        if let w = width, let h = height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 9.0 / 16.0
    }
}

/// /api/videos 的响应
struct VideoPage: Decodable {
    let total: Int
    let offset: Int
    let limit: Int
    let items: [VideoItem]
}
