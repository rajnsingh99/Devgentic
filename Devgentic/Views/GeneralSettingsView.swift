// Views/GeneralSettingsView.swift
import SwiftUI

// MARK: - General Settings Detail View
struct GeneralSettingsView: View {
    // Binding to the setting managed by the parent view
    @Binding var windowOpacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 15) { // Increased spacing slightly
            Text("General Settings")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            HStack {
                Text("Window Transparency:")
                    .frame(width: 150, alignment: .leading) // Consistent label width
                Slider(value: $windowOpacity, in: 0.2...1.0) { // Add label for accessibility
                    Text("Window Transparency")
                } minimumValueLabel: {
                    Text("20%").font(.caption) // Optional min/max labels
                } maximumValueLabel: {
                    Text("100%").font(.caption)
                }
                // Display the current value numerically
                Text("\(Int(windowOpacity * 100))%")
                    .frame(width: 40, alignment: .trailing)
            }
            .controlSize(.regular) // Consistent control size

            // Add more general settings here later if needed
            // Example:
            // Toggle("Start at Login", isOn: .constant(false)) // Placeholder

            Spacer() // Push content to top if view is tall
        }
    }
}

// Preview Provider
struct GeneralSettingsView_Previews: PreviewProvider {
    @State static var opacity = 0.75

    static var previews: some View {
        GeneralSettingsView(windowOpacity: $opacity)
            .padding()
            .frame(width: 400) // Simulate typical detail view width
            .previewLayout(.sizeThatFits)
    }
}
