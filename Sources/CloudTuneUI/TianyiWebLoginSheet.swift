import CloudTuneCore
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

package struct TianyiWebLoginSheet: View {
    @Bindable package var viewModel: CloudTuneViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentPageTitle: String = "正在加载天翼云盘官方登录页…"

    package init(viewModel: CloudTuneViewModel) {
        self.viewModel = viewModel
    }

    package var body: some View {
        let palette = CloudTunePalette(isDark: colorScheme == .dark)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("天翼云盘官方网页登录")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Text(currentPageTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                SecondaryActionButton("切换二维码", systemImage: "qrcode", palette: palette) {
                    viewModel.isShowingWebLoginSheet = false
                    Task { await viewModel.beginQrLogin() }
                }
                SecondaryActionButton("关闭", systemImage: "xmark", palette: palette) {
                    viewModel.isShowingWebLoginSheet = false
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(palette.surfacePrimary)

            Divider().overlay(palette.separator)

            IsolatedTianyiWebView(
                entryURL: Cloud189Protocol.webLoginEntryURL(),
                onTitleChange: { title in
                    if !title.isEmpty { currentPageTitle = title }
                },
                onCallbackIntercepted: { url, cookies in
                    Task {
                        await viewModel.completeEmbeddedWebLogin(callbackURL: url, cookies: cookies)
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 620)
        #endif
    }
}

@MainActor
final class TianyiWebCoordinator: NSObject, WKNavigationDelegate {
    let onTitleChange: (String) -> Void
    let onCallbackIntercepted: (URL, [HTTPCookie]) -> Void
    private var didCompleteCallback = false

    init(
        onTitleChange: @escaping (String) -> Void,
        onCallbackIntercepted: @escaping (URL, [HTTPCookie]) -> Void
    ) {
        self.onTitleChange = onTitleChange
        self.onCallbackIntercepted = onCallbackIntercepted
    }

    static func makeWebView(entryURL: URL, delegate: TianyiWebCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = delegate
        var req = URLRequest(url: entryURL)
        req.setValue(Cloud189Constants.referer, forHTTPHeaderField: "Referer")
        webView.load(req)
        return webView
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if !didCompleteCallback && Cloud189Protocol.isInterceptableWebLoginCallback(url) {
            didCompleteCallback = true
            decisionHandler(.cancel)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [onCallbackIntercepted] cookies in
                Task { @MainActor in
                    onCallbackIntercepted(url, cookies)
                }
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onTitleChange(webView.title ?? "天翼账号安全登录")
    }
}

#if os(macOS)
struct IsolatedTianyiWebView: NSViewRepresentable {
    let entryURL: URL
    let onTitleChange: (String) -> Void
    let onCallbackIntercepted: (URL, [HTTPCookie]) -> Void

    func makeCoordinator() -> TianyiWebCoordinator {
        TianyiWebCoordinator(onTitleChange: onTitleChange, onCallbackIntercepted: onCallbackIntercepted)
    }

    func makeNSView(context: Context) -> WKWebView {
        TianyiWebCoordinator.makeWebView(entryURL: entryURL, delegate: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#elseif os(iOS)
struct IsolatedTianyiWebView: UIViewRepresentable {
    let entryURL: URL
    let onTitleChange: (String) -> Void
    let onCallbackIntercepted: (URL, [HTTPCookie]) -> Void

    func makeCoordinator() -> TianyiWebCoordinator {
        TianyiWebCoordinator(onTitleChange: onTitleChange, onCallbackIntercepted: onCallbackIntercepted)
    }

    func makeUIView(context: Context) -> WKWebView {
        TianyiWebCoordinator.makeWebView(entryURL: entryURL, delegate: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
