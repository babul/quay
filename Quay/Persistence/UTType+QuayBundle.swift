import UniformTypeIdentifiers

extension UTType {
    // Must match UTImportedTypeDeclarations in the app Info.plist.
    static let quayBundle = UTType(importedAs: "com.montopolis.quay.bundle", conformingTo: .data)
}
