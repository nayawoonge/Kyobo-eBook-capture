import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let apps = NSPopUpButton()
    private var runningApps: [NSRunningApplication] = []
    private let mode = NSPopUpButton()
    private let pageCount = NSTextField(string: "3")
    private let interval = NSTextField(string: "1.5")
    private let regionLabel = NSTextField(wrappingLabelWithString: "아직 선택하지 않았습니다")
    private let pointLabel = NSTextField(wrappingLabelWithString: "방향키가 안 되면 클릭 위치를 지정하세요")
    private let status = NSTextField(wrappingLabelWithString: "교보 앱에서 책을 열고, 아래 순서대로 준비하세요.")
    private let folderLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let preview = NSImageView()
    private var controls: [NSControl] = []
    private var stopButton: NSButton!
    private var region: CaptureRegion?
    private var clickPoint: CGPoint?
    private var overlays: [NSWindow] = []
    private var isSelecting = false
    private var task: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var requestedScreenPermission = false
    private var requestedAccessibilityPermission = false
    private var showingPermissionStatus = false
    private var lastOutput: URL?
    private var root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Captures")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        refreshApps()
        folderLabel.stringValue = root.path
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                if self?.task != nil { self?.stopCapture(); return nil }
                if self?.overlays.isEmpty == false { self?.closeSelection(); return nil }
            }
            return event
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Checking status must never trigger another system permission prompt.
        if showingPermissionStatus, task == nil, !isSelecting { showPermissionStatus() }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "PageCapture 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu
        menu.addItem(app)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return field
    }
    private func button(_ text: String, _ action: Selector, track: Bool = true) -> NSButton {
        let button = NSButton(title: text, target: self, action: action)
        button.bezelStyle = .rounded
        if track { controls.append(button) }
        return button
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 790), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PageCapture · 책 화면을 PDF로"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 25)
        ])
        stack.addArrangedSubview(label("PageCapture 1.1", size: 29, bold: true))
        let subtitle = label("영역 선택 → 페이지 넘김 → PNG + PDF 저장", size: 14)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(row([
            button("화면 기록 권한", #selector(screenPermission)),
            button("손쉬운 사용 권한", #selector(accessibilityPermission)),
            button("권한 상태 확인", #selector(showPermissionStatus))
        ]))
        stack.addArrangedSubview(label("1. 캡처할 앱", bold: true))
        apps.widthAnchor.constraint(equalToConstant: 395).isActive = true
        apps.target = self
        apps.action = #selector(appChanged)
        stack.addArrangedSubview(row([apps, button("새로고침", #selector(refreshApps))]))
        stack.addArrangedSubview(label("2. 본문 영역과 페이지 넘김", bold: true))
        regionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(row([button("본문 영역 선택", #selector(selectRegion)), regionLabel]))
        mode.addItems(withTitles: ["오른쪽 방향키 →", "왼쪽 방향키 ←", "Page Down", "Space", "지정한 위치 클릭"])
        mode.widthAnchor.constraint(equalToConstant: 215).isActive = true
        stack.addArrangedSubview(row([mode, button("넘김 위치 지정", #selector(selectPoint))]))
        pointLabel.font = .systemFont(ofSize: 12)
        pointLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(pointLabel)
        stack.addArrangedSubview(label("3. 저장 설정", bold: true))
        pageCount.widthAnchor.constraint(equalToConstant: 65).isActive = true
        interval.widthAnchor.constraint(equalToConstant: 65).isActive = true
        stack.addArrangedSubview(row([label("캡처 장수"), pageCount, label("장    넘긴 뒤 대기"), interval, label("초")]))
        stack.addArrangedSubview(row([button("저장 폴더 변경", #selector(chooseFolder)), button("결과 폴더 열기", #selector(openFolder), track: false)]))
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.maximumNumberOfLines = 2
        folderLabel.widthAnchor.constraint(equalToConstant: 638).isActive = true
        stack.addArrangedSubview(folderLabel)
        let start = button("캡처 시작", #selector(startCapture))
        start.contentTintColor = .systemOrange
        stopButton = button("중지 · Esc", #selector(stopCapture), track: false)
        stopButton.isEnabled = false
        stack.addArrangedSubview(row([button("한 장 시험", #selector(testCapture)), start, stopButton, button("이미지 폴더 → PDF", #selector(rebuildPDF))]))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.widthAnchor.constraint(equalToConstant: 638).isActive = true
        stack.addArrangedSubview(progressBar)
        status.widthAnchor.constraint(equalToConstant: 638).isActive = true
        status.maximumNumberOfLines = 4
        stack.addArrangedSubview(status)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 638).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 125).isActive = true
        stack.addArrangedSubview(preview)
        let tip = label("실행 중 창 위치·크기를 유지하세요. 다른 앱으로 전환하면 캡처가 중단됩니다.", size: 11)
        tip.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tip)
        controls += [apps, mode, pageCount, interval]
    }

    @objc private func refreshApps() {
        let previous = targetApp?.processIdentifier
        runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        apps.removeAllItems()
        apps.addItems(withTitles: runningApps.map {
            if ($0.bundleIdentifier ?? "").lowercased().contains("kyobo") { return "교보eBook" }
            return $0.localizedName ?? "앱 \($0.processIdentifier)"
        })
        if let index = runningApps.firstIndex(where: { $0.processIdentifier == previous }) {
            apps.selectItem(at: index)
        } else if let index = runningApps.firstIndex(where: {
            let name = ($0.localizedName ?? "") + ($0.bundleIdentifier ?? "")
            return name.lowercased().contains("kyobo") || name.contains("교보")
        }) { apps.selectItem(at: index) }
    }
    private var targetApp: NSRunningApplication? {
        let index = apps.indexOfSelectedItem
        return runningApps.indices.contains(index) ? runningApps[index] : nil
    }
    @objc private func appChanged() {
        region = nil
        clickPoint = nil
        regionLabel.stringValue = "앱이 바뀌었습니다. 본문 영역을 다시 선택하세요."
        pointLabel.stringValue = "방향키가 안 되면 클릭 위치를 지정하세요"
    }
    @objc private func showPermissionStatus() {
        showingPermissionStatus = true
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        let summary = "화면 기록: \(screen ? "허용됨" : "인식 안 됨") · 손쉬운 사용: \(accessibility ? "허용됨" : "인식 안 됨")"
        if !screen || !accessibility {
            status.stringValue = summary + "\n설정에서 이미 켰다면 앱을 완전히 종료 후 다시 실행하세요. 그래도 인식되지 않으면 시스템 설정의 PageCapture 항목을 제거한 뒤 현재 앱을 다시 추가하세요."
        } else {
            status.stringValue = summary + "\n권한이 확인되었습니다. 본문 영역을 선택하고 ‘한 장 시험’을 실행하세요."
        }
    }
    @objc private func screenPermission() {
        showingPermissionStatus = true
        if CGPreflightScreenCaptureAccess() { showPermissionStatus(); return }
        // Only an explicit click on this button may request permission, once per run.
        if !requestedScreenPermission {
            requestedScreenPermission = true
            if CGRequestScreenCaptureAccess() { showPermissionStatus(); return }
        }
        showPermissionStatus()
        openSettings("Privacy_ScreenCapture")
    }
    @objc private func accessibilityPermission() {
        showingPermissionStatus = true
        if AXIsProcessTrusted() { showPermissionStatus(); return }
        if !requestedAccessibilityPermission {
            requestedAccessibilityPermission = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options) { showPermissionStatus(); return }
        }
        showPermissionStatus()
        openSettings("Privacy_Accessibility")
    }
    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { root = url; folderLabel.stringValue = url.path }
    }
    @objc private func openFolder() {
        let path = lastOutput ?? root
        if FileManager.default.fileExists(atPath: path.path) { NSWorkspace.shared.open(path) }
        else { status.stringValue = "첫 캡처를 저장하면 결과 폴더가 생성됩니다." }
    }
    @objc private func selectRegion() { beginSelection(pointMode: false) }
    @objc private func selectPoint() { beginSelection(pointMode: true) }
    private func beginSelection(pointMode: Bool) {
        guard !isSelecting, task == nil else { return }
        guard let target = targetApp, !target.isTerminated else { status.stringValue = "교보 앱을 열고 앱 목록을 새로고침하세요."; return }
        showingPermissionStatus = false
        // Keep the application alive throughout the transition to selection.
        isSelecting = true
        status.stringValue = pointMode ? "책 화면의 다음 페이지 버튼을 클릭하세요. Esc로 취소할 수 있습니다." : "책 본문의 왼쪽 위에서 오른쪽 아래까지 드래그하세요. Esc로 취소할 수 있습니다."
        target.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.isSelecting else { return }
            guard !NSScreen.screens.isEmpty else {
                self.closeSelection()
                self.status.stringValue = "디스플레이를 찾지 못했습니다. 화면 연결을 확인하고 다시 선택하세요."
                return
            }
            for screen in NSScreen.screens {
                let overlay = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                overlay.title = pointMode ? "PageCapture · 넘김 위치 선택" : "PageCapture · 본문 영역 선택"
                overlay.isReleasedWhenClosed = false
                overlay.hidesOnDeactivate = false
                overlay.hasShadow = false
                overlay.isOpaque = false
                overlay.backgroundColor = .clear
                overlay.level = .screenSaver
                overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(screen: screen, pointMode: pointMode, selected: { [weak self] screen, rect in
                    guard let self else { return }
                    if pointMode {
                        self.clickPoint = CaptureRegion.quartzPoint(rect.origin, screenFrame: screen.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
                        self.mode.selectItem(at: 4)
                        self.pointLabel.stringValue = "클릭 위치 지정됨 (\(Int(self.clickPoint!.x)), \(Int(self.clickPoint!.y)))"
                    } else if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        self.region = CaptureRegion(displayID: id.uint32Value, sourceRect: CaptureRegion.topLeftRect(rect, height: screen.frame.height), screenFrame: screen.frame, scale: screen.backingScaleFactor)
                        self.regionLabel.stringValue = "\(Int(rect.width * screen.backingScaleFactor)) × \(Int(rect.height * screen.backingScaleFactor)) px"
                    }
                    self.closeSelection()
                    self.status.stringValue = pointMode ? "넘김 위치를 저장했습니다. ‘한 장 시험’으로 본문 영역을 먼저 확인하세요." : "본문 영역을 저장했습니다. ‘한 장 시험’을 눌러 범위와 화질을 확인하세요."
                }, cancelled: { [weak self] in self?.closeSelection() })
                overlay.contentView = view
                self.overlays.append(overlay)
                overlay.makeKeyAndOrderFront(nil)
                overlay.makeFirstResponder(view)
            }
            // Never leave a gap with no visible windows while preparing the overlay.
            self.window.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func closeSelection() {
        // Restore the main window before removing the last selection window.
        window.makeKeyAndOrderFront(nil)
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        isSelecting = false
        status.stringValue = "선택을 취소했습니다. ‘본문 영역 선택’을 눌러 다시 드래그하세요."
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func testCapture() { beginCapture(test: true) }
    @objc private func startCapture() { beginCapture(test: false) }
    private func beginCapture(test: Bool) {
        guard task == nil else { return }
        guard let region else { status.stringValue = "먼저 ‘본문 영역 선택’을 눌러 캡처할 영역을 정하세요."; return }
        guard let target = targetApp, !target.isTerminated else { status.stringValue = "대상 앱을 다시 선택하세요."; return }
        guard let pages = Int(pageCount.stringValue), (1...5000).contains(pages),
              let delay = Double(interval.stringValue), delay.isFinite, (0.3...30).contains(delay) else {
            status.stringValue = "장수는 1~5000, 대기 시간은 0.3~30초로 입력하세요."
            return
        }
        let selectedMode = mode.indexOfSelectedItem
        let point = clickPoint
        guard test || selectedMode != 4 || point != nil else { status.stringValue = "‘넘김 위치 지정’으로 다음 페이지 버튼의 위치를 먼저 지정하세요."; return }
        let requested = test ? 1 : pages
        // Never prompt automatically when the user starts a capture. A one-page
        // screenshot does not send input and therefore needs no Accessibility grant.
        guard CGPreflightScreenCaptureAccess() else { showPermissionStatus(); return }
        let accessibilityGranted = AXIsProcessTrusted()
        guard requested == 1 || accessibilityGranted else { showPermissionStatus(); return }
        showingPermissionStatus = false
        setRunning(true)
        progressBar.maxValue = Double(requested)
        progressBar.doubleValue = 0
        preview.image = nil
        status.stringValue = accessibilityGranted ? "3초 후 시작합니다. Esc로 중지할 수 있습니다." : "3초 후 한 장을 저장합니다. 다른 앱으로 전환하면 중단됩니다."
        if accessibilityGranted {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.stopCapture() }
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.setRunning(false)
                if let monitor = self.globalMonitor { NSEvent.removeMonitor(monitor); self.globalMonitor = nil }
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == region.displayID }),
                      let application = content.applications.first(where: { $0.processID == target.processIdentifier }) else {
                    throw CaptureError("선택한 화면 또는 앱을 찾을 수 없습니다. 앱을 열고 본문 영역을 다시 선택하세요.")
                }
                let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = region.sourceRect
                configuration.width = Int((region.sourceRect.width * region.scale).rounded())
                configuration.height = Int((region.sourceRect.height * region.scale).rounded())
                configuration.showsCursor = false
                configuration.captureResolution = .best
                configuration.scalesToFit = true
                self.window.orderOut(nil)
                target.activate(options: [.activateAllWindows])
                try await CaptureEngine.wait(3)
                let validate = {
                    guard !target.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                        throw CaptureError("대상 앱에서 벗어나 캡처를 중단했습니다. 책 화면을 다시 열고 이어서 실행하세요.")
                    }
                    guard let screen = NSScreen.screens.first(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID
                    }), screen.frame == region.screenFrame, screen.backingScaleFactor == region.scale else {
                        throw CaptureError("디스플레이 설정이 바뀌었습니다. 본문 영역을 다시 선택하세요.")
                    }
                }
                let result = try await CaptureEngine().run(root: self.root, pages: requested, interval: delay, pageSize: region.sourceRect.size, capture: {
                    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                }, turn: {
                    try validate()
                    try self.turnPage(mode: selectedMode, point: point, pid: target.processIdentifier)
                }, validate: validate, progress: { count in
                    self.progressBar.doubleValue = Double(count)
                    self.status.stringValue = "\(count) / \(requested)장 저장 · Esc 중지"
                })
                self.lastOutput = result.directory
                self.preview.image = NSImage(contentsOf: result.directory.appendingPathComponent("0001.png"))
                self.status.stringValue = "\(result.message)\n\(result.saved)장 저장\(result.pdf == nil ? "" : " · book.pdf 생성됨")\(test ? " · 한 장 시험에서는 페이지를 넘기지 않습니다." : "")"
            } catch is CancellationError {
                self.status.stringValue = "캡처 시작 전에 중지했습니다."
            } catch {
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    private func turnPage(mode: Int, point: CGPoint?, pid: pid_t) throws {
        if mode == 4, let point {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                throw CaptureError("클릭 이벤트를 만들 수 없습니다.")
            }
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            let keys: [CGKeyCode] = [124, 123, 121, 49]
            guard keys.indices.contains(mode),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: keys[mode], keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: keys[mode], keyDown: false) else {
                throw CaptureError("키 입력 이벤트를 만들 수 없습니다.")
            }
            down.flags = []
            up.flags = []
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }
    @objc private func stopCapture() {
        task?.cancel()
        status.stringValue = "중지하는 중입니다. 저장한 페이지의 PDF를 마무리합니다."
    }
    private func setRunning(_ running: Bool) {
        controls.forEach { $0.isEnabled = !running }
        stopButton.isEnabled = running
    }
    @objc private func rebuildPDF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "번호순 이미지가 저장된 폴더를 선택하세요."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = "combined-\(UUID().uuidString.prefix(6)).pdf"
        save.directoryURL = directory
        guard save.runModal() == .OK, let output = save.url else { return }
        setRunning(true)
        stopButton.isEnabled = false
        status.stringValue = "이미지에서 PDF를 만드는 중입니다."
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try combineImages(imageFiles(in: directory), into: output) }.value
                lastOutput = output.deletingLastPathComponent()
                status.stringValue = "PDF 생성 완료: \(output.lastPathComponent)"
            } catch { status.stringValue = error.localizedDescription }
            setRunning(false)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if task != nil { stopCapture(); return false }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isSelecting && task == nil
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isSelecting { overlays.last?.makeKeyAndOrderFront(nil) }
        else { window.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if task != nil { stopCapture(); return .terminateCancel }
        return .terminateNow
    }
}

if CommandLine.arguments.contains("--self-test") {
    let index = CommandLine.arguments.firstIndex(of: "--self-test")!
    let directory = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "/tmp/pagecapture-tests"
    Task { @MainActor in
        do { try await runSelfTests(directory: URL(fileURLWithPath: directory)); exit(0) }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
