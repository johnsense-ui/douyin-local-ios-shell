import UIKit

/// 一屏视频卡片（第 2 步：只显示首帧图 + 文字，不含播放器）。
///
/// 布局全部用**纯 frame**，不用自动布局 —— 少一层出错的可能。
/// cell 尺寸变化时在 layoutSubviews 里重排。
final class FeedCardCell: UICollectionViewCell {

    private let firstFrame = UIImageView()
    private let gradient = CAGradientLayer()
    private let shade = UIView()

    private let authorLabel = UILabel()
    private let textLabel = UILabel()
    private let audioLabel = UILabel()
    private let indexLabel = UILabel()
    private let loadingBox = UIView()

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
    }

    private func setupCell() {
        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        firstFrame.contentMode = .scaleAspectFill
        firstFrame.backgroundColor = UIColor(white: 0.08, alpha: 1)
        firstFrame.clipsToBounds = true
        contentView.addSubview(firstFrame)

        // 底部渐变，让文字在亮画面上也看得清
        gradient.colors = [UIColor.clear.cgColor,
                           UIColor(white: 0, alpha: 0.55).cgColor]
        gradient.locations = [0.55, 1.0]
        contentView.layer.addSublayer(gradient)

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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        guard w > 1, h > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        firstFrame.frame = contentView.bounds
        gradient.frame = CGRect(x: 0, y: h * 0.5, width: w, height: h * 0.5)
        CATransaction.commit()

        let pad: CGFloat = 16
        let textW = w - pad * 2

        var y = h - pad
        audioLabel.frame = CGRect(x: pad, y: y - 18, width: textW, height: 18)
        y -= 18 + 6

        let textH = CGFloat(min(3, max(1, (textLabel.text ?? "").count / 22 + 1))) * 19
        textLabel.frame = CGRect(x: pad, y: y - textH, width: textW, height: textH)
        y -= textH + 8

        authorLabel.frame = CGRect(x: pad, y: y - 22, width: textW, height: 22)

        indexLabel.frame = CGRect(x: (w - 60) / 2, y: safeTop() + 6, width: 60, height: 16)
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
        authorLabel.text = "@" + item.author
        textLabel.text = item.text
        audioLabel.text = "♪ " + item.audio
        indexLabel.text = "#\(item.id)"
        indexLabel.isHidden = false
        setNeedsLayout()

        loadImage(item, base: base)
    }

    private func loadImage(_ item: VideoItem, base: String) {
        let key = "ff-\(item.id)" as NSString
        if let hit = Self.cache.object(forKey: key) {
            firstFrame.image = hit
            return
        }
        firstFrame.image = nil

        // 优先首帧图；没有就用封面
        let url = item.firstFrameURL(base) ?? item.posterURL(base)
        guard let u = url else { return }

        imageTask?.cancel()
        imageTask = URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Self.cache.setObject(img, forKey: key)
            DispatchQueue.main.async {
                self?.firstFrame.image = img
            }
        }
        imageTask?.resume()
    }
}
