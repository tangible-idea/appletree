import SwiftUI
import AppleTreeCore

struct FDAPromptView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)
                .padding(.top, 10)

            VStack(spacing: 8) {
                Text(L10n.text("fda.title"))
                    .font(.system(size: 18, weight: .bold))

                Text(L10n.text("fda.message"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                stepRow(number: "1", text: L10n.text("fda.step1"))
                stepRow(number: "2", text: L10n.text("fda.step2"))
                stepRow(number: "3", text: L10n.text("fda.step3"))
            }
            .padding(14)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        FullDiskAccess.openSettings()
                    } label: {
                        Label(L10n.text("fda.openSettings"), systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle())

                    Button {
                        FullDiskAccess.revealAppInFinder()
                    } label: {
                        Label(L10n.text("fda.revealApp"), systemImage: "folder")
                    }
                    .buttonStyle(QuietButtonStyle())
                }

                Button(L10n.text("fda.continueWithout")) {
                    store.confirmFDAScan()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 4)
            }
        }
        .padding(26)
        .frame(width: 460)
        .background(.white)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink)
        }
    }
}
