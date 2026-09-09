
import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = webView
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    override var prefersStatusBarHidden: Bool { false }
}
