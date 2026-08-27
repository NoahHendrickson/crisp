import SwiftUI
import AppKit

// The library sidebar's inline rename control. AppKit rather than SwiftUI's
// TextField so the field editor honors the cell insets exactly (Figma 76:13501).

/// Compact single-line rename field (Figma 76:13501). The cell insets both
/// drawing and the field editor so the first glyph isn’t clipped and the
/// selection band sits 4pt in from the box, 16pt tall.
struct RenameNameField: NSViewRepresentable {
    static let size = NSSize(width: 152, height: 24)
    /// 1pt border + 4pt padding: text starts 5pt in (Figma text x = 5).
    static let horizontalInset: CGFloat = 5

    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    static let font: NSFont = {
        let base = NSFont(name: "Geist-Regular", size: 14) ?? .systemFont(ofSize: 14)
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: desc, size: 14) ?? base
    }()

    /// Editor rect inside the 24pt box: one line of Geist/14, vertically
    /// centred. Rounded up: measured offscreen, the exact 2.5pt offset draws
    /// the glyphs half a point above the static SwiftUI label; 3pt matches.
    static func editorRect(for bounds: NSRect) -> NSRect {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let dy = max(0, ceil((bounds.height - lineHeight) / 2))
        return NSRect(
            x: bounds.minX + horizontalInset,
            y: bounds.minY + dy,
            width: max(0, bounds.width - horizontalInset * 2),
            height: min(bounds.height, lineHeight)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CompactRenameField {
        let field = CompactRenameField()
        field.stringValue = text
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: CompactRenameField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CompactRenameField, context: Context) -> CGSize? {
        CGSize(width: Self.size.width, height: Self.size.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameNameField
        init(_ parent: RenameNameField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSTextField)?.stringValue ?? ""
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onSubmit()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

final class CompactRenameField: NSTextField {
    init() {
        super.init(frame: NSRect(origin: .zero, size: RenameNameField.size))
        let cell = CompactRenameFieldCell(textCell: "")
        cell.wraps = false
        cell.isScrollable = true
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byClipping
        cell.isBordered = false
        cell.drawsBackground = false
        cell.focusRingType = .none
        cell.font = RenameNameField.font
        self.cell = cell
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        font = RenameNameField.font
        textColor = NSColor(Theme.foreground)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { RenameNameField.size }

    /// NSTextField reports 2pt side alignment insets; SwiftUI would lay out
    /// the alignment rect at 152 and let the bounds spill 2pt each way, so
    /// the editor inset (measured from bounds) would land 2pt left of the
    /// background's padding. Zero them so bounds == the 152×24 box.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// Style the field editor once it’s attached: Figma’s blue@30 selection
    /// band, foreground caret, and the same font/colour as the cell.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.font = RenameNameField.font
            editor.textColor = NSColor(Theme.foreground)
            editor.insertionPointColor = NSColor(Theme.foreground)
            editor.selectedTextAttributes = [.backgroundColor: NSColor(Theme.selection)]
            editor.drawsBackground = false
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
        }
        return ok
    }
}

/// Insets drawing *and* the field editor. `drawingRect` alone only affects
/// the static glyphs — `edit`/`select` position the editor and would
/// otherwise run edge to edge.
final class CompactRenameFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: RenameNameField.editorRect(for: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: RenameNameField.editorRect(for: rect))
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
        delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: RenameNameField.editorRect(for: rect), in: controlView,
            editor: textObj, delegate: delegate, event: event
        )
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
        delegate: Any?, start selStart: Int, length selLength: Int
    ) {
        super.select(
            withFrame: RenameNameField.editorRect(for: rect), in: controlView,
            editor: textObj, delegate: delegate, start: selStart, length: selLength
        )
    }
}

