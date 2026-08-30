import SwiftUI

struct SessionsView: View {
    @State var vm: SessionsViewModel
    let repository: SessionRepository
    var client: GatewayClientProtocol?
    @State private var selectedTab: SessionTab = .active
    enum SessionTab: String, CaseIterable {
        case active = "Active Sessions"
        case subagents = "Subagents"
    }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            Picker("Session type", selection: $selectedTab) {
                ForEach(SessionTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

            switch selectedTab {
            case .active:
                activeSessionsSection
            case .subagents:
                subagentsSection
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                DetailTitleView(title: "Sessions") {
                    sessionSubtitle
                }
            }
        }
        }
        .task { await vm.load() }
    }

    // MARK: - Active Sessions (open in chat)

    @ViewBuilder
    private var activeSessionsSection: some View {
        if vm.isLoading && vm.activeSessions.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !vm.activeSessions.isEmpty {
            List {
                Section("Select a session to open in Chat") {
                    ForEach(vm.activeSessions) { session in
                        NavigationLink {
                            if let client {
                                ChatTab(client: client, sessionKey: session.id, title: session.displayName)
                            }
                        } label: {
                            ActiveSessionRow(session: session)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await vm.load()
                Haptics.shared.refreshComplete()
            }
        } else if let err = vm.error {
            List { CardErrorView(error: err, minHeight: 60) }
                .listStyle(.insetGrouped)
        } else {
            ContentUnavailableView(
                "No Active Sessions",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("No active chat sessions found.")
            )
        }
    }

    // MARK: - Subagents

    @ViewBuilder
    private var subagentsSection: some View {
        if vm.isLoading && vm.subagents.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !vm.subagents.isEmpty {
            List {
                Section("Subagent Sessions") {
                    ForEach(vm.subagents) { session in
                        NavigationLink {
                            SessionTraceView(
                                sessionKey: session.id,
                                title: session.displayName,
                                subtitle: session.updatedAtFormatted,
                                repository: repository,
                                client: client
                            )
                        } label: {
                            SubagentRow(session: session)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await vm.load()
                Haptics.shared.refreshComplete()
            }
        } else if let err = vm.error {
            List { CardErrorView(error: err, minHeight: 60) }
                .listStyle(.insetGrouped)
        } else {
            ContentUnavailableView(
                "No Subagents",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("No subagent sessions found.")
            )
        }
    }

    @ViewBuilder
    private var sessionSubtitle: some View {
        if let main = vm.mainSession {
            HStack(spacing: Spacing.xs) {
                Text(main.status == .running ? "Running" : "Idle")
                    .font(AppTypography.micro)
                    .foregroundStyle(main.status == .running ? AppColors.success : AppColors.neutral)
                Text("\u{00B7} \(Formatters.tokens(main.totalTokens))")
                    .font(AppTypography.micro)
                    .foregroundStyle(AppColors.neutral)
            }
        } else if vm.isLoading {
            Text("Loading\u{2026}")
                .font(AppTypography.micro)
                .foregroundStyle(AppColors.neutral)
        }
    }
}

// MARK: - Active Session Row
private struct ActiveSessionRow: View {
    let session: SessionEntry
    /// Friendly title: the main terminal session is always "Main Session".
    private var title: String {
        if case .main = session.kind { return "Main Session" }
        return session.displayName
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(session.status == .running ? AppColors.success : AppColors.neutral)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(AppTypography.body)
                    .lineLimit(1)

                HStack(spacing: Spacing.sm) {
                    if let model = session.model {
                        ModelPill(model: model)
                    }
                    Label(Formatters.tokens(session.totalTokens), systemImage: "number.circle")
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.metricPrimary)
                    Spacer()
                    Text(session.updatedAtFormatted)
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.neutral)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Subagent Row
private struct SubagentRow: View {
    let session: SessionEntry

    var body: some View {
        HStack(spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(session.displayName)
                    .font(AppTypography.body)
                    .lineLimit(1)

                HStack(spacing: Spacing.sm) {
                    if let model = session.model {
                        ModelPill(model: model)
                    }
                    Label(Formatters.tokens(session.totalTokens), systemImage: "number.circle")
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.metricPrimary)
                    Spacer()
                    Text(session.updatedAtFormatted)
                        .font(AppTypography.micro)
                        .foregroundStyle(AppColors.neutral)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}
