import Foundation

/// 服务端地址与数据获取。
///
/// 地址来源优先级：UserDefaults → 编译期注入 → 首启让用户填。
final class FeedService {

    static let shared = FeedService()

    private let key = "dzc.serverBase"
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 15
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    var base: String {
        get { (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: key) }
    }

    var hasBase: Bool { !base.isEmpty }

    /// 拉一页视频
    func fetchPage(offset: Int, limit: Int = 20, sort: String = "random", completion: @escaping (Result<[VideoItem], Error>) -> Void) {
        guard hasBase else {
            completion(.failure(NSError(domain: "dzc", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "还没设置服务器地址"])))
            return
        }
        var comps = URLComponents(string: "\(base)/api/videos")!
        // seed 固定住，翻页才不会重复/漏
        let seed = UserDefaults.standard.integer(forKey: "dzc.feedSeed")
        let realSeed = seed == 0 ? Int(Date().timeIntervalSince1970) : seed
        if seed == 0 { UserDefaults.standard.set(realSeed, forKey: "dzc.feedSeed") }

        comps.queryItems = [
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "seed", value: "\(realSeed)"),
        ]
        guard let url = comps.url else { return }

        session.dataTask(with: url) { data, _, err in
            DispatchQueue.main.async {
                if let err { completion(.failure(err)); return }
                guard let data else {
                    completion(.failure(NSError(domain: "dzc", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "没拿到数据"])))
                    return
                }
                do {
                    let page = try JSONDecoder().decode(VideoPage.self, from: data)
                    completion(.success(page.items))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    /// 重置随机种子（下拉刷新用）
    func resetSeed() {
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: "dzc.feedSeed")
    }

    /// 预取首帧图（让 UICollectionView 滚起来不缺图）
    func prefetchFirstFrames(_ items: [VideoItem]) {
        for v in items {
            guard let u = v.firstFrameURL(base: base) else { continue }
            var req = URLRequest(url: u)
            req.cachePolicy = .returnCacheDataElseLoad
            session.dataTask(with: req) { _, _, _ in }.resume()
        }
    }
}
