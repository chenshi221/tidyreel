import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

public struct SourcesRootView: View {
    public let store: AppStore
    @State private var coordinator = SourcesCoordinator()
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let openId = store.openConnectionId,
               let conn = store.connections.first(where: { $0.id == openId }) {
                FileBrowserView(
                    store: store,
                    connection: conn,
                    coordinator: coordinator
                )
                .id(openId)
            } else {
                SourcesHomeView(
                    store: store,
                    coordinator: coordinator
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .sheet(item: $coordinator.editorRequest) { req in
            ConnectionEditorSheet(
                store: store,
                existing: req.existing,
                isCopy: req.isCopy,
                onSavedNewConnection: { saved in
                    let msg = l10n.tr("已添加「\(saved.name)」", "Added \"\(saved.name)\"")
                    store.showToast(
                        msg,
                        actionLabel: l10n.tr("打开", "Open")
                    ) { [weak weakStore = store] in
                        weakStore?.openBrowser(connection: saved)
                    }
                }
            )
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }
}
