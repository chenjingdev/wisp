import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var container: AppContainer
    @State private var section: SidebarSection? = .general

    enum SidebarSection: String, CaseIterable, Identifiable {
        case general = "일반"
        case model = "모델"
        case hotkey = "단축키"
        case modes = "모드"
        case history = "히스토리"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .model: return "cpu"
            case .hotkey: return "keyboard"
            case .modes: return "square.stack"
            case .history: return "clock"
            }
        }
    }

    public init(container: AppContainer) {
        self.container = container
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch section ?? .general {
            case .general: GeneralPane(container: container)
            case .model: ModelsPane(container: container, manager: container.modelManager)
            case .hotkey: HotkeyPane(container: container)
            case .modes: ModesPane(container: container)
            case .history: HistoryPane(container: container)
            }
        }
        // 모드 패널은 3열(사이드바|모드목록|편집기)이라 최소 너비 합이 크다 —
        // 컬럼 최소 합(≈150+160+360+분할선/여백)보다 넉넉히 잡아 잘림을 막는다.
        .frame(minWidth: 760, minHeight: 460)
    }
}
