#if canImport(AppKit)
import AppKit
import CoreText

/// The session panel: what this viewer is actually receiving, stated in the
/// terms a person debugging a slow session needs -- the applied scale against
/// the one asked for, each latency figure attributed to the machine that
/// measured it, and every absent or stale reading named rather than filled in.
///
/// Deliberately dumb, like `ViewerSessionStatusOverlay` beside it: every word,
/// every tone and every "unavailable" comes from `SessionHUDPanel`, which is
/// pure and verified without a window. This draws rows and nothing else.
///
/// Colours and metrics come from `ViewerDesign`; never an AppKit semantic
/// colour, and nothing here casts a shadow.
@MainActor
public final class SessionHUDView: NSView {
    private let stack = NSStackView()
    private var blockViews: [SessionHUDBlockView] = []
    private var telemetry: SessionHUDSnapshot?
    private var session: ViewerSessionStatus?

    public static let panelWidth: CGFloat = 320

    /// `TelemetryAttentionThreshold`'s verdict on the whole reading, carried
    /// by the panel's own border so a session going bad is visible to someone
    /// who has the panel open without reading every row.
    private var isAttentionWorthy = false

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        // The eyebrows separate the groups; whitespace only has to keep them
        // from touching. This panel floats over the user's own work, so every
        // band of empty pixels is taken from something they were looking at.
        stack.spacing = ViewerDesign.Space.md
        // The panel is pinned by one corner inside a view the size of the
        // whole canvas, so nothing about its height may be negotiable: a
        // stack that can stretch will, and the extra height lands between
        // rows, pulling a short column out of line with the one beside it.
        stack.setHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        addSubview(stack)

        let inset = ViewerDesign.Space.sm
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.panelWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Drawn rather than set on a layer. This panel sits over a live picture,
    /// and it must be opaque under every path AppKit might draw it through --
    /// a layer background is skipped by the view-drawing path
    /// (`cacheDisplay`), which would let canvas pixels through the numbers.
    /// Filled and stroked as `docs/design-system.md` prescribes: a
    /// `roundedRect` at radius `base`, stroked at `lineWidth` 1 inset by
    /// 0.5pt so the stroke lands on the pixel. No shadow, ever.
    public override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: ViewerDesign.Radius.base,
            yRadius: ViewerDesign.Radius.base
        )
        ViewerDesign.chromeBg2.nsColor.setFill()
        border.fill()
        (isAttentionWorthy ? ViewerDesign.warn : ViewerDesign.chromeBorder2).nsColor.setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    /// The per-surface reading, pushed once per telemetry tick.
    public func apply(telemetry: SessionHUDSnapshot) {
        self.telemetry = telemetry
        render()
    }

    /// The session lifecycle, pushed by whoever owns it. Separate from the
    /// telemetry tick because the two arrive from different places and at
    /// different times.
    public func apply(session: ViewerSessionStatus) {
        self.session = session
        render()
    }

    private func render() {
        guard let telemetry else { return }
        if isAttentionWorthy != telemetry.isAttentionWorthy {
            isAttentionWorthy = telemetry.isAttentionWorthy
            needsDisplay = true
        }
        let blocks = SessionHUDPanel.blocks(telemetry: telemetry, session: session)
        // The panel's shape is fixed by the model, so the usual case reuses
        // every view and only rewrites strings -- this runs once a second
        // over a live video window.
        if blockViews.map(\.shape) != blocks.map(SessionHUDBlockView.shape(of:)) {
            blockViews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            blockViews = blocks.map { SessionHUDBlockView(shape: SessionHUDBlockView.shape(of: $0)) }
            for view in blockViews {
                stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        for (view, block) in zip(blockViews, blocks) {
            view.update(block)
        }
    }
}

/// One entry in the panel's vertical run: a single section, or two of them
/// side by side. The pairing itself is `SessionHUDBlock`'s decision; this only
/// lays out what it is handed.
@MainActor
private final class SessionHUDBlockView: NSView {
    /// Row counts per section, which is all the reuse check needs: one entry
    /// is a lone section, two are columns.
    let shape: [Int]
    private let sectionViews: [SessionHUDSectionView]
    private let title = NSTextField(labelWithString: "")

    static func shape(of block: SessionHUDBlock) -> [Int] {
        block.sections.map(\.rows.count)
    }

    init(shape: [Int]) {
        self.shape = shape
        // A column is half the panel less the gutter, so its labels get a
        // narrower column than a full-width section's.
        let isColumns = shape.count > 1
        sectionViews = shape.map { SessionHUDSectionView(rowCount: $0, isNarrow: isColumns) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Each column sits in a wrapper pinned at the top and free at the
        // bottom. Two columns of unequal length otherwise leave the shorter
        // one stretched to the taller's height, and the slack lands inside
        // its first row -- which puts every row after it out of line with the
        // column beside it, exactly where the comparison is being read.
        let arranged: [NSView] = isColumns ? sectionViews.map { section in
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(section)
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                section.topAnchor.constraint(equalTo: wrapper.topAnchor),
                section.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor)
            ])
            return wrapper
        } : sectionViews

        let columns = NSStackView(views: arranged)
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.orientation = isColumns ? .horizontal : .vertical
        columns.alignment = isColumns ? .top : .leading
        columns.distribution = isColumns ? .fillEqually : .fill
        columns.spacing = isColumns ? ViewerDesign.Space.md : 0

        title.translatesAutoresizingMaskIntoConstraints = false
        title.isHidden = true

        let stack = NSStackView(views: [title, columns])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ViewerDesign.Space.xxs
        stack.setHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            columns.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(_ block: SessionHUDBlock) {
        if let blockTitle = block.title {
            title.attributedStringValue = SessionHUDEyebrow.attributed(blockTitle)
            title.isHidden = false
        } else {
            title.isHidden = true
        }
        for (view, section) in zip(sectionViews, block.sections) {
            view.update(section)
        }
    }
}

/// The system's `h6`: uppercase mono at 12px, `widest` tracking, muted. One
/// place, so a block's eyebrow and a section's cannot drift apart.
@MainActor
private enum SessionHUDEyebrow {
    static func attributed(_ text: String, size: CGFloat = 12) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: ViewerDesign.font(mono: true, size: size, weight: .medium),
                .foregroundColor: ViewerDesign.muted2.nsColor,
                .kern: ViewerDesign.kern(ViewerDesign.Tracking.widest, size: size)
            ]
        )
    }

    /// "THIS MACHINE" and the host's own column headers sit directly under the
    /// "LATENCY" block eyebrow at almost the same size, reading as a third
    /// machine rather than as the two halves of the one thing above them. One
    /// step down, at the size the panel's own rows already use for labels.
    static let columnSize: CGFloat = 11
}

/// One titled group: an uppercase mono eyebrow, its rows, and the group-wide
/// caveat when there is one.
@MainActor
private final class SessionHUDSectionView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let rows: [SessionHUDRowView]
    private let stack = NSStackView()
    /// True only for the two latency columns -- their own "THIS MACHINE" /
    /// host-name headers are a column caption under the shared "LATENCY"
    /// eyebrow, not a section title of their own.
    private let isNarrow: Bool

    var rowCount: Int { rows.count }

    init(rowCount: Int, isNarrow: Bool = false) {
        self.isNarrow = isNarrow
        rows = (0..<rowCount).map { _ in SessionHUDRowView(isNarrow: isNarrow) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        title.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = ViewerDesign.font(mono: false, size: 11)
        note.textColor = ViewerDesign.muted2.nsColor
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = SessionHUDView.panelWidth - ViewerDesign.Space.sm * 2

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        // 4px between rows: the eyebrows do the separating, not whitespace.
        stack.spacing = ViewerDesign.Space.xxs
        stack.setHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(title)
        rows.forEach { stack.addArrangedSubview($0) }
        stack.addArrangedSubview(note)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(_ section: SessionHUDSection) {
        title.attributedStringValue = isNarrow
            ? SessionHUDEyebrow.attributed(section.title, size: SessionHUDEyebrow.columnSize)
            : SessionHUDEyebrow.attributed(section.title)
        for (view, row) in zip(rows, section.rows) {
            view.update(row)
        }
        note.stringValue = section.note ?? ""
        note.isHidden = section.note == nil
    }
}

/// A label, its value, and the one sentence that keeps the value from being
/// misread. The value is set in figures that hold their column, so a number
/// changing every second does not make the panel twitch.
@MainActor
private final class SessionHUDRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    /// `nil` in a narrow (two-column) row: half the panel less its label and
    /// gutter has no room left for a 64pt sparkline beside the value, so
    /// those rows never carry one, whatever their model's own `trend` says.
    private let sparkline: SessionHUDSparklineView?
    /// The value's own column, before any sparkline reserve -- kept so
    /// `update(_:)` can hand it back on a row whose sparkline this reading
    /// leaves hidden. Set once in `init`; every other row-to-row change goes
    /// through `update(_:)`, not a fresh constraint.
    private var valueWidthConstraint: NSLayoutConstraint!
    private var fullValueWidth: CGFloat = 0
    private var sparklineReserve: CGFloat = 0

    private static let labelColumnWidth: CGFloat = 96
    /// A column is half the panel less the gutter, so its labels take the
    /// width the longest of them actually needs and no more -- measured
    /// against "END-TO-END", the longest label a narrow row carries.
    private static let narrowLabelColumnWidth: CGFloat = 70

    init(isNarrow: Bool) {
        sparkline = isNarrow ? nil : SessionHUDSparklineView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for field in [label, value, note] {
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        label.font = ViewerDesign.font(mono: true, size: 11)
        label.textColor = ViewerDesign.muted.nsColor
        value.font = Self.tabularFigures(ViewerDesign.font(mono: true, size: 11, weight: .medium))
        value.textColor = ViewerDesign.ink.nsColor
        // A narrow column's whole width is under 150pt, which a long enough
        // value has nowhere else to go in. Bounded to the column's real
        // remaining width and truncated with an ellipsis rather than left
        // unconstrained, which lets AppKit clip the glyphs with no ellipsis.
        value.lineBreakMode = .byTruncatingTail
        value.maximumNumberOfLines = 1
        // Subordinate to the value it qualifies, by weight and by indent: it
        // is a disclosure about that number, not another reading.
        note.font = ViewerDesign.font(mono: false, size: 11)
        note.textColor = ViewerDesign.muted2.nsColor
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        // Wraps inside whatever it is actually in: a column is under half the
        // panel, and a note measured against the full width silently
        // truncates there instead of wrapping.
        let contentWidth = SessionHUDView.panelWidth - ViewerDesign.Space.sm * 2
        let columnWidth = isNarrow ? (contentWidth - ViewerDesign.Space.md) / 2 : contentWidth
        note.preferredMaxLayoutWidth = columnWidth - ViewerDesign.Space.xs
        let labelWidth = isNarrow ? Self.narrowLabelColumnWidth : Self.labelColumnWidth
        fullValueWidth = columnWidth - labelWidth - ViewerDesign.Space.xs
        // Only a row whose own reading actually draws a sparkline gives up
        // this width: most rows on a sparkline-capable (non-narrow) section
        // never carry one, and reserving the column unconditionally there
        // just truncates a value like the address for no view beside it.
        // `update(_:)` narrows this per row, once it knows.
        sparklineReserve = sparkline == nil ? 0 : SessionHUDSparklineView.size.width + ViewerDesign.Space.xs
        valueWidthConstraint = value.widthAnchor.constraint(lessThanOrEqualToConstant: fullValueWidth)
        valueWidthConstraint.isActive = true

        // The sparkline is never one of `line`'s arranged views: hugging the
        // value's own width would put it at a different x on every row,
        // since VIDEO IN's and FPS's values are not the same width. It is
        // instead pinned below, at a fixed trailing column every row with
        // one shares.
        let line = NSStackView(views: [label, value])
        line.translatesAutoresizingMaskIntoConstraints = false
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = ViewerDesign.Space.xs

        let noteRow = NSStackView(views: [note])
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        noteRow.orientation = .horizontal
        noteRow.alignment = .top
        noteRow.edgeInsets = NSEdgeInsets(top: 0, left: ViewerDesign.Space.xs, bottom: 0, right: 0)

        // A stack, not constraints: an arranged subview that is hidden leaves
        // the layout entirely, so a row with no note costs no height at all.
        // A constraint would reserve the note's height on every row, showing
        // or not.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ViewerDesign.Space.xxs
        stack.setHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(line)
        stack.addArrangedSubview(noteRow)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(
                equalToConstant: isNarrow ? Self.narrowLabelColumnWidth : Self.labelColumnWidth
            ),
            noteRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        // Its own trailing column, vertically centred on the label/value line
        // -- not the note below it, and not `stack`'s own bottom, which
        // moves with the note's presence. Anchored off `leadingAnchor` plus
        // the column's own known width, not `trailingAnchor`: nothing pins
        // this row's actual width to `columnWidth`, since the section
        // stack's `.leading` alignment leaves a short row's real trailing
        // edge wherever its own content ends, short of the column -- the
        // leading edge, alone, is what every row genuinely shares.
        if let sparkline {
            addSubview(sparkline)
            NSLayoutConstraint.activate([
                sparkline.trailingAnchor.constraint(equalTo: leadingAnchor, constant: columnWidth),
                sparkline.centerYAnchor.constraint(equalTo: line.centerYAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(_ row: SessionHUDRow) {
        label.stringValue = row.label
        value.stringValue = row.value
        // Dimmed, not coloured: a last-known reading has to be visibly not
        // live to someone scanning for numbers, and it has to recede rather
        // than compete with the status colours that mean "look at this".
        let valueColor = row.isStale
            ? ViewerDesign.muted.nsColor
            : (row.tone.map { ViewerDesign.color(for: $0).nsColor } ?? ViewerDesign.ink.nsColor)
        value.textColor = valueColor
        note.stringValue = row.note ?? ""
        note.superview?.isHidden = row.note == nil

        if let sparkline {
            let trend = row.trend ?? []
            // Same rule as the pure layout helper: fewer than two samples is
            // no line to draw, so the sparkline leaves the row entirely
            // rather than sitting there empty.
            let showsSparkline = trend.count >= 2
            sparkline.isHidden = !showsSparkline
            // The value only gives up its trailing column on a row that is
            // actually drawing a sparkline this update; every other row on
            // the same (sparkline-capable) section keeps its full width.
            valueWidthConstraint.constant = showsSparkline ? fullValueWidth - sparklineReserve : fullValueWidth
            // The system's own data-viz colour, not the value's tone: a
            // trend line is a shape to glance at, not another status to
            // read, so it stays the same colour whatever the row beside it
            // is doing.
            sparkline.lineColor = ViewerDesign.accent2.nsColor
            sparkline.samples = trend
        }
    }

    /// The AppKit equivalent of `font-variant-numeric: tabular-nums`. The mono
    /// face already spaces digits evenly, but the fallback path and any future
    /// face change must not silently lose the alignment a per-second readout
    /// depends on.
    private static func tabularFigures(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

/// The trend beside one row's value: a faint baseline, the series as a
/// plain polyline in the system's own data-viz colour, and its last point as
/// a small dot. `SessionHUDSparklineLayout` owns the actual point mapping;
/// this only strokes what it returns.
@MainActor
private final class SessionHUDSparklineView: NSView {
    static let size = NSSize(width: 64, height: 14)

    var samples: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var lineColor: NSColor = ViewerDesign.accent2.nsColor {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        let plotRect = bounds.insetBy(dx: 0, dy: 1)

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: bounds.minX, y: bounds.midY))
        baseline.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        baseline.lineWidth = 1
        ViewerDesign.line.nsColor.setStroke()
        baseline.stroke()

        let points = SessionHUDSparklineLayout.points(for: samples, in: plotRect)
        guard points.count >= 2 else { return }

        let trendLine = NSBezierPath()
        trendLine.move(to: points[0])
        for point in points.dropFirst() {
            trendLine.line(to: point)
        }
        trendLine.lineWidth = 1.5
        lineColor.setStroke()
        trendLine.stroke()

        guard let last = points.last else { return }
        let dotRadius: CGFloat = 1
        let dot = NSBezierPath(ovalIn: NSRect(
            x: last.x - dotRadius,
            y: last.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
        lineColor.setFill()
        dot.fill()
    }
}
#endif
