//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "AI", icon: "sparkles", view: .ai)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var aiPanel = AIPanelModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.enableAITab) var enableAITab
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home: return true
            case .shelf: return boringShelf
            case .ai: return enableAITab
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    // Hovering a tab switches to it, same as clicking. onContinuousHover
                    // (not onHover) so it also works when the cursor is already over the
                    // tab as the tab bar appears (onHover needs a fresh mouse-enter).
                    .onContinuousHover { phase in
                        if case .active = phase, coordinator.currentView != tab.view {
                            withAnimation(.smooth) {
                                coordinator.currentView = tab.view
                            }
                        }
                    }
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // An agent waits for a permission / plan / question answer.
                        if tab.view == .ai && aiPanel.hasPendingDecision {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                                .padding(.top, 3)
                                .padding(.trailing, 9)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
