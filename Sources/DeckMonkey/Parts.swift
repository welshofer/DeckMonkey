import Foundation

/// The parts DeckMonkey copies new text boxes and pictures from: Keynote-made drawables (a plain
/// text item and a plain picture AppleScript made in Basic White, `Corpus/features`), extracted with
/// `deckmonkey parts` into two packages of about 10 KB each that hold only those drawables, what
/// only they use, and the styles they point at. No slide, master, theme or picture data.
public enum Parts {
    public enum Kind: String, Sendable { case textBox = "textbox", picture }

    public enum Failure: Error, Equatable, Sendable { case missing(String) }

    public static func document(_ kind: Kind) throws -> KeynoteDocument {
        guard let url = Bundle.module.url(forResource: kind.rawValue, withExtension: "keyparts", subdirectory: "Parts") else {
            throw Failure.missing(kind.rawValue)
        }
        return try KeynoteDocument.open(IWAPackage.openZip(Data(contentsOf: url)))
    }
}

extension KeynoteDocument {
    /// A new text box on `slide` holding `text` (one paragraph per line), in this deck's default
    /// text box style; `frame` fixes its width, its height follows the text unless given.
    @discardableResult
    public mutating func insertTextBox(onto slide: UInt64, frame: Frame, text: String) throws -> UInt64 {
        try insertTextBox(onto: slide, frame: frame, paragraphs: text.components(separatedBy: "\n").map { TextParagraphs.Paragraph($0) },
                          parts: Parts.document(.textBox))
    }

    /// A new picture on `slide` showing `bytes`, in this deck's default image style, at `frame`.
    @discardableResult
    public mutating func insertImage(_ bytes: Data, preferredFileName: String, onto slide: UInt64, frame: Frame) throws -> UInt64 {
        try insertImage(bytes, preferredFileName: preferredFileName, onto: slide, frame: frame, parts: Parts.document(.picture))
    }
}
