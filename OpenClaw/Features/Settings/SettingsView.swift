import SwiftUI

struct SettingsView: View {
    var accountStore: AccountStore
    var client: GatewayClientProtocol?

    @State private var showAddAccount = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var accountToDelete: GatewayAccount?
    @State private var accountToEdit: GatewayAccount?

    var body: some View {
        List {
            // Active account
            if let active = accountStore.activeAccount {
                Section {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(AppColors.success)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(active.name)
                                .font(AppTypography.body)
                                .fontWeight(.medium)
                            Text(active.displayURL)
                                .font(AppTypography.micro)
                                .foregroundStyle(AppColors.neutral)
                        }
                        Spacer()
                        Text("Active")
                            .font(AppTypography.nano)
                            .padding(.horizontal, Spacing.xxs)
                            .padding(.vertical, 2)
                            .background(AppColors.success.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppColors.success)
                    }
                } header: {
                    Text("Active Account")
                }
            }

            // All accounts (switch)
            if accountStore.accounts.count > 1 {
                Section("Switch Account") {
                    ForEach(accountStore.accounts) { account in
                        Button {
                            accountStore.setActive(account.id)
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: account.id == accountStore.activeAccountId ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(account.id == accountStore.activeAccountId ? AppColors.success : AppColors.neutral)
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(account.name)
                                        .font(AppTypography.body)
                                    Text(account.displayURL)
                                        .font(AppTypography.micro)
                                        .foregroundStyle(AppColors.neutral)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button {
                                accountToEdit = account
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(AppColors.primaryAction)

                            Button(role: .destructive) {
                                accountToDelete = account
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            // Add account
            Section {
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus.circle")
                }
            }

            // Gateway info
            Section("Gateway") {
                LabeledContent("Agent", value: AppConstants.agentId.capitalized)
            }

            // Connection test
            Section {
                Button(action: runConnectionTest) {
                    HStack {
                        Label("Test Connection", systemImage: "network")
                        Spacer()
                        if isTesting { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(isTesting || !accountStore.isConfigured)

                if let result = testResult {
                    Label(result.message, systemImage: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(AppTypography.captionMono)
                        .foregroundStyle(result.isSuccess ? AppColors.success : AppColors.danger)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Diagnostics")
            }

            // About
            Section("About") {
                LabeledContent("App", value: "OpenClaw")
                LabeledContent("Accounts", value: "\(accountStore.accounts.count)")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddAccount) {
            AddAccountView(accountStore: accountStore)
        }
        .sheet(item: $accountToEdit) { account in
            AddAccountView(accountStore: accountStore, editingAccount: account)
        }
        .alert("Delete Account?", isPresented: Binding(
            get: { accountToDelete != nil },
            set: { if !$0 { accountToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let account = accountToDelete {
                    accountStore.delete(account.id)
                }
            }
            Button("Cancel", role: .cancel) { accountToDelete = nil }
        } message: {
            if let account = accountToDelete {
                Text("Remove \"\(account.name)\"? The token will be deleted from Keychain.")
            }
        }
    }

    private func runConnectionTest() {
        isTesting = true
        testResult = nil
        guard let client else { return }
        Task {
            do {
                let dto: SystemStatsDTO = try await client.stats("stats/system")
                testResult = TestResult(
                    isSuccess: true,
                    message: "OK \u{2014} CPU \(String(format: "%.1f", dto.cpuPercent))%  RAM \(dto.ramPercent)%"
                )
                Haptics.shared.success()
            } catch {
                testResult = TestResult(isSuccess: false, message: error.localizedDescription)
                Haptics.shared.error()
            }
            isTesting = false
        }
    }
}

private struct TestResult {
    let isSuccess: Bool
    let message: String
}
