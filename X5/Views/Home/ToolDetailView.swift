import SwiftUI

/// Detail screen shown when tapping any AI tool card on Home.
/// "Coming soon" content with a notify-me hook (no-op stub for now).
struct ToolDetailView: View {
    let tool: HomeTool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationService
    @State private var notified = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    cover
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tool.title)
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundColor(.white)
                        Text(tool.subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))

                        if let tag = tool.tag, let tc = tool.tagColor {
                            Text(tag)
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(0.7)
                                .foregroundColor(.black)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(tc)
                                .clipShape(Capsule())
                        }
                    }

                    Text(loc.t("tool_status"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.top, 4)

                    HStack(spacing: 12) {
                        Image(systemName: "hammer.fill")
                            .foregroundColor(.accentColor)
                        Text(loc.t("tool_in_dev"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text(loc.t("tool_what_it_does"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.top, 8)

                    Text(longDescription)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        notified = true
                    } label: {
                        HStack {
                            Image(systemName: notified ? "checkmark.circle.fill" : "bell.fill")
                            Text(notified ? loc.t("tool_will_let_you_know") : loc.t("tool_notify_me"))
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(notified ? Color.white.opacity(0.86) : Color.accentColor)
                        .cornerRadius(14)
                    }
                    .disabled(notified)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("common_done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var cover: some View {
        ZStack {
            LinearGradient(colors: [tool.gradientStart, tool.gradientEnd],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Build 66: LoopingVideo disabled — AVPlayer crash on iOS 26 stable.
            Image(systemName: tool.icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var longDescription: String {
        let key = "tool_desc_\(tool.id)"
        let localized = loc.t(key)
        if localized != key { return localized }
        return loc.t("tool_desc_default")
    }
}
