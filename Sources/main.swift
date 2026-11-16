import AppKit
import Security
import QuartzCore

let demoMode = (Bundle.main.infoDictionary?["ControllerDemo"] as? Bool) == true
let demoState = FileManager.default.temporaryDirectory.appendingPathComponent("codex-controller-demo-\(ProcessInfo.processInfo.processIdentifier)")

let keychainService = "com.kelvin.codex-controller.azure"
let keychainAccount = "primary"

enum ControllerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

func keyQuery(_ profileID: String = "company-azure") -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: keychainService,
     kSecAttrAccount as String: profileID == "company-azure" ? keychainAccount : profileID]
}

func readKey(_ profileID: String = "company-azure") throws -> String {
    var q = keyQuery(profileID)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
          let key = String(data: data, encoding: .utf8), !key.isEmpty else {
        throw ControllerError.message("Azure key unavailable in Keychain. Open Codex Controller and save the key again.")
    }
    return key
}

func keyExists(_ profileID: String = "company-azure") -> Bool {
    if demoMode { return false }
    var q = keyQuery(profileID)
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
}

func saveKey(_ text: String, profileID: String = "company-azure", name: String = "Company Azure") throws {
    let data = Data(text.utf8)
    let status = SecItemUpdate(keyQuery(profileID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var q = keyQuery(profileID)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Codex Controller — \(name)"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw ControllerError.message("Keychain could not save the key (\(added)).") }
    } else if status != errSecSuccess {
        throw ControllerError.message("Keychain could not update the key (\(status)).")
    }
}

// Codex invokes this executable directly as its credential helper.
// No shell, environment export, secret file, or command-line key is involved.
if CommandLine.arguments.contains("--print-azure-key") {
    let args = CommandLine.arguments
    let idx = args.firstIndex(of: "--profile-id")
    let identity = idx.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "company-azure"
    do { print(try readKey(identity)); exit(0) }
    catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
}

struct Profile {
    let id: String
    let name: String
    let kind: String
    let hex: String
    let endpoint: String
    let deployment: String
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? "Profile"
        kind = d["kind"] as? String ?? "azure"
        hex = d["color"] as? String ?? "#19AAA5"
        endpoint = d["endpoint"] as? String ?? ""
        deployment = d["deployment"] as? String ?? ""
    }
    var color: NSColor { NSColor(hex: hex) }
}

extension NSColor {
    convenience init(hex: String) {
        let n = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x19AAA5
        self.init(srgbRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? .systemTeal
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

/// A soft, profile-colored light field. No interaction, network or asset dependencies.
final class WaveView: NSView {
    var targetColor = NSColor(hex: "#8170E9") {
        didSet {
            if !motion || !NSApp.isActive || window == nil { shownColor = targetColor }
            needsDisplay = true
        }
    }
    private var shownColor = NSColor(hex: "#8170E9")
    var motion = true { didSet { configureTimer(); needsDisplay = true } }
    private var phase: CGFloat = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.configureTimer() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureTimer() }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        if motion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window != nil {
            timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self = self, self.window?.isVisible == true,
                      self.window?.occlusionState.contains(.visible) == true,
                      NSApp.isActive else { return }
                self.phase += 0.012
                self.shownColor = self.shownColor.blended(withFraction: 0.08, of: self.targetColor) ?? self.targetColor
                self.needsDisplay = true
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else { shownColor = targetColor }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let c = motion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? shownColor : targetColor
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSGradient(starting: c.withAlphaComponent(0.17), ending: c.withAlphaComponent(0.015))?.draw(in: bounds, angle: -18)
        let glow = NSRect(x: bounds.width * (0.49 + 0.12 * sin(phase * 0.4)), y: -bounds.height * 0.5,
                          width: bounds.width * 0.7, height: bounds.height * 2.3)
        NSGradient(starting: c.withAlphaComponent(0.24), ending: c.withAlphaComponent(0))?.draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: .zero)
        for j in 0..<4 {
            let path = NSBezierPath()
            let baseline = bounds.height * (0.18 + CGFloat(j) * 0.11)
            path.move(to: NSPoint(x: -10, y: -10))
            for step in 0...120 {
                let x = bounds.width * CGFloat(step) / 120
                let y = baseline + sin(x / max(bounds.width, 1) * .pi * 2 + phase + CGFloat(j) * 0.65) * bounds.height * 0.19
                    + cos(x / max(bounds.width, 1) * .pi * 3 - phase * 0.4) * 7
                path.line(to: NSPoint(x: x, y: y))
            }
            path.line(to: NSPoint(x: bounds.width + 10, y: -10)); path.close()
            NSGradient(starting: c.withAlphaComponent(0.025), ending: c.withAlphaComponent(0.08))?.draw(in: path, angle: 90)
        }
    }
    deinit { timer?.invalidate(); if let observer = observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byWordWrapping
    l.maximumNumberOfLines = 0
    return l
}

func stack(_ orientation: NSUserInterfaceLayoutOrientation, _ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = orientation
    s.spacing = spacing
    s.alignment = orientation == .vertical ? .leading : .centerY
    return s
}

func flexibleSpace() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    return v
}

final class Panel: NSView {
    init(_ content: NSView, padding: CGFloat = 18) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class UsageChart: NSView {
    var accent = NSColor.systemTeal { didSet { needsDisplay = true } }
    var days: [[String: Any]] = [] { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 850, height: 135) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !days.isEmpty else { return }
        let values = days.map { ($0["total"] as? NSNumber)?.doubleValue ?? 0 }
        let maxValue = max(values.max() ?? 0, 1)
        let step = bounds.width / CGFloat(days.count)
        let chartHeight = bounds.height - 30
        for (i, value) in values.enumerated() {
            let x = CGFloat(i) * step + 6
            let height = max(CGFloat(value / maxValue) * (chartHeight - 8), 2)
            (i == days.count - 1 ? accent : accent.withAlphaComponent(0.40)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 26, width: step - 12, height: height), xRadius: 4, yRadius: 4).fill()
            let date = String((days[i]["date"] as? String ?? "").suffix(5))
            (date as NSString).draw(at: NSPoint(x: x, y: 5), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
    }
}

final class ProfileEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let owner: AppDelegate
    let window: NSWindow
    let table = NSTableView()
    var profiles: [Profile] = []
    var editingID: String?
    var reloading = false
    var saving = false
    let nameField = NSTextField(string: "")
    let typeLabel = label("Azure OpenAI", size: 12, color: .secondaryLabelColor)
    let endpointField = NSTextField(string: "")
    let modelField = NSTextField(string: "")
    let colorWell = NSColorWell()
    let preview = WaveView(frame: .zero)
    let keyField = NSSecureTextField(string: "")
    let keyHint = label("", size: 11, color: .secondaryLabelColor)
        let status = label("", size: 11, color: .secondaryLabelColor)
    var connectionForm: NSStackView!
    var saveButton: NSButton!
    var deleteButton: NSButton!
    var newButton: NSButton!

    init(owner: AppDelegate) {
        self.owner = owner
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Profile Settings"
        window.isReleasedWhenClosed = false
        window.center()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.width = 220
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.delegate = self; table.dataSource = self
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.widthAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        newButton = NSButton(title: "+ New Azure profile", target: self, action: #selector(newProfile))
        newButton.bezelStyle = .rounded
        deleteButton = NSButton(title: "Delete profile…", target: self, action: #selector(deleteProfile))
        deleteButton.bezelStyle = .rounded
        let sidebar = stack(.vertical, [label("YOUR PROFILES", size: 11, weight: .semibold, color: .secondaryLabelColor), scroll, newButton, deleteButton], spacing: 10)
        sidebar.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for button in [newButton!, deleteButton!] { button.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
        nameField.placeholderString = "Profile name"
        endpointField.placeholderString = "https://your-resource.services.ai.azure.com/openai/v1"
        endpointField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        modelField.placeholderString = "Azure deployment name"
        keyField.placeholderString = "API key"
        let identityForm = stack(.vertical, [label("Profile name", size: 12, weight: .medium), nameField, typeLabel], spacing: 7)
        connectionForm = stack(.vertical, [
            label("Azure endpoint", size: 12, weight: .medium), endpointField,
            label("Deployment name", size: 12, weight: .medium), modelField,
            label("API key", size: 12, weight: .medium), keyField, keyHint
        ], spacing: 7)
        for v in [endpointField, modelField, keyField, keyHint] { v.widthAnchor.constraint(equalTo: connectionForm.widthAnchor).isActive = true }
        nameField.widthAnchor.constraint(equalTo: identityForm.widthAnchor).isActive = true
        colorWell.target = self; colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let palette = stack(.horizontal, [colorWell], spacing: 7)
        let colors = [("Violet", "#8170E9"), ("Ocean", "#19AAA5"), ("Rose", "#DE7B9B"), ("Amber", "#CF9B42")]
        for (index, pair) in colors.enumerated() {
            let button = NSButton(title: pair.0, target: self, action: #selector(presetColor(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.contentTintColor = NSColor(hex: pair.1)
            palette.addArrangedSubview(button)
        }
        preview.heightAnchor.constraint(equalToConstant: 78).isActive = true
        saveButton = NSButton(title: "Save profile", target: self, action: #selector(saveProfile))
        saveButton.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(closeEditor))
        done.bezelStyle = .rounded
        let buttons = stack(.horizontal, [flexibleSpace(), done, saveButton])
        let form = stack(.vertical, [label("Make it yours", size: 22, weight: .semibold), identityForm, connectionForm,
                                     label("Wave color", size: 12, weight: .medium), palette, preview, status, buttons], spacing: 13)
        for view in [identityForm, connectionForm!, palette, preview, status, buttons] { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        let content = stack(.horizontal, [sidebar, form], spacing: 26)
        content.alignment = .top
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -18)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let p = profiles[row]
        let cell = NSTableCellView()
        let text = label("●  " + p.name, size: 12, weight: .medium, color: p.color)
        text.maximumNumberOfLines = 1
        text.lineBreakMode = .byTruncatingTail
        cell.textField = text
        cell.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, !saving, profiles.indices.contains(table.selectedRow) else { return }
        populate(profiles[table.selectedRow])
    }
    func reload(_ updated: [Profile], select: String?) {
        guard !saving else { return }
        profiles = updated
        reloading = true
        table.reloadData()
        if let index = profiles.firstIndex(where: { $0.id == select }) ?? (profiles.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            populate(profiles[index])
        }
        reloading = false
    }
    func populate(_ p: Profile) {
        editingID = p.id
        nameField.stringValue = p.name
        endpointField.stringValue = p.endpoint
        modelField.stringValue = p.deployment
        colorWell.color = p.color; preview.targetColor = p.color
        keyField.stringValue = ""
        connectionForm.isHidden = p.kind == "personal"
        typeLabel.stringValue = p.kind == "personal" ? "ChatGPT subscription" : "Azure OpenAI"
        deleteButton.isEnabled = p.kind != "personal" && owner.latestStatus["active_profile_id"] as? String != p.id
        status.stringValue = ""
        keyHint.stringValue = keyExists(p.id) ? "Saved in Keychain" : ""
        saveButton.title = "Save profile"
    }
    @objc func newProfile() {
        editingID = nil
        reloading = true; table.deselectAll(nil); reloading = false
        nameField.stringValue = ""
        endpointField.stringValue = ""
        modelField.stringValue = "gpt-6.1-sol"
        keyField.stringValue = ""
        connectionForm.isHidden = false
        typeLabel.stringValue = "New Azure OpenAI profile"
        keyHint.stringValue = ""
        colorWell.color = NSColor(hex: "#DE7B9B"); preview.targetColor = colorWell.color
        deleteButton.isEnabled = false
        saveButton.title = "Create profile"
        status.stringValue = ""
        window.makeFirstResponder(nameField)
    }
    @objc func colorChanged() { preview.targetColor = colorWell.color }
    @objc func presetColor(_ button: NSButton) {
        let colors = ["#8170E9", "#19AAA5", "#DE7B9B", "#CF9B42"]
        colorWell.color = NSColor(hex: colors[button.tag]); colorChanged()
    }
    func setSaving(_ value: Bool) {
        saving = value
        saveButton.isEnabled = !value
        newButton.isEnabled = !value
        deleteButton.isEnabled = !value && editingID != nil && editingID != "personal" && editingID != owner.latestStatus["active_profile_id"] as? String
        table.isEnabled = !value
    }
    @objc func saveProfile() {
        guard !saving else { return }
        guard !owner.busy else { owner.showError(ControllerError.message("Wait for the Codex provider switch to finish before editing profiles.")); return }
        let identity = editingID
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.contains("\n") || key.contains("\r") { owner.showError(ControllerError.message("Paste a single Azure API key.")); return }
        var args = ["profile-save", "--name", nameField.stringValue, "--color", colorWell.color.hexString,
                    "--endpoint", endpointField.stringValue, "--model", modelField.stringValue]
        if let identity = identity { args += ["--profile-id", identity] }
        setSaving(true)
        owner.backend(args) { result in
            self.setSaving(false)
            switch result {
            case .success(let data):
                guard let object = data["profile"] as? [String: Any] else { return }
                let saved = Profile(object)
                var keyError: Error?
                if !demoMode && !key.isEmpty && saved.kind == "azure" {
                    do { try saveKey(key, profileID: saved.id, name: saved.name) } catch { keyError = error }
                }
                self.keyField.stringValue = ""
                let updated = (data["profiles"] as? [[String: Any]] ?? []).map(Profile.init)
                self.owner.selectedID = saved.id
                UserDefaults.standard.set(saved.id, forKey: "selectedProfile")
                self.reload(updated, select: saved.id)
                self.owner.refreshStatus()
                self.status.stringValue = "Saved"
                if let error = keyError { self.owner.showError(ControllerError.message("Profile saved, but its key could not be saved: \(error.localizedDescription)")) }
            case .failure(let error): self.owner.showError(error)
            }
        }
    }
    @objc func deleteProfile() {
        guard !owner.busy else { owner.showError(ControllerError.message("Wait for the Codex provider switch to finish before deleting profiles.")); return }
        guard let identity = editingID, let p = profiles.first(where: { $0.id == identity }), !saving else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(p.name)?"
        alert.informativeText = "Removes this saved profile and its Keychain entry. Recorded usage is retained under All profiles. The currently configured profile and your personal recovery profile cannot be deleted."
        alert.addButton(withTitle: "Delete profile"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setSaving(true)
        owner.backend(["profile-delete", "--profile-id", identity]) { result in
            self.setSaving(false)
            switch result {
            case .success(let data):
                let deleted = demoMode ? errSecItemNotFound : SecItemDelete(keyQuery(identity) as CFDictionary)
                let updated = (data["profiles"] as? [[String: Any]] ?? []).map(Profile.init)
                self.reload(updated, select: "personal")
                if self.owner.selectedID == identity { self.owner.selectedID = "personal" }
                self.owner.refreshStatus()
                if deleted != errSecSuccess && deleted != errSecItemNotFound {
                    self.owner.showError(ControllerError.message("Profile deleted, but remove its saved key manually in Keychain Access (\(deleted))."))
                }
            case .failure(let error): self.owner.showError(error)
            }
        }
    }
    @objc func closeEditor() { NSColorPanel.shared.orderOut(nil); window.orderOut(nil) }
}

final class ActivityWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let owner: AppDelegate
    let window: NSWindow
    let sessionsTable = NSTableView()
    let eventsTable = NSTableView()
    let detail = NSTextView()
    let heading = label("Activity", size: 23, weight: .semibold)
    let counter = label("", size: 11, color: .secondaryLabelColor)
    let filter = NSPopUpButton(frame: .zero, pullsDown: false)
    var sessions: [[String: Any]] = []
    var events: [[String: Any]] = []
    var visibleEvents: [[String: Any]] = []
    var selectedSession: String?
    var profileID: String?
    var reloading = false
    var request = 0

    init(owner: AppDelegate) {
        self.owner = owner
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1130, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Codex Activity"
        window.minSize = NSSize(width: 950, height: 550)
        window.isReleasedWhenClosed = false
        window.center()
        func tableScroll(_ table: NSTableView, width: CGFloat) -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
            column.width = width - 12
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 48
            table.dataSource = self; table.delegate = self
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
            return scroll
        }
        let sessionsView = tableScroll(sessionsTable, width: 225)
        let eventsView = tableScroll(eventsTable, width: 260)
        let detailView = NSScrollView()
        detailView.hasVerticalScroller = true
        detailView.borderType = .bezelBorder
        detail.isEditable = false
        detail.isSelectable = true
        detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textContainerInset = NSSize(width: 16, height: 16)
        detail.autoresizingMask = [.width]
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.textContainer?.widthTracksTextView = true
        detail.minSize = .zero; detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailView.documentView = detail
        let columns = stack(.horizontal, [sessionsView, eventsView, detailView], spacing: 12)
        columns.alignment = .top
        sessionsView.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        eventsView.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        detailView.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        filter.addItems(withTitles: ["All events", "Tool calls", "Results", "Reasoning summaries", "Messages"])
        filter.target = self; filter.action = #selector(filterChanged)
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh activity")!, target: self, action: #selector(refreshActivity))
        refresh.bezelStyle = .rounded
        let top = stack(.horizontal, [heading, flexibleSpace(), filter, refresh])
        let titles = stack(.horizontal, [label("SESSIONS", size: 10, weight: .semibold, color: .secondaryLabelColor), flexibleSpace(), counter])
        let root = stack(.vertical, [top, titles, columns], spacing: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        for view in [top, titles, columns] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        columns.setContentHuggingPriority(.init(1), for: .vertical)
    }
    func load(profile: Profile?) {
        profileID = profile?.id
        heading.stringValue = "Activity · \(profile?.name ?? "All profiles")"
        selectedSession = nil
        refreshActivity()
    }
    @objc func refreshActivity() {
        request += 1; let number = request
        counter.stringValue = "Loading…"
        var args = ["activity"]
        if let profileID = profileID { args += ["--profile-id", profileID] }
        if let selectedSession = selectedSession { args += ["--session-id", selectedSession] }
        owner.backend(args) { result in
            guard self.request == number else { return }
            switch result {
            case .success(let data):
                self.reloading = true
                self.sessions = data["sessions"] as? [[String: Any]] ?? []
                self.selectedSession = data["session_id"] as? String
                self.events = (data["events"] as? [[String: Any]] ?? []).reversed()
                self.sessionsTable.reloadData()
                if let index = self.sessions.firstIndex(where: { $0["id"] as? String == self.selectedSession }) {
                    self.sessionsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
                self.reloading = false
                self.filterChanged()
            case .failure(let error): self.counter.stringValue = error.localizedDescription
            }
        }
    }
    @objc func filterChanged() {
        let category = ["", "tool", "result", "summary", "message"][filter.indexOfSelectedItem]
        visibleEvents = events.filter { category.isEmpty || $0["category"] as? String == category }
        reloading = true
        eventsTable.reloadData()
        if !visibleEvents.isEmpty { eventsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        reloading = false
        counter.stringValue = "\(sessions.count) sessions · \(visibleEvents.count) events"
        showEvent()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sessionsTable ? sessions.count : visibleEvents.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let data = tableView === sessionsTable ? sessions : visibleEvents
        guard data.indices.contains(row) else { return nil }
        let title = data[row]["title"] as? String ?? "Event"
        let suffix = tableView === sessionsTable ? data[row]["started"] as? String ?? "" : data[row]["timestamp"] as? String ?? ""
        let text = label(title.replacingOccurrences(of: "\n", with: " ") + "\n" + String(suffix.prefix(19)).replacingOccurrences(of: "T", with: " "), size: 11)
        text.maximumNumberOfLines = 2; text.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView(); cell.addSubview(text); cell.textField = text
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let table = notification.object as? NSTableView else { return }
        if table === sessionsTable && sessions.indices.contains(table.selectedRow) {
            selectedSession = sessions[table.selectedRow]["id"] as? String
            refreshActivity()
        } else { showEvent() }
    }
    func showEvent() {
        guard visibleEvents.indices.contains(eventsTable.selectedRow) else { detail.string = "No recorded events"; return }
        let event = visibleEvents[eventsTable.selectedRow]
        detail.string = (event["title"] as? String ?? "") + "\n" + (event["timestamp"] as? String ?? "") + "\n\n" + (event["detail"] as? String ?? "")
        detail.scrollToBeginningOfDocument(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel = label("Reading configuration…", size: 14, weight: .medium)
    var detailLabel = label("", size: 12, color: .secondaryLabelColor)
    var keyStatus = label("", size: 11, color: .secondaryLabelColor)
    var footer = label("", size: 11, color: .secondaryLabelColor)
    var providerBreakdown = label("Loading local usage…", size: 12, color: .secondaryLabelColor)
    var profilePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    var profiles: [Profile] = []
    var selectedID = "personal"
    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }
    var wave = WaveView(frame: .zero)
    var selectedName = label("Personal subscription", size: 17, weight: .semibold)
    var connectionInfo: NSStackView!
    var profileNote = label("", size: 11, color: .secondaryLabelColor)
    var usageTitle = label("Token activity", size: 16, weight: .semibold)
    var usageScope = NSSegmentedControl(labels: ["This profile", "All profiles"], trackingMode: .selectOne, target: nil, action: nil)
    var usageRequest = 0
    var editor: ProfileEditor?
    var endpoint = NSTextField(string: "")
    var deployment = NSTextField(string: "gpt-6.1-sol")
    var secret = NSSecureTextField(string: "")
    var chart = UsageChart()
    var metricLabels: [String: NSTextField] = [:]
    var metricDetails: [String: NSTextField] = [:]
    var applyButton: NSButton!
    var refreshButton: NSButton!
    var busy = false
    var latestStatus: [String: Any] = [:]
    var activityWindow: ActivityWindow?
    let bundleID = "com.openai.codex"

    var targetApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? (FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") ? URL(fileURLWithPath: "/Applications/ChatGPT.app") : nil)
    }
    var resources: URL { Bundle.main.resourceURL! }
    var helper: String { Bundle.main.executableURL!.path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if demoMode {
            try? FileManager.default.createDirectory(at: demoState, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: resources.appendingPathComponent("demo/state/settings.json"), to: demoState.appendingPathComponent("settings.json"))
        }
        buildMenu()
        buildWindow()
        refreshStatus(updateFields: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Codex Controller", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Profile Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Codex Controller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1010, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Controller"
        window.minSize = NSSize(width: 880, height: 650)
        window.center()
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = label("Codex Controller", size: 27, weight: .bold)
        wave.motion = true
        let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Profile settings")!, target: self, action: #selector(showSettings))
        settingsButton.toolTip = "Profile settings"
        settingsButton.bezelStyle = .rounded
        let header = NSView()
        wave.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(wave)
        let heading = stack(.horizontal, [title, flexibleSpace(), settingsButton])
        let heroContent = stack(.vertical, [heading, selectedName], spacing: 16)
        heroContent.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(heroContent)
        NSLayoutConstraint.activate([
            wave.leadingAnchor.constraint(equalTo: header.leadingAnchor), wave.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            wave.topAnchor.constraint(equalTo: header.topAnchor), wave.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            heroContent.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            heroContent.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22),
            heroContent.topAnchor.constraint(equalTo: header.topAnchor, constant: 20),
            heroContent.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -20),
            heading.widthAnchor.constraint(equalTo: heroContent.widthAnchor)
        ])

        let status = stack(.vertical, [statusLabel, detailLabel], spacing: 5)
        let statusPanel = Panel(status, padding: 14)
        profilePicker.target = self
        profilePicker.action = #selector(providerChanged)
        profilePicker.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let providerTitle = stack(.horizontal, [label("Profile", size: 16, weight: .semibold), flexibleSpace(), profilePicker])
        let form = NSGridView(views: [
            [label("Azure endpoint", size: 12, color: .secondaryLabelColor), endpoint],
            [label("Deployment name", size: 12, color: .secondaryLabelColor), deployment]
        ])
        form.columnSpacing = 16
        form.rowSpacing = 10
        form.column(at: 0).width = 120
        form.column(at: 0).xPlacement = .leading
        form.column(at: 1).xPlacement = .fill
        endpoint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        deployment.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        endpoint.isEditable = false
        deployment.isEditable = false
        secret.placeholderString = "Azure API key"
        let save = NSButton(title: "Save in Keychain", target: self, action: #selector(saveCredential))
        save.bezelStyle = .rounded
        let keyRow = stack(.horizontal, [secret, save])
        secret.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        let keyInfo = stack(.vertical, [keyRow, keyStatus], spacing: 5)
        connectionInfo = stack(.vertical, [form, keyInfo], spacing: 12)
        let providerContent = stack(.vertical, [providerTitle, connectionInfo, profileNote], spacing: 13)
        for v in [providerTitle, connectionInfo!, profileNote] { v.widthAnchor.constraint(equalTo: providerContent.widthAnchor).isActive = true }
        for v in [form, keyInfo] { v.widthAnchor.constraint(equalTo: connectionInfo.widthAnchor).isActive = true }
        keyRow.widthAnchor.constraint(equalTo: keyInfo.widthAnchor).isActive = true
        let providerPanel = Panel(providerContent)

        refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh usage")!, target: self, action: #selector(refreshTapped))
        refreshButton.toolTip = "Refresh usage"
        refreshButton.bezelStyle = .rounded
        refreshButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        usageScope.selectedSegment = 0
        usageScope.target = self
        usageScope.action = #selector(usageScopeChanged)
        let usageHeader = stack(.horizontal, [usageTitle, flexibleSpace(), usageScope, refreshButton])
        let cards = stack(.horizontal, [], spacing: 12)
        cards.distribution = .fillEqually
        for (key, name) in [("today", "TODAY"), ("week", "THIS WEEK"), ("month", "THIS MONTH")] {
            let amount = label("—", size: 28, weight: .semibold)
            amount.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
            let details = label("Input — · Output —", size: 10, color: .secondaryLabelColor)
            let box = stack(.vertical, [label(name, size: 10, weight: .semibold, color: .secondaryLabelColor), amount, details], spacing: 5)
            metricLabels[key] = amount
            metricDetails[key] = details
            cards.addArrangedSubview(box)
        }
        let scope = label("Hong Kong time · Week starts Monday", size: 10, color: .secondaryLabelColor)
        let usageContent = stack(.vertical, [usageHeader, cards, chart, providerBreakdown, scope], spacing: 12)
        for v in [usageHeader, cards, chart, providerBreakdown, scope] { v.widthAnchor.constraint(equalTo: usageContent.widthAnchor).isActive = true }
        chart.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let usagePanel = Panel(usageContent)

        let backups = NSButton(title: "Backups", target: self, action: #selector(openBackups))
        backups.bezelStyle = .rounded
        let open = NSButton(title: "Open Codex", target: self, action: #selector(openCodex))
        open.bezelStyle = .rounded
        applyButton = NSButton(title: "Switch & Open", target: self, action: #selector(applySelection))
        applyButton.bezelStyle = .rounded
        applyButton.contentTintColor = .systemTeal
        let activityButton = NSButton(title: "Activity", target: self, action: #selector(showActivity))
        activityButton.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Activity")
        activityButton.imagePosition = .imageLeading
        activityButton.bezelStyle = .rounded
        let actions = stack(.horizontal, [activityButton, backups, flexibleSpace(), open, applyButton])
        footer.stringValue = ""
        let root = stack(.vertical, [header, statusPanel, providerPanel, usagePanel, actions, footer], spacing: 14)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.addSubview(scroll)
        root.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])
        for v in [header, statusPanel, providerPanel, usagePanel, actions, footer] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        window.makeKeyAndOrderFront(nil)
    }

    func backend(_ args: [String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                var arguments = args
                if demoMode {
                    arguments += ["--home", self.resources.appendingPathComponent("demo/codex").path,
                                  "--state", demoState.path]
                }
                process.arguments = [self.resources.appendingPathComponent("backend/controller.py").path] + arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ControllerError.message("The local controller returned an invalid response.")
                }
                if object["ok"] as? Bool != true {
                    throw ControllerError.message(object["error"] as? String ?? "Controller operation failed.")
                }
                guard let result = object["data"] as? [String: Any] else { throw ControllerError.message("Missing controller response.") }
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func refreshStatus(updateFields: Bool = false) {
        backend(["status"]) { result in
            switch result {
            case .success(let data):
                self.latestStatus = data
                self.profiles = (data["profiles"] as? [[String: Any]] ?? []).map(Profile.init)
                let activeID = data["active_profile_id"] as? String
                let name = self.profiles.first { $0.id == activeID }?.name ?? "Another provider"
                self.statusLabel.stringValue = "Active · \(name)"
                self.detailLabel.stringValue = data["model"] as? String ?? "Default model"
                if updateFields {
                    self.selectedID = UserDefaults.standard.string(forKey: "selectedProfile") ?? activeID ?? "personal"
                }
                if !self.profiles.contains(where: { $0.id == self.selectedID }) { self.selectedID = activeID ?? "personal" }
                self.rebuildPicker()
                self.showSelectedProfile()
            case .failure(let error): self.showError(error)
            }
        }
    }

    func refreshUsage() {
        let requestID = usageRequest + 1
        usageRequest = requestID
        refreshButton.isEnabled = false
        let all = usageScope.selectedSegment == 1
        let requestedProfile = selectedID
        usageTitle.stringValue = all ? "All token activity" : "Token activity"
        metricLabels.values.forEach { $0.stringValue = "—" }
        metricDetails.values.forEach { $0.stringValue = "Loading…" }
        chart.days = []
        providerBreakdown.stringValue = all ? "Loading all profiles…" : "Loading \(selectedProfile?.name ?? "profile")…"
        backend(["usage"] + (all ? [] : ["--profile-id", requestedProfile])) { result in
            guard self.usageRequest == requestID else { return }
            self.refreshButton.isEnabled = true
            switch result {
            case .success(let data):
                let periods = data["periods"] as? [String: [String: Any]] ?? [:]
                for key in ["today", "week", "month"] {
                    let p = periods[key] ?? [:]
                    self.metricLabels[key]?.stringValue = self.compact(p["total"])
                    self.metricDetails[key]?.stringValue = "In \(self.compact(p["input"])) · Cached \(self.compact(p["cached"])) · Out \(self.compact(p["output"]))"
                }
                self.chart.days = data["days"] as? [[String: Any]] ?? []
                let providers = data["providers_month"] as? [String: [String: Any]] ?? [:]
                let text = providers.keys.sorted().map { key -> String in
                    let name = key == "openai" ? "OpenAI" : (key.contains("azure") ? "Azure (\(key))" : key)
                    return "\(name): \(self.compact(providers[key]?["total"]))"
                }.joined(separator: "    •    ")
                self.providerBreakdown.stringValue = all ? "This month  ·  " + (text.isEmpty ? "No local usage recorded yet" : text) : "\(data["profile_name"] as? String ?? "Profile") · This month's recorded requests: \((periods["month"]?["requests"] as? NSNumber)?.stringValue ?? "0")"
                let skipped = data["unreadable_files"] as? Int ?? 0
                self.footer.stringValue = "\(data["files"] as? Int ?? 0) sessions" + (skipped > 0 ? " · \(skipped) unavailable" : "")
                if demoMode, let path = Bundle.main.infoDictionary?["ControllerScreenshotPath"] as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.exportPreview(to: path) }
                }
            case .failure(let error):
                self.providerBreakdown.stringValue = "Usage unavailable: \(error.localizedDescription)"
            }
        }
    }

    func compact(_ value: Any?) -> String {
        let v = (value as? NSNumber)?.doubleValue ?? 0
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "0"
    }

    func updateKeyStatus() {
        guard let profile = selectedProfile, profile.kind == "azure" else { return }
        let exists = keyExists(profile.id)
        keyStatus.stringValue = exists ? "Saved in Keychain" : "Add an API key"
        keyStatus.textColor = exists ? .systemTeal : .secondaryLabelColor
    }

    @objc func providerChanged() {
        guard profiles.indices.contains(profilePicker.indexOfSelectedItem) else { return }
        selectedID = profiles[profilePicker.indexOfSelectedItem].id
        UserDefaults.standard.set(selectedID, forKey: "selectedProfile")
        showSelectedProfile()
    }
    @objc func refreshTapped() { refreshStatus() }
    @objc func usageScopeChanged() { refreshUsage() }
    func rebuildPicker() {
        profilePicker.removeAllItems()
        for profile in profiles { profilePicker.addItem(withTitle: profile.name) }
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) { profilePicker.selectItem(at: index) }
    }
    func showSelectedProfile() {
        guard let p = selectedProfile else { return }
        selectedName.stringValue = p.name
        selectedName.textColor = p.color
        wave.targetColor = p.color
        chart.accent = p.color
        applyButton.contentTintColor = p.color
        statusLabel.textColor = .labelColor
        connectionInfo.isHidden = p.kind == "personal"
        endpoint.stringValue = p.endpoint
        deployment.stringValue = p.deployment
        secret.stringValue = ""
        applyButton.title = "Switch & Open"
        profileNote.stringValue = p.kind == "personal" ? "ChatGPT subscription" : "Azure OpenAI"
        updateKeyStatus()
        refreshUsage()
    }
    @objc func showActivity() {
        if activityWindow == nil { activityWindow = ActivityWindow(owner: self) }
        activityWindow?.load(profile: selectedProfile)
        activityWindow?.window.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        guard !busy else { return }
        if editor == nil { editor = ProfileEditor(owner: self) }
        editor?.reload(profiles, select: selectedID)
        editor?.window.makeKeyAndOrderFront(nil)
    }

    @objc func saveCredential() {
        guard !demoMode else { return }
        guard let profile = selectedProfile, profile.kind == "azure" else { return }
        let key = secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else {
            showError(ControllerError.message("Paste a single Azure API key first.")); return
        }
        do { try saveKey(key, profileID: profile.id, name: profile.name); secret.stringValue = ""; updateKeyStatus() }
        catch { showError(error) }
    }

    @objc func applySelection() {
        guard !demoMode else { return }
        guard !busy else { return }
        guard let profile = selectedProfile else { return }
        if profile.kind == "azure" && (profile.endpoint.isEmpty || profile.deployment.isEmpty) {
            showError(ControllerError.message("Set the endpoint and deployment in Profile Settings.")); return
        }
        if profile.kind == "azure" && !keyExists(profile.id) {
            showError(ControllerError.message("Save your Azure API key in Keychain before switching.")); return
        }
        guard targetApp != nil else { showError(ControllerError.message("Could not locate your original Codex / ChatGPT app.")); return }
        let alert = NSAlert()
        alert.messageText = "Switch to \(profile.name)?"
        alert.informativeText = "Codex will close and reopen. Finish active work before continuing, then start a new chat."
        alert.addButton(withTitle: "Switch & Reopen")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        applyButton.isEnabled = false
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in apps { app.terminate() }
        footer.stringValue = "Waiting for Codex to close normally…"
        waitForQuit(deadline: Date().addingTimeInterval(20)) { closed in
            guard closed else {
                self.busy = false; self.applyButton.isEnabled = true
                self.showError(ControllerError.message("Codex is still running. Finish your work and quit it manually, then try again. No settings were changed.")); return
            }
            self.backend(["apply", "--profile-id", profile.id, "--helper", self.helper]) { result in
                self.busy = false; self.applyButton.isEnabled = true
                switch result {
                case .success:
                    self.footer.stringValue = "Provider settings saved. Start a new chat in Codex and confirm its selected model."
                    self.refreshStatus()
                    self.openCodex()
                case .failure(let error):
                    self.showError(error)
                    if !apps.isEmpty { self.openCodex() }
                }
            }
        }
    }

    func waitForQuit(deadline: Date, completion: @escaping (Bool) -> Void) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { completion(true); return }
        if Date() > deadline { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.waitForQuit(deadline: deadline, completion: completion) }
    }

    @objc func openCodex() {
        guard let url = targetApp else { showError(ControllerError.message("Original Codex app not found.")); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    @objc func openBackups() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Controller/backups")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { showError(ControllerError.message("A backup is created automatically the first time you switch providers.")) }
    }
    @objc func showAbout() {
        let a = NSAlert()
        a.messageText = "Codex Controller 0.3"
        a.informativeText = "Local provider switching and token activity for the original Codex app. It makes no inference requests and stores no prompts. Usage is reconstructed from local session records and may be incomplete."
        a.runModal()
    }
    func showError(_ error: Error) {
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Codex Controller"
        a.informativeText = error.localizedDescription
        a.runModal()
    }
    func exportPreview(to path: String) {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
