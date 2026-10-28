import SwiftUI
import WebKit
import MarkmeCore

struct PageWebView: NSViewRepresentable {
    let html: String
    let articleHTML: String
    let needsDiagrams: Bool
    let baseURL: URL?
    let findQuery: String
    let scrollToLine: Int?
    let scrollToAnchor: String?
    let anchorToken: Int
    let zoom: Double
    let presenting: Bool
    let slideIndex: Int
    let changeCursor: Int?
    let changeScrollToken: Int
    var onSlide: (Int) -> Void
    var onLink: (URL) -> Void
    var onVisibleLine: (Int) -> Void
    var onSelection: (Int, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLink: onLink, onVisibleLine: onVisibleLine, onSelection: onSelection, onSlide: onSlide)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "markme")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.pageZoom = zoom
        context.coordinator.pageZoom = zoom
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        context.coordinator.onVisibleLine = onVisibleLine
        context.coordinator.onSelection = onSelection
        context.coordinator.onSlide = onSlide
        context.coordinator.pageZoom = zoom
        if abs(view.pageZoom - zoom) > 0.001 {
            view.pageZoom = zoom
        }
        let presentationChanged = context.coordinator.presenting != presenting
            || context.coordinator.slideIndex != slideIndex
        context.coordinator.presenting = presenting
        context.coordinator.slideIndex = slideIndex
        if presentationChanged {
            context.coordinator.applyPresentation(in: view)
        }
        if context.coordinator.lastChangeToken != changeScrollToken {
            context.coordinator.lastChangeToken = changeScrollToken
            context.coordinator.pendingChangeToken = changeScrollToken
            context.coordinator.pendingChangeCursor = changeScrollToken > 0 ? changeCursor : nil
        }
        let htmlChanged = context.coordinator.lastHTML != html || context.coordinator.lastBase != baseURL
        if htmlChanged {
            let canReplace = context.coordinator.lastHTML != nil
                && context.coordinator.lastBase == baseURL
                && !context.coordinator.awaitingLoad
                && !presenting
                && !articleHTML.isEmpty
                && (!needsDiagrams || context.coordinator.loadedDiagrams)
            context.coordinator.lastHTML = html
            context.coordinator.lastBase = baseURL
            if canReplace {
                context.coordinator.replaceArticle(articleHTML, in: view)
            } else {
                context.coordinator.awaitingLoad = true
                context.coordinator.loadedDiagrams = needsDiagrams
                view.loadHTMLString(html, baseURL: baseURL)
            }
        } else if !context.coordinator.awaitingLoad,
                  context.coordinator.pendingChangeToken > 0,
                  let changeCursor = context.coordinator.pendingChangeCursor {
            context.coordinator.pendingChangeCursor = nil
            context.coordinator.pendingChangeToken = 0
            view.evaluateJavaScript(
                "window.markmeShowChange && window.markmeShowChange(\(changeCursor))",
                completionHandler: nil
            )
        }
        if context.coordinator.lastFind != findQuery {
            context.coordinator.lastFind = findQuery
            let configuration = WKFindConfiguration()
            configuration.caseSensitive = false
            view.find(findQuery, configuration: configuration) { _ in }
        }
        if let scrollToLine,
           context.coordinator.pendingChangeToken == 0,
           context.coordinator.lastScroll != scrollToLine {
            context.coordinator.lastScroll = scrollToLine
            view.evaluateJavaScript("window.markmeScrollToLine && window.markmeScrollToLine(\(scrollToLine))", completionHandler: nil)
        }
        if anchorToken != context.coordinator.lastAnchorToken {
            context.coordinator.lastAnchorToken = anchorToken
            context.coordinator.pendingAnchor = scrollToAnchor
            if let scrollToAnchor {
                Coordinator.scrollToAnchor(scrollToAnchor, in: view)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onLink: (URL) -> Void
        var onVisibleLine: (Int) -> Void
        var onSelection: (Int, Bool) -> Void
        var onSlide: (Int) -> Void
        var lastHTML: String?
        var lastBase: URL?
        var lastFind: String?
        var lastScroll: Int?
        var lastAnchorToken = 0
        var pendingAnchor: String?
        var lastReportedLine: Int?
        var pageZoom = 1.0
        var presenting = false
        var slideIndex = 0
        var lastChangeToken = 0
        var pendingChangeCursor: Int?
        var pendingChangeToken = 0
        var awaitingLoad = false
        var loadedDiagrams = false

        func applyPresentation(in webView: WKWebView) {
            let flag = presenting ? "true" : "false"
            let requested = slideIndex
            let reportCaret = presenting
            webView.evaluateJavaScript(
                """
                (function () {
                  if (window.markmePresent) window.markmePresent(\(flag));
                  var index = window.markmeSlide ? window.markmeSlide(\(requested)) : 0;
                  var line = 0;
                  var slide = document.querySelector('article > section.slide.active');
                  if (slide) {
                    var node = slide.querySelector('[data-sourcepos]');
                    if (node) {
                      var start = parseInt((node.getAttribute('data-sourcepos') || '').split(':')[0], 10);
                      if (!isNaN(start)) line = start;
                    }
                  }
                  return { index: index, line: line };
                })()
                """
            ) { value, _ in
                let payload = value as? [String: Any]
                let shown = Self.scriptInt(payload?["index"])
                let line = Self.scriptInt(payload?["line"]) ?? 0
                if reportCaret, line > 0 {
                    self.onSelection(line, true)
                }
                guard let shown, shown != requested else { return }
                self.onSlide(shown)
            }
        }

        private static func scriptInt(_ value: Any?) -> Int? {
            if let number = value as? Int { return number }
            if let number = value as? NSNumber { return number.intValue }
            return nil
        }

        init(
            onLink: @escaping (URL) -> Void,
            onVisibleLine: @escaping (Int) -> Void,
            onSelection: @escaping (Int, Bool) -> Void,
            onSlide: @escaping (Int) -> Void
        ) {
            self.onLink = onLink
            self.onVisibleLine = onVisibleLine
            self.onSelection = onSelection
            self.onSlide = onSlide
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], (body["kind"] as? String) == "selection" {
                let line = (body["line"] as? NSNumber)?.intValue ?? (body["line"] as? Int) ?? 0
                let collapsed = (body["collapsed"] as? NSNumber)?.boolValue ?? (body["collapsed"] as? Bool) ?? true
                if line > 0 {
                    onSelection(line, collapsed)
                } else {
                    onSelection(0, true)
                }
                return
            }
            let line: Int?
            if let value = message.body as? Int {
                line = value
            } else if let number = message.body as? NSNumber {
                line = number.intValue
            } else {
                line = nil
            }
            if let line {
                lastReportedLine = line
                onVisibleLine(line)
            }
        }

        func replaceArticle(_ html: String, in webView: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: [html]),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.markmeReplace && window.markmeReplace(\(json)[0])",
                completionHandler: nil
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            awaitingLoad = false
            webView.pageZoom = pageZoom
            applyPresentation(in: webView)
            webView.evaluateJavaScript(Self.scrollScript) { _, _ in
                if let pending = self.pendingAnchor {
                    Self.scrollToAnchor(pending, in: webView)
                } else if self.pendingChangeToken > 0, let cursor = self.pendingChangeCursor {
                    self.pendingChangeCursor = nil
                    self.pendingChangeToken = 0
                    webView.evaluateJavaScript(
                        "window.markmeShowChange && window.markmeShowChange(\(cursor))",
                        completionHandler: nil
                    )
                } else if let line = self.lastReportedLine, line > 1 {
                    webView.evaluateJavaScript(
                        "window.markmeScrollToLine && window.markmeScrollToLine(\(line))",
                        completionHandler: nil
                    )
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let isLink = navigationAction.navigationType == .linkActivated
            let initial = Self.isDocumentRequest(navigationAction.request.url, base: lastBase)
            let decision = DocumentLoadPolicy.decide(
                isLinkActivation: isLink,
                requestIsInitialDocument: initial
            )
            if decision == .allow {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if isLink, let url = navigationAction.request.url {
                onLink(url)
            }
        }

        private static let scrollScript = """
        if (!window.__markme) {
          window.__markme = true;
          const lineOf = (node) => parseInt((node.getAttribute('data-sourcepos') || '').split(':')[0], 10);
          const sourcePos = (node) => {
            const match = (node.getAttribute('data-sourcepos') || '').match(/^(\\d+):\\d+-(\\d+):\\d+$/);
            if (!match) return null;
            return { start: parseInt(match[1], 10), end: parseInt(match[2], 10) };
          };
          const fenceLead = (el) => {
            if (!el || el.tagName !== 'PRE') return 0;
            const pos = sourcePos(el);
            if (!pos) return 0;
            const text = el.textContent || '';
            const parts = text.split('\\n');
            if (text.endsWith('\\n') && parts.length && parts[parts.length - 1] === '') parts.pop();
            const span = pos.end - pos.start + 1;
            return parts.length < span ? Math.floor((span - parts.length) / 2) : 0;
          };
          const newlines = (text) => (text.match(/\\n/g) || []).length;
          const lineAt = (container, offset) => {
            const node = container;
            if (!node) return 0;
            let el = node.nodeType === 3 ? node.parentElement : node;
            while (el && el.nodeType === 1 && !el.getAttribute('data-sourcepos')) el = el.parentElement;
            if (!el || !el.contains(node)) return 0;
            const pos = sourcePos(el);
            if (!pos) return 0;
            let count = 0;
            let skipOneNewline = false;
            const take = (text) => {
              let rest = text;
              if (skipOneNewline && rest.charAt(0) === '\\n') {
                rest = rest.slice(1);
                skipOneNewline = false;
              } else {
                skipOneNewline = false;
              }
              count += newlines(rest);
            };
            const visit = (current) => {
              if (current === node && current.nodeType === 3) {
                take((current.textContent || '').slice(0, offset));
                return true;
              }
              if (current === node && current.nodeType === 1) {
                const kids = current.childNodes;
                for (let i = 0; i < offset && i < kids.length; i++) visit(kids[i]);
                return true;
              }
              if (current.nodeType === 3) {
                take(current.textContent || '');
                return false;
              }
              if (current.nodeType === 1 && current.tagName === 'BR') {
                count += 1;
                skipOneNewline = true;
                return false;
              }
              const kids = current.childNodes;
              for (let i = 0; i < kids.length; i++) {
                if (visit(kids[i])) return true;
              }
              return false;
            };
            visit(el);
            return pos.start + fenceLead(el) + count;
          };
          const report = () => {
            if (document.body.classList.contains('presenting')) {
              const slide = document.querySelector('article > section.slide.active');
              const node = slide && slide.querySelector('[data-sourcepos]');
              const line = node ? lineOf(node) : 0;
              if (line) window.webkit.messageHandlers.markme.postMessage(line);
              return;
            }
            const nodes = document.querySelectorAll('[data-sourcepos]');
            let line = 1;
            let best = -1e9;
            nodes.forEach((node) => {
              if (!node.getClientRects().length) return;
              const top = node.getBoundingClientRect().top;
              const start = lineOf(node);
              if (!Number.isNaN(start) && top <= 32 && top >= best) {
                best = top;
                line = start;
              }
            });
            window.webkit.messageHandlers.markme.postMessage(line);
          };
          document.addEventListener('scroll', report, true);
          document.addEventListener('selectionchange', () => {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount) {
              window.webkit.messageHandlers.markme.postMessage({ kind: 'selection', line: 0, collapsed: true });
              return;
            }
            const range = sel.getRangeAt(0);
            const line = lineAt(range.startContainer, range.startOffset);
            window.webkit.messageHandlers.markme.postMessage({
              kind: 'selection',
              line: line || 0,
              collapsed: line ? sel.isCollapsed : true
            });
          });
          window.markmeScrollToLine = (line) => {
            const nodes = document.querySelectorAll('[data-sourcepos]');
            let target = null;
            nodes.forEach((node) => {
              const start = lineOf(node);
              if (!Number.isNaN(start) && start <= line) target = node;
            });
            if (target) target.scrollIntoView({block: 'start'});
          };
        }
        """

        fileprivate static func isDocumentRequest(_ url: URL?, base: URL?) -> Bool {
            guard let url else { return true }
            if url.scheme == "about" { return true }
            guard url.isFileURL, let base else { return false }
            let requestPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
            return Self.sameDirectory(requestPath, basePath)
        }

        private static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
            let left = lhs.hasSuffix("/") ? String(lhs.dropLast()) : lhs
            let right = rhs.hasSuffix("/") ? String(rhs.dropLast()) : rhs
            return left == right
        }

        fileprivate static func scrollToAnchor(_ id: String, in view: WKWebView) {
            view.evaluateJavaScript(
                "document.getElementById(\(jsLiteral(id)))?.scrollIntoView({block:'start'})",
                completionHandler: nil
            )
        }

        private static func jsLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: data, encoding: .utf8) else { return "\"\"" }
            return text
        }
    }
}
