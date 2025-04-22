// Views/VisualEffectBlur.swift
import SwiftUI
import AppKit

// MARK: - Visual Effect View for Background Blur
struct VisualEffectBlur: NSViewRepresentable {
    // Creates the NSVisualEffectView
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // Configure the blur effect
        view.material = .hudWindow // A common material for floating panels
        view.blendingMode = .behindWindow // Blend with content behind the window
        view.state = .active // Ensure the effect is active
        return view
    }

    // No updates needed when SwiftUI state changes for this simple view
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// Preview Provider (Optional, shows the effect)
struct VisualEffectBlur_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            // Sample background content to see the blur through
            LinearGradient(gradient: Gradient(colors: [.red, .blue]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 200, height: 100)

            // The blur view itself
            VisualEffectBlur()
                .frame(width: 150, height: 80)
                .overlay(Text("Blurred").foregroundColor(.white)) // Add text on top
        }
        .previewLayout(.sizeThatFits)
    }
}
