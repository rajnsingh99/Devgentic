// VSCodifiedSidebarContainerView.swift
//
//  VSCodifiedSidebarContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import Combine
import os

// MARK: - Main Sidebar Container View
struct VSCodifiedSidebarContainerView: View {
    // --- State Management ---
    @State private var selectedTab: SidebarTab? = .conversations
    @Binding var isSidebarVisible: Bool
    @Binding var sidebarWidth: CGFloat
    
    private let minSidebarWidth: CGFloat = 300
    private let maxSidebarWidth: CGFloat = 1000
    private let activityBarWidth: CGFloat = 50

    @State private var preferredWidths: [SidebarTab: CGFloat] = [
        .newChat: 300,
        .conversations: 300,
        .explorer: 300,
        .ollama: 500,
        .agents: 300,
        .promptLibrary: 300,
        .settings: 300,
        .user: 300
    ]

    @EnvironmentObject var viewModel: MainApplicationViewModel

    init(isSidebarVisible: Binding<Bool>, sidebarWidth: Binding<CGFloat>) {
        self._isSidebarVisible = isSidebarVisible
        self._sidebarWidth = sidebarWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                .frame(width: activityBarWidth)

            if isSidebarVisible {
                SideBarPaneView(selectedTab: $selectedTab, sidebarWidth: $sidebarWidth)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                Divider()
                    .frame(width: 8)
                    .background(Color.gray.opacity(0.01))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = self.sidebarWidth + value.translation.width
                                self.sidebarWidth = min(max(newWidth, self.minSidebarWidth), self.maxSidebarWidth)
                            }
                    )
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .onChange(of: selectedTab) { newTab in
            if let newTab = newTab, let newPreferredWidth = preferredWidths[newTab] {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.sidebarWidth = min(max(newPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
                }
            }
        }
        .onAppear {
            if let initialTab = selectedTab, let initialPreferredWidth = preferredWidths[initialTab] {
                self.sidebarWidth = min(max(initialPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
            }
        }
    }
}

// MARK: - Preview Provider for VSCodifiedSidebarContainerView
struct VSCodifiedSidebarContainerView_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State var sidebarVisible = true
        @State var currentSidebarWidth: CGFloat = 350

        // MARK: - Corrected: Initializer for the view model no longer takes OllamaService
        @StateObject var vm = MainApplicationViewModel(
            ollamaProfileStore: OllamaProfileStore()
        )

        var body: some View {
             HStack(spacing: 0) {
                 VStack {
                      Button("Toggle Sidebar") {
                           withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible.toggle()
                           }
                      }
                      Text("Current Width: \(currentSidebarWidth, specifier: "%.0f")")
                      Spacer()
                 }
                 .padding()
                 .frame(width: 150)

                 VSCodifiedSidebarContainerView(
                    isSidebarVisible: $sidebarVisible,
                    sidebarWidth: $currentSidebarWidth
                 )
                 .environmentObject(vm)
                 .background(Color.gray.opacity(0.3))
                 
                 VStack {
                     Text("Main Content")
                 }
                 .frame(maxWidth: .infinity, maxHeight: .infinity)
                 .background(Color.blue.opacity(0.2))
             }
             .frame(width: 800, height: 600)
             .previewDisplayName("Resizable Sidebar Container")
             .onAppear {
                 // MARK: - Corrected: Configure the SHARED service instance for the preview
                 let service = OllamaService.shared
                 service.serverStatus = .connected
                 service.localModels = ["preview-model:latest"]
             }
        }
    }
    
    static var previews: some View {
        PreviewWrapper()
    }
}

