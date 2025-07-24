// Views/Shared/VisualEffectBlur.swift
import SwiftUI
import AppKit

// MARK: - Visual Effect View for Background Blur
struct VisualEffectBlur: NSViewRepresentable {
    // Allow customizing the material
    var material: NSVisualEffectView.Material = .hudWindow // Default remains .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow // Default
    var state: NSVisualEffectView.State = .active // Default

    // Creates the NSVisualEffectView
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // Configure the blur effect using the properties
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    // Update the view if the properties change
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// Preview Provider (Optional, shows the effect)
struct VisualEffectBlur_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            // Example with default (.hudWindow)
            ZStack {
                LinearGradient(gradient: Gradient(colors: [.red, .blue]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 200, height: 100)
                VisualEffectBlur() // Uses default .hudWindow
                    .frame(width: 150, height: 80)
                    .overlay(Text("HUD Window").foregroundColor(.white))
            }

            // Example with a different material
            ZStack {
                 LinearGradient(gradient: Gradient(colors: [.green, .yellow]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 200, height: 100)
                VisualEffectBlur(material: .windowBackground) // Explicitly set material
                    .frame(width: 150, height: 80)
                    .overlay(Text("Window Background").foregroundColor(.primary)) // Use primary color for better contrast
            }
        }
        .previewLayout(.sizeThatFits)
        .padding()
    }
}
