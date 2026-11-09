//
//  AppDelegate.swift
//  拾光阅读器 iOS 壳：
//  启动内嵌 CPython 运行原版 HTTP 服务，再用 WKWebView 全屏加载。
//

import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var webView: WKWebView?
    private let port: UInt16 = 8791

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // ---- 1. 计算路径并启动内嵌 Python 服务 ----
        let root = Bundle.main.resourceURL!.appendingPathComponent("app").path
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        shiguang_start_python(root as NSString, docs as NSString)

        // ---- 2. 搭建 WKWebView 界面 ----
        let window = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.backgroundColor = .white
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: vc.view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.scrollView.contentInsetAdjustmentBehavior = .never
        vc.view.addSubview(web)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        self.webView = web

        pollAndLoad(attempt: 0)
        return true
    }

    /// 服务是异步起来的，轮询就绪后再加载，最多等 30 秒
    private func pollAndLoad(attempt: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.webView?.load(URLRequest(url: url))
                } else if attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.pollAndLoad(attempt: attempt + 1)
                    }
                } else {
                    let html = """
                    <html><body style="font-family:-apple-system;padding:40px;text-align:center">
                    <h2>服务启动失败</h2>
                    <p>连续 30 秒未检测到本地服务。可重启应用重试；若多次失败，请把
                    文件 App 里的沙盒 Documents/boot_error.txt 提供给开发者。</p>
                    </body></html>
                    """
                    self.webView?.loadHTMLString(html, baseURL: nil)
                }
            }
        }
        task.resume()
    }
}
