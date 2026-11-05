import Foundation
import UIKit

public enum PDFDisplayBox { case mediaBox }
public enum PDFDisplayMode { case singlePageContinuous }
public enum PDFDisplayDirection { case vertical }

public final class PDFPage: @unchecked Sendable {
    public func bounds(for box: PDFDisplayBox) -> CGRect { .zero }
    public func thumbnail(of size: CGSize, for box: PDFDisplayBox) -> UIImage { UIImage(cgImage: CGImage()) }
}

public final class PDFSelection: Equatable, @unchecked Sendable {
    public var pages: [PDFPage] { [] }
    public var color: UIColor?
    public static func == (a: PDFSelection, b: PDFSelection) -> Bool { a === b }
}

public final class PDFDocument: @unchecked Sendable {
    public init?(url: URL) {}
    public var pageCount: Int { 0 }
    public func page(at: Int) -> PDFPage? { nil }
    public func index(for page: PDFPage) -> Int { 0 }
    public func findString(_ text: String, withOptions: NSString.CompareOptions) -> [PDFSelection] { [] }
}

public final class PDFView: UIView {
    public var autoScales = false
    public var displayMode = PDFDisplayMode.singlePageContinuous
    public var displayDirection = PDFDisplayDirection.vertical
    public var document: PDFDocument?
    public var highlightedSelections: [PDFSelection]?
    public func go(to selection: PDFSelection) {}
    public func go(to page: PDFPage) {}
}
