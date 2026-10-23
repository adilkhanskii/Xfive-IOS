import SwiftUI
import UIKit
import MessageUI

/// Settings sheet — split out of ProfileView. Contains account actions, language picker,
/// Face ID toggle, public profile toggle, system links, version.
struct SettingsView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var subscription: Subscription
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @EnvironmentObject private var iap: IAPService
    @Environment(\.dismiss) private var dismiss

    @State private var deleteStage: DeleteStage = .idle
    @State private var errorMessage: String?
    @AppStorage("x5.face_id_enabled") private var faceIDEnabled = false
    @AppStorage("x5.promo.enabled") private var promoEnabled = true
    @State private var publicToggle: Bool = true
    @State private var showingStore = false
    @State private var isRestoringSubscriptions = false
    @StateObject private var supportChats = ChatsService()
    @State private var openingSupportChat = false
    @State private var supportChat: ChatRoom?
    @State private var showingEmailOptions = false
    @State private var emailCopied = false

    private enum DeleteStage { case idle, firstConfirm, finalConfirm, deleting }

    var body: some View {
        NavigationStack {
            List {
                // Account
                Section(loc.t("settings_account")) {
                    if let email = auth.userEmail {
                        LabeledContent(loc.t("settings_email"), value: email)
                    }

                    Button { showingStore = true } label: {
                        HStack {
                            Image(systemName: "cart.fill")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("profile_store_title"))
                                    .foregroundColor(.primary)
                                Text(loc.t("profile_buy_credits"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }

                    if IAPSettingsPurchaseVisibilityPolicy.shouldShowRestorePurchases {
                        Button {
                            restoreSubscriptions()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 22)
                                Text(loc.t("settings_restore_subscriptions"))
                                    .foregroundColor(.primary)
                                Spacer()
                                if isRestoringSubscriptions {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isRestoringSubscriptions || iap.isPurchasing)
                    }

                    if IAPSettingsPurchaseVisibilityPolicy.shouldShowManageSubscription(
                        hasActiveLegacyAppStoreSubscription:
                            iap.activeSubscriptionSnapshot.hasActiveLegacySubscription,
                        hasActiveVerifiedAppStoreSubscription:
                            iap.activeSubscriptionSnapshot.hasActiveVerifiedSubscription
                    ) {
                        Button {
                            if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "creditcard")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 22)
                                Text(loc.t("settings_manage_subscription"))
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Appearance / language
                Section {
                    Picker(selection: Binding(
                        get: { loc.current },
                        set: { loc.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { language in
                            Text("\(language.flag) \(language.label)").tag(language)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("settings_language"))
                                    .foregroundColor(.primary)
                                Text("\(loc.current.flag) \(loc.current.label)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(loc.t("settings_appearance"))
                } footer: {
                    Text(loc.t("settings_language_footer"))
                }

                // Privacy & app
                Section {
                    Toggle(isOn: $faceIDEnabled) {
                        HStack {
                            Image(systemName: "faceid")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("settings_face_id"))
                                Text(loc.t("settings_face_id_sub"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $publicToggle) {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("settings_public_profile"))
                                Text(loc.t("settings_public_profile_sub"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onChange(of: publicToggle) { newValue in
                        Task { await updatePublic(newValue) }
                    }

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "bell")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("settings_notifications"))
                                    .foregroundColor(.primary)
                                Text(loc.t("settings_notifications_sub"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink {
                        CacheView()
                    } label: {
                        HStack {
                            Image(systemName: "internaldrive")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("settings_cache"))
                                    .foregroundColor(.primary)
                                Text(loc.t("settings_cache_sub"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $promoEnabled) {
                        HStack {
                            Image(systemName: "megaphone")
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("settings_promo"))
                                Text(loc.t("settings_promo_sub"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onChange(of: promoEnabled) { newValue in
                        if newValue {
                            PushNotifications.shared.schedulePromoLoop()
                        } else {
                            PushNotifications.shared.cancelPromoLoop()
                        }
                    }

                }

                // Sign out
                Section {
                    Button(loc.t("settings_signout")) {
                        Task {
                            await auth.signOut()
                            dismiss()
                        }
                    }
                }

                // Danger zone
                Section {
                    Button(role: .destructive) {
                        deleteStage = .firstConfirm
                    } label: {
                        if deleteStage == .deleting {
                            HStack { ProgressView(); Text(loc.t("settings_deleting")) }
                        } else {
                            Text(loc.t("settings_delete"))
                        }
                    }
                    .disabled(deleteStage == .deleting)
                } header: {
                    Text(loc.t("settings_danger"))
                } footer: {
                    Text(loc.t("settings_delete_footer"))
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }

                // Поддержка (Адильхан 22.10): его WhatsApp и основной аккаунт X5 в приложении.
                Section(loc.t("settings_support")) {
                    if let whatsappURL = URL(string: X5SupportContacts.whatsappURL) {
                        Link(destination: whatsappURL) {
                            Label(loc.t("settings_support_whatsapp"), systemImage: "message.fill")
                        }
                    }
                    // 23.10 Адильхан: «Связаться с разработчиком» — сразу чат с его аккаунтом,
                    // без промежуточного профиля (профиль у владельца мигал и закрывался).
                    Button(action: openSupportChat) {
                        HStack {
                            Label(loc.t("settings_support_x5"), systemImage: "bubble.left.and.bubble.right.fill")
                            Spacer()
                            if openingSupportChat {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(openingSupportChat)
                    // 23.10: mailto без настроенной почты открывал «Новая учётная запись» в Почте —
                    // теперь шторка с адресом: «Открыть почту» (если настроена) и «Скопировать адрес».
                    Button {
                        showingEmailOptions = true
                    } label: {
                        HStack {
                            Label(loc.t("settings_support_email"), systemImage: "envelope.fill")
                            Spacer()
                            Text(X5SupportContacts.email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .confirmationDialog(
                        X5SupportContacts.email,
                        isPresented: $showingEmailOptions,
                        titleVisibility: .visible
                    ) {
                        if MFMailComposeViewController.canSendMail(),
                           let mailURL = X5SupportContacts.mailtoURL {
                            Button(loc.t("settings_support_email_open")) {
                                UIApplication.shared.open(mailURL)
                            }
                        }
                        Button(loc.t("settings_support_email_copy")) {
                            UIPasteboard.general.string = X5SupportContacts.email
                            emailCopied = true
                        }
                        Button(loc.t("btn_cancel"), role: .cancel) {}
                    } message: {
                        Text(loc.t("settings_support_email_hint"))
                    }
                    .alert(loc.t("settings_support_email_copied"), isPresented: $emailCopied) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(X5SupportContacts.email)
                    }
                }

                // Legal
                Section(loc.t("settings_legal")) {
                    if let privacyURL = URL(string: "https://tooyakov-art.github.io/x5site/privacy.html") {
                        Link(loc.t("settings_privacy"), destination: privacyURL)
                    }
                    if let termsURL = URL(string: "https://tooyakov-art.github.io/x5site/terms.html") {
                        Link(loc.t("settings_terms"), destination: termsURL)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text(versionString).font(.footnote).foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            // Чат с разработчиком — шторкой поверх Настроек, как «Написать» в профиле.
            .sheet(item: $supportChat) { chat in
                NavigationStack { ChatThreadView(chat: chat) }
                    .preferredColorScheme(.dark)
            }
            .navigationTitle(loc.t("settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("btn_done")) { dismiss() }
                }
            }
            .confirmationDialog(
                loc.t("settings_delete_confirm"),
                isPresented: Binding(
                    get: { deleteStage == .firstConfirm },
                    set: { if !$0 { deleteStage = .idle } }
                ),
                titleVisibility: .visible
            ) {
                Button(loc.t("btn_continue"), role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        deleteStage = .finalConfirm
                    }
                }
                Button(loc.t("btn_cancel"), role: .cancel) { deleteStage = .idle }
            } message: {
                Text(loc.t("settings_delete_confirm_msg"))
            }
            .confirmationDialog(
                loc.t("settings_delete_sure"),
                isPresented: Binding(
                    get: { deleteStage == .finalConfirm },
                    set: { if !$0 { deleteStage = .idle } }
                ),
                titleVisibility: .visible
            ) {
                Button(loc.t("settings_delete_forever"), role: .destructive) {
                    Task { await runDelete() }
                }
                Button(loc.t("btn_cancel"), role: .cancel) { deleteStage = .idle }
            } message: {
                Text(loc.t("settings_delete_sure_msg"))
            }
            .onAppear {
                publicToggle = currentUser.profile?.isPublic ?? true
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingStore) { PaywallView() }
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Xfive marketing · v\(v) (\(b))"
    }

    private func restoreSubscriptions() {
        errorMessage = nil
        isRestoringSubscriptions = true
        Task {
            defer { isRestoringSubscriptions = false }
            await iap.restore()
            if let userID = auth.userId,
               let accessToken = await auth.freshAccessToken() {
                await currentUser.load(userId: userID, accessToken: accessToken)
            }
            subscription.sync(from: currentUser.profile)
            errorMessage = iap.lastError
        }
    }

    private func openSupportChat() {
        // Владелец (сам Адильхан) себе написать не может — открываем его «Чаты»,
        // туда приходят сообщения пользователей.
        if X5SupportContacts.isOfficialAccount(auth.userId) {
            NotificationCenter.default.post(
                name: .x5SwitchTab,
                object: nil,
                userInfo: ["tab": X5AppTab.chats.notificationKey]
            )
            dismiss()
            return
        }
        guard let me = auth.userId else { return }
        errorMessage = nil
        openingSupportChat = true
        Task {
            defer { openingSupportChat = false }
            supportChats.configureAccessTokenProvider(auth: auth)
            guard let token = await auth.freshAccessToken() else {
                errorMessage = loc.t("settings_support_chat_failed")
                return
            }
            let chat = await supportChats.ensureChat(
                otherUserId: X5SupportContacts.officialAccountId,
                currentUserId: me,
                taskId: nil,
                taskTitle: nil,
                accessToken: token
            )
            if let chat {
                supportChat = chat
            } else {
                errorMessage = loc.t("settings_support_chat_failed")
            }
        }
    }

    private func updatePublic(_ value: Bool) async {
        guard let token = auth.accessToken else { return }
        await currentUser.patch("is_public", value: value, accessToken: token)
    }

    private func runDelete() async {
        deleteStage = .deleting
        errorMessage = nil
        do {
            try await auth.deleteAccount()
            await MainActor.run {
                deleteStage = .idle
                dismiss()
            }
        } catch {
            await MainActor.run {
                DiagnosticLogger.log(event: "delete_account_failed", extra: [
                    "summary": error.localizedDescription
                ])
                deleteStage = .idle
                errorMessage = "\(loc.t("settings_delete_failed")): \(error.localizedDescription)"
            }
        }
    }
}

// Language is system-driven only — see LocalizationService for the auto-detect logic.
