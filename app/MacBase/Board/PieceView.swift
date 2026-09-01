import SwiftUI
import AppKit

/// Bundled piece images (Merida SVGs, see Resources/pieces/merida/LICENSE.txt),
/// cached one NSImage per piece. NSImage keeps the SVG rep, so drawing stays
/// vector-sharp at any board size.
@MainActor
enum PieceAssets {
    private static var cache: [Character: NSImage] = [:]

    private static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }()

    static func image(for symbol: Character) -> NSImage? {
        if let image = cache[symbol] { return image }
        let name = (symbol.isUppercase ? "w" : "b") + symbol.uppercased()
        // SPM (.copy) and the Xcode folder reference keep the directory;
        // a flat resources phase would not — probe both.
        let url = bundle.url(forResource: name, withExtension: "svg",
                             subdirectory: "pieces/merida")
            ?? bundle.url(forResource: name, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        cache[symbol] = image
        return image
    }
}

/// One piece, sized to a board cell. Falls back to the Unicode glyph if the
/// asset is missing (e.g. resource bundle not shipped).
struct PieceView: View {
    let piece: BoardPiece
    let cell: CGFloat

    var body: some View {
        if let image = PieceAssets.image(for: piece.symbol) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: cell, height: cell)
        } else {
            Text(piece.glyph)
                .font(.system(size: cell * 0.78))
                .foregroundStyle(.black)
                .shadow(color: piece.isWhite ? .white.opacity(0.6) : .clear, radius: 1)
        }
    }
}
