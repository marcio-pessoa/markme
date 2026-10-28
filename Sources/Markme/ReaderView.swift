import AppKit
import SwiftUI
import MarkmeCore

struct ReaderView: View {
    let fileURL: URL?
    @State private var model: ReaderModel
    @State private var pageHTML = ""
    @State private var pageBody = ""
    @State private var pageNeedsDiagrams = false
    @State private var split = SplitFraction()
    @State private var dragOrigin: CGFloat = 0.5
    @State private var findQuery = ""
    @State private var findPresented = false
    @State private var pageScrollLine: Int?
    @State private var sourceScrollLine: Int?
    @State private var anchorName: String?
    @State private var anchorToken = 0
    @State private var hostWindow: NSWindow?
    @State private var renderGeneration = 0
    @State private var sync = ScrollSync()
    @State private var zoom = ReaderZoom()
    @State private var slideIndex = 0
    @State private var companionToken = 0
    @State private var liveToken = 0
    @State private var liveTicket = 0
    @State private var saveTicket = 0
    @State private var sourceFocusToken = 0
    @State private var draft: DraftSync
    @State private var saveFailed = false
    @State private var presentationFullscreen = false
    @State private var hideToolbar = false
    @State private var toolbarNeedsRestore = false
    @State private var modeToolbarMounted = true
    @State private var changeScrollToken = 0
    @State private var sourceCaretLine = 1
    @State private var sourceSelectionCollapsed = true
    @State private var pageCaretLine = 1
    @State private var pageSelectionCollapsed = true
    /// Change navigation scrolls both panes itself. Ignore the bounds events that scroll posts.
    @State private var ignoreScrollSyncUntil: Date?
    @FocusState private var findFieldFocused: Bool
    @StateObject private var watcher = FileWatcher()

    init(document: ReaderDocument, fileURL: URL?) {
        self.fileURL = fileURL
        let name = fileURL?.lastPathComponent ?? "markdown"
        let dismissed = UserDefaults.standard.bool(forKey: Self.bannerKey)
        let data: Data? = document.missing ? nil : document.data
        let model = ReaderModel(fileName: name, data: data, bannerDismissed: dismissed)
        _model = State(initialValue: model)
        _draft = State(initialValue: DraftSync(saved: model.failure == nil ? model.text : ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showsBanner, model.mode != .presentation {
                banner
                Divider()
            }
            if draft.saveIsBlocked, model.mode != .presentation {
                draftConflictBar
                Divider()
            }
            if saveFailed, !draft.saveIsBlocked, model.mode != .presentation {
                saveFailedBar
                Divider()
            }
            if showsChangeBar {
                changeBar
                Divider()
            }
            if findPresented, model.mode != .presentation {
                findBar
                Divider()
            }
            documentBody
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar { modeToolbar }
        .toolbar(hideToolbar ? .hidden : .visible, for: .windowToolbar)
        .background(WindowPlacement { hostWindow = $0 })
        .onAppear {
            startWatching()
            ZoomKeys.installCompanion()
            WheelZoomMonitor.shared.install()
            PresentationSession.shared.install()
            syncPresentationChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            syncPresentationChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            if model.mode == .presentation {
                // The green button left fullscreen. Entering it again would
                // trap the window. Show the mode buttons and stay on the slides.
                presentationFullscreen = false
                hideToolbar = false
                if toolbarNeedsRestore {
                    restoreModeToolbar(window)
                }
            } else {
                syncPresentationChrome()
            }
        }
        .onChange(of: model.mode) { previous, mode in
            if mode == .presentation, previous != .presentation {
                slideIndex = 0
            }
            if mode == .source || mode == .split {
                sourceFocusToken += 1
            }
            syncPresentationChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markmeSlide)) { note in
            guard let number = note.userInfo?[PresentationSession.windowKey] as? Int,
                  hostWindow?.windowNumber == number,
                  model.mode == .presentation,
                  let action = note.object as? String else { return }
            switch action {
            case "next":
                slideIndex += 1
            case "previous":
                slideIndex = max(0, slideIndex - 1)
            case "first":
                slideIndex = 0
            case "exit":
                model.mode = .page
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .markmeZoom)) { note in
            guard let raw = note.object as? String, let action = ReaderZoomAction(rawValue: raw) else { return }
            if let number = note.userInfo?[WheelZoomMonitor.windowKey] as? Int {
                guard hostWindow?.windowNumber == number else { return }
            } else {
                guard ownsMenuAction else { return }
            }
            var next = zoom
            next.apply(action)
            zoom = next
        }
        .onReceive(NotificationCenter.default.publisher(for: .markmeFind)) { _ in
            guard ownsMenuAction else { return }
            findPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .markmeCopyLocation)) { _ in
            copyLocation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markmeSave)) { _ in
            guard ownsMenuAction else { return }
            saveTicket += 1
            commitDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markmeMode)) { note in
            guard ownsMenuAction, let raw = note.object as? String, let mode = ReaderMode(rawValue: raw) else { return }
            model.mode = mode
        }
        .onChange(of: findPresented) { _, shown in
            findFieldFocused = shown
        }
        .onChange(of: model.text) { _, _ in
            refreshCompanion()
        }
        .onDisappear {
            commitDraft()
            watcher.stop()
        }
        .task(id: "\(model.changeRevision).\(companionToken).\(liveToken)") { await renderPage() }
    }

    @ViewBuilder
    private var documentBody: some View {
        if let failure = model.failure {
            VStack(spacing: 8) {
                Text(ReaderCopy.string(failure == .notUTF8 ? .notUTF8 : .unreadable, languageCode: languageCode))
                    .font(.title3)
                if !model.failureDetail.isEmpty {
                    Text(model.failureDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            switch model.mode {
            case .page, .presentation:
                page
            case .source:
                source
            case .split:
                splitBody
            }
        }
    }

    private var page: some View {
        PageWebView(
            html: pageHTML,
            articleHTML: pageBody,
            needsDiagrams: pageNeedsDiagrams,
            baseURL: fileURL?.deletingLastPathComponent(),
            findQuery: findPresented ? findQuery : "",
            scrollToLine: pageScrollLine,
            scrollToAnchor: anchorName,
            anchorToken: anchorToken,
            zoom: zoom.factor,
            presenting: model.mode == .presentation,
            slideIndex: slideIndex,
            changeCursor: model.changeCursor,
            changeScrollToken: changeScrollToken,
            onSlide: { slideIndex = $0 },
            onLink: open,
            onVisibleLine: { line in
                pageScrolled(line)
                if pageSelectionCollapsed { pageCaretLine = line }
            },
            onSelection: { line, collapsed in
                if line > 0 { pageCaretLine = line }
                pageSelectionCollapsed = collapsed
            }
        )
        .onAppear {
            pageSelectionCollapsed = true
            pageCaretLine = 1
        }
        .onChange(of: pageHTML) { _, _ in
            pageSelectionCollapsed = true
        }
    }

    private var source: some View {
        SourceTextView(
            text: model.text,
            editable: fileURL != nil && model.failure == nil,
            focusToken: sourceFocusToken,
            findQuery: findPresented ? findQuery : "",
            scrollToLine: sourceScrollLine,
            zoom: zoom.factor,
            changes: model.changes,
            changeCursor: model.changeCursor,
            changeScrollToken: changeScrollToken,
            onVisibleLine: sourceScrolled,
            onSelection: { line, collapsed in
                sourceCaretLine = line
                sourceSelectionCollapsed = collapsed
            },
            onEdit: noteTyped
        )
    }

    private var splitBody: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let gutter: CGFloat = 8
            let usable = max(width - gutter, 1)
            HStack(spacing: 0) {
                source.frame(width: max(usable * split.fraction, 0))
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 8)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let delta = value.translation.width
                                var next = SplitFraction()
                                next.fraction = dragOrigin
                                next.drag(translation: delta, width: usable)
                                split = next
                            }
                            .onEnded { _ in
                                dragOrigin = split.fraction
                            }
                    )
                page
            }
        }
    }

    private var draftConflictBar: some View {
        HStack(spacing: 12) {
            Text(copy(.draftConflict))
                .font(.callout)
            Spacer()
            Button(copy(.draftUseDisk)) { useDisk() }
            Button(copy(.draftKeepMine)) { keepMine() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var saveFailedBar: some View {
        HStack(spacing: 12) {
            Text(copy(.draftSaveFailed))
                .font(.callout)
            Spacer()
            Button(copy(.save)) {
                saveTicket += 1
                commitDraft()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Text(copy(.bannerQuestion))
                .font(.callout)
            Spacer()
            Button(copy(.bannerNotNow)) { dismissBanner() }
            Button(copy(.bannerAccept)) { DefaultReader.request() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var showsChangeBar: Bool {
        model.failure == nil && model.mode != .presentation && !model.changes.isEmpty
    }

    private var changeBar: some View {
        HStack(spacing: 8) {
            Button {
                stepChange(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(copy(.changesPrevious))
            .accessibilityLabel(copy(.changesPrevious))
            Text(ReaderCopy.changePosition(
                current: (model.changeCursor ?? 0) + 1,
                total: model.changes.count,
                languageCode: languageCode
            ))
            .font(.callout.monospacedDigit())
            if let removed = currentRemovalCount {
                Text(ReaderCopy.linesRemoved(removed, languageCode: languageCode))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                stepChange(1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(copy(.changesNext))
            .accessibilityLabel(copy(.changesNext))
            Spacer()
            Button(copy(.changesSeen)) { model.dismissChanges() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var currentRemovalCount: Int? {
        guard let cursor = model.changeCursor, model.changes.indices.contains(cursor) else { return nil }
        guard case .removed(_, let count) = model.changes[cursor].kind else { return nil }
        return count
    }

    private func stepChange(_ delta: Int) {
        ignoreScrollSyncUntil = Date().addingTimeInterval(0.4)
        if changeScrollToken == 0 {
            changeScrollToken = 1
            return
        }
        model.stepChange(by: delta)
        changeScrollToken += 1
    }

    private var findBar: some View {
        HStack {
            TextField(copy(.findPrompt), text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($findFieldFocused)
            Button {
                findQuery = ""
                findPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(8)
    }

    @ToolbarContentBuilder
    private var modeToolbar: some ToolbarContent {
        if modeToolbarMounted {
            ToolbarItemGroup(placement: .primaryAction) {
                modeButton(.source, symbol: "line.3.horizontal")
                modeButton(.split, symbol: "rectangle.split.2x1")
                modeButton(.page, symbol: "photo")
                modeButton(.presentation, symbol: "play.rectangle")
            }
        }
    }

    private func modeButton(_ mode: ReaderMode, symbol: String) -> some View {
        let key: CopyKey = switch mode {
        case .source: .modeSource
        case .split: .modeSplit
        case .page: .modePage
        case .presentation: .modePresentation
        }
        return Button {
            model.mode = mode
        } label: {
            Image(systemName: symbol)
                .frame(width: 32, height: 28)
                .background(
                    model.mode == mode ? Color.primary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help(copy(key))
        .accessibilityLabel(copy(key))
    }

    private var languageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private func copy(_ key: CopyKey) -> String {
        ReaderCopy.string(key, languageCode: languageCode)
    }

    private func copyLocation() {
        guard ownsMenuAction, let fileURL else { return }
        let headings = LocationReference.headingLines(in: model.text)
        let caret: Int
        let extends: Bool
        switch model.mode {
        case .source:
            caret = sourceCaretLine
            extends = !sourceSelectionCollapsed
        case .page, .presentation:
            caret = pageCaretLine
            extends = !pageSelectionCollapsed
        case .split:
            if !sourceSelectionCollapsed {
                caret = sourceCaretLine
                extends = true
            } else if !pageSelectionCollapsed {
                caret = pageCaretLine
                extends = true
            } else {
                caret = sourceCaretLine
                extends = false
            }
        }
        let line = LocationReference.line(caret: caret, selectionExtends: extends, headings: headings)
        let reference = LocationReference.format(fileURL: fileURL, line: line)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(reference, forType: .string)
    }

    private func dismissBanner() {
        model.dismissBannerForever()
        UserDefaults.standard.set(true, forKey: Self.bannerKey)
    }

    private func renderPage() async {
        renderGeneration += 1
        let generation = renderGeneration
        let revision = model.changeRevision
        let baseline = model.changeBaseline
        let text = model.text
        let language = languageCode
        let highlighter = HighlighterLibrary.script
        let baseDirectory = fileURL?.deletingLastPathComponent()
        let openedFile = fileURL
        let cited = baseDirectory.flatMap {
            FeaturePage.load(plan: text, planDirectory: $0, excluding: openedFile)
        }
        let needsDiagram = PageShell.containsMermaidFence(text)
            || cited.map { PageShell.containsMermaidFence($0.markdown) } == true
        let mermaid = needsDiagram ? MermaidLibrary.script : ""
        let planLabel = openedFile?.lastPathComponent ?? ""
        let rememberedSpans = model.changes
        let rememberedCursor = model.changeCursor
        let rendered = await Task.detached(priority: .userInitiated) {
            let planBody = MarkdownRenderer.render(text, baseDirectory: baseDirectory, languageCode: language).htmlBody
            let spans: [ChangeSpan]
            let selected: Int?
            if let baseline {
                spans = ChangeReview.spans(from: baseline, to: text)
                selected = spans.isEmpty ? nil : 0
            } else {
                spans = rememberedSpans
                selected = rememberedCursor.flatMap { spans.indices.contains($0) ? $0 : nil }
            }
            let markedPlan = ChangeReview.annotate(
                html: planBody,
                spans: spans,
                selected: selected,
                removedLabel: { ReaderCopy.linesRemoved($0, languageCode: language) }
            )
            let body: String
            if let cited, let baseDirectory {
                body = FeaturePage.compose(
                    plan: text,
                    planHTML: markedPlan,
                    spec: cited,
                    planDirectory: baseDirectory,
                    planLabel: planLabel,
                    languageCode: language
                )
            } else {
                body = markedPlan
            }
            let html = PageShell.html(body: body, highlighter: highlighter, mermaid: mermaid)
            return (html: html, body: body, spans: spans)
        }.value
        guard generation == renderGeneration, model.changeRevision == revision else { return }
        if baseline != nil {
            model.adoptChanges(rendered.spans, revision: revision)
            changeScrollToken = 0
        }
        pageBody = rendered.body
        pageNeedsDiagrams = needsDiagram
        pageHTML = rendered.html
    }

    private var ownsMenuAction: Bool {
        guard let hostWindow else { return NSApp.windows.count < 2 }
        if hostWindow.isKeyWindow || hostWindow.isMainWindow { return true }
        // Menu commands can arrive while the app is inactive. A hidden window
        // that cannot become main sits beside the document, so the only visible
        // document still owns the command.
        let documents = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        return documents.count == 1 && documents[0] === hostWindow
    }

    private func open(_ url: URL) {
        if let fragment = url.fragment, !fragment.isEmpty, isCurrentDocument(url) {
            scrollToAnchor(fragment)
            return
        }
        let href = url.isFileURL ? url.lastPathComponent : url.absoluteString
        let base = fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        switch LinkResolver.resolve(href: href, baseDirectory: base) {
        case .browser(let destination):
            NSWorkspace.shared.open(destination)
        case .markdownFile(let destination):
            openInMarkme(url.isFileURL ? url : destination)
        case .anchor(let name):
            scrollToAnchor(name)
        case .ignore:
            if url.isFileURL {
                let ext = url.pathExtension.lowercased()
                if ["md", "markdown", "mdown", "mkd", "mdwn"].contains(ext) {
                    openInMarkme(url)
                }
            }
        }
    }

    private func openInMarkme(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
    }

    private func scrollToAnchor(_ name: String) {
        let decoded = name.removingPercentEncoding ?? name
        guard !decoded.isEmpty else { return }
        anchorName = decoded
        anchorToken += 1
    }

    private func isCurrentDocument(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        if sameFile(url) { return true }
        guard url.isFileURL, let fileURL else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        return path == directory
    }

    private func sameFile(_ url: URL) -> Bool {
        guard let fileURL else { return false }
        return url.path == fileURL.path
    }

    private func pageScrolled(_ line: Int) {
        let now = Date()
        guard !scrollSyncIsPaused(now), model.mode == .split else { return }
        sync.markEcho(now: now)
        sourceScrollLine = line
    }

    private func sourceScrolled(_ line: Int) {
        let now = Date()
        guard !scrollSyncIsPaused(now), model.mode == .split else { return }
        sync.markEcho(now: now)
        pageScrollLine = line
    }

    private func scrollSyncIsPaused(_ now: Date) -> Bool {
        if let ignoreScrollSyncUntil, now < ignoreScrollSyncUntil { return true }
        return sync.isEcho(now: now)
    }

    private func syncPresentationChrome() {
        guard let window = hostWindow else { return }
        let on = model.mode == .presentation
        PresentationSession.shared.set(window: window.windowNumber, active: on)
        let fullscreen = window.styleMask.contains(.fullScreen)
        let plan = PresentationChromePlanner.plan(
            presenting: on,
            fullscreen: fullscreen,
            enteredByUs: presentationFullscreen
        )
        presentationFullscreen = plan.enteredByUs
        if plan.hideToolbar {
            toolbarNeedsRestore = true
            hideToolbar = true
        } else {
            hideToolbar = false
            if toolbarNeedsRestore, !plan.toggleFullscreen {
                restoreModeToolbar(window)
            }
        }
        if plan.toggleFullscreen {
            window.toggleFullScreen(nil)
        }
    }

    /// SwiftUI drops the mode buttons when the toolbar was hidden across a
    /// fullscreen transition. Take them out and put them back on the next turn,
    /// after AppKit has finished restoring the pre-fullscreen chrome.
    private func restoreModeToolbar(_ window: NSWindow) {
        toolbarNeedsRestore = false
        hideToolbar = false
        modeToolbarMounted = false
        Task { @MainActor in
            modeToolbarMounted = true
            guard model.mode != .presentation else { return }
            window.toolbar?.isVisible = true
        }
    }

    private func startWatching() {
        guard let fileURL else { return }
        _ = fileURL.startAccessingSecurityScopedResource()
        watcher.onChange = { data, detail in
            acceptDisk(data, detail: detail)
        }
        watcher.onCompanion = {
            companionToken += 1
            refreshCompanion()
        }
        watcher.start(url: fileURL)
        refreshCompanion()
    }

    /// The spec is not the opened file. A change there redraws the page and leaves the plan's change marks alone.
    private func refreshCompanion() {
        guard let fileURL else { return }
        let spec = FeaturePage.load(
            plan: model.text,
            planDirectory: fileURL.deletingLastPathComponent(),
            excluding: fileURL
        )
        watcher.watchCompanion(spec?.url)
    }

    static let bannerKey = "markme.bannerDismissed"

    private func noteTyped(_ text: String) {
        model.text = text
        if !model.changes.isEmpty || model.changeBaseline != nil {
            model.dismissChanges()
        }
        scheduleLive()
        scheduleSave()
    }

    private func scheduleLive() {
        liveTicket += 1
        let ticket = liveTicket
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard ticket == liveTicket else { return }
            liveToken += 1
        }
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTicket += 1
        let ticket = saveTicket
        let delay = UInt64(DraftSync.saveDelay * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard ticket == saveTicket else { return }
            commitDraft()
        }
    }

    private func commitDraft() {
        guard let fileURL, !draft.saveIsBlocked else { return }
        let text = model.text
        guard text != draft.saved else {
            saveFailed = false
            return
        }
        draft.willWrite(text)
        do {
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            draft.didWrite(text)
            saveFailed = false
            settleDocument()
        } catch {
            draft.failWrite(text)
            saveFailed = true
        }
    }

    private func settleDocument() {
        settleMarkdownWindow(hostWindow)
    }

    private func keepMine() {
        draft.keepMine()
        saveTicket += 1
        commitDraft()
    }

    private func useDisk() {
        guard let text = draft.takeDisk() else { return }
        saveTicket += 1
        model.text = text
        if !model.changes.isEmpty || model.changeBaseline != nil {
            model.dismissChanges()
        }
        saveFailed = false
        scheduleLive()
    }

    private func acceptDisk(_ data: Data?, detail: String) {
        guard let data, let disk = String(data: data, encoding: .utf8) else {
            if draft.pendingWrite != nil || draft.echoedWrite != nil || draft.saveIsBlocked || model.text != draft.saved {
                return
            }
            model.reload(data: data, failureDetail: detail)
            return
        }
        switch draft.receive(disk: disk, buffer: model.text) {
        case .same, .continued:
            break
        case .reload:
            model.reload(data: data)
        case .conflict:
            saveTicket += 1
        }
    }
}

private enum HighlighterLibrary {
    static let script: String = {
        load(resource: "highlight.min", ext: "js") + "\n" + load(resource: "dart", ext: "js")
    }()

    private static func load(resource: String, ext: String) -> String {
        if let url = Bundle.main.url(forResource: resource, withExtension: ext),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/\(resource).\(ext)")
        return (try? String(contentsOf: dev, encoding: .utf8)) ?? ""
    }
}

private enum MermaidLibrary {
    static let script: String = {
        let raw: String
        if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            raw = text
        } else {
            let dev = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("App/Resources/mermaid.min.js")
            raw = (try? String(contentsOf: dev, encoding: .utf8)) ?? ""
        }
        return raw.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }()
}

extension Notification.Name {
    static let markmeFind = Notification.Name("markme.find")
    static let markmeCopyLocation = Notification.Name("markme.copyLocation")
    static let markmeSave = Notification.Name("markme.save")
    static let markmeMode = Notification.Name("markme.mode")
    static let markmeZoom = Notification.Name("markme.zoom")
    static let markmeSlide = Notification.Name("markme.slide")
}

@MainActor
enum ZoomKeys {
    static func installCompanion() {
        if attach() { return }
        Task { @MainActor in _ = attach() }
    }

    @discardableResult
    private static func attach() -> Bool {
        let titles = [
            ReaderCopy.string(.zoomIn, languageCode: "pt"),
            ReaderCopy.string(.zoomIn, languageCode: "en"),
        ]
        guard let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { submenu in
            submenu.items.contains { titles.contains($0.title) && !$0.isHidden }
        }) else { return false }
        guard let visible = menu.items.first(where: { titles.contains($0.title) && !$0.isHidden }) else { return false }
        let companion = visible.keyEquivalent == "+" ? "=" : "+"
        guard !menu.items.contains(where: { $0.isHidden && $0.keyEquivalent == companion }) else { return true }
        let extra = NSMenuItem(title: visible.title, action: #selector(ZoomBridge.zoomIn(_:)), keyEquivalent: companion)
        extra.keyEquivalentModifierMask = .command
        extra.target = ZoomBridge.shared
        extra.isHidden = true
        extra.allowsKeyEquivalentWhenHidden = true
        menu.addItem(extra)
        return true
    }
}

final class WheelZoomMonitor: @unchecked Sendable {
    static let shared = WheelZoomMonitor()
    static let windowKey = "window"
    private let lock = NSLock()
    private var wheel = WheelZoom()
    private var installed = false

    func install() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.transform(event) ?? event
        }
    }

    private func transform(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control) else {
            lock.lock()
            wheel.endGesture()
            lock.unlock()
            return event
        }
        lock.lock()
        let actions = wheel.actions(
            deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas
        )
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            wheel.endGesture()
        }
        lock.unlock()
        for action in actions {
            NotificationCenter.default.post(
                name: .markmeZoom,
                object: action.rawValue,
                userInfo: [Self.windowKey: event.windowNumber]
            )
        }
        return nil
    }
}

final class PresentationSession: @unchecked Sendable {
    static let shared = PresentationSession()
    static let windowKey = "window"
    private let lock = NSLock()
    private var windows = Set<Int>()
    private var installed = false

    func install() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.transform(event) ?? event
        }
    }

    func set(window: Int, active: Bool) {
        lock.lock()
        if active {
            windows.insert(window)
        } else {
            windows.remove(window)
        }
        lock.unlock()
    }

    private func transform(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return event
        }
        lock.lock()
        let active = windows.contains(event.windowNumber)
        lock.unlock()
        guard active else { return event }
        let action: String?
        switch event.keyCode {
        case 124, 125, 49, 36, 76, 121:
            action = "next"
        case 123, 126, 116:
            action = "previous"
        case 115:
            action = "first"
        case 53:
            action = "exit"
        default:
            action = nil
        }
        guard let action else { return event }
        NotificationCenter.default.post(
            name: .markmeSlide,
            object: action,
            userInfo: [Self.windowKey: event.windowNumber]
        )
        return nil
    }
}

@MainActor
final class ZoomBridge: NSObject {
    static let shared = ZoomBridge()

    @objc func zoomIn(_ sender: Any?) {
        NotificationCenter.default.post(name: .markmeZoom, object: ReaderZoomAction.zoomIn.rawValue)
    }
}

private struct WindowPlacement: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PlacementView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PlacementView else { return }
        view.onWindow = onWindow
    }

    final class PlacementView: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }
        private var placed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
            schedule()
        }

        private func schedule() {
            DispatchQueue.main.async { [weak self] in self?.centerIfOffscreen(lock: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.centerIfOffscreen(lock: true)
            }
        }

        private func centerIfOffscreen(lock: Bool) {
            guard let window, !placed else { return }
            let frame = window.frame
            guard frame.width > 40, frame.height > 40 else { return }
            let visible = NSScreen.screens.contains { screen in
                let overlap = frame.intersection(screen.visibleFrame)
                return !overlap.isNull && overlap.width > 80 && overlap.height > 80
            }
            if !visible {
                window.center()
            }
            if visible || lock {
                placed = true
            }
        }
    }
}

final class FileWatcher: ObservableObject {
    var onChange: (Data?, String) -> Void = { _, _ in }
    var onCompanion: () -> Void = {}
    private var plan = Watch()
    private var companion = Watch()

    func start(url: URL) {
        plan.stop()
        plan.url = url
        plan.arm { [weak self] reopen in
            guard let self else { return }
            if reopen, let url = self.plan.url {
                self.start(url: url)
            }
            guard let url = self.plan.url else { return }
            let outcome = Self.read(url)
            self.onChange(outcome.data, outcome.detail)
        }
    }

    /// Pass nil to stop. The same path does not restart the watch.
    func watchCompanion(_ url: URL?) {
        guard url?.path != companion.url?.path else { return }
        companion.stop()
        guard let url else { return }
        companion.url = url
        companion.arm { [weak self] reopen in
            guard let self else { return }
            if reopen, let url = self.companion.url {
                self.companion.stop()
                self.watchCompanion(url)
            }
            self.onCompanion()
        }
    }

    func stop() {
        plan.stop()
        companion.stop()
    }

    private static func read(_ url: URL) -> (data: Data?, detail: String) {
        do {
            return (try Data(contentsOf: url), "")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private final class Watch {
        var source: DispatchSourceFileSystemObject?
        var pending: DispatchWorkItem?
        var descriptor: CInt = -1
        var url: URL?

        func stop() {
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
            descriptor = -1
            url = nil
        }

        func arm(_ fire: @escaping (Bool) -> Void) {
            guard let url else { return }
            descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .link],
                queue: .global(qos: .utility)
            )
            let descriptor = descriptor
            source.setEventHandler { [weak self, weak source] in
                let flags = source?.data ?? []
                let reopen = flags.contains(.rename) || flags.contains(.delete) || flags.contains(.link)
                self?.schedule(reopen: reopen, fire: fire)
            }
            source.setCancelHandler {
                if descriptor >= 0 { close(descriptor) }
            }
            source.resume()
            self.source = source
        }

        private func schedule(reopen: Bool, fire: @escaping (Bool) -> Void) {
            pending?.cancel()
            let work = DispatchWorkItem {
                fire(reopen)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}
