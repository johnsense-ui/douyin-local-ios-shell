import Foundation
import Capacitor
import WebKit
import AVFoundation

/// 把 NativeStage 暴露给网页里的 JS。
///
/// 网页侧（见 native/native-bridge.js）：
///   Capacitor.Plugins.NativeVideo.load({ id, url, nextId, nextUrl, prevId, prevUrl })
///   Capacitor.Plugins.NativeVideo.play() / pause() / hold()
///   Capacitor.Plugins.NativeVideo.advanceDown() / advanceUp()
///
/// 事件回传（notifyListeners → bridge 转成 window 事件）：
///   state     { phase, id }
///   progress  { id, position, duration, buffered, playing }
///   ended     {}
///   error     { message }
@objc(NativeVideoPlugin)
public class NativeVideoPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "NativeVideoPlugin"
    public let jsName = "NativeVideo"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hold", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "advanceDown", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "advanceUp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "preloadNeighbors", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "replay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "attach", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "detach", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "debug", returnType: CAPPluginReturnPromise)
    ]

    private var stage: NativeStage?

    // MARK: - 生命周期

    override public func load() {
        // 音频会话：允许后台播、允许跟静音键共存
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[NativeVideo] AVAudioSession 设置失败: \(error)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebReady),
            name: Notification.Name("dzcWebReady"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// WKWebView 加载完 / 重新布局后，vc.view 的层级可能被重置，这里重新确保舞台在底部
    @objc private func handleWebReady() {
        guard let s = stage, let vc = bridge?.viewController else { return }
        if let webView = bridge?.webView, s.superview === vc.view {
            vc.view.insertSubview(s, belowSubview: webView)
            vc.view.sendSubviewToBack(s)
        }
    }

    // MARK: - 舞台挂载

    private func ensureStage() -> NativeStage? {
        if let stage { return stage }
        guard let vc = bridge?.viewController else { return nil }

        let s = NativeStage(frame: vc.view.bounds)
        s.translatesAutoresizingMaskIntoConstraints = true
        s.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        s.onStateChange = { [weak self] payload in
            self?.notifyListeners("state", data: payload)
        }
        s.onProgress = { [weak self] payload in
            self?.notifyListeners("progress", data: payload)
        }
        s.onEnded = { [weak self] in
            self?.notifyListeners("ended", data: [:])
        }
        s.onError = { [weak self] message in
            self?.notifyListeners("error", data: ["message": message])
        }

        // 关键：插到 WKWebView **下面**。
        // 页面 UI（文案/按钮）画在上面，视频画面在底层 ——
        // 网页侧把 body/容器背景设为透明，就形成「底原生画面 + 上网页 UI」。
        vc.view.backgroundColor = .black
        if let webView = bridge?.webView {
            vc.view.insertSubview(s, belowSubview: webView)
            vc.view.sendSubviewToBack(s)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isOpaque = false
        } else {
            vc.view.insertSubview(s, at: 0)
        }
        stage = s
        return s
    }

    // MARK: - Plugin 方法

    @objc func attach(_ call: CAPPluginCall) {
        guard let s = ensureStage() else {
            call.reject("无法挂载原生舞台")
            return
        }
        s.isHidden = false
        call.resolve(["ok": true])
    }

    @objc func detach(_ call: CAPPluginCall) {
        stage?.isHidden = true
        // 用 hold 而不是 pause：detach 只是临时离场，不该清掉"想播"的意图
        stage?.hold()
        call.resolve(["ok": true])
    }

    @objc func load(_ call: CAPPluginCall) {
        guard let s = ensureStage() else {
            call.reject("无法挂载原生舞台")
            return
        }
        guard let id = call.getString("id"), let url = call.getString("url") else {
            call.reject("缺少 id / url")
            return
        }
        s.load(
            current: id,
            url: url,
            next: call.getString("nextId"),
            nextURL: call.getString("nextUrl"),
            prev: call.getString("prevId"),
            prevURL: call.getString("prevUrl")
        )
        call.resolve(["ok": true])
    }

    @objc func preloadNeighbors(_ call: CAPPluginCall) {
        guard let s = stage else {
            call.resolve(["ok": false])
            return
        }
        // 复用 load：同一条不会重建，只补邻条
        guard let id = call.getString("id"), let url = call.getString("url") else {
            call.resolve(["ok": false])
            return
        }
        s.load(
            current: id,
            url: url,
            next: call.getString("nextId"),
            nextURL: call.getString("nextUrl"),
            prev: call.getString("prevId"),
            prevURL: call.getString("prevUrl")
        )
        call.resolve(["ok": true])
    }

    @objc func play(_ call: CAPPluginCall) {
        stage?.play()
        call.resolve(["ok": true])
    }

    @objc func pause(_ call: CAPPluginCall) {
        stage?.pause()
        call.resolve(["ok": true])
    }

    @objc func hold(_ call: CAPPluginCall) {
        stage?.hold()
        call.resolve(["ok": true])
    }

    @objc func advanceDown(_ call: CAPPluginCall) {
        call.resolve(["ok": stage?.advanceDown() ?? false])
    }

    @objc func advanceUp(_ call: CAPPluginCall) {
        call.resolve(["ok": stage?.advanceUp() ?? false])
    }

    @objc func setMuted(_ call: CAPPluginCall) {
        stage?.setMuted(call.getBool("muted") ?? true)
        call.resolve(["ok": true])
    }

    @objc func seek(_ call: CAPPluginCall) {
        stage?.seek(seconds: call.getDouble("seconds") ?? 0)
        call.resolve(["ok": true])
    }

    @objc func replay(_ call: CAPPluginCall) {
        stage?.replay()
        call.resolve(["ok": true])
    }

    /// 真机排错用：返回三个槽位的状态
    @objc func debug(_ call: CAPPluginCall) {
        call.resolve(stage?.debugSnapshot() ?? ["error": "stage 未挂载"])
    }
}
