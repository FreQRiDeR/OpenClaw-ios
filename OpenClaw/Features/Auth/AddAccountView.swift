import SwiftUI

/// Add or edit a gateway account.
/// Used for first-time setup (add), adding additional accounts (add),
/// and editing an existing account (when `editingAccount` is provided, the
/// form pre-fills values and shows Save / Cancel buttons).
struct AddAccountView: View {
    var accountStore: AccountStore
    var onDone: (() -> Void)?
    /// When non-nil, the view edits this account and shows Save/Cancel instead of Connect.
    let editingAccount: GatewayAccount?

    init(accountStore: AccountStore, editingAccount: GatewayAccount? = nil, onDone: (() -> Void)? = nil) {
        self.accountStore = accountStore
        self.onDone = onDone
        self.editingAccount = editingAccount
        _nameInput = State(initialValue: editingAccount?.name ?? "")
        _urlInput = State(initialValue: editingAccount?.url ?? "")
        // The token lives in the Keychain and is never stored on GatewayAccount,
        // so it can't be pre-filled when editing. Leaving it empty keeps the
        // existing token on save (see AccountStore.update).
        _tokenInput = State(initialValue: "")
        _agentIdInput = State(initialValue: editingAccount?.agentId ?? "orchestrator")
        _workspacePathInput = State(initialValue: editingAccount?.workspacePath ?? "")
    }

    @State private var nameInput = ""
    @State private var urlInput = ""
    @State private var tokenInput = ""
    @State private var agentIdInput = "orchestrator"
    @State private var workspacePathInput = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool { editingAccount != nil }

    private var title: String {
        if isEditing {
            return "Edit Account"
        } else if accountStore.accounts.isEmpty {
            return "Connect to Gateway"
        } else {
            return "Add Account"
        }
    }

    private var canSave: Bool {
        !isSaving
        && !urlInput.trimmingCharacters(in: .whitespaces).isEmpty
        && (isEditing || !tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image("openclaw")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(AppTypography.screenTitle)
                Text("Enter your gateway URL and Bearer token.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.neutral)
                    .multilineTextAlignment(.center)
            }
                // Token
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("BEARER TOKEN")
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.neutral)
                    SecureField("Paste token here\u{2026}", text: $tokenInput)
                        #if os(iOS)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .padding(Spacing.sm)
                        .background(AppColors.neutral.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                // Agent ID
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("AGENT ID")
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.neutral)
                    TextField("orchestrator", text: $agentIdInput)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .padding(Spacing.sm)
                        .background(AppColors.neutral.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                // Workspace path (optional override)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("WORKSPACE PATH")
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.neutral)
                    TextField("auto (based on Agent ID)", text: $workspacePathInput)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        .padding(Spacing.sm)
                        .background(AppColors.neutral.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    Text("Leave empty for default. Set to ~/.openclaw/workspace/ for flat layouts.")
                        .font(AppTypography.nano)
                        .foregroundStyle(AppColors.neutral)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: save) {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text(isEditing ? "Save" : "Connect")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(Spacing.sm + 2)
            }
            .background(AppColors.primaryAction, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            .foregroundStyle(.white)
            .disabled(!canSave)
            if isEditing {
                Button(action: cancel) {
                    Text("Cancel")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(Spacing.sm + 2)
                }
                .background(Color.clear, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .stroke(AppColors.neutral.opacity(0.4), lineWidth: 1)
                )
                .foregroundStyle(AppColors.neutral)
            }
            Spacer()
        }
        .padding(Spacing.xl)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        let name = nameInput.trimmingCharacters(in: .whitespaces)
        let finalName = name.isEmpty ? (URL(string: urlInput)?.host() ?? "Gateway") : name
        do {
            let agent = agentIdInput.trimmingCharacters(in: .whitespaces)
            if let account = editingAccount {
                try accountStore.update(
                    id: account.id,
                    name: finalName,
                    url: urlInput,
                    token: tokenInput,
                    agentId: agent.isEmpty ? "orchestrator" : agent,
                    workspacePath: workspacePathInput
                )
            } else {
                try accountStore.add(
                    name: finalName,
                    url: urlInput,
                    token: tokenInput,
                    agentId: agent.isEmpty ? "orchestrator" : agent,
                    workspacePath: workspacePathInput
                )
            }
            Haptics.shared.success()
            onDone?()
            dismiss()
        } catch {
            Haptics.shared.error()
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func cancel() {
        onDone?()
        dismiss()
    }
}
