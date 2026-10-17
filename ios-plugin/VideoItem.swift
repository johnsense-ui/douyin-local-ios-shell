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
    func streamURL(_ base: String) -> URL? {
        URL(string: "\(base)/api/stream/\(id)")
    }
    /// 首帧图（服务端用 ffmpeg 抽的第一帧，和视频开头像素一致）
    func firstFrameURL(_ base: String) -> URL? {
        URL(string: "\(base)/api/firstframe/\(id)")
    }
    /// 封面
    func posterURL(_ base: String) -> URL? {
        URL(string: "\(base)/api/poster/\(id)")
    }

    var author: String {
        if let a = authorName, !a.isEmpty { return a }
        return "未知作者"
    }

    var text: String {
        let c = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        return title ?? ""
    }

    var audio: String {
        if let a = audioName, !a.isEmpty { return a }
        return "原声"
    }

    var diggText: String {
        let n = digg ?? 0
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        if n > 0 { return "\(n)" }
        return "点赞"
    }
}

/// /api/videos 的响应
struct VideoPage: Decodable {
    let total: Int
    let offset: Int?
    let limit: Int?
    let items: [VideoItem]
}
