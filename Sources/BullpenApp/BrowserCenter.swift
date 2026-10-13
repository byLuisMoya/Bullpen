import AppKit
import BPCore
import BPSessions
import Observation
import os
import SwiftUI
import WebKit

/// One browser per worktree, kept alive while Bullpen runs so its tab and the agents (through
/// Bullpen's MCP server) share the same page: open it, read it, click, type, run JavaScript,
/// take screenshots and read its console.
@MainActor
@Observable
final class BrowserCenter {
    @ObservationIgnored private var pages: [UUID: BrowserPage] = [:]
    @ObservationIgnored private var bridge: BrowserBridge.Server?

    func page(for worktree: UUID) -> BrowserPage {
        if let page = pages[worktree] { return page }
        let page = BrowserPage()
        pages[worktree] = page
        return page
    }

    /// Listens for the agents' requests (`bp mcp` → app).
    func start() {
        let server = BrowserBridge.Server { [weak self] request in
            await self?.handle(request) ?? BrowserResponse(ok: false, text: "Bullpen se está cerrando")
        }
        do {
            try server.start()
            bridge = server
        } catch {
            Logger.bullpen("browser").error("Browser bridge: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handle(_ request: BrowserRequest) async -> BrowserResponse {
        guard let id = UUID(uuidString: request.worktree) else { return BrowserResponse(ok: false, text: "Worktree desconocido") }
        let page = page(for: id)
        page.home = request.home
        do {
            if request.action != .open, page.webView.url == nil { try await page.load(request.home) }
            switch request.action {
            case .open:
                try await page.load(Self.absolute(request.url, home: request.home))
                let title = (try? await page.evaluate("return document.title")) ?? ""
                return BrowserResponse(ok: true, text: "\(title) — \(page.webView.url?.absoluteString ?? "")")
            case .snapshot:
                return BrowserResponse(ok: true, text: try await page.snapshot())
            case .screenshot:
                return BrowserResponse(ok: true, text: page.webView.url?.absoluteString, image: try await page.screenshot())
            case .click:
                return BrowserResponse(ok: true, text: try await page.click(selector: request.selector, text: request.text))
            case .type:
                return BrowserResponse(ok: true, text: try await page.type(request.text ?? "", into: request.selector ?? "", submit: request.submit ?? false))
            case .eval:
                return BrowserResponse(ok: true, text: try await page.evaluate(request.script ?? ""))
            case .console:
                return BrowserResponse(ok: true, text: page.console.isEmpty ? "(consola vacía)" : page.console.joined(separator: "\n"))
            }
        } catch {
            return BrowserResponse(ok: false, text: error.localizedDescription)
        }
    }

    /// `/login` → on the worktree's URL; a full URL as is; nothing → the worktree's URL.
    static func absolute(_ url: String?, home: String) -> String {
        guard let url, !url.isEmpty else { return home }
        if url.contains("://") { return url }
        guard let base = URL(string: home) else { return url }
        return URL(string: url, relativeTo: base)?.absoluteString ?? url
    }
}

/// A worktree's page: a WKWebView with its console captured.
@MainActor
final class BrowserPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    var home = ""
    private(set) var console: [String] = []
    private var loading: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Console and errors go to Bullpen, for `browser_console`.
        let capture = """
        (function(){const send=(level,args)=>{try{window.webkit.messageHandlers.bullpen.postMessage(level+': '+Array.from(args).map(a=>{try{return typeof a==='string'?a:JSON.stringify(a)}catch(e){return String(a)}}).join(' '))}catch(e){}};
        for(const level of ['log','info','warn','error','debug']){const original=console[level];console[level]=function(){send(level,arguments);return original.apply(console,arguments)}}
        window.addEventListener('error',e=>send('error',[e.message+' ('+(e.filename||'')+':'+(e.lineno||0)+')']));
        window.addEventListener('unhandledrejection',e=>send('error',['Promesa rechazada: '+(e.reason&&e.reason.message||e.reason)]));})();
        """
        config.userContentController.addUserScript(WKUserScript(source: capture, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(self, name: "bullpen")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        console.append(String(describing: message.body))
        if console.count > 300 { console.removeFirst(console.count - 300) }
    }

    func load(_ address: String) async throws {
        guard let url = URL(string: address) else { throw BrowserError("URL no válida: \(address)") }
        loading?.resume(throwing: BrowserError("Interrumpido por otra carga"))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            webView.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finish(BrowserError("La página tarda demasiado en cargar"))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) } else { loading.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(BrowserError("No se pudo abrir \(webView.url?.absoluteString ?? ""): \(error.localizedDescription). ¿Está arrancado el servidor del worktree?"))
    }

    func evaluate(_ script: String) async throws -> String {
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        return Self.text(result)
    }

    func snapshot() async throws -> String {
        try await evaluate("""
        const css = el => { if (el.id) return '#' + CSS.escape(el.id);
          const name = el.getAttribute('name'); if (name) return el.tagName.toLowerCase() + '[name="' + name + '"]';
          const path = []; for (let e = el; e && e.nodeType === 1 && path.length < 5; e = e.parentElement) {
            let i = 1; for (let s = e.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === e.tagName) i++;
            path.unshift(e.tagName.toLowerCase() + ':nth-of-type(' + i + ')'); if (e.id) { path[0] = '#' + CSS.escape(e.id); break; } }
          return path.join(' > '); };
        const visible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
        const items = [...document.querySelectorAll('a,button,input,textarea,select,[role=button]')].filter(visible).slice(0, 80)
          .map(el => '- ' + el.tagName.toLowerCase() + (el.type ? '[' + el.type + ']' : '') + ' "' +
               (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || '').trim().slice(0, 60) + '" → ' + css(el));
        return 'URL: ' + location.href + '\\nTítulo: ' + document.title + '\\n\\nTexto:\\n' +
          (document.body ? document.body.innerText : '').trim().slice(0, 6000) + '\\n\\nElementos:\\n' + items.join('\\n');
        """)
    }

    func click(selector: String?, text: String?) async throws -> String {
        let result = try await webView.callAsyncJavaScript("""
        let el = selector ? document.querySelector(selector) : null;
        if (!el && text) el = [...document.querySelectorAll('a,button,input[type=submit],[role=button],label,summary')]
          .find(e => (e.innerText || e.value || '').trim().toLowerCase().includes(text.toLowerCase()));
        if (!el) throw new Error('No encuentro el elemento');
        el.scrollIntoView({block: 'center'}); el.click();
        await new Promise(r => setTimeout(r, 400));
        return 'Pulsado. Ahora en ' + location.href;
        """, arguments: ["selector": selector ?? "", "text": text ?? ""], in: nil, contentWorld: .page)
        return Self.text(result)
    }

    func type(_ value: String, into selector: String, submit: Bool) async throws -> String {
        try await webView.callAsyncJavaScript("""
        const el = document.querySelector(selector);
        if (!el) throw new Error('No encuentro ' + selector);
        el.focus();
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value');
        if (setter && setter.set) setter.set.call(el, value); else el.value = value;
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        if (submit) { if (el.form && el.form.requestSubmit) el.form.requestSubmit(); else el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); }
        await new Promise(r => setTimeout(r, 400));
        return 'Escrito en ' + selector + (submit ? ' y enviado' : '');
        """, arguments: ["selector": selector, "value": value, "submit": submit], in: nil, contentWorld: .page)
        .map(Self.text) ?? "Hecho"
    }

    func screenshot() async throws -> Data {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw BrowserError("No se pudo capturar") }
        return png
    }

    static func text(_ value: Any?) -> String {
        switch value {
        case nil: return "undefined"
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default:
            if let value, JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: value!)
        }
    }
}

struct BrowserError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The browser tab: address bar and the worktree's page.
struct BrowserPane: View {
    let worktree: Worktree
    let home: String
    @Environment(BrowserCenter.self) private var browsers
    @State private var address = ""

    var body: some View {
        let page = browsers.page(for: worktree.id)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { page.webView.goForward() } label: { Image(systemName: "chevron.right") }
                Button { page.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { Task { try? await page.load(home); address = home } } label: { Image(systemName: "house") }
                    .help("Volver a \(home)")
                TextField("URL", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { Task { try? await page.load(BrowserCenter.absolute(address, home: home)) } }
                Button {
                    if let url = page.webView.url ?? URL(string: home) { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "safari") }
                .help("Abrir en el navegador del sistema")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(white: 0.12))
            WebViewHost(webView: page.webView)
        }
        .task(id: worktree.id) {
            page.home = home
            if page.webView.url == nil { try? await page.load(home) }
            address = page.webView.url?.absoluteString ?? home
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }
    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
