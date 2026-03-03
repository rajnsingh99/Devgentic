import SwiftUI
import AppKit

/// A view modifier that allows direct configuration of the underlying NSWindow.
struct WindowConfigurator: ViewModifier {
    let collectionBehavior: NSWindow.CollectionBehavior
    
    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(collectionBehavior: collectionBehavior))
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let collectionBehavior: NSWindow.CollectionBehavior
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.collectionBehavior = collectionBehavior
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.collectionBehavior = collectionBehavior
            }
        }
    }
}

extension View {
    /// Configures the underlying NSWindow's collection behavior.
    /// Useful for making windows float over fullscreen apps or join all spaces.
    func configureWindow(collectionBehavior: NSWindow.CollectionBehavior) -> some View {
        self.modifier(WindowConfigurator(collectionBehavior: collectionBehavior))
    }
}
