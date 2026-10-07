import Cocoa
import UsageHUDCore

/// One line of the logo's popover: a battery, a name and its reading, or a plain command. Hovering lights it like a menu row.
final class PopoverRow: NSView {
    var action: () -> Void = {}
    var context: ((NSEvent, NSView) -> Void)?
    private let tint = NSView()
    init(image: NSImage?, title: String, detail: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        wantsLayer = true
        tint.wantsLayer = true; tint.layer?.cornerRadius = 7; tint.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        tint.frame = bounds.insetBy(dx: 6, dy: 1); tint.isHidden = true; addSubview(tint)
        var x: CGFloat = 14
        if let image = image {
            let view = NSImageView(image: image); view.frame = NSRect(x: x, y: (30 - image.size.height) / 2, width: image.size.width, height: image.size.height)
            addSubview(view); x += image.size.width + 10
        }
        let name = NSTextField(labelWithString: title); name.font = .menuFont(ofSize: 0); name.sizeToFit()
        name.frame.origin = NSPoint(x: x, y: (30 - name.frame.height) / 2); addSubview(name)
        if !detail.isEmpty {
            let reading = NSTextField(labelWithString: detail); reading.font = .menuFont(ofSize: 0); reading.textColor = .secondaryLabelColor; reading.sizeToFit()
            reading.frame.origin = NSPoint(x: width - 14 - reading.frame.width, y: (30 - reading.frame.height) / 2); addSubview(reading)
        }
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { tint.isHidden = false }
    override func mouseExited(with event: NSEvent) { tint.isHidden = true }
    override func mouseDown(with event: NSEvent) { action() }
    override func rightMouseDown(with event: NSEvent) { context?(event, self) }
}

extension HUD {
    /// What a click on the logo opens, drawn by the system's own popover so its glass and edge are the system's: the batteries
    /// behind the logo (choose one to keep it in the bar), then Add source… and Quit.
    func showLogoPopover(from sender: StatusCellButton, hidden: Bool) {
        logoPopover.close()
        let ids = hidden ? arrangedIDs.filter { id in !(items[id]?.isVisible ?? false) } : arrangedIDs
        let entries = shelf.ranked(ids).compactMap { id -> (String, Panel)? in panels[id].map { (id, $0) } }
        let width: CGFloat = 270
        var rows: [PopoverRow] = []
        for (id, panel) in entries {
            let balance = panel.windows.first { $0.label == panel.name }?.right
            let reading = balance ?? displayedQuota(panel)?.pct.map { "\(Int((100 - $0).rounded()))% left" } ?? "no reading"
            let row = PopoverRow(image: icon(panel), title: panel.name, detail: reading, width: width)
            if hidden {
                row.action = { [weak self] in self?.logoPopover.close(); self?.keepInBar(id) }
            }
            row.context = { [weak self] event, view in
                guard let self = self else { return }
                NSMenu.popUpContextMenu(self.providerMenu(panel), with: event, for: view)
            }
            rows.append(row)
        }
        let add = PopoverRow(image: nil, title: "Add source…", detail: "", width: width)
        add.action = { [weak self] in self?.logoPopover.close(); self?.addSourceFromMenu() }
        let quit = PopoverRow(image: nil, title: "Quit Usage HUD", detail: "⌘Q", width: width)
        quit.action = { [weak self] in self?.quit() }
        let stack = NSStackView(views: rows + [add, quit])
        stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        if !rows.isEmpty { stack.setCustomSpacing(8, after: rows.last!) }
        let height = CGFloat(rows.count + 2) * 30 + 16 + (rows.isEmpty ? 0 : 8)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let controller = NSViewController(); controller.view = stack
        logoPopover.contentViewController = controller; logoPopover.contentSize = stack.frame.size
        logoPopover.behavior = .transient; logoPopover.animates = true
        NSApp.activate(ignoringOtherApps: true)
        logoPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}
