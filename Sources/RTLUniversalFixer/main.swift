import AppKit
import AVFoundation
import Carbon.HIToolbox
import NaturalLanguage
import QuartzCore
import Vision

private let hotkeySignature: OSType = 0x52544C46 // RTLF
private let showSelectionHotkeyId: UInt32 = 1
private let showClipboardHotkeyId: UInt32 = 2
private let ocrRegionHotkeyId: UInt32 = 3
private let pickContainerHotkeyId: UInt32 = 4
private let defaults = UserDefaults.standard

enum DirectionMode: Int {
    case auto = 0
    case rtl = 1
    case ltr = 2
}

enum ViewerStyle: Int {
    case comfortable = 0
    case compact = 1
    case large = 2
    case document = 3
}

private func eventHotKeyId(_ id: UInt32) -> EventHotKeyID {
    EventHotKeyID(signature: hotkeySignature, id: id)
}

private func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

private func rtlWrapped(_ text: String) -> String {
    let rli = "\u{2067}"
    let pdi = "\u{2069}"
    let rlm = "\u{200F}"
    return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            let raw = String(line)
            if raw.isEmpty { return raw }
            if raw.hasPrefix(rli) && raw.hasSuffix(pdi) { return raw }
            return rlm + rli + raw + pdi
        }
        .joined(separator: "\n")
}

private func rtlCleaned(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\u{200E}", with: "")
        .replacingOccurrences(of: "\u{200F}", with: "")
        .replacingOccurrences(of: "\u{202A}", with: "")
        .replacingOccurrences(of: "\u{202B}", with: "")
        .replacingOccurrences(of: "\u{202C}", with: "")
        .replacingOccurrences(of: "\u{202D}", with: "")
        .replacingOccurrences(of: "\u{202E}", with: "")
        .replacingOccurrences(of: "\u{2066}", with: "")
        .replacingOccurrences(of: "\u{2067}", with: "")
        .replacingOccurrences(of: "\u{2068}", with: "")
        .replacingOccurrences(of: "\u{2069}", with: "")
}

private func normalizedForViewing(_ text: String) -> String {
    rtlCleaned(text)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func containsRTL(_ text: String) -> Bool {
    text.range(of: #"[\u0591-\u07FF\uFB1D-\uFDFF\uFE70-\uFEFC]"#, options: .regularExpression) != nil
}

private func looksLikeCode(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return false }
    if trimmed.hasPrefix("```") || trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") { return true }
    if trimmed.range(of: #"^(import|export|const|let|var|func|class|struct|enum|if|for|while|return|def|from|sudo|npm|pnpm|yarn|git|cd|ls|cat|curl)\b"#, options: .regularExpression) != nil {
        return true
    }
    let symbols = trimmed.filter { "{}[]();=<>|/&*".contains($0) }.count
    return symbols >= 3 && !containsRTL(trimmed)
}

private func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
}

private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    if let string = axAttribute(element, attribute) as? String {
        let cleaned = normalizedForViewing(string)
        return cleaned.isEmpty ? nil : cleaned
    }
    if let attributed = axAttribute(element, attribute) as? NSAttributedString {
        let cleaned = normalizedForViewing(attributed.string)
        return cleaned.isEmpty ? nil : cleaned
    }
    return nil
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    let attributes: [CFString] = [
        kAXChildrenAttribute as CFString,
        "AXVisibleChildren" as CFString,
        "AXRows" as CFString,
        "AXContents" as CFString,
    ]
    var children: [AXUIElement] = []
    var seen = Set<CFHashCode>()

    for attribute in attributes {
        let values = (axAttribute(element, attribute) as? [AXUIElement]) ?? []
        for child in values {
            let hash = CFHash(child)
            guard !seen.contains(hash) else { continue }
            seen.insert(hash)
            children.append(child)
        }
    }
    return children
}

private func axParent(_ element: AXUIElement) -> AXUIElement? {
    axAttribute(element, kAXParentAttribute as CFString) as! AXUIElement?
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = axAttribute(element, kAXPositionAttribute as CFString),
          let sizeValue = axAttribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 1,
          size.height > 1 else { return nil }
    return CGRect(origin: position, size: size)
}

private func axRole(_ element: AXUIElement) -> String {
    (axAttribute(element, kAXRoleAttribute as CFString) as? String) ?? "Element"
}

private func axDeepestElement(at point: CGPoint, startingAt root: AXUIElement) -> AXUIElement {
    var current = root
    var visited = Set<CFHashCode>()

    for _ in 0..<40 {
        let hash = CFHash(current)
        guard !visited.contains(hash) else { break }
        visited.insert(hash)

        let candidates = axChildren(current)
            .compactMap { child -> (AXUIElement, CGRect)? in
                guard let frame = axFrame(child), frame.contains(point) else { return nil }
                return (child, frame)
            }
            .sorted { left, right in
                left.1.width * left.1.height < right.1.width * right.1.height
            }

        guard let next = candidates.first?.0 else { break }
        current = next
    }

    return current
}

private func applicationElementUnderPointer(_ point: CGPoint) -> AXUIElement? {
    let ownPID = getpid()
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []

    for window in windows {
        guard let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
              pidNumber.int32Value != ownPID,
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.contains(point) else { continue }

        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard alpha > 0.01, layer == 0 else { continue }
        return AXUIElementCreateApplication(pidNumber.int32Value)
    }

    return nil
}

private func enableDetailedAccessibility(for application: AXUIElement) {
    let trueValue = kCFBooleanTrue as CFTypeRef
    _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, trueValue)
    _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, trueValue)
}

private func axText(from root: AXUIElement) -> String {
    var lines: [String] = []
    var seenLines = Set<String>()
    var visited = Set<CFHashCode>()
    var nodeCount = 0
    var characterCount = 0
    let maximumNodes = 12_000
    let maximumCharacters = 300_000

    func append(_ text: String?) {
        guard let text else { return }
        let normalized = normalizedForViewing(text)
        guard !normalized.isEmpty, !seenLines.contains(normalized) else { return }
        seenLines.insert(normalized)
        lines.append(normalized)
        characterCount += normalized.count + 1
    }

    func visit(_ element: AXUIElement, depth: Int) {
        guard nodeCount < maximumNodes, characterCount < maximumCharacters, depth < 80 else { return }
        let hash = CFHash(element)
        guard !visited.contains(hash) else { return }
        visited.insert(hash)
        nodeCount += 1

        let children = axChildren(element)
        append(axString(element, kAXTitleAttribute as CFString))
        append(axString(element, kAXDescriptionAttribute as CFString))
        append(axString(element, kAXValueAttribute as CFString))
        append(axString(element, kAXSelectedTextAttribute as CFString))
        append(axString(element, kAXHelpAttribute as CFString))
        append(axString(element, kAXPlaceholderValueAttribute as CFString))

        for child in children {
            visit(child, depth: depth + 1)
        }
    }

    visit(root, depth: 0)
    return lines.joined(separator: "\n")
}

final class ElementPickerHighlightView: NSView {
    var label = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemTeal.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.systemTeal.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        guard bounds.width > 180, bounds.height > 28 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemTeal.withAlphaComponent(0.92),
        ]
        let text = NSAttributedString(string: "  \(label)  ", attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: 6, y: max(5, bounds.height - size.height - 6)))
    }
}

final class ElementPickerController {
    private let onPick: (AXUIElement) -> Void
    private let onCancel: () -> Void
    private let highlightView = ElementPickerHighlightView()
    private var highlightWindow: NSWindow?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var chain: [AXUIElement] = []
    private var selectedDepth = 0
    private var lastPoint = CGPoint.zero
    private var displayedFrame = CGRect.null
    private var accessibilityEnabledPIDs = Set<pid_t>()

    init(onPick: @escaping (AXUIElement) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func start() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = highlightView
        window.setAccessibilityElement(false)
        highlightView.setAccessibilityElement(false)
        highlightWindow = window

        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .scrollWheel,
            .keyDown,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let picker = Unmanaged<ElementPickerController>.fromOpaque(userInfo).takeUnretainedValue()
                return picker.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            stop()
            onCancel()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateAtPointer()
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        chain.removeAll()
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged:
            update(at: event.location)
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            moveSelection(delta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)))
            return nil
        case .leftMouseDown:
            confirmSelection()
            return nil
        case .leftMouseUp:
            return nil
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                cancel()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func updateAtPointer() {
        guard let point = CGEvent(source: nil)?.location else { return }
        update(at: point)
    }

    private func update(at point: CGPoint) {
        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 1, !chain.isEmpty { return }
        lastPoint = point

        guard let application = applicationElementUnderPointer(point) else {
            highlightWindow?.orderOut(nil)
            return
        }

        var applicationPID: pid_t = 0
        var enabledNow = false
        if AXUIElementGetPid(application, &applicationPID) == .success,
           !accessibilityEnabledPIDs.contains(applicationPID) {
            enableDetailedAccessibility(for: application)
            accessibilityEnabledPIDs.insert(applicationPID)
            enabledNow = true
        }

        if enabledNow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.lastPoint = CGPoint(x: -10_000, y: -10_000)
                self?.updateAtPointer()
            }
        }

        var hitElement: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(
            application,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        let deepest: AXUIElement
        if hitStatus == .success, let hitElement {
            deepest = hitElement
        } else {
            deepest = axDeepestElement(at: point, startingAt: application)
        }
        chain = [deepest]
        var current = deepest
        for _ in 0..<24 {
            guard let parent = axParent(current), axFrame(parent) != nil else { break }
            chain.append(parent)
            current = parent
        }
        selectedDepth = 0
        updateHighlight()
    }

    private func moveSelection(delta: CGFloat) {
        guard !chain.isEmpty, abs(delta) > 0.1 else { return }
        if delta > 0 {
            selectedDepth = min(selectedDepth + 1, chain.count - 1)
        } else {
            selectedDepth = max(selectedDepth - 1, 0)
        }
        updateHighlight()
    }

    private func updateHighlight() {
        guard chain.indices.contains(selectedDepth), let frame = axFrame(chain[selectedDepth]) else { return }
        let desktopFrame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let appKitFrame = NSRect(
            x: frame.minX,
            y: desktopFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        highlightView.label = "\(axRole(chain[selectedDepth])) • Scroll: parent/child • Click: capture • Esc: cancel"
        if displayedFrame != appKitFrame {
            displayedFrame = appKitFrame
            highlightWindow?.setFrame(appKitFrame, display: true)
            highlightView.needsDisplay = true
        }
        if highlightWindow?.isVisible != true {
            highlightWindow?.orderFrontRegardless()
        }
    }

    private func confirmSelection() {
        guard chain.indices.contains(selectedDepth) else { return }
        let selected = chain[selectedDepth]
        stop()
        onPick(selected)
    }

    private func cancel() {
        stop()
        onCancel()
    }
}

final class ScreenSelectionOverlay: NSWindowController {
    private let overlayView: SelectionView

    init(screen: NSScreen, onComplete: @escaping (NSScreen, NSRect) -> Void, onCancel: @escaping () -> Void) {
        overlayView = SelectionView(screen: screen, onComplete: onComplete, onCancel: onCancel)
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = overlayView
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SelectionView: NSView {
    private let targetScreen: NSScreen
    private let onComplete: (NSScreen, NSRect) -> Void
    private let onCancel: () -> Void
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    init(screen: NSScreen, onComplete: @escaping (NSScreen, NSRect) -> Void, onCancel: @escaping () -> Void) {
        targetScreen = screen
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape {
            onCancel()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        let localRect = selectionRect()
        guard localRect.width >= 8, localRect.height >= 8 else {
            onCancel()
            return
        }
        let screenRect = NSRect(
            x: targetScreen.frame.minX + localRect.minX,
            y: targetScreen.frame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        onComplete(targetScreen, screenRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let startPoint, let currentPoint else { return }
        let rect = NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.systemTeal.withAlphaComponent(0.18).setFill()
        rect.fill()
        NSColor.systemTeal.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func selectionRect() -> NSRect {
        guard let startPoint, let currentPoint else { return .zero }
        return NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }
}

final class RTLViewerWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let textView = NSTextView()
    private let titleLabel = NSTextField(labelWithString: "RTL Viewer")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let sectionLabel = NSTextField(labelWithString: "Translate")
    private let sourceCardLabel = NSTextField(labelWithString: "")
    private let translationCardLabel = NSTextField(labelWithString: "")
    private let sourceBadgeLabel = NSTextField(labelWithString: "Arabic")
    private let targetBadgeLabel = NSTextField(labelWithString: "English")
    private let cardArrowLabel = NSTextField(labelWithString: "→")
    private let statusButton = NSButton()
    private let speakerButton = NSButton()
    private let footerMenuButton = NSButton()
    private let copyTranslationButton = NSButton()
    private let actionsButton = NSButton()
    private let directionPopup = NSPopUpButton()
    private let stylePopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let readingToolbar = NSStackView()
    private let readingToolbarSeparator = NSBox()
    private let toolbarToggleButton = NSButton()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private var currentText = ""
    private var currentSource = "Text"
    private var translatedText: String?
    private var translationRequest: URLSessionDataTask?
    private var translationGeneration = UUID()
    private var isApplyingAutomaticSize = false
    private var userIsLiveResizing = false
    private var preferredWindowHeight: CGFloat {
        get {
            let saved = defaults.double(forKey: "viewerPreferredHeightV3")
            return saved > 0 ? CGFloat(saved) : 520
        }
        set {
            defaults.set(Double(max(newValue, 360)), forKey: "viewerPreferredHeightV3")
        }
    }
    private var directionMode: DirectionMode = DirectionMode(rawValue: defaults.integer(forKey: "directionMode")) ?? .auto
    private var viewerStyle: ViewerStyle = ViewerStyle(rawValue: defaults.integer(forKey: "viewerStyle")) ?? .comfortable
    private var fontSize: CGFloat {
        get {
            let saved = defaults.double(forKey: "viewerFontSize")
            return saved == 0 ? 18 : CGFloat(saved)
        }
        set {
            defaults.set(Double(min(max(newValue, 13), 28)), forKey: "viewerFontSize")
        }
    }
    private let contentInset: CGFloat = 16
    private let cardCornerRadius: CGFloat = 22
    private let windowCornerRadius: CGFloat = 18
    private let speechSynthesizer = AVSpeechSynthesizer()

    private static func sanitizedFrame(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 760, height: 520)
        }
        let visible = screen.visibleFrame
        let width = min(max(frame.width, 700), min(visible.width - 48, 900))
        let height = min(max(frame.height, 460), min(visible.height - 48, 680))
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    init() {
        let savedFrame = NSRectFromString(defaults.string(forKey: "viewerFrame") ?? "")
        let initialFrame = savedFrame.isEmpty
            ? NSRect(x: 0, y: 0, width: 760, height: 520)
            : Self.sanitizedFrame(savedFrame)
        let window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "RTL Viewer"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.animationBehavior = .utilityWindow
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 680, height: 420)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(text rawText: String, source: String) {
        let text = normalizedForViewing(rawText)
        guard !text.isEmpty else { return }
        translationRequest?.cancel()
        translationGeneration = UUID()
        translatedText = nil
        currentText = text
        currentSource = source
        addHistory(text)
        titleLabel.stringValue = text
        metadataLabel.stringValue = "Arabic → English"
        sourceCardLabel.stringValue = text
        translationCardLabel.stringValue = "Translating..."
        render(animated: true)
        placeWindowIfNeeded()
        window?.alphaValue = 0
        window?.contentView?.alphaValue = 0.98
        window?.orderFrontRegardless()
        animatePresentation()
        DispatchQueue.main.async { [weak self] in
            self?.resizeForContentIfNeeded()
        }
        translateAutomaticallyIfNeeded(text)
    }

    func showLastWindow() {
        window?.orderFrontRegardless()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor
        content.layer?.cornerRadius = windowCornerRadius
        content.layer?.masksToBounds = true

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        root.edgeInsets = NSEdgeInsets(top: contentInset, left: contentInset, bottom: contentInset, right: contentInset)

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14

        let logoView = NSImageView(image: NSImage(systemSymbolName: "translate", accessibilityDescription: "Translate") ?? NSImage())
        logoView.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        logoView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        logoView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        logoView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        titleLabel.font = .systemFont(ofSize: 29, weight: .regular)
        titleLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metadataLabel.font = .systemFont(ofSize: 15, weight: .regular)
        metadataLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1)
        metadataLabel.alignment = .right
        metadataLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        topRow.addArrangedSubview(logoView)
        topRow.addArrangedSubview(titleLabel)
        topRow.addArrangedSubview(NSView())
        topRow.addArrangedSubview(metadataLabel)

        sectionLabel.font = .systemFont(ofSize: 15, weight: .regular)
        sectionLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)

        let cardContainer = NSView()
        cardContainer.wantsLayer = true
        cardContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.21, alpha: 1).cgColor
        cardContainer.layer?.cornerRadius = cardCornerRadius
        cardContainer.layer?.borderWidth = 1
        cardContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let speakerImage = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Speak translation") ?? NSImage()
        speakerImage.isTemplate = true
        speakerButton.image = speakerImage
        speakerButton.imageScaling = .scaleProportionallyDown
        speakerButton.isBordered = false
        speakerButton.translatesAutoresizingMaskIntoConstraints = false
        speakerButton.target = self
        speakerButton.action = #selector(speakTranslation)
        speakerButton.toolTip = "Speak translation"
        speakerButton.setAccessibilityLabel("Speak translation")
        speakerButton.contentTintColor = NSColor(calibratedWhite: 0.82, alpha: 1)

        let sourceColumn = NSStackView()
        sourceColumn.orientation = .vertical
        sourceColumn.alignment = .centerX
        sourceColumn.spacing = 20

        sourceCardLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        sourceCardLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        sourceCardLabel.alignment = .right
        sourceCardLabel.maximumNumberOfLines = 4
        sourceCardLabel.lineBreakMode = .byWordWrapping

        sourceBadgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sourceBadgeLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        sourceBadgeLabel.alignment = .center
        sourceBadgeLabel.wantsLayer = true
        sourceBadgeLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.34, alpha: 1).cgColor
        sourceBadgeLabel.layer?.cornerRadius = 10
        sourceBadgeLabel.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        sourceBadgeLabel.drawsBackground = true
        sourceBadgeLabel.backgroundColor = NSColor(calibratedWhite: 0.34, alpha: 1)
        sourceBadgeLabel.isBezeled = false
        sourceBadgeLabel.isEditable = false

        sourceColumn.addArrangedSubview(sourceCardLabel)
        sourceColumn.addArrangedSubview(sourceBadgeLabel)

        let targetColumn = NSStackView()
        targetColumn.orientation = .vertical
        targetColumn.alignment = .centerX
        targetColumn.spacing = 20

        translationCardLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        translationCardLabel.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        translationCardLabel.alignment = .left
        translationCardLabel.maximumNumberOfLines = 4
        translationCardLabel.lineBreakMode = .byWordWrapping

        targetBadgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        targetBadgeLabel.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        targetBadgeLabel.alignment = .center
        targetBadgeLabel.wantsLayer = true
        targetBadgeLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.34, alpha: 1).cgColor
        targetBadgeLabel.layer?.cornerRadius = 10
        targetBadgeLabel.drawsBackground = true
        targetBadgeLabel.backgroundColor = NSColor(calibratedWhite: 0.34, alpha: 1)
        targetBadgeLabel.isBezeled = false
        targetBadgeLabel.isEditable = false

        targetColumn.addArrangedSubview(translationCardLabel)
        targetColumn.addArrangedSubview(targetBadgeLabel)

        cardArrowLabel.font = .systemFont(ofSize: 28, weight: .regular)
        cardArrowLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        cardArrowLabel.alignment = .center
        cardArrowLabel.setContentHuggingPriority(.required, for: .horizontal)

        let cardBody = NSStackView()
        cardBody.orientation = .horizontal
        cardBody.alignment = .centerY
        cardBody.spacing = 24
        cardBody.edgeInsets = NSEdgeInsets(top: 42, left: 36, bottom: 24, right: 36)
        cardBody.translatesAutoresizingMaskIntoConstraints = false
        cardBody.addArrangedSubview(sourceColumn)
        cardBody.addArrangedSubview(cardArrowLabel)
        cardBody.addArrangedSubview(targetColumn)

        cardContainer.addSubview(cardBody)
        cardContainer.addSubview(speakerButton)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        footerMenuButton.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "More") ?? NSImage()
        footerMenuButton.imageScaling = .scaleProportionallyDown
        footerMenuButton.isBordered = false
        footerMenuButton.target = self
        footerMenuButton.action = #selector(showMoreMenu(_:))
        footerMenuButton.toolTip = "More actions"
        footerMenuButton.setAccessibilityLabel("More actions")
        footerMenuButton.contentTintColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        footerMenuButton.wantsLayer = true
        footerMenuButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        footerMenuButton.layer?.cornerRadius = 22
        footerMenuButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        footerMenuButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
            target: self,
            action: #selector(closeWindow)
        )
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityLabel("Close")
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        closeButton.layer?.cornerRadius = 22
        closeButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        copyTranslationButton.title = "Copy Translation"
        copyTranslationButton.target = self
        copyTranslationButton.action = #selector(copyText)
        copyTranslationButton.isBordered = false
        copyTranslationButton.contentTintColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        copyTranslationButton.wantsLayer = true
        copyTranslationButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        copyTranslationButton.layer?.cornerRadius = 18
        copyTranslationButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        actionsButton.title = "Actions"
        actionsButton.target = self
        actionsButton.action = #selector(showMoreMenu(_:))
        actionsButton.isBordered = false
        actionsButton.contentTintColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        actionsButton.wantsLayer = true
        actionsButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        actionsButton.layer?.cornerRadius = 18
        actionsButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let footerPill = NSStackView(views: [copyTranslationButton, actionsButton])
        footerPill.orientation = .horizontal
        footerPill.alignment = .centerY
        footerPill.spacing = 10
        footerPill.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        footerPill.wantsLayer = true
        footerPill.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        footerPill.layer?.cornerRadius = 22
        footerPill.layer?.borderWidth = 1
        footerPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 12
        footerRow.addArrangedSubview(footerMenuButton)
        footerRow.addArrangedSubview(closeButton)
        footerRow.addArrangedSubview(NSView())
        footerRow.addArrangedSubview(footerPill)

        root.addArrangedSubview(topRow)
        root.addArrangedSubview(sectionLabel)
        root.addArrangedSubview(cardContainer)
        root.addArrangedSubview(footerRow)
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            cardContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            speakerButton.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 14),
            speakerButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -14),
            cardBody.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            cardBody.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            cardBody.topAnchor.constraint(equalTo: cardContainer.topAnchor),
            cardBody.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
            footerRow.heightAnchor.constraint(equalToConstant: 54),
            sourceColumn.widthAnchor.constraint(equalTo: cardContainer.widthAnchor, multiplier: 0.43),
            targetColumn.widthAnchor.constraint(equalTo: cardContainer.widthAnchor, multiplier: 0.43),
            cardArrowLabel.widthAnchor.constraint(equalToConstant: 28),
        ])

        metadataLabel.alignment = .right
        updateFontSizeLabel()
    }

    private func iconButton(
        symbol: String,
        tooltip: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel) ?? NSImage(),
            target: self,
            action: action
        )
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor(calibratedWhite: 0.74, alpha: 1)
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibilityLabel)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.alphaValue = 0.32
        return line
    }

    private enum TextBlockKind {
        case paragraph
        case heading
        case bullet
        case quote
        case code
    }

    private struct TextBlock {
        let text: String
        let kind: TextBlockKind
        var isCode: Bool { kind == .code }
    }

    private enum ContentTone {
        case primary
        case secondary
    }

    private func blockKind(for text: String, isCode: Bool) -> TextBlockKind {
        if isCode { return .code }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(">") { return .quote }
        if trimmed.range(of: #"^([#]{1,6}\s+|[-*•]\s+|\d+[.)]\s+)"#, options: .regularExpression) != nil {
            if trimmed.range(of: #"^([#]{1,6}\s+)"#, options: .regularExpression) != nil { return .heading }
            return .bullet
        }
        return .paragraph
    }

    private func makeBlocks(from text: String) -> [TextBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [TextBlock] = []
        var buffer: [String] = []
        var bufferIsCode = false
        var inFence = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                blocks.append(TextBlock(text: text, kind: blockKind(for: text, isCode: bufferIsCode)))
            }
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !buffer.isEmpty && !bufferIsCode { flush() }
                inFence.toggle()
                bufferIsCode = true
                buffer.append(line)
                if !inFence { flush() }
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            let structural = trimmed.range(of: #"^([#]{1,6}\s+|[-*•]\s+|\d+[.)]\s+|>)"#, options: .regularExpression) != nil
            if structural && !buffer.isEmpty && !bufferIsCode {
                flush()
            }

            let code = inFence || looksLikeCode(line)
            if !buffer.isEmpty && code != bufferIsCode {
                flush()
            }
            bufferIsCode = code
            buffer.append(line)

            if structural && !bufferIsCode {
                flush()
            }
        }

        flush()
        return blocks
    }

    private func cleanedMarkdownText(_ text: String, kind: TextBlockKind) -> String {
        switch kind {
        case .heading:
            return text.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
        case .bullet:
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let raw = String(line)
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if let markerRange = trimmed.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                        return "• " + trimmed[markerRange.upperBound...]
                    }
                    if trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
                        return trimmed.replacingOccurrences(of: #"^(\d+[.)])\s+"#, with: "$1 ", options: .regularExpression)
                    }
                    return raw
                }
                .joined(separator: "\n")
        case .quote:
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression) }
                .joined(separator: "\n")
        case .code:
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
                .joined(separator: "\n")
        case .paragraph:
            return text
        }
    }

    private func applyInlineMarkdown(to attributed: NSMutableAttributedString, baseFont: NSFont, codeFontSize: CGFloat) {
        applyInlinePattern(#"`([^`\n]+)`"#, to: attributed) { value in
            [
                .font: NSFont.monospacedSystemFont(ofSize: max(12, codeFontSize), weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.8),
            ]
        }
        applyInlinePattern(#"\*\*([^*\n]+)\*\*"#, to: attributed) { _ in
            [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]
        }
        applyInlinePattern(#"__([^_\n]+)__"#, to: attributed) { _ in
            [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]
        }
        applyInlinePattern(#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, to: attributed) { _ in
            [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        }
        applyInlinePattern(#"(?<!_)_([^_\n]+)_(?!_)"#, to: attributed) { _ in
            [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        }
        applyInlinePattern(#"\[([^\]\n]+)\]\([^) \n]+\)"#, to: attributed) { _ in
            [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
    }

    private func applyInlinePattern(
        _ pattern: String,
        to attributed: NSMutableAttributedString,
        attributesForValue: (String) -> [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsString = attributed.string as NSString
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: nsString.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let matchedTextRange = match.range(at: 1)
            guard matchedTextRange.location != NSNotFound else { continue }
            let matchedText = nsString.substring(with: matchedTextRange)
            let replacement = NSMutableAttributedString(string: matchedText)
            let attributeIndex = min(max(match.range.location, 0), max(attributed.length - 1, 0))
            var merged = attributed.length > 0 ? attributed.attributes(at: attributeIndex, effectiveRange: nil) : [:]
            for (attributeKey, attributeValue) in attributesForValue(matchedText) {
                merged[attributeKey] = attributeValue
            }
            replacement.addAttributes(merged, range: NSRange(location: 0, length: (matchedText as NSString).length))
            attributed.replaceCharacters(in: match.range, with: replacement)
        }
    }

    private func renderedAttributedText() -> NSAttributedString {
        let renderedText = NSMutableAttributedString()
        if let translatedText {
            renderedText.append(renderedContent(translatedText, fontOffset: 0, tone: .primary))
            renderedText.append(originalLabel())
            renderedText.append(renderedContent(currentText, fontOffset: -4, tone: .secondary))
        } else {
            renderedText.append(renderedContent(currentText, fontOffset: 0, tone: .primary))
        }
        return renderedText
    }

    private func render(animated: Bool = false) {
        titleLabel.font = .systemFont(ofSize: max(24, fontSize + 11), weight: .regular)
        sourceCardLabel.font = .systemFont(ofSize: max(22, fontSize + 9), weight: .semibold)
        translationCardLabel.font = .systemFont(ofSize: max(20, fontSize + 7), weight: .semibold)
        titleLabel.stringValue = currentText
        metadataLabel.stringValue = "Arabic → English"
        sourceCardLabel.stringValue = currentText
        translationCardLabel.stringValue = translatedText ?? "Translating..."
        if animated {
            crossfadeRenderedText(NSAttributedString())
        }
    }

    private func crossfadeRenderedText(_ renderedText: NSAttributedString) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.contentView?.animator().alphaValue = 1
        }
    }

    private func animatePresentation() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.contentView?.animator().alphaValue = 1
        }
    }

    private func originalLabel() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        paragraph.paragraphSpacingBefore = 18
        paragraph.paragraphSpacing = 7
        return NSAttributedString(
            string: "\nOriginal\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1),
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func renderedContent(
        _ text: String,
        fontOffset: CGFloat,
        tone: ContentTone
    ) -> NSAttributedString {
        let renderedText = NSMutableAttributedString()
        let blocks = makeBlocks(from: text)
        for (index, block) in blocks.enumerated() {
            renderedText.append(renderedBlock(block, fontOffset: fontOffset, tone: tone))
            if index < blocks.count - 1 {
                renderedText.append(NSAttributedString(string: "\n"))
            }
        }
        return renderedText
    }

    private func renderedBlock(
        _ block: TextBlock,
        fontOffset: CGFloat,
        tone: ContentTone
    ) -> NSAttributedString {
        let displayText = cleanedMarkdownText(block.text, kind: block.kind)
        let direction = resolvedMode(for: displayText, isCode: block.isCode)
        let font = fontFor(block, offset: fontOffset)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle(for: block, direction: direction),
            .foregroundColor: tone == .secondary
                ? NSColor(calibratedWhite: 0.58, alpha: 1)
                : colorFor(block),
        ]
        attributes[.backgroundColor] = backgroundFor(block)
        let renderedBlock = NSMutableAttributedString(string: displayText, attributes: attributes)
        if !block.isCode {
            applyInlineMarkdown(to: renderedBlock, baseFont: font, codeFontSize: fontSize + fontOffset - 3)
        }
        return renderedBlock
    }

    private func measuredTextHeight(_ text: String, font: NSFont, width: CGFloat, alignment: NSTextAlignment) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
        return ceil(rect.height)
    }

    private func resizeForContentIfNeeded() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()

        let contentWidth = max(window.frame.width - 32, 680)
        let cardWidth = max(600, contentWidth - 16)
        let columnWidth = max(260, floor((cardWidth - 28 - 24) / 2))
        let sourceHeight = measuredTextHeight(currentText, font: .systemFont(ofSize: max(22, fontSize + 9), weight: .semibold), width: columnWidth, alignment: .right)
        let translationHeight = measuredTextHeight(translatedText ?? "Translating...", font: .systemFont(ofSize: max(20, fontSize + 7), weight: .semibold), width: columnWidth, alignment: .left)
        let sourceBlockHeight = sourceHeight + 20 + 20
        let targetBlockHeight = translationHeight + 20 + 20
        let cardHeight = max(max(sourceBlockHeight, targetBlockHeight) + 66, 260)
        let chromeHeight: CGFloat = 42 + 15 + 20 + 12 + 54
        let totalHeight = cardHeight + chromeHeight + 32
        let screenLimit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000
        let maximumAutomaticHeight = min(screenLimit * 0.72, 680)
        let targetHeight = min(max(totalHeight, window.minSize.height), maximumAutomaticHeight)

        guard abs(window.frame.height - targetHeight) > 1 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight

        isApplyingAutomaticSize = true
        window.setFrame(frame, display: true)
        isApplyingAutomaticSize = false

        DispatchQueue.main.async { [weak self] in
            self?.expandIfRenderedTextIsClipped(maximumHeight: maximumAutomaticHeight)
        }
    }

    private func expandIfRenderedTextIsClipped(maximumHeight: CGFloat) {
        guard let window else { return }
        let targetHeight = min(window.frame.height, maximumHeight)
        guard abs(window.frame.height - targetHeight) > 1 else { return }
    }

    private func paragraphStyle(
        for block: TextBlock,
        direction: DirectionMode
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = direction == .rtl ? .right : .left
        paragraph.baseWritingDirection = direction == .rtl ? .rightToLeft : .leftToRight
        paragraph.lineBreakMode = .byWordWrapping

        let compact = viewerStyle == .compact
        let large = viewerStyle == .large
        paragraph.lineSpacing = block.isCode ? 1 : (compact ? 0.75 : large ? 2.5 : 1.25)
        paragraph.paragraphSpacing = spacingAfter(block)
        paragraph.minimumLineHeight = 0
        paragraph.maximumLineHeight = 0
        paragraph.headIndent = block.kind == .bullet ? 24 : 0
        paragraph.firstLineHeadIndent = 0
        paragraph.tailIndent = 0
        return paragraph
    }

    private func fontFor(_ block: TextBlock, offset: CGFloat = 0) -> NSFont {
        let adjustedSize = max(11, fontSize + offset)
        switch block.kind {
        case .code:
            return .monospacedSystemFont(ofSize: max(11, adjustedSize - 3), weight: .regular)
        case .heading:
            return .systemFont(ofSize: adjustedSize + (viewerStyle == .large ? 5 : 3), weight: .semibold)
        case .quote:
            return .systemFont(ofSize: adjustedSize - 1, weight: .regular)
        case .bullet, .paragraph:
            return .systemFont(ofSize: adjustedSize, weight: .regular)
        }
    }

    private func colorFor(_ block: TextBlock) -> NSColor {
        switch block.kind {
        case .code:
            return .secondaryLabelColor
        case .quote:
            return .tertiaryLabelColor
        case .heading:
            return .labelColor
        case .bullet, .paragraph:
            return .labelColor
        }
    }

    private func backgroundFor(_ block: TextBlock) -> NSColor? {
        switch block.kind {
        case .code:
            return NSColor.controlBackgroundColor.withAlphaComponent(0.78)
        case .quote:
            return NSColor.systemTeal.withAlphaComponent(0.08)
        default:
            return nil
        }
    }

    private func spacingAfter(_ block: TextBlock) -> CGFloat {
        switch viewerStyle {
        case .compact:
            return block.isCode ? 4 : block.kind == .heading ? 7 : 4
        case .large:
            return block.kind == .heading ? 13 : block.isCode ? 8 : 9
        case .document:
            return block.kind == .heading ? 11 : block.isCode ? 7 : 7
        case .comfortable:
            return block.kind == .heading ? 10 : block.isCode ? 6 : 7
        }
    }

    private func resolvedMode(for line: String, isCode: Bool) -> DirectionMode {
        if directionMode != .auto { return directionMode }
        if isCode { return .ltr }
        return containsRTL(line) ? .rtl : .ltr
    }

    private func placeWindowIfNeeded() {
        guard let window else { return }
        let hasSavedFrame = defaults.string(forKey: "viewerFrame") != nil
        if hasSavedFrame { return }
        if let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            let frame = window.frame
            let visible = screen.visibleFrame
            let x = min(max(mouse.x - frame.width * 0.5, visible.minX), visible.maxX - frame.width)
            let y = min(max(mouse.y - frame.height - 24, visible.minY), visible.maxY - frame.height)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
    }

    private func addHistory(_ text: String) {
        var history = defaults.stringArray(forKey: "history") ?? []
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        defaults.set(Array(history.prefix(10)), forKey: "history")
    }

    func showHistoryItem(_ index: Int) {
        let history = defaults.stringArray(forKey: "history") ?? []
        guard history.indices.contains(index) else { return }
        show(text: history[index], source: "History \(index + 1)")
    }

    @objc private func directionChanged() {
        directionMode = DirectionMode(rawValue: directionPopup.indexOfSelectedItem) ?? .auto
        defaults.set(directionMode.rawValue, forKey: "directionMode")
        render()
    }

    @objc private func styleChanged() {
        viewerStyle = ViewerStyle(rawValue: stylePopup.indexOfSelectedItem) ?? .comfortable
        defaults.set(viewerStyle.rawValue, forKey: "viewerStyle")
        render()
        resizeForContentIfNeeded()
    }

    @objc private func toggleReadingToolbar() {
        let visible = readingToolbar.isHidden
        readingToolbar.isHidden = !visible
        readingToolbarSeparator.isHidden = !visible
        defaults.set(visible, forKey: "readerToolbarVisible")
        updateToolbarToggleAppearance()
        resizeForContentIfNeeded()
    }

    private func updateToolbarToggleAppearance() {
        let visible = !readingToolbar.isHidden
        toolbarToggleButton.contentTintColor = visible
            ? .systemTeal
            : NSColor(calibratedWhite: 0.74, alpha: 1)
        toolbarToggleButton.toolTip = visible ? "Hide reading controls" : "Show reading controls"
        toolbarToggleButton.setAccessibilityLabel(visible ? "Hide reading controls" : "Show reading controls")
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(menuItem("Refresh Selected Text", action: #selector(refreshSelectedText)))
        menu.addItem(menuItem("Copy with RTL Marks", action: #selector(copyWrappedText)))
        menu.addItem(.separator())

        let autoTranslate = defaults.object(forKey: "autoTranslateEnglish") == nil
            ? true
            : defaults.bool(forKey: "autoTranslateEnglish")
        let translationItem = menuItem("Translate Arabic to English", action: #selector(toggleAutomaticTranslation))
        translationItem.state = autoTranslate ? .on : .off
        menu.addItem(translationItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Close Window", action: #selector(closeWindow)))
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 4), in: sender)
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshSelectedText() {
        (NSApp.delegate as? AppDelegate)?.showSelectedText()
    }

    @objc private func toggleAutomaticTranslation() {
        let enabled = defaults.object(forKey: "autoTranslateEnglish") == nil
            ? true
            : defaults.bool(forKey: "autoTranslateEnglish")
        defaults.set(!enabled, forKey: "autoTranslateEnglish")

        if enabled {
            translationRequest?.cancel()
            translationGeneration = UUID()
            translatedText = nil
            titleLabel.stringValue = currentText
            metadataLabel.stringValue = "Arabic → English"
            render()
            resizeForContentIfNeeded()
        } else {
            translateAutomaticallyIfNeeded(currentText)
        }
    }

    private func translateAutomaticallyIfNeeded(_ text: String) {
        let enabled = defaults.object(forKey: "autoTranslateEnglish") == nil
            ? true
            : defaults.bool(forKey: "autoTranslateEnglish")
        guard enabled, containsArabic(text) else { return }

        let generation = translationGeneration
        let translationInput = makeBlocks(from: text)
            .map { cleanedMarkdownText($0.text, kind: $0.kind) }
            .joined(separator: "\n\n")
        let chunks = translationChunks(from: translationInput)
        guard !chunks.isEmpty else { return }

        metadataLabel.stringValue = "Translating to English..."
        translate(chunks: chunks, index: 0, translations: [], generation: generation)
    }

    private func containsArabic(_ text: String) -> Bool {
        guard containsRTL(text) else { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(8_000)))
        return recognizer.dominantLanguage == .arabic || containsRTL(text)
    }

    private func translationChunks(from text: String) -> [String] {
        let maximumLength = 3_500
        var chunks: [String] = []
        var pendingChunk = ""

        for paragraph in text.components(separatedBy: "\n\n") {
            if paragraph.count > maximumLength {
                if !pendingChunk.isEmpty {
                    chunks.append(pendingChunk)
                    pendingChunk = ""
                }
                var start = paragraph.startIndex
                while start < paragraph.endIndex {
                    let end = paragraph.index(start, offsetBy: maximumLength, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                    chunks.append(String(paragraph[start..<end]))
                    start = end
                }
                continue
            }

            let candidate = pendingChunk.isEmpty ? paragraph : pendingChunk + "\n\n" + paragraph
            if candidate.count > maximumLength {
                chunks.append(pendingChunk)
                pendingChunk = paragraph
            } else {
                pendingChunk = candidate
            }
        }

        if !pendingChunk.isEmpty {
            chunks.append(pendingChunk)
        }
        return chunks
    }

    private func translate(
        chunks: [String],
        index: Int,
        translations: [String],
        generation: UUID
    ) {
        guard generation == translationGeneration else { return }
        guard chunks.indices.contains(index) else {
            showCompletedTranslation(translations)
            return
        }

        let request = translationRequest(for: chunks[index])
        translationRequest = URLSession.shared.dataTask(with: request) { [weak self] responseData, _, requestError in
            guard let self, generation == self.translationGeneration else { return }
            guard requestError == nil,
                  let responseData,
                  let translation = self.arabicTranslation(from: responseData) else {
                DispatchQueue.main.async {
                    self.showTranslationFailure(generation: generation)
                }
                return
            }

            DispatchQueue.main.async {
                self.translate(
                    chunks: chunks,
                    index: index + 1,
                    translations: translations + [translation],
                    generation: generation
                )
            }
        }
        translationRequest?.resume()
    }

    private func translationRequest(for arabicText: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/single")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "ar"),
            URLQueryItem(name: "tl", value: "en"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: arabicText),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    private func arabicTranslation(from responseData: Data) -> String? {
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [Any],
              let translatedSegments = response.first as? [Any] else { return nil }
        let translation = translatedSegments.compactMap { segment -> String? in
            guard let fields = segment as? [Any] else { return nil }
            return fields.first as? String
        }.joined()
        return normalizedForViewing(translation).isEmpty ? nil : translation
    }

    private func showCompletedTranslation(_ translations: [String]) {
        translatedText = translations.joined(separator: "\n\n")
        titleLabel.stringValue = currentText
        metadataLabel.stringValue = "Arabic → English"
        render()
        resizeForContentIfNeeded()
    }

    private func showTranslationFailure(generation: UUID) {
        guard generation == translationGeneration else { return }
        metadataLabel.stringValue = "Translation unavailable"
        translationCardLabel.stringValue = "Translation unavailable"
    }

    @objc private func decreaseFontSize() {
        fontSize -= 1
        updateFontSizeLabel()
        render()
        resizeForContentIfNeeded()
    }

    @objc private func increaseFontSize() {
        fontSize += 1
        updateFontSizeLabel()
        render()
        resizeForContentIfNeeded()
    }

    private func updateFontSizeLabel() {
        fontSizeLabel.stringValue = "\(Int(fontSize))"
    }

    @objc private func findNext() {
        let query = searchField.stringValue
        guard !query.isEmpty else { return }
        let full = textView.string as NSString
        let selectedEnd = NSMaxRange(textView.selectedRange())
        var range = full.range(of: query, options: [.caseInsensitive], range: NSRange(location: selectedEnd, length: max(0, full.length - selectedEnd)))
        if range.location == NSNotFound {
            range = full.range(of: query, options: [.caseInsensitive], range: NSRange(location: 0, length: full.length))
        }
        guard range.location != NSNotFound else { NSSound.beep(); return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText ?? currentText, forType: .string)
    }

    @objc private func copyWrappedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rtlWrapped(translatedText ?? currentText), forType: .string)
    }

    @objc private func speakTranslation() {
        let text = translatedText ?? currentText
        guard !normalizedForViewing(text).isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    @objc private func closeWindow() {
        window?.orderOut(nil)
    }

    @objc override func cancelOperation(_ sender: Any?) {
        closeWindow()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowWillStartLiveResize(_ notification: Notification) {
        userIsLiveResizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard userIsLiveResizing else { return }
        userIsLiveResizing = false
        guard let window else { return }
        preferredWindowHeight = window.frame.height
        saveFrame()
    }

    private func saveFrame() {
        guard !isApplyingAutomaticSize else { return }
        if let frame = window?.frame {
            defaults.set(NSStringFromRect(Self.sanitizedFrame(frame)), forKey: "viewerFrame")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkeys: [EventHotKeyRef?] = []
    private var modifierMonitor: Any?
    private var optionWasDown = false
    private var lastOptionTapTime: TimeInterval = 0
    private let viewer = RTLViewerWindowController()
    private var overlays: [ScreenSelectionOverlay] = []
    private var elementPicker: ElementPickerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestAccessibilityIfNeeded()
        registerHotkeys()
        registerDoubleOptionTrigger()
        NSLog("RTL Viewer started")

        if CommandLine.arguments.contains("--preview") {
            viewer.show(
                text: """
                # Reading Preview

                This is a short English paragraph used to verify automatic Arabic translation and the reading layout.

                - The translated Arabic text should appear first.
                - The original English text should remain below in a smaller size.

                **Important text** with `inline code` and a clear ending.
                """,
                source: "Design Preview"
            )
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "text.alignright", accessibilityDescription: "RTL Fixer") {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
        } else {
            item.button?.title = "↔"
        }
        item.button?.setAccessibilityLabel("RTL Fixer")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Selected Text    Double Option", action: #selector(showSelectedText), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Clipboard    ⌃⌥C", action: #selector(showClipboardText), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Last Window", action: #selector(showLastWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let captureMenu = NSMenu()
        captureMenu.addItem(NSMenuItem(title: "Pick UI Container    ⌃⌥E", action: #selector(startElementPicker), keyEquivalent: ""))
        captureMenu.addItem(NSMenuItem(title: "OCR Screen Region    ⌃⌥S", action: #selector(startOCRRegion), keyEquivalent: ""))
        let captureItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        captureItem.submenu = captureMenu
        menu.addItem(captureItem)

        let historyMenu = NSMenu()
        let history = defaults.stringArray(forKey: "history") ?? []
        if history.isEmpty {
            historyMenu.addItem(NSMenuItem(title: "No History Yet", action: nil, keyEquivalent: ""))
        } else {
            for (index, text) in history.enumerated() {
                let title = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
                let item = NSMenuItem(title: "\(index + 1). \(title)", action: #selector(openHistoryItem(_:)), keyEquivalent: "")
                item.tag = index
                historyMenu.addItem(item)
            }
        }
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let textToolsMenu = NSMenu()
        textToolsMenu.addItem(NSMenuItem(title: "Replace Selection with RTL Marks", action: #selector(fixSelectedText), keyEquivalent: ""))
        textToolsMenu.addItem(NSMenuItem(title: "Clean Selected Text Marks", action: #selector(cleanSelectedText), keyEquivalent: ""))
        textToolsMenu.addItem(NSMenuItem.separator())
        textToolsMenu.addItem(NSMenuItem(title: "Fix Clipboard RTL", action: #selector(fixClipboard), keyEquivalent: ""))
        textToolsMenu.addItem(NSMenuItem(title: "Clean Clipboard Marks", action: #selector(cleanClipboard), keyEquivalent: ""))
        let textToolsItem = NSMenuItem(title: "Text Utilities", action: nil, keyEquivalent: "")
        textToolsItem.submenu = textToolsMenu
        menu.addItem(textToolsItem)

        let settingsMenu = NSMenu()
        settingsMenu.addItem(NSMenuItem(title: "Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        settingsMenu.addItem(NSMenuItem(title: "Screen Recording Settings", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func registerHotkeys() {
        let eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyId = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyId)
            DispatchQueue.main.async {
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                if hotkeyId.id == showSelectionHotkeyId {
                    delegate.showSelectedText()
                } else if hotkeyId.id == showClipboardHotkeyId {
                    delegate.showClipboardText()
                } else if hotkeyId.id == ocrRegionHotkeyId {
                    delegate.startOCRRegion()
                } else if hotkeyId.id == pickContainerHotkeyId {
                    delegate.startElementPicker()
                }
            }
            return noErr
        }, 1, eventTypes, nil, nil)

        var selectionRef: EventHotKeyRef?
        let selectionStatus = RegisterEventHotKey(UInt32(kVK_Return), UInt32(controlKey | optionKey), eventHotKeyId(showSelectionHotkeyId), GetApplicationEventTarget(), 0, &selectionRef)
        hotkeys.append(selectionRef)

        var clipboardRef: EventHotKeyRef?
        let clipboardStatus = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), eventHotKeyId(showClipboardHotkeyId), GetApplicationEventTarget(), 0, &clipboardRef)
        hotkeys.append(clipboardRef)

        var ocrRef: EventHotKeyRef?
        let ocrStatus = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), eventHotKeyId(ocrRegionHotkeyId), GetApplicationEventTarget(), 0, &ocrRef)
        hotkeys.append(ocrRef)

        var pickerRef: EventHotKeyRef?
        let pickerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(controlKey | optionKey), eventHotKeyId(pickContainerHotkeyId), GetApplicationEventTarget(), 0, &pickerRef)
        hotkeys.append(pickerRef)

        if selectionStatus != noErr || clipboardStatus != noErr || ocrStatus != noErr || pickerStatus != noErr {
            showNotification("Could not register one of the global shortcuts. Use the RTL menu bar menu instead.")
        }
    }

    private func registerDoubleOptionTrigger() {
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierEvent(event)
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        let optionIsDown = event.modifierFlags.contains(.option)
        defer { optionWasDown = optionIsDown }

        guard optionIsDown,
              !optionWasDown,
              isPlainOptionTap(event) else { return }

        let now = Date.timeIntervalSinceReferenceDate
        if now - lastOptionTapTime <= 0.35 {
            lastOptionTapTime = 0
            showSelectedText()
        } else {
            lastOptionTapTime = now
        }
    }

    private func isPlainOptionTap(_ event: NSEvent) -> Bool {
        let activeFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return activeFlags == .option
    }

    @objc func startElementPicker() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityIfNeeded()
            showNotification("RTL Viewer needs Accessibility permission to inspect UI containers.")
            return
        }

        elementPicker?.stop()
        let picker = ElementPickerController(
            onPick: { [weak self] element in
                guard let self else { return }
                self.elementPicker = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    let text = axText(from: element)
                    DispatchQueue.main.async {
                        guard !normalizedForViewing(text).isEmpty else {
                            self.showNotification("The selected container did not expose readable Accessibility text. Try its parent with the scroll wheel, or use OCR.")
                            return
                        }
                        self.viewer.show(text: text, source: "UI Container")
                        self.refreshMenu()
                    }
                }
            },
            onCancel: { [weak self] in
                self?.elementPicker = nil
            }
        )
        elementPicker = picker
        picker.start()
    }

    @objc func showSelectedText() {
        captureSelectedText(fallbackToClipboard: true) { [weak self] text, source in
            self?.viewer.show(text: text, source: source)
            self?.refreshMenu()
        }
    }

    @objc private func showClipboardText() {
        guard let text = NSPasteboard.general.string(forType: .string), !normalizedForViewing(text).isEmpty else {
            showNotification("Clipboard does not contain text.")
            return
        }
        viewer.show(text: text, source: "Clipboard")
        refreshMenu()
    }

    @objc private func startOCRRegion() {
        guard requestScreenCapturePermissionIfNeeded() else {
            showNotification("RTL Viewer needs Screen Recording permission for OCR capture.")
            return
        }

        overlays = NSScreen.screens.map { screen in
            ScreenSelectionOverlay(
                screen: screen,
                onComplete: { [weak self] screen, rect in
                    self?.closeOverlays()
                    self?.performOCR(screen: screen, rect: rect)
                },
                onCancel: { [weak self] in
                    self?.closeOverlays()
                }
            )
        }
        overlays.forEach { $0.showWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showLastWindow() {
        viewer.showLastWindow()
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        viewer.showHistoryItem(sender.tag)
        refreshMenu()
    }

    @objc private func fixSelectedText() {
        captureSelectedText(fallbackToClipboard: false) { text, _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rtlWrapped(text), forType: .string)
            key(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
    }

    @objc private func cleanSelectedText() {
        captureSelectedText(fallbackToClipboard: false) { text, _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rtlCleaned(text), forType: .string)
            key(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
    }

    @objc private func fixClipboard() {
        transformClipboard(rtlWrapped)
    }

    @objc private func cleanClipboard() {
        transformClipboard(rtlCleaned)
    }

    private func transformClipboard(_ transform: (String) -> String) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showNotification("Clipboard does not contain text.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transform(text), forType: .string)
    }

    private func captureSelectedText(fallbackToClipboard: Bool, completion: @escaping (String, String) -> Void) {
        guard AXIsProcessTrusted() else {
            requestAccessibilityIfNeeded()
            showNotification("RTL Viewer needs Accessibility permission to read selected text.")
            return
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        key(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let copied = pasteboard.string(forType: .string) ?? ""
            if !normalizedForViewing(copied).isEmpty && copied != previous {
                completion(copied, "Selected Text")
            } else if fallbackToClipboard, let previous, !normalizedForViewing(previous).isEmpty {
                completion(previous, "Clipboard Fallback")
            } else {
                self.showNotification("No selected text found.")
            }

            if let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestScreenCapturePermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    private func closeOverlays() {
        overlays.forEach { $0.window?.orderOut(nil) }
        overlays.removeAll()
    }

    private func performOCR(screen: NSScreen, rect: NSRect) {
        guard let image = capture(screen: screen, rect: rect) else {
            showNotification("Could not capture the selected screen region.")
            return
        }

        let request = VNRecognizeTextRequest { [weak self] request, error in
            DispatchQueue.main.async {
                if let error {
                    self?.showNotification("OCR failed: \(error.localizedDescription)")
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                guard !normalizedForViewing(text).isEmpty else {
                    self?.showNotification("No text found in the selected region.")
                    return
                }
                self?.viewer.show(text: text, source: "OCR Region")
                self?.refreshMenu()
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ar", "en", "he"]

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.showNotification("OCR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func capture(screen: NSScreen, rect: NSRect) -> CGImage? {
        let unionFrame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let captureRect = CGRect(
            x: rect.minX,
            y: unionFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        ).integral

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtl-viewer-ocr-\(UUID().uuidString).png")
        let region = "\(Int(captureRect.minX)),\(Int(captureRect.minY)),\(Int(captureRect.width)),\(Int(captureRect.height))"

        do {
            try Process.run(URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments: ["-x", "-R", region, url.path]).waitUntilExit()
            defer { try? FileManager.default.removeItem(at: url) }
            guard let image = NSImage(contentsOf: url) else { return nil }
            var proposed = NSRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        } catch {
            return nil
        }
    }

    private func showNotification(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "RTL Viewer"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
