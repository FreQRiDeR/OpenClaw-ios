import SwiftUI

struct ChatTab: View {
    @State private var vm: ChatViewModel
    let sessionKey: String
    let title: String
    init(client: GatewayClientProtocol, sessionKey: String? = nil, title: String = "Chat") {
        let resolvedKey = sessionKey ?? SessionKeys.main
        _vm = State(initialValue: ChatViewModel(client: client, sessionKey: resolvedKey))
        self.sessionKey = resolvedKey
        self.title = title
    }

    var body: some View {
        ChatView(vm: vm, title: title)
    }
}
