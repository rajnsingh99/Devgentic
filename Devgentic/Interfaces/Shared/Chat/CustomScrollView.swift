// CustomScrollView.swift
import SwiftUI
import AppKit

// MARK: - Step 1: Subclass NSScroller for Custom Drawing
fileprivate class TransparentScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }
}

// MARK: - Step 2: Subclass NSScrollView to Enforce Style
fileprivate class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

// MARK: - Step 3: PreferenceKey to communicate child view frames
fileprivate struct ScrollViewFramesKey: PreferenceKey {
    typealias Value = [AnyHashable: CGRect]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Step 4: The NSViewRepresentable implementation
fileprivate struct CustomScrollViewRepresentable<Content: View>: NSViewRepresentable {
    let content: Content
    @Binding var scrollToID: AnyHashable?
    let frames: [AnyHashable: CGRect]
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OverlayScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        
        scrollView.verticalScroller = TransparentScroller()
        scrollView.horizontalScroller = TransparentScroller()
        
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        
        guard let clipView = scrollView.contentView as? NSClipView else { return scrollView }
        clipView.translatesAutoresizingMaskIntoConstraints = false
        
        // --- CORRECTED CONSTRAINTS ---
        // We only constrain the width (leading/trailing) and the top.
        // The height is determined by the content, allowing it to scroll.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: clipView.topAnchor)
        ])
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hostingView = nsView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
        }
        
        if let id = scrollToID, let frame = frames[id] {
            DispatchQueue.main.async {
                nsView.contentView.scroll(to: frame.origin)
                self.scrollToID = nil
            }
        }
    }
}

// MARK: - Step 5: The public SwiftUI View
struct CustomScrollView<Content: View>: View {
    let content: () -> Content
    @Binding var scrollToID: AnyHashable?
    
    @State private var frames: [AnyHashable: CGRect] = [:]
    
    init(scrollToID: Binding<AnyHashable?>, @ViewBuilder content: @escaping () -> Content) {
        self._scrollToID = scrollToID
        self.content = content
    }
    
    var body: some View {
        CustomScrollViewRepresentable(
            content: content()
                .onPreferenceChange(ScrollViewFramesKey.self) {
                    self.frames = $0
                },
            scrollToID: $scrollToID,
            frames: frames
        )
    }
}

// MARK: - Step 6: Helper for tracking view frames
extension View {
    func scrollTrackable(id: AnyHashable) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ScrollViewFramesKey.self,
                    value: [id: geo.frame(in: .global)]
                )
            }
        )
    }
}
