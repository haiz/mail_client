import AppKit

extension NSAttributedString.Key {
    static let inlineCid = NSAttributedString.Key("com.litemail.inline-cid")
}

/// NSTextView subclass that accepts drag-dropped image files as inline attachments.
/// Non-image files are forwarded via `onFilesDropped` for the composer to add as chips.
final class ComposerBodyTextView: NSTextView {

    /// Called when image files are dropped: (fileURL, imageData, mimeType, contentId).
    var onImageDropped: ((URL, Data, String, String) -> Void)?

    /// Called when non-image files are dropped so they can become attachment chips.
    var onFilesDropped: (([URL]) -> Void)?

    // MARK: - Drag Destination

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return super.draggingEntered(sender) }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return super.performDragOperation(sender) }

        let imageURLs = urls.filter { Self.isImageExtension($0.pathExtension) }
        let otherURLs  = urls.filter { !Self.isImageExtension($0.pathExtension) }

        let dropPoint = convert(sender.draggingLocation, from: nil)
        for url in imageURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = Self.imageMime(for: url.pathExtension)
            let cid  = "\(UUID().uuidString)@litemail"
            insertInlineImage(data: data, cid: cid, at: dropPoint)
            onImageDropped?(url, data, mime, cid)
        }

        if !otherURLs.isEmpty { onFilesDropped?(otherURLs) }
        return true
    }

    // MARK: - Inline Image Insertion

    private func insertInlineImage(data: Data, cid: String, at point: NSPoint) {
        guard let storage = textStorage, let image = NSImage(data: data) else { return }

        let attachment = NSTextAttachment()
        attachment.image = image

        let maxWidth = max(frame.width - 32, 120)
        if image.size.width > maxWidth {
            let scale = maxWidth / image.size.width
            attachment.bounds = CGRect(x: 0, y: 0,
                                       width: maxWidth,
                                       height: image.size.height * scale)
        }

        let attachStr = NSMutableAttributedString(attachment: attachment)
        attachStr.addAttribute(.inlineCid, value: cid,
                               range: NSRange(location: 0, length: attachStr.length))

        let insertAt = characterIndex(at: point)
        storage.insert(attachStr, at: insertAt)
        setSelectedRange(NSRange(location: insertAt + 1, length: 0))
    }

    private func characterIndex(at point: NSPoint) -> Int {
        guard let layout = layoutManager, let container = textContainer else {
            return textStorage?.length ?? 0
        }
        var fraction: CGFloat = 0
        let glyphIdx = layout.glyphIndex(for: point, in: container,
                                         fractionOfDistanceThroughGlyph: &fraction)
        let charIdx = layout.characterIndexForGlyph(at: glyphIdx)
        return min(charIdx, textStorage?.length ?? 0)
    }

    // MARK: - Helpers

    private func hasFileURLs(in sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        return !urls.isEmpty
    }

    private static func isImageExtension(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext.lowercased())
    }

    private static func imageMime(for ext: String) -> String {
        switch ext.lowercased() {
        case "png":       return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":       return "image/gif"
        case "webp":      return "image/webp"
        case "heic":      return "image/heic"
        case "tiff":      return "image/tiff"
        default:          return "image/png"
        }
    }
}
