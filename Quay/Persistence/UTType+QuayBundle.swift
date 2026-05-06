import UniformTypeIdentifiers

extension UTType {
    // Must match UTImportedTypeDeclarations in the app Info.plist.
    static let quayBundle = UTType(importedAs: "io.github.babul.quay.bundle", conformingTo: .data)
}
