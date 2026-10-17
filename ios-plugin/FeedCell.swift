import AVFoundation
import UIKit

/// 一个竖屏视频 cell。UI 全部原生（对齐抖音布局）。
///
/// 重要：cell **不持有播放器**。播放器在 PlaybackPool 里，
/// cell 只提供一个 videoContainer，池子把 AVPlayerLayer 塞进去。
/// 这样 cell 复用时播放器完全不重建 —— 抖音就是这么做的。
final class FeedCell: UICollectionViewCell {

    static let reuseID = "FeedCell"

    // MARK: - 图层容器
    let videoContainer = UIView()
    /// 首帧图：原生画面还没就绪时顶着，避免黑
    private let firstFrameView = UIImageView()

    // MARK: - 顶部
    private let topBar = UIView()
    private let followingBtn = UIButton(type: .system)
    private let recommendBtn = UIButton(type: .system)
    private let topIndicator = UIView()

    // MARK: - 右侧
    private let rightStack = UIStackView()
    private let avatarView = UIImageView()
    private lazy var likeBtn = makeActionButton(symbol: "heart.fill", label: "点赞")
    private lazy var commentBtn = makeActionButton(symbol: "bubble.right.fill", label: "评论")
    private lazy var favBtn = makeActionButton(symbol: "star.fill", label: "收藏")
    private lazy var shareBtn = makeActionButton(symbol: "arrowshape.turn.up.right.fill", label: "分享")

    // MARK: - 底部
    private let bottomBar = UIView()
    private let authorLabel = UILabel()
    private let captionLabel = UILabel()
    private let audioRow = UIView()
    private let audioIcon = UIImageView()
    private let audioMarquee = UILabel()

    // MARK: - 中心
    private let centerPlayIcon = UIImageView()

    // MARK: - 进度
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint?
    private let pauseOverlay = UIView()

    private var itemID: Int?

    // MARK: - init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        firstFrameView.image = nil
        centerPlayIcon.isHidden = true
        setProgress(0)
    }

    // MARK: - 布局

    private func setup() {
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        // ---- video
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoContainer)
        firstFrameView.contentMode = .scaleAspectFit
        firstFrameView.backgroundColor = .black
        firstFrameView.translatesAutoresizingMaskIntoConstraints = false
        videoContainer.addSubview(firstFrameView)

        // ---- 顶部 tab
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)
        configureTopBar()

        // ---- 右侧按钮
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.axis = .vertical
        rightStack.spacing = 18
        rightStack.alignment = .center
        contentView.addSubview(rightStack)
        // 【坑】这个方法只能调一次。
        // UIStackView.addArrangedSubview 对同一个 view 调两次会抛
        // NSInternalInconsistencyException → 启动就闪退。
        configureRightStack()

        // ---- 底部信息
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomBar)
        configureBottomBar()

        // ---- 中心播放图标
        centerPlayIcon.image = UIImage(systemName: "play.fill")
        centerPlayIcon.tintColor = UIColor.white.withAlphaComponent(0.85)
        centerPlayIcon.contentMode = .scaleAspectFit
        centerPlayIcon.isHidden = true
        centerPlayIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(centerPlayIcon)

        // ---- 进度条（底部 2pt）
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressTrack)
        progressFill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            firstFrameView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            firstFrameView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            firstFrameView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            firstFrameView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),

            topBar.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 4),
            topBar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 36),

            // 右侧按钮：只靠 trailing + 一个垂直定位。不要跟 bottomBar 互相约束，
            // 否则 rightStack.bottom ← bottomBar.top ← rightStack.leading 会成环，
            // 环一旦解不开就刷约束警告，严重时直接崩。
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 40),

            // 底部信息：左右各自定位，宽度不依赖 rightStack
            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -80),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -10),

            centerPlayIcon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            centerPlayIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            centerPlayIcon.widthAnchor.constraint(equalToConstant: 64),
            centerPlayIcon.heightAnchor.constraint(equalToConstant: 64),

            progressTrack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 2),
        ])

        let pw = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = pw
        NSLayoutConstraint.activate([
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            pw,
        ])
    }

    private func configureTopBar() {
        let stack = UIStackView(arrangedSubviews: [followingBtn, recommendBtn])
        stack.axis = .horizontal
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(stack)

        styleTab(followingBtn, title: "关注", active: false)
        styleTab(recommendBtn, title: "推荐", active: true)

        topIndicator.backgroundColor = .white
        topIndicator.layer.cornerRadius = 1.5
        topIndicator.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topIndicator)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topIndicator.topAnchor.constraint(equalTo: recommendBtn.bottomAnchor, constant: 2),
            topIndicator.centerXAnchor.constraint(equalTo: recommendBtn.centerXAnchor),
            topIndicator.widthAnchor.constraint(equalToConstant: 18),
            topIndicator.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    private func styleTab(_ btn: UIButton, title: String, active: Bool) {
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: active ? 17 : 16, weight: active ? .semibold : .regular)
        btn.setTitleColor(active ? .white : UIColor.white.withAlphaComponent(0.6), for: .normal)
    }

    private func configureRightStack() {
        avatarView.backgroundColor = UIColor(white: 0.25, alpha: 1)
        avatarView.layer.cornerRadius = 23
        avatarView.layer.borderWidth = 1.5
        avatarView.layer.borderColor = UIColor.white.cgColor
        avatarView.clipsToBounds = true
        avatarView.image = UIImage(systemName: "person.fill")
        avatarView.tintColor = UIColor(white: 0.7, alpha: 1)
        avatarView.contentMode = .center
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.widthAnchor.constraint(equalToConstant: 46).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: 46).isActive = true

        rightStack.addArrangedSubview(avatarView)
        rightStack.setCustomSpacing(24, after: avatarView)
        [likeBtn, commentBtn, favBtn, shareBtn].forEach { rightStack.addArrangedSubview($0) }
    }

    private func makeActionButton(symbol: String, label: String) -> UIButton {
        // iOS 15 的 UIButton.Configuration 用不了（部署目标 13.0），
        // 用 setImage/setTitle + imageEdgeInsets 手工排布。
        //
        // 【闪退教训】不要在这里读 titleLabel.intrinsicContentSize 或 currentImage.size
        // 来算 inset —— 此刻还没布局，值可能是 0 甚至 nil，
        // 一旦不小心用了 `!` 就直接崩。这里全部用固定值。
        let b = UIButton(type: .custom)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        b.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        b.setTitle(label, for: .normal)
        b.tintColor = .white
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 12)
        b.titleLabel?.textAlignment = .center
        b.titleLabel?.lineBreakMode = .byClipping
        // 固定 56x60：图标在上、文字在下，不依赖任何运行时测量
        b.imageEdgeInsets = UIEdgeInsets(top: -32, left: 0, bottom: 0, right: 0)
        b.titleEdgeInsets = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 56),
            b.heightAnchor.constraint(equalToConstant: 58),
        ])
        return b
    }

    private func configureBottomBar() {
        authorLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        authorLabel.textColor = .white

        captionLabel.font = .systemFont(ofSize: 14)
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 2

        audioIcon.image = UIImage(systemName: "music.note")
        audioIcon.tintColor = .white
        audioIcon.contentMode = .scaleAspectFit
        audioIcon.translatesAutoresizingMaskIntoConstraints = false
        audioIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        audioIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        audioMarquee.font = .systemFont(ofSize: 13)
        audioMarquee.textColor = .white

        let audioStack = UIStackView(arrangedSubviews: [audioIcon, audioMarquee])
        audioStack.axis = .horizontal
        audioStack.spacing = 6
        audioStack.alignment = .center

        let v = UIStackView(arrangedSubviews: [authorLabel, captionLabel, audioStack])
        v.axis = .vertical
        v.spacing = 6
        v.alignment = .leading
        v.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            v.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
        ])
    }

    // MARK: - 绑定

    func bind(_ item: VideoItem, base: String) {
        itemID = item.id
        authorLabel.text = "@" + item.displayAuthor
        captionLabel.text = item.displayCaption
        audioMarquee.text = item.displayAudio.isEmpty ? "原声" : item.displayAudio
        setActionTitle(likeBtn, item.diggText)

        // 首帧图先顶上（原生层就绪后会被盖住）
        loadFirstFrame(item, base: base)
    }

    private var imageTask: URLSessionDataTask?
    private static let imgCache = NSCache<NSString, UIImage>()

    private func loadFirstFrame(_ item: VideoItem, base: String) {
        guard let url = item.firstFrameURL(base: base) else { return }
        let key = "\(item.id)" as NSString
        if let hit = Self.imgCache.object(forKey: key) {
            firstFrameView.image = hit
            return
        }
        firstFrameView.image = nil
        imageTask?.cancel()
        imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Self.imgCache.setObject(img, forKey: key)
            DispatchQueue.main.async { self?.firstFrameView.image = img }
        }
        imageTask?.resume()
    }

    func setActionTitle(_ btn: UIButton, _ title: String) {
        btn.setTitle(title, for: .normal)
    }

    /// 播放器的 layer 挂到本 cell
    func attach(_ playerLayer: AVPlayerLayer?) {
        playerLayer?.frame = videoContainer.bounds
        if let l = playerLayer, l.superlayer !== videoContainer.layer {
            videoContainer.layer.addSublayer(l)
        }
    }

    func layoutPlayerLayer(_ playerLayer: AVPlayerLayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = videoContainer.bounds
        CATransaction.commit()
    }

    /// 原生画面已就绪 → 盖住首帧图
    func setNativeVisible(_ visible: Bool) {
        firstFrameView.alpha = visible ? 0 : 1
    }

    func setPlaying(_ playing: Bool) {
        centerPlayIcon.isHidden = playing
    }

    func setProgress(_ ratio: Double) {
        let w = contentView.bounds.width * CGFloat(max(0, min(1, ratio)))
        progressWidth?.constant = w
    }
}
