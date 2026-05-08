import AppKit
import SwiftData
import SwiftUI

struct ImportSettingsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let fileData: Data
    var onSuccess: (ImportSummary) -> Void

    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Password Protected")
                .font(.headline)
            Text("This settings file is encrypted. Enter the password to import it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Import") { performImport() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(password.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340, height: 200)
    }

    @MainActor
    private func performImport() {
        let pw = SensitiveBytes(Data(password.utf8))
        password = ""
        errorMessage = nil

        do {
            let summary = try SettingsBundle.decode(data: fileData, container: modelContext.container, password: pw)
            dismiss()
            onSuccess(summary)
        } catch SettingsBundle.BundleError.wrongPassword {
            errorMessage = "Incorrect password."
        } catch {
            errorMessage = bundleErrorMessage(error)
            dismiss()
        }
    }
}

// MARK: - Settings import/export flow modifier

extension View {
    /// Attaches the export/import sheet pair, the import-failed alert, and the
    /// file-picker logic shared by ContentView and AppSettingsView. Flip either
    /// binding to true to launch the corresponding flow; the modifier resets it.
    func settingsImportExportFlow(
        triggerExport: Binding<Bool>,
        triggerImport: Binding<Bool>
    ) -> some View {
        modifier(SettingsImportExportFlow(
            triggerExport: triggerExport,
            triggerImport: triggerImport
        ))
    }
}

private struct IdentifiableData: Identifiable {
    let id = UUID()
    let data: Data
}

private struct SettingsImportExportFlow: ViewModifier {
    @Binding var triggerExport: Bool
    @Binding var triggerImport: Bool
    @Environment(\.modelContext) private var modelContext

    @State private var pendingImportFile: IdentifiableData?
    @State private var importError: String?

    private var importErrorIsPresented: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: triggerImport) { _, requested in
                guard requested else { return }
                triggerImport = false
                startImport()
            }
            .sheet(isPresented: $triggerExport) {
                ExportSettingsSheet()
            }
            .sheet(item: $pendingImportFile) { file in
                ImportSettingsSheet(fileData: file.data) { summary in
                    showImportSummaryAlert(summary)
                }
            }
            .alert("Import failed", isPresented: importErrorIsPresented, actions: {
                Button("OK") { importError = nil }
            }, message: {
                Text(importError ?? "")
            })
    }

    @MainActor
    private func startImport() {
        Task { @MainActor in
            runImportFlow(
                container: modelContext.container,
                onPassword: { data in pendingImportFile = IdentifiableData(data: data) },
                onSummary: { summary in showImportSummaryAlert(summary) },
                onError: { msg in importError = msg }
            )
        }
    }
}

// MARK: - Shared helpers

private func bundleErrorMessage(_ error: Error) -> String {
    guard let bundleError = error as? SettingsBundle.BundleError else {
        return error.localizedDescription
    }
    switch bundleError {
    case .malformedFile:
        return "This file isn't a Quay settings bundle."
    case .unsupportedVersion(let v):
        return "This bundle was created by a newer version of Quay (format v\(v))."
    case .wrongPassword:
        return "Incorrect password."
    case .missingPassword:
        return "This file is encrypted. A password is required."
    case .cyclicFolderGraph:
        return "The bundle contains a circular folder reference and could not be imported."
    case .lockedStepResolutionFailed, .snippetSecretResolutionFailed, .passwordRequiredForSecrets:
        return bundleError.errorDescription ?? bundleError.localizedDescription
    }
}

@MainActor
private func runImportFlow(
    container: ModelContainer,
    onPassword: @escaping (Data) -> Void,
    onSummary: @escaping (ImportSummary) -> Void,
    onError: @escaping (String) -> Void
) {
    let panel = NSOpenPanel()
    panel.title = "Import Quay Settings"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.quayBundle]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        onError("Could not read file: \(error.localizedDescription)")
        return
    }

    // Try a passwordless decode: succeeds for plaintext bundles, throws
    // missingPassword for encrypted ones (which is how we know to prompt).
    do {
        let summary = try SettingsBundle.decode(data: data, container: container, password: nil)
        onSummary(summary)
    } catch SettingsBundle.BundleError.missingPassword {
        onPassword(data)
    } catch {
        onError(bundleErrorMessage(error))
    }
}

@MainActor
private func showImportSummaryAlert(_ summary: ImportSummary) {
    let alert = NSAlert()
    alert.messageText = "Import complete"

    let pluralize: (Int, String, String) -> String = { count, singular, plural in
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    var parts = [
        "Imported \(pluralize(summary.connectionsAdded, "host", "hosts")) and \(pluralize(summary.foldersAdded, "group", "groups"))."
    ]

    if summary.snippetsAdded > 0 || summary.snippetGroupsAdded > 0 {
        parts.append(
            "Imported \(pluralize(summary.snippetsAdded, "snippet", "snippets")) in \(pluralize(summary.snippetGroupsAdded, "snippet group", "snippet groups"))."
        )
    }

    alert.informativeText = parts.joined(separator: " ")
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
