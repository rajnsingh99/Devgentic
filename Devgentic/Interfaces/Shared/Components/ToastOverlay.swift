//
//  ToastOverlay.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  A lightweight toast notification system.
//  Inject `ToastManager` as an EnvironmentObject at the app root,
//  then call `toastManager.show("message", style: .success)` from any view.
//

import SwiftUI

// MARK: - Toast Style

enum ToastStyle {
    case success
    case error
    case warning

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .error:   return .red
        case .warning: return .orange
        }
    }
}

// MARK: - Toast Manager

@Observable @MainActor
final class ToastManager {
    var isShowing: Bool = false
    var message: String = ""
    var style: ToastStyle = .success

    private var dismissTask: Task<Void, Never>?

    /// Shows a toast with the given message and style.
    /// Auto-dismisses after `duration` seconds.
    func show(_ message: String, style: ToastStyle = .success, duration: TimeInterval = 3.0) {
        dismissTask?.cancel()

        self.message = message
        self.style = style

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.isShowing = true
        }

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.isShowing = false
            }
        }
    }

    /// Immediately dismisses the current toast.
    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            isShowing = false
        }
    }
}

// MARK: - Toast View

struct ToastOverlay: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    var body: some View {
        if toastManager.isShowing {
            HStack(spacing: 10) {
                Image(systemName: toastManager.style.icon)
                    .foregroundColor(toastManager.style.tint)
                    .font(.system(.title3, weight: .semibold))

                Text(toastManager.message)
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)

                Spacer()

                Button {
                    toastManager.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // MARK: Liquid Glass — toast with glass treatment + semantic tint (success/warning/error)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(toastManager.style.tint.opacity(0.35), lineWidth: 1)
            )
            // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
            // .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4))
            // .overlay(RoundedRectangle(cornerRadius: 12).stroke(toastManager.style.tint.opacity(0.3), lineWidth: 1))
            .frame(maxWidth: 400)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("\(toastManager.style == .error ? "Error" : toastManager.style == .warning ? "Warning" : "Success"): \(toastManager.message)")
        }
    }
}

// MARK: - View Modifier for Easy Integration

struct ToastContainerModifier: ViewModifier {
    @Environment(ToastManager.self) private var toastManager

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ToastOverlay()
                    .padding(.top, 8)
            }
    }
}

extension View {
    /// Adds a toast overlay container to this view.
    func withToastOverlay() -> some View {
        modifier(ToastContainerModifier())
    }
}
