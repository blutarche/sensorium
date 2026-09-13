import AppKit
import Foundation

/// One launch's result, as the off-main placement poll reports it: which
/// application, and what became of it. The words come later, on the main
/// thread, where the view's own `hostName` is.
struct CanvasLaunchReport: Sendable {
    let application: String
    let outcome: CanvasApplicationLaunchOutcome
}

/// Carries one launch report from the off-main placement poll back to the
/// launcher's status label. The label is AppKit main-thread state and cannot be
/// captured by the `@Sendable` closure the adopter runs; this box is the one
/// place that boundary is crossed, and it crosses it by hopping to the main
/// thread rather than by sharing the view.
final class LaunchStatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@MainActor (CanvasLaunchReport) -> Void)?

    @MainActor
    func connect(_ deliver: @escaping @MainActor (CanvasLaunchReport) -> Void) {
        lock.lock()
        self.deliver = deliver
        lock.unlock()
    }

    func post(_ report: CanvasLaunchReport) {
        lock.lock()
        let deliver = self.deliver
        lock.unlock()
        guard let deliver else {
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                deliver(report)
            }
        }
    }
}

/// How loudly one line of launcher status reads.
///
/// Carried from the launch outcome itself rather than derived from the message
/// text, so a failure can never be drawn like a success because two sentences
/// happened to start the same way.
public enum CanvasLauncherStatusSeverity: Equatable, Sendable {
    /// Standing information about what the catalog holds.
    case neutral
    /// Something is under way and has not settled yet.
    case progress
    /// The application is on this canvas.
    case ok
    /// It started, but its window is not here.
    case warn
    /// Nothing started, or nothing can.
    case bad

    public var color: DesignColor {
        switch self {
        case .neutral: return CanvasDesign.muted
        case .progress: return CanvasDesign.info
        case .ok: return CanvasDesign.ok
        case .warn: return CanvasDesign.warn
        case .bad: return CanvasDesign.bad
        }
    }
}

/// The launcher panel's fixed measurements, kept out of the view so the ones
/// that decide whether text fits and whether the list sizes to its content can
/// be checked without a window.
public enum CanvasLauncherMetrics {
    /// A 16pt icon with 4px above and below it. On the 4px grid.
    public static let rowHeight: CGFloat = 24
    public static let iconSize: CGFloat = 16

    /// How many characters of the mono face fit across the panel's inner width
    /// at 12px. JetBrains Mono advances 0.6em, so 408pt / 7.2pt is 56; the
    /// budget is under that, because copy that fits exactly is copy that is one
    /// long application name away from being cut in half.
    public static let lineBudget = 50

    /// The list is exactly as tall as the rows it holds, until it runs out of
    /// panel: one match is one row, not a screenful of list background.
    public static func listHeight(
        rowCount: Int,
        available: CGFloat,
        rowHeight: CGFloat = rowHeight
    ) -> CGFloat {
        min(available, CGFloat(max(0, rowCount)) * rowHeight)
    }
}

/// One line of launcher status: what to say, and how loudly.
public struct CanvasLauncherStatus: Equatable, Sendable {
    public let text: String
    public let severity: CanvasLauncherStatusSeverity

    public init(text: String, severity: CanvasLauncherStatusSeverity) {
        self.text = text
        self.severity = severity
    }
}

/// The system's two-line empty state: a heading naming what is empty, and
/// subtext naming what to do about it.
public struct CanvasLauncherEmptyState: Equatable, Sendable {
    public let heading: String
    public let subtext: String

    public init(heading: String, subtext: String) {
        self.heading = heading
        self.subtext = subtext
    }
}

/// Every word and severity the launcher shows, decided without AppKit.
public enum CanvasLauncherPresentation {
    /// The keyboard hint. Constant chrome, never a status: a count and a hint
    /// are different kinds of information and cannot share one line.
    /// Two authored lines rather than one that wraps: at this width a wrap
    /// lands after a separator and clips the last item.
    public static let keyboardHint = """
        Type to filter · Arrows to choose
        Return to launch · Esc to close
        """

    /// `showing` is how many rows the list is actually offering. A count of the
    /// whole catalog printed under a list showing one row reads as a
    /// contradiction, so a filtered list is counted by what it shows.
    ///
    /// An empty catalog leaves this blank: `emptyState(catalogCount: 0)`'s
    /// subtext already says the host has nothing installed, and a status line
    /// under it saying the same thing again reads as a stutter.
    public static func catalogStatus(count: Int, showing: Int? = nil) -> CanvasLauncherStatus {
        guard count > 0 else {
            return CanvasLauncherStatus(text: "", severity: .neutral)
        }
        if let showing, showing != count {
            return CanvasLauncherStatus(text: "\(showing) of \(count)", severity: .neutral)
        }
        let text = count == 1 ? "1 application" : "\(count) applications"
        return CanvasLauncherStatus(text: text, severity: .neutral)
    }

    public static func launchingStatus(application: String) -> CanvasLauncherStatus {
        CanvasLauncherStatus(text: "Launching \(application)…", severity: .progress)
    }

    /// The outcome's own words, not the host log's. The log line names the step
    /// and the framework's error; a remote user reading one line on a streamed
    /// canvas needs what happened to their application and what to do next.
    public static func outcomeStatus(
        application: String,
        outcome: CanvasApplicationLaunchOutcome,
        hostName: String = Host.current().localizedName ?? "this machine"
    ) -> CanvasLauncherStatus {
        switch outcome {
        case .launchFailed:
            return CanvasLauncherStatus(
                text: "\(application) did not open on \(hostName). It may no longer be installed there.",
                severity: .bad
            )
        case let .placed(windows):
            let text = windows == 1
                ? "\(application) is open."
                : "\(application) is open, in \(windows) windows."
            return CanvasLauncherStatus(text: text, severity: .ok)
        case .placementRefused:
            return CanvasLauncherStatus(
                text: "\(application) opened, but its window could not be moved here.",
                severity: .warn
            )
        case .noWindows:
            return CanvasLauncherStatus(
                text: "\(application) opened but has not shown a window yet.",
                severity: .warn
            )
        case .accessibilityDenied:
            return CanvasLauncherStatus(
                text: "\(application) opened elsewhere."
                    + " Grant Sensorium Accessibility access on the host machine.",
                severity: .bad
            )
        }
    }

    /// A host with nothing installed and a filter that matched nothing need
    /// different advice. `hostName` names the host explicitly, because this
    /// panel is drawn on the session canvas only the remote viewer sees. The
    /// catalog is scanned once at install and never refreshed, so connecting
    /// again is the only way to see a newly installed application.
    public static func emptyState(
        catalogCount: Int,
        hostName: String = Host.current().localizedName ?? "this machine"
    ) -> CanvasLauncherEmptyState {
        guard catalogCount > 0 else {
            return CanvasLauncherEmptyState(
                heading: "Nothing to Launch",
                subtext: "Install an application on \(hostName) and reconnect."
            )
        }
        return CanvasLauncherEmptyState(
            heading: "No Matching Applications",
            subtext: "Clear the filter, or type fewer letters."
        )
    }

    /// What Return says when there is no row to launch. Pressing a key and
    /// having nothing at all happen is the one thing this panel must never do.
    public static func nothingToLaunchStatus(
        catalogCount: Int,
        hostName: String = Host.current().localizedName ?? "this machine"
    ) -> CanvasLauncherStatus {
        guard catalogCount > 0 else {
            return CanvasLauncherStatus(
                text: "Nothing to launch: no applications were found on \(hostName).",
                severity: .warn
            )
        }
        return CanvasLauncherStatus(
            text: "No application matches what you typed. Try fewer letters.",
            severity: .warn
        )
    }

    /// The keyboard hint, trimmed to what still works: an empty catalog has
    /// nothing to type, choose, or launch, and a filter matching nothing
    /// still has nothing to choose or launch, though typing a different
    /// query still might.
    public static func footerHint(catalogCount: Int, visibleCount: Int) -> String {
        guard catalogCount > 0 else {
            return "Esc to close"
        }
        guard visibleCount > 0 else {
            return "Type to filter \u{00B7} Esc to close"
        }
        return keyboardHint
    }
}

/// The application launcher a remote user operates on the session canvas.
///
/// Driven by the input that is already proven on hardware: the pointer, and
/// keys typed into the query field. Typing filters, the arrow keys move the
/// selection, Return launches, and Escape hands the keyboard back to the
/// workspace's text view. Everything it decides -- what is installed, what the
/// query selects, where a launched window may go -- lives in
/// `CanvasApplicationCatalog` and `CanvasLaunchedWindowPlacement`; this view
/// only draws it.
@MainActor
final class CanvasLauncherView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let queryField = NSTextField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// The keyboard hint, on its own line and updated by `applyQuery()` to
    /// name only what still works in the catalog's current state. Kept
    /// separate from `statusLabel`, since sharing one label would let the
    /// catalog count overwrite the hint before anyone reads it.
    private let hintLabel = NSTextField(labelWithString: CanvasLauncherPresentation.keyboardHint)
    /// Draws the input's fill, border and focus state around `queryField`, so
    /// the field itself can stay unbezelled and inherit none of AppKit's own
    /// control chrome.
    private let queryWell = NSView()
    private let emptyState = LauncherEmptyStateView()
    private let brand = NSTextField(labelWithString: "")
    private let eyebrow = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
    /// One `NSWorkspace` icon lookup per bundle, however often the table asks
    /// for the row again while the remote user scrolls.
    private var iconCache: [String: NSImage] = [:]
    private let launcher: CanvasApplicationLauncher
    private let relay = LaunchStatusRelay()
    private var applications: [LaunchableApplication] = []
    private var visible: [LaunchableApplication] = []
    /// Whether the query field holds the keyboard. The table is never itself
    /// first responder -- the field drives it -- so AppKit's own emphasis is
    /// always false here and the selected row has to be told directly whether
    /// it is the live one or a leftover the user has typed away from.
    private var listIsActive = false
    /// The one name every sentence on this panel calls the host by. This
    /// panel is drawn on the session canvas, which only the remote viewer
    /// ever sees, so "this machine" would read as the viewer's own machine.
    var hostName: String = Host.current().localizedName ?? "this machine"
    /// Called when the remote user presses Escape, so the workspace can hand
    /// the keyboard back to its text view.
    var onDismiss: (() -> Void)?
    /// The tallest the panel may stand: the column the workspace gave it. The
    /// panel takes only the height its contents need, up to this, and keeps its
    /// top edge where it is -- a query matching one application is a small card,
    /// not a full-height box that is empty from the second row down.
    var maximumHeight: CGFloat {
        didSet {
            layoutColumn()
        }
    }
    /// `layoutColumn` resizes the view it is laying out, which asks AppKit for
    /// another layout pass. The flag keeps that one pass rather than a spiral.
    private var isLayingOut = false

    init(frame frameRect: NSRect, canvas: CanvasWorkspacePlacement) {
        maximumHeight = frameRect.height
        let relay = self.relay
        launcher = CanvasApplicationLauncher(
            canvas: canvas,
            opener: WorkspaceApplicationOpener(),
            adopter: CanvasWindowAdopter(
                placer: AccessibilityWindowPlacer(),
                isAccessibilityTrusted: HostAccessibilityTrust.isTrusted
            ),
            log: { print($0) },
            onOutcome: { application, outcome in
                relay.post(CanvasLaunchReport(application: application, outcome: outcome))
            }
        )
        super.init(frame: frameRect)

        applyDesignSurface(fill: CanvasDesign.bg2, border: CanvasDesign.line, radius: CanvasDesign.Radius.wide)

        brand.attributedStringValue = CanvasDesign.wordmark("Sensorium")
        addSubview(brand)

        queryWell.applyDesignSurface(fill: CanvasDesign.bg4, border: CanvasDesign.line2)
        addSubview(queryWell)

        queryField.font = CanvasDesign.font(.primary, size: 14)
        queryField.textColor = CanvasDesign.ink.nsColor
        queryField.placeholderAttributedString = NSAttributedString(
            string: "Filter by name",
            attributes: [
                .font: CanvasDesign.font(.primary, size: 14),
                .foregroundColor: CanvasDesign.muted2.nsColor
            ]
        )
        queryField.delegate = self
        // Sending on Return would end editing and clear the field before the
        // list has been consulted; Return is handled as a command instead, in
        // `control(_:textView:doCommandBy:)`, alongside the arrow keys.
        queryField.isBezeled = false
        queryField.isBordered = false
        queryField.drawsBackground = false
        // The system marks focus with the accent, on the well's border; AppKit's
        // ring would draw a second, system-coloured one around the same edge.
        queryField.focusRingType = .none
        queryWell.addSubview(queryField)

        eyebrow.attributedStringValue = CanvasDesign.eyebrow("Applications")
        addSubview(eyebrow)

        statusLabel.font = CanvasDesign.font(.primary, size: 12)
        statusLabel.textColor = CanvasDesign.muted.nsColor
        // Unbounded and measured at layout, so a three-line failure message
        // is not clipped.
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        addSubview(statusLabel)

        hintLabel.font = CanvasDesign.font(.mono, size: 12)
        hintLabel.textColor = CanvasDesign.muted.nsColor
        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byWordWrapping
        addSubview(hintLabel)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CanvasDesign.bg.nsColor
        scrollView.scrollerKnobStyle = .light
        scrollView.applyDesignSurface(fill: CanvasDesign.bg, border: CanvasDesign.line)
        scrollView.layer?.masksToBounds = true

        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = CanvasLauncherMetrics.rowHeight
        // The rows carry their own inset; a gap between them as well would cost
        // a row of names per screen and buy nothing, and 2pt is off the grid.
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        // `.automatic` resolves to an inset, rounded style on current macOS,
        // which is both the bubbly shape the system rules out and a side inset
        // this panel has no room to spend.
        tableView.style = .plain
        tableView.backgroundColor = CanvasDesign.bg.nsColor
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(launchSelectedRow)
        scrollView.documentView = tableView
        addSubview(scrollView)

        addSubview(emptyState)

        relay.connect { [weak self] report in
            self?.report(report)
        }
        loadCatalog()
        layoutColumn()
    }

    override func layout() {
        super.layout()
        layoutColumn()
    }

    /// The 4px-grid column, from the top down: wordmark, query, list label,
    /// list, status, hint. The list is exactly as tall as the rows it holds and
    /// the two foot lines follow directly beneath it, so a query matching one
    /// application is one row with its status under it rather than a screenful
    /// of empty list background.
    private func layoutColumn() {
        guard !isLayingOut else {
            return
        }
        isLayingOut = true
        defer { isLayingOut = false }

        let pad = CanvasDesign.Space.md
        let innerWidth = max(1, bounds.width - pad * 2)
        // An empty status collapses its row rather than reserving the
        // two-line slot a real status needs.
        let hasStatus = !statusLabel.stringValue.isEmpty
        let statusHeight = hasStatus ? measuredHeight(statusLabel, width: innerWidth) : 0
        let statusGapAbove = hasStatus ? CanvasDesign.Space.sm : 0
        let statusGapBelow = hasStatus ? CanvasDesign.Space.xs : 0
        let hintHeight = measuredHeight(hintLabel, width: innerWidth)
        // Everything above the list, and everything below it, both fixed.
        let head = pad + 18 + CanvasDesign.Space.sm + 32 + CanvasDesign.Space.md + 14 + CanvasDesign.Space.xs
        let foot = statusGapAbove + statusHeight + statusGapBelow + hintHeight + pad
        let available = max(0, maximumHeight - head - foot)
        let block = visible.isEmpty
            ? min(available, emptyState.fittingHeight())
            : CanvasLauncherMetrics.listHeight(rowCount: visible.count, available: available)
        let height = head + block + foot
        if abs(frame.height - height) > 0.5 {
            let top = frame.maxY
            setFrameSize(NSSize(width: frame.width, height: height))
            setFrameOrigin(NSPoint(x: frame.minX, y: top - height))
        }

        brand.frame = NSRect(x: pad, y: bounds.height - pad - 18, width: innerWidth, height: 18)
        queryWell.frame = NSRect(
            x: pad,
            y: brand.frame.minY - CanvasDesign.Space.sm - 32,
            width: innerWidth,
            height: 32
        )
        queryField.frame = NSRect(x: 10, y: 6, width: max(1, innerWidth - 20), height: 20)
        eyebrow.frame = NSRect(
            x: pad,
            y: queryWell.frame.minY - CanvasDesign.Space.md - 14,
            width: innerWidth,
            height: 14
        )

        let top = eyebrow.frame.minY - CanvasDesign.Space.xs
        let listHeight = visible.isEmpty ? 0 : block
        let emptyHeight = visible.isEmpty ? block : 0

        scrollView.isHidden = visible.isEmpty
        emptyState.isHidden = !visible.isEmpty
        scrollView.frame = NSRect(x: pad, y: top - listHeight, width: innerWidth, height: max(1, listHeight))
        emptyState.frame = NSRect(x: pad, y: top - emptyHeight, width: innerWidth, height: max(1, emptyHeight))
        column.width = max(1, innerWidth - 2)

        statusLabel.frame = NSRect(
            x: pad,
            y: top - block - statusGapAbove - statusHeight,
            width: innerWidth,
            height: statusHeight
        )
        hintLabel.frame = NSRect(
            x: pad,
            y: statusLabel.frame.minY - statusGapBelow - hintHeight,
            width: innerWidth,
            height: hintHeight
        )
    }

    /// What the text actually needs, and never less than two lines, so the foot
    /// does not jump as one status replaces another.
    private func measuredHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(max(twoLineHeight, label.sizeThatFits(NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height))
    }

    private lazy var twoLineHeight: CGFloat = {
        let probe = NSTextField(labelWithString: "A\nB")
        probe.font = statusLabel.font
        probe.maximumNumberOfLines = 0
        return ceil(probe.sizeThatFits(NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)).height)
    }()

    /// An application's own icon, at the row's icon size.
    private func icon(for application: LaunchableApplication) -> NSImage {
        let path = application.bundleURL.path
        if let cached = iconCache[path] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: CanvasLauncherMetrics.iconSize, height: CanvasLauncherMetrics.iconSize)
        iconCache[path] = image
        return image
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Enumerated synchronously, once, while this canvas's window is being
    /// installed: three directory listings plus one nested level, in a path
    /// that already waits on display readiness for far longer. Doing it off
    /// the main thread would buy a few milliseconds and cost a whole
    /// cross-thread handoff of AppKit state.
    private func loadCatalog() {
        adopt(catalog: CanvasApplicationCatalog.discover(
            roots: CanvasApplicationCatalog.defaultSearchRoots(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            list: CanvasApplicationCatalog.systemListing
        ))
    }

    private func adopt(catalog: [LaunchableApplication]) {
        applications = catalog
        applyQuery()
    }

    private func applyQuery() {
        visible = CanvasApplicationCatalog.filter(applications, query: queryField.stringValue)
        tableView.reloadData()
        emptyState.apply(CanvasLauncherPresentation.emptyState(catalogCount: applications.count, hostName: hostName))
        show(CanvasLauncherPresentation.catalogStatus(count: applications.count, showing: visible.count))
        hintLabel.stringValue = CanvasLauncherPresentation.footerHint(
            catalogCount: applications.count,
            visibleCount: visible.count
        )
        select(row: 0)
        layoutColumn()
    }

    /// The selected row is drawn in the accent only while the query field is
    /// where the keys are going; once the user has escaped back to the editor it
    /// stays legible in a dimmer treatment rather than claiming focus it lacks.
    private func setListActive(_ active: Bool) {
        guard listIsActive != active else {
            return
        }
        listIsActive = active
        queryWell.layer?.borderColor = (active ? CanvasDesign.accentBorder : CanvasDesign.line2).cgColor
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? LauncherRowView)?.isActive = active
        }
    }

    private func select(row: Int) {
        guard !visible.isEmpty else {
            return
        }
        let clamped = CanvasApplicationSelection.move(from: row, by: 0, count: visible.count)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private func show(_ status: CanvasLauncherStatus) {
        statusLabel.stringValue = status.text
        statusLabel.textColor = status.severity.color.nsColor
        // A longer sentence is a taller label, and the hint below it moves.
        layoutColumn()
    }

    private func report(_ report: CanvasLaunchReport) {
        show(CanvasLauncherPresentation.outcomeStatus(
            application: report.application,
            outcome: report.outcome,
            hostName: hostName
        ))
    }

    /// `show(_:)`, reached directly rather than through the relay's async
    /// hop -- `CanvasHostTestHooks.launcherStatusLayout` needs the layout
    /// it produces without waiting on a queue round-trip.
    func testApplyStatus(_ status: CanvasLauncherStatus) {
        show(status)
    }

    /// `adopt(catalog:)`, reached directly rather than through `loadCatalog()`'s
    /// disk read -- the only headless way to drive this view through its own
    /// real empty-catalog path (`applyQuery()`'s `emptyState.apply(...)` and
    /// `layoutColumn()`, correctly sized for whatever text that state carries)
    /// rather than poking `emptyState`'s labels directly with a frame left
    /// over from another state.
    func testAdoptCatalog(_ catalog: [LaunchableApplication]) {
        adopt(catalog: catalog)
    }

    /// `report(_:)`, reached directly rather than through the relay's async
    /// hop, so a launch outcome's words can be read back without a queue
    /// round-trip.
    func testReport(_ report: CanvasLaunchReport) {
        self.report(report)
    }

    @objc private func launchSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < visible.count else {
            // Doing nothing here would read as a broken key rather than as
            // an empty list.
            show(CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: applications.count, hostName: hostName))
            return
        }
        let application = visible[row]
        show(CanvasLauncherPresentation.launchingStatus(application: application.name))
        launcher.launch(application)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        visible.count
    }

    /// An application name is a name, not raw data, so it takes the primary
    /// face; the system reserves the mono face for labels and data.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        LauncherRowCellView(name: visible[row].name, icon: icon(for: visible[row]))
    }

    /// Selecting with the pointer hands the query field the keyboard too.
    /// Without this the row the user just clicked is drawn as the un-focused
    /// leftover selection: `listIsActive` otherwise follows the field alone.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        setListActive(window?.makeFirstResponder(queryField) ?? false)
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = LauncherRowView()
        rowView.isActive = listIsActive
        return rowView
    }

    // MARK: - Query field

    func controlTextDidChange(_ notification: Notification) {
        applyQuery()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        setListActive(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        setListActive(false)
    }

    /// The list is driven entirely from the query field, so a remote user never
    /// has to hit a row with the pointer over a video link.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(row: CanvasApplicationSelection.move(from: tableView.selectedRow, by: 1, count: visible.count))
            return true
        case #selector(NSResponder.moveUp(_:)):
            select(row: CanvasApplicationSelection.move(from: tableView.selectedRow, by: -1, count: visible.count))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            launchSelectedRow()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        default:
            return false
        }
    }
}

/// One row of the application list. Draws its own selection: the design system
/// has no elevation and no system highlight, so a selected row is a fill plus a
/// border and nothing else.
@MainActor
private final class LauncherRowView: NSTableRowView {
    var isActive = false {
        didSet {
            needsDisplay = true
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else {
            return
        }
        // Inset by half the stroke so the 1pt border lands on the pixel rather
        // than straddling it.
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: CanvasDesign.Radius.tight,
            yRadius: CanvasDesign.Radius.tight
        )
        // The selection is the one thing a keyboard-driven list must never make
        // the user hunt for, and it has to survive the stream's downscale, so
        // it is the system's `selection` fill under the accent itself.
        let fill = isActive ? CanvasDesign.selection : CanvasDesign.bg3
        let border = isActive ? CanvasDesign.accent : CanvasDesign.lineHi
        fill.nsColor.setFill()
        path.fill()
        border.nsColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class LauncherRowCellView: NSView {
    private let label: NSTextField
    /// An icon is the fastest thing to scan in a list of a hundred names, and
    /// on a static panel it costs nothing after encode.
    private let iconView = NSImageView()

    init(name: String, icon: NSImage?) {
        label = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        label.font = CanvasDesign.font(.primary, size: 14)
        label.textColor = CanvasDesign.ink.nsColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    // The table hands this view its frame after construction, so the label is
    // placed from the size rather than from a spring.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionLabel()
    }

    override func layout() {
        super.layout()
        positionLabel()
    }

    private func positionLabel() {
        let iconSize = CanvasLauncherMetrics.iconSize
        let inset = CanvasDesign.Space.xs
        iconView.frame = NSRect(
            x: inset,
            y: ((bounds.height - iconSize) / 2).rounded(),
            width: iconSize,
            height: iconSize
        )
        let textLeft = inset + iconSize + inset
        let height = ceil(label.fittingSize.height)
        label.frame = NSRect(
            x: textLeft,
            y: (bounds.height - height) / 2,
            width: max(0, bounds.width - textLeft - inset),
            height: height
        )
    }
}

/// The system's empty state: a heading naming what is empty, and subtext naming
/// what to do about it. Both come from `CanvasLauncherPresentation`, because a
/// host with nothing installed needs different advice from an over-narrow
/// filter.
@MainActor
private final class LauncherEmptyStateView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let subtext = NSTextField(labelWithString: "")

    /// The two lines plus the space that keeps them from sitting against the
    /// list above and the status below. Measures the subtext by its own
    /// wrapped line count at this view's own current width -- the same
    /// width `position()` wraps it to -- so a long host name's extra
    /// wrapped line is already counted here, before the caller ever sizes
    /// this view's frame. `NSTextField.fittingSize` does not honor
    /// `preferredMaxLayoutWidth` outside a true Auto Layout constraint
    /// hierarchy, which this frame-based view does not use, so it reports a
    /// single line's height even once the text needs two; `wrappedHeight`
    /// measures the string directly at the constrained width instead.
    func fittingHeight() -> CGFloat {
        let width = max(1, bounds.width - CanvasDesign.Space.md * 2)
        return ceil(heading.fittingSize.height + CanvasDesign.Space.xs + Self.wrappedHeight(of: subtext, width: width))
            + CanvasDesign.Space.xl * 2
    }

    /// A label's own text, measured at a given width -- unlike
    /// `NSTextField.fittingSize`, which stays at its unwrapped natural
    /// width here since this view lays out subviews by frame, never by
    /// Auto Layout constraint.
    private static func wrappedHeight(of field: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = field.cell else {
            return ceil(field.fittingSize.height)
        }
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(cell.cellSize(forBounds: bounds).height)
    }

    func apply(_ state: CanvasLauncherEmptyState) {
        heading.stringValue = state.heading
        subtext.stringValue = state.subtext
        position()
    }

    init() {
        super.init(frame: .zero)
        heading.font = CanvasDesign.font(.primary, size: 14, weight: .medium)
        heading.textColor = CanvasDesign.ink2.nsColor
        heading.alignment = .center
        addSubview(heading)

        subtext.font = CanvasDesign.font(.primary, size: 14)
        subtext.textColor = CanvasDesign.ink2.nsColor
        subtext.alignment = .center
        // The host name inside this sentence is a person's own choice, with
        // no length this code bounds -- a long one must wrap onto another
        // line rather than run to the empty state's own edge.
        subtext.lineBreakMode = .byWordWrapping
        subtext.maximumNumberOfLines = 0
        addSubview(subtext)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        position()
    }

    override func layout() {
        super.layout()
        position()
    }

    private func position() {
        let gap = CanvasDesign.Space.xs
        let inset = CanvasDesign.Space.md
        let usableWidth = max(1, bounds.width - inset * 2)
        let headingHeight = ceil(heading.fittingSize.height)
        let subtextHeight = Self.wrappedHeight(of: subtext, width: usableWidth)
        let top = (bounds.height - (headingHeight + gap + subtextHeight)) / 2
        heading.frame = NSRect(
            x: 0,
            y: bounds.height - top - headingHeight,
            width: bounds.width,
            height: headingHeight
        )
        subtext.frame = NSRect(
            x: inset,
            y: heading.frame.minY - gap - subtextHeight,
            width: usableWidth,
            height: subtextHeight
        )
    }
}
