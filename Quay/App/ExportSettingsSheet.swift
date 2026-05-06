import AppKit
import SwiftData
import SwiftUI

struct ExportSettingsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var usePassword = true
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?

    private var passwordsMatch: Bool { password == confirmPassword }
    private var canExport: Bool {
        if usePassword { return !password.isEmpty && passwordsMatch }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Settings")
                .font(.headline)

            Toggle("Encrypt with password", isOn: $usePassword.animation())

            if usePassword {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Password", text: $password)
                    SecureField("Confirm password", text: $confirmPassword)

                    if !confirmPassword.isEmpty && !passwordsMatch {
                        Text("Passwords don't match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if confirmPassword.isEmpty && !password.isEmpty {
                        Text("Please confirm your password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                Button("Export…") { performExport() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canExport)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380, height: usePassword ? 240 : 160)
    }

    @MainActor
    private func performExport() {
        let pw: SensitiveBytes? = usePassword
            ? SensitiveBytes(Data(password.utf8))
            : nil
        password = ""
        confirmPassword = ""

        let bundleData: Data
        do {
            bundleData = try SettingsBundle.encode(modelContext: modelContext, password: pw)
        } catch {
            errorMessage = "Could not build export: \(error.localizedDescription)"
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Quay Settings"
        panel.nameFieldStringValue = exportFilename()
        panel.allowedContentTypes = [.quayBundle]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try bundleData.write(to: url, options: .atomic)
            dismiss()
        } catch {
            errorMessage = "Could not write file: \(error.localizedDescription)"
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func exportFilename() -> String {
        "Quay Settings \(Self.exportDateFormatter.string(from: Date())).quaybundle"
    }
}
