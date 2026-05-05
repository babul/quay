import SwiftUI

struct AppSettingsView: View {
    @AppStorage("appearance.showTabColorBars") private var showTabColorBars = true

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Show host color bars in tabs", isOn: $showTabColorBars)

                HStack(spacing: 8) {
                    ForEach(ConnectionColor.tags) { tag in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 16, height: 16)
                            Text(tag.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 48)
                    }
                }
                .padding(.top, 2)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 260)
    }
}
