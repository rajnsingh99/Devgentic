//
//  JoinModeCard.swift
//  Devgentic
//
//  Reusable fan-in (join) behaviour control shared by every node inspector.
//  A node with two or more incoming edges can either wait for ALL of them to
//  succeed (AND-join, the historical default) or run as soon as ANY one of them
//  succeeds (OR-join / synchronizing merge). Both modes are synchronizing — the
//  node still waits for its whole dependency level to finish; they differ only
//  in how many branches must have succeeded for the node to run.
//
//  The control binds straight to `JoinMode`; each inspector decides whether to
//  drive it with a live `nodeConfig` binding (Profile) or a local @State value
//  flushed on Save (structural inspectors with Cancel/Save).
//

import SwiftUI

struct JoinModeCard: View {
    @Binding var joinMode: JoinMode
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard(title: "Fan-In Behavior", icon: "arrow.triangle.merge", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Text("When more than one branch feeds into this node, choose whether it needs every branch or just one. Has no effect with fewer than two incoming connections.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $joinMode) {
                    ForEach(JoinMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                Text(explanation)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explanation: String {
        switch joinMode {
        case .all:
            return "AND-join: runs only after every incoming branch succeeds. If any branch fails or is skipped, this node is skipped too."
        case .any:
            return "OR-join: waits for all branches to finish, then runs if at least one succeeded — using only the successful branches' outputs."
        }
    }
}
