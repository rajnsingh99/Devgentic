// Views/Messages/ImageView.swift
import SwiftUI

struct ImageView: View {
    let url: URL?
    let alt: String? // Optional alt text/caption

    // Define max dimensions (adjust these based on your desired layout)
    private let maxImageWidth: CGFloat = 350
    private let maxImageHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    // Placeholder while loading
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(maxWidth: maxImageWidth, idealHeight: maxImageHeight * 0.6) // Give placeholder a size
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                case .success(let image):
                    // Display the loaded image
                    image
                        .resizable()
                        .scaledToFit()
                        // Apply frame constraints AFTER scaledToFit for correct behavior
                        .frame(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
                        .cornerRadius(6)
                        // Optional: Add context menu or tap gesture
                        .contextMenu {
                            Button {
                                copyImageToClipboard(image: image)
                            } label: {
                                Label("Copy Image", systemImage: "doc.on.doc")
                            }
                            if let url = url {
                                Link("Open Image URL", destination: url)
                                // Button("Quick Look") { /* Add QuickLook logic */ }
                            }
                        }


                case .failure(let error):
                    // Display error state
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title)
                            .foregroundColor(.red)
                        Text("Failed to load image")
                            .font(.caption)
                        Text(error.localizedDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: maxImageWidth, idealHeight: maxImageHeight * 0.6) // Give error view a size
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                @unknown default:
                    EmptyView() // Should not happen
                }
            }

            // Display caption if alt text exists and is not empty
            if let alt = alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4) // Padding for caption
            }
        }
        // Apply overall padding if needed, depending on how it's used in container
        // .padding(.vertical, 4)
    }

    // Helper for copy action
    private func copyImageToClipboard(image: Image) {
        // Converting SwiftUI Image to NSImage for clipboard requires rendering
        // This is a simplified example; might need refinement based on image source/type
        #if os(macOS)
        let view = NSHostingView(rootView: image.frame(width: 200, height: 200)) // Render at a nominal size
        view.layer?.contentsScale = 2.0 // Improve resolution if needed
        view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!) // Ensure it renders

        if let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                 NSPasteboard.general.clearContents()
                 NSPasteboard.general.setData(pngData, forType: .png)
                 print("Image copied to clipboard (as PNG).")
            } else { print("Failed to get PNG data for image.") }
        } else { print("Failed to get bitmap representation for image.") }
        #endif
    }
}

// Optional Preview Provider
struct ImageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ImageView(url: URL(string: "https://via.placeholder.com/300x200.png/09f/fff?text=Valid+Image"), alt: "A valid placeholder image")
            ImageView(url: URL(string: "https://invalid-url-that-will-fail"), alt: "An invalid URL")
            ImageView(url: nil, alt: "A nil URL")
            ImageView(url: URL(string: "https://via.placeholder.com/150"), alt: nil) // Valid image, no alt
        }
        .padding()
    }
}
