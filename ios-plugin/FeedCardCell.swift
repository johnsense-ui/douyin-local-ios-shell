import UIKit
import AVFoundation

/// 一屏视频 cell。
///
/// 移植自 dks333/Tiktok-Clone 的 HomeTableViewCell，改：
///   · 不用 XIB / IBOutlet，纯代码布局
///   · 不用 MarqueeLabel，用普通 UILabel
///   · 数据换成我们的 VideoItem
///
/// 播放器由 cell 自己持有（这是原版的设计）。
/// 虽然"播放器放池子里"理论更省，但原版这样写能跑通 ——
/// 先用被验证过的方案，跑通后再考虑优化。
final class FeedCardCell: UITableViewCell {

    static let reuseID = "FeedCardCell"

    let playerView = VideoPlayerView()

    private let nameLabel = UILabel()
    private let captionLabel = UILabel()
    private let musicLabel = UILabel()
    private let likeBtn = UIButton(type: .custom)
    private let likeCountLabel = UILabel()
    private let commentBtn = UIButton(type: .custom)
    private let shareBtn = UIButton(type: .custom)
    private let pauseIcon = UIImageView()
    private let avatarView = UIImageView()
    private let debugLabel = UILabel()

    private(set) var isPlaying = false
    private(set) var liked = false
    private var videoID: Int = -1

    // MARK: - init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerView.teardown()
        isPlaying = false
        pauseIcon.alpha = 0
        captionLabel.text = nil
        debugLabel.text = nil
    }

    // MARK: - 布局（纯 frame）

    private func setup() {
        selectionStyle = .none
        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        // 播放器铺满，放最底层
        playerView.frame = contentView.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(playerView)

        // 底部渐变
        let g = CAGradientLayer()
        g.colors = [UIColor.clear.cgColor, UIColor(white: 0, alpha: 0.6).cgColor]
        g.locations = [0.55, 1.0]
        g.name = "grad"
        contentView.layer.addSublayer(g)

        // 右侧按钮
        for b in [likeBtn, commentBtn, shareBtn] {
            b.translatesAutoresizingMaskIntoConstraints = true
            b.tintColor = .white
            contentView.addSubview(b)
        }
        likeBtn.setImage(UIImage(systemName: "heart.fill"), for: .normal)
        commentBtn.setImage(UIImage(systemName: "bubble.right.fill"), for: .normal)
        shareBtn.setImage(UIImage(systemName: "arrowshape.turn.up.right.fill"), for: .normal)

        for l in [likeCountLabel, nameLabel, captionLabel, musicLabel, debugLabel] {
            l.translatesAutoresizingMaskIntoConstraints = true
            contentView.addSubview(l)
        }
        likeCountLabel.textColor = .white
        likeCountLabel.font = .systemFont(ofSize: 12)
        likeCountLabel.textAlignment = .center

        avatarView.backgroundColor = UIColor(white: 0.25, alpha: 1)
        avatarView.layer.cornerRadius = 23
        avatarView.layer.borderWidth = 1.5
        avatarView.layer.borderColor = UIColor.white.cgColor
        avatarView.clipsToBounds = true
        avatarView.image = UIImage(systemName: "person.fill")
        avatarView.tintColor = UIColor(white: 0.7, alpha: 1)
        avatarView.contentMode = .center
        contentView.addSubview(avatarView)

        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        captionLabel.textColor = .white
        captionLabel.font = .systemFont(ofSize: 14)
        captionLabel.numberOfLines = 3

        musicLabel.textColor = UIColor(white: 1, alpha: 0.85)
        musicLabel.font = .systemFont(ofSize: 13)

        pauseIcon.image = UIImage(systemName: "play.fill")
        pauseIcon.tintColor = UIColor(white: 1, alpha: 0.8)
        pauseIcon.contentMode = .scaleAspectFit
        pauseIcon.alpha = 0
        contentView.addSubview(pauseIcon)

        debugLabel.textColor = UIColor(red: 0.3, green: 1, blue: 0.5, alpha: 1)
        debugLabel.backgroundColor = UIColor(white: 0, alpha: 0.7)
        debugLabel.font = UIFont(name: "Menlo", size: 8) ?? .systemFont(ofSize: 8)
        debugLabel.numberOfLines = 3

        // 手势
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let dbl = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        tap.require(toFail: dbl)
        contentView.addGestureRecognizer(tap)
        contentView.addGestureRecognizer(dbl)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        guard w > 1, h > 1 else { return }

        playerView.frame = contentView.bounds
        contentView.layer.sublayers?.first { $0.name == "grad" }?.frame =
            CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45)

        let pad: CGFloat = 16
        let rightX = w - 56
        var ry = h - 200
        likeBtn.frame = CGRect(x: rightX, y: ry, width: 40, height: 40)
        likeCountLabel.frame = CGRect(x: rightX - 6, y: ry + 40, width: 52, height: 16)
        ry -= 74
        commentBtn.frame = CGRect(x: rightX, y: ry, width: 40, height: 40)
        ry -= 64
        shareBtn.frame = CGRect(x: rightX, y: ry, width: 40, height: 40)
        ry -= 70
        avatarView.frame = CGRect(x: rightX - 3, y: ry, width: 46, height: 46)

        let textW = w - pad * 2 - 70
        var y = h - pad - 20
        musicLabel.frame = CGRect(x: pad, y: y, width: textW, height: 18)
        y -= 24
        let c = captionLabel.text ?? ""
        let lines = max(1, min(3, c.count / 20 + 1))
        let ch = CGFloat(lines) * 19
        captionLabel.frame = CGRect(x: pad, y: y - ch, width: textW, height: ch)
        y -= ch + 6
        nameLabel.frame = CGRect(x: pad, y: y - 22, width: textW, height: 22)

        let icon: CGFloat = 60
        pauseIcon.frame = CGRect(x: (w - icon) / 2, y: (h - icon) / 2, width: icon, height: icon)

        debugLabel.frame = CGRect(x: 6, y: safeTop() + 4, width: w - 12, height: 40)
    }

    private func safeTop() -> CGFloat {
        var t: CGFloat = 20
        if #available(iOS 13.0, *) {
            t = window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 20
        }
        return max(t, 20)
    }

    // MARK: - 绑定

    func configure(_ item: VideoItem, base: String) {
        videoID = item.id
        nameLabel.text = "@" + item.author
        captionLabel.text = item.text
        musicLabel.text = "♪ " + item.audio
        likeCountLabel.text = item.diggText
        setNeedsLayout()

        playerView.onStatus = { [weak self] s in
            guard let self else { return }
            self.debugLabel.text = "id=\(item.id) \(s) \(self.playerView.debugText())"
        }
        playerView.onError = { [weak self] msg in
            self?.debugLabel.text = "id=\(item.id) ERR \(msg)"
        }

        guard let url = item.streamURL(base) else {
            debugLabel.text = "id=\(item.id) 地址无效"
            return
        }
        playerView.configure(url: url, aspect: item.aspect)
        debugLabel.text = "id=\(item.id) 配置中…"
    }

    // MARK: - 播放控制

    func play() {
        guard !isPlaying else { return }
        playerView.play()
        isPlaying = true
        pauseIcon.alpha = 0
    }

    func pause() {
        guard isPlaying else { return }
        playerView.pause()
        isPlaying = false
    }

    func replay() {
        playerView.replay()
        isPlaying = true
        pauseIcon.alpha = 0
    }

    // MARK: - 手势

    @objc private func handleTap() {
        if isPlaying {
            pause()
            UIView.animate(withDuration: 0.08) { self.pauseIcon.alpha = 0.35 }
        } else {
            play()
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        // 双击点赞：爱心飞出
        if !liked {
            liked = true
            likeBtn.tintColor = .red
        }
        let p = g.location(in: contentView)
        let heart = UIImageView(image: UIImage(systemName: "heart.fill"))
        heart.tintColor = .red
        heart.contentMode = .scaleAspectFit
        let s: CGFloat = 100
        heart.frame = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        heart.transform = CGAffineTransform(rotationAngle: CGFloat.random(in: -0.4...0.4))
        contentView.addSubview(heart)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 3) {
            heart.transform = heart.transform.scaledBy(x: 0.85, y: 0.85)
        } completion: { _ in
            UIView.animate(withDuration: 0.4, delay: 0.08, usingSpringWithDamping: 0.8, initialSpringVelocity: 3) {
                heart.transform = heart.transform.scaledBy(x: 2.3, y: 2.3)
                heart.alpha = 0
            } completion: { _ in
                heart.removeFromSuperview()
            }
        }
    }
}
