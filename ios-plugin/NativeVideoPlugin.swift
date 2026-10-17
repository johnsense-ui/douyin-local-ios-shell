import Foundation
import Capacitor
import WebKit

/// 把 NativeStage 暴露给网页里的 JS。
///
/// 网页侧调用方式（见 native/native-bridge.js）：
///   window.Capacitor.Plugins.NativeVideo.load({ id, url, nextId, nextUrl })
///   window.Capacitor.Plugins.NativeVideo.play()
///   ...
///
/// 事件回传：
///   window.addEventListener('native-video-state', e => e.detail)
///   window.addEventListener('native-video-progress', e => e.detail)
///   window.addEventListener('native-video-ended', ...)
@objc(NativeVideoPlugin)
public class NativeVideoPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "NativeVideoPlugin"
    public let jsName = "NativeVideo"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hold", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "advance", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "preloadNext", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "attach", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "detach", returnType: CAPPluginReturnPromise)
    ]

    private var stage: NativeStage?

    override public func load() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWebReady),
            name: Notification.Name("dzcWebReady"),
            object: nil
        )
    }

    /// WKWebView 加载完页面后，vc.view 的层级可能被重置，这里重新确保舞台在底部
    @objc private func handleWebReady() {
        guard let s = stage else { return }
        guard let vc = bridge?.viewController else { return }
        if let webView = bridge?.webView, s.superview === vc.view, vc.view.subviews.first !== s {
            vc.view.insertSubview(s, belowSubview: webView)
            vc.view.sendSubviewToBack(s)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 舞台挂载

    private func ensureStage() -> NativeStage? {
        if let stage { return stage }
        guard let vc = bridge?.viewController else { return nil }

        let s = NativeStage(frame: vc.view.bounds)
        s.translatesAutoresizingMaskIntoConstraints = true
        s.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 事件回传
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
        // 这样页面 UI（文案/按钮）画在上面，视频画面在底层 ——
        // 网页侧把 body/容器背景设为透明，就形成了「底原生画面 + 上网页 UI」的叠加。
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
        stage?.setMuted(true)
        if let s = stage {
            s.pause()
        }
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
            nextURL: call.getString("nextUrl")
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

    @objc func advance(_ call: CAPPluginCall) {
        let ok = stage?.advanceToNext() ?? false
        call.resolve(["ok": ok])
    }

    @objc func preloadNext(_ call: CAPPluginCall) {
        stage?.preloadNext(id: call.getString("id"), url: call.getString("url"))
        call.resolve(["ok": true])
    }

    @objc func setMuted(_ call: CAPPluginCall) {
        stage?.setMuted(call.getBool("muted") ?? true)
        call.resolve(["ok": true])
    }

    @objc func seek(_ call: CAPPluginCall) {
        stage?.seek(seconds: call.getDouble("seconds") ?? 0)
        call.resolve(["ok": true])
    }

    @objc func setRate(_ call: CAPPluginCall) {
        stage?.setRate(Float(call.getDouble("rate") ?? 1))
        call.resolve(["ok": true])
    }
}
