// Minimal "browser shell" on the system WebView: one window, one WKWebView per
// URL (tabs), only the last one on screen. Used to measure what the WebView
// route costs in memory on this Mac. Private data store, so nothing is written
// to ~/Library.
import Cocoa
import WebKit

setvbuf(stdout, nil, _IONBF, 0)

final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let urls: [URL]
    var window: NSWindow!
    var views: [WKWebView] = []
    var settled = 0

    init(urls: [URL]) { self.urls = urls }

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 800),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "WebView memory probe"
        window.level = .floating // on screen without taking keyboard focus
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for (i, url) in urls.enumerated() {
            let view = WKWebView(frame: window.contentView!.bounds, configuration: config)
            view.autoresizingMask = [.width, .height]
            view.navigationDelegate = self
            view.isHidden = i != urls.count - 1
            window.contentView!.addSubview(view)
            view.load(URLRequest(url: url))
            views.append(view)
        }
        window.orderFrontRegardless()
        print("PID \(getpid())")
    }

    func report(_ what: String) {
        settled += 1
        print("\(what) \(settled)/\(urls.count)")
        guard settled == urls.count else { return }
        // Private property, probe-only: which WebContent process serves which tab.
        for v in views {
            let pid = (v.value(forKey: "_webProcessIdentifier") as? Int32) ?? -1
            print("TAB \(pid) \(v.url?.absoluteString ?? "?")")
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { report("LOADED \(w.url?.absoluteString ?? "?")") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { report("FAILED \(e.localizedDescription)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { report("FAILED \(e.localizedDescription)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe(urls: CommandLine.arguments.dropFirst().compactMap(URL.init(string:)))
app.delegate = probe
app.run()
