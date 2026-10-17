import AVFoundation
import UIKit

/// 一屏视频卡片：首帧图 + 原生播放画面 + 文字。
///
/// 布局全部纯 frame，不用自动布局 —— 少一层出错的可能。
///
/// 层叠关系（从下到上）：
///   firstFrame(首帧图) → videoHost(AVPlayerLayer 挂这儿) → gradient → 文字
///   首帧图在最下层顶着，原生画面出来后就把它盖住；万一原生没就绪，
///   用户看到的是首帧图而不是黑屏。
final class FeedCardCell: UICollectionViewCell {

    /// 播放器的 layer 挂在这里
    let videoHost = UIView()

    private let firstFrame = UIImageView()
    private let gradient = CAGradientLayer()
    private let shade = UIView()

    private let authorLabel = UILabel()
    private let textLabel = UILabel()
    private let audioLabel = UILabel()
    private let indexLabel = UILabel()
    private let playIcon = UIImageView()
    private let statusLabel = UILabel()

    private var imageTask: URLSessionDataTask?
    private var currentID: Int = -1

    private static let cache = NSCache<NSString, UIImage>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCell()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        currentID = -1
        firstFrame.image = nil
        firstFrame.isHidden = false
        playIcon.isHidden = true
        statusLabel.text = nil
    }

    private func setupCell() {
        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        // 1. 首帧图（最底层，顶着用）
        firstFrame.contentMode = .scaleAspectFill
        firstFrame.backgroundColor = UIColor(white: 0.08, alpha: 1)
        firstFrame.clipsToBounds = true
        contentView.addSubview(firstFrame)

        // 2. 原生画面容器
        videoHost.backgroundColor = .clear
        videoHost.isUserInteractionEnabled = false
        contentView.addSubview(videoHost)

        // 3. 底部渐变
        gradient.colors = [UIColor.clear.cgColor,
                           UIColor(white: 0, alpha: 0.55).cgColor]
        gradient.locations = [0.55, 1.0]
        contentView.layer.addSublayer(gradient)

        // 4. 文字
        authorLabel.textColor = .white
        authorLabel.font = .systemFont(ofSize: 17, weight: .bold)
        contentView.addSubview(authorLabel)

        textLabel.textColor = .white
        textLabel.font = .systemFont(ofSize: 14)
        textLabel.numberOfLines = 3
        contentView.addSubview(textLabel)

        audioLabel.textColor = UIColor(white: 1, alpha: 0.85)
        audioLabel.font = .systemFont(ofSize: 13)
        contentView.addSubview(audioLabel)

        indexLabel.textColor = UIColor(white: 1, alpha: 0.5)
        indexLabel.font = .systemFont(ofSize: 11)
        indexLabel.textAlignment = .center
        contentView.addSubview(indexLabel)

        // 5. 播放图标（暂停时显示）
        playIcon.image = UIImage(systemName: "play.fill")
        playIcon.tintColor = UIColor(white: 1, alpha: 0.8)
        playIcon.contentMode = .scaleAspectFit
        playIcon.isHidden = true
        contentView.addSubview(playIcon)

        // 6. 错误/状态
        statusLabel.textColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        contentView.addSubview(statusLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        guard w > 1, h > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        firstFrame.frame = contentView.bounds
        videoHost.frame = contentView.bounds
        gradient.frame = CGRect(x: 0, y: h * 0.5, width: w, height: h * 0.5)
        CATransaction.commit()

        let pad: CGFloat = 16
        let textW = w - pad * 2

        var y = h - pad - 34
        audioLabel.frame = CGRect(x: pad, y: y, width: textW, height: 18)
        y -= 24

        let t = textLabel.text ?? ""
        let lines = max(1, min(3, t.count / 22 + 1))
        let textH = CGFloat(lines) * 19
        textLabel.frame = CGRect(x: pad, y: y - textH, width: textW, height: textH)
        y -= textH + 6

        authorLabel.frame = CGRect(x: pad, y: y - 22, width: textW, height: 22)

        indexLabel.frame = CGRect(x: (w - 80) / 2, y: safeTop() + 6, width: 80, height: 16)

        let iconSide: CGFloat = 64
        playIcon.frame = CGRect(x: (w - iconSide) / 2, y: (h - iconSide) / 2,
                                width: iconSide, height: iconSide)

        statusLabel.frame = CGRect(x: 24, y: h / 2 + 44, width: w - 48, height: 40)
    }

    private func safeTop() -> CGFloat {
        var t: CGFloat = 0
        if #available(iOS 13.0, *) {
            t = window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        }
        return max(t, 20)
    }

    // MARK: - 绑定

    func bind(_ item: VideoItem, base: String) {
        currentID = item.id
        authorLabel.text = "@" + item.author
        textLabel.text = item.text
        audioLabel.text = "♪ " + item.audio
        indexLabel.text = "#\(item.id)"
        statusLabel.text = nil
        setNeedsLayout()
        loadImage(item, base: base)
    }

    /// 原生画面就绪 → 把首帧图藏起来
    func setNativeVisible(_ visible: Bool) {
        firstFrame.isHidden = visible
    }

    func setPlaying(_ playing: Bool) {
        playIcon.isHidden = playing
    }

    func showError(_ msg: String) {
        statusLabel.text = msg
        firstFrame.isHidden = false
    }

    func clearError() {
        statusLabel.text = nil
    }

    private func loadImage(_ item: VideoItem, base: String) {
        let key = "ff-\(item.id)" as NSString
        if let hit = Self.cache.object(forKey: key) {
            firstFrame.image = hit
            return
        }
        firstFrame.image = nil

        let url = item.firstFrameURL(base) ?? item.posterURL(base)
        guard let u = url else { return }

        imageTask?.cancel()
        imageTask = URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Self.cache.setObject(img, forKey: key)
            DispatchQueue.main.async { self?.firstFrame.image = img }
        }
        imageTask?.resume()
    }
}
