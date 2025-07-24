//
//  CodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import Combine

// MARK: - Theme & Color Extensions (No Change)
extension CodeEditSourceEditor.EditorTheme {
    public static let defaultDark: Self = .init(
        text: .init(color: .white),
        insertionPoint: .white,
        invisibles: .init(color: .systemGray.withAlphaComponent(0.5)),
        background: NSColor(hex: "#000000"),
        lineHighlight: NSColor(hex: "#44475a").withAlphaComponent(0.5),
        selection: NSColor(hex: "#44475a"),
        keywords: .init(color: NSColor(hex: "#ff79c6")),
        commands: .init(color: NSColor(hex: "#8be9fd")),
        types: .init(color: NSColor(hex: "#8be9fd")),
        attributes: .init(color: NSColor(hex: "#50fa7b")),
        variables: .init(color: .white),
        values: .init(color: NSColor(hex: "#f1fa8c")),
        numbers: .init(color: NSColor(hex: "#bd93f9")),
        strings: .init(color: NSColor(hex: "#f1fa8c")),
        characters: .init(color: NSColor(hex: "#f1fa8c")),
        comments: .init(color: NSColor(hex: "#6272a4"))
    )
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

// MARK: - PHASE 2 COMPLETE: GapBuffer Data Structure
/// A data structure optimized for efficient insertion and deletion of text.
/// It uses an array with a "gap" that can be moved to the cursor's position.
/// Edits within the gap are extremely fast (O(1) complexity).
struct GapBuffer {
    private var buffer: [Character]
    private var gapStart: Int
    private var gapEnd: Int
    
    /// The full text content derived from the buffer.
    var string: String {
        return String(buffer[0..<gapStart] + buffer[gapEnd..<buffer.count])
    }
    
    /// Initializes the Gap Buffer with an initial string content.
    init(string: String) {
        self.buffer = Array(string)
        self.gapStart = buffer.count
        self.gapEnd = buffer.count
    }
    
    /// Moves the gap to a specified position in the text.
    /// This is the most expensive operation, but it makes subsequent edits fast.
    mutating func moveGap(to position: Int) {
        guard position != gapStart else { return }
        
        if position < gapStart {
            let distance = gapStart - position
            let gapSize = gapEnd - gapStart
            buffer.replaceSubrange(position..<position+gapSize, with: buffer[position..<gapStart])
            gapStart = position
            gapEnd = position + gapSize
        } else {
            let distance = position - gapStart
            buffer.replaceSubrange(gapStart..<gapStart+distance, with: buffer[gapEnd..<gapEnd+distance])
            gapStart = position
            gapEnd = position + (gapEnd - gapStart)
        }
    }
    
    /// Inserts a character at the current gap position.
    mutating func insert(_ char: Character) {
        ensureGap(ofSize: 1)
        buffer[gapStart] = char
        gapStart += 1
    }
    
    /// Deletes a character from before the current gap position.
    mutating func delete() {
        if gapStart > 0 {
            gapStart -= 1
        }
    }
    
    /// Ensures the gap has at least a certain size, resizing if necessary.
    private mutating func ensureGap(ofSize size: Int) {
        if gapEnd - gapStart < size {
            let newGapSize = max(size, 64) // Ensure a minimum new gap size
            buffer.insert(contentsOf: [Character](repeating: " ", count: newGapSize), at: gapStart)
            gapEnd = gapStart + newGapSize
        }
    }
}

// MARK: - Centralized Data Model
/// The document model now uses a `GapBuffer` for its content,
/// enabling high-performance text manipulations.
class CodeDocument: ObservableObject, Equatable {
    static func == (lhs: CodeDocument, rhs: CodeDocument) -> Bool {
        // Documents are considered equal if they are the same object instance.
        return lhs === rhs
    }
    
    @Published var content: GapBuffer
    @Published var language: CodeLanguage

    init(content: String, language: String?) {
        self.content = GapBuffer(string: content)
        self.language = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == language?.lowercased()
        } ?? .default
    }
}


// MARK: - CodeViewerPanelView (Main SwiftUI View)
struct CodeViewerPanelView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @State private var isHoveringOnDivider = false
    @AppStorage("codeEditFontSize") var fontSize: Double = 14
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600

    @State private var document: CodeDocument?

    var body: some View {
        HStack(spacing: 0) {
            resizableDivider
            panelContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .transition(.move(edge: .trailing))
        .shadow(radius: 10)
        .onReceive(viewModel.$codeViewerContent) { newContent in
            if let content = newContent {
                if document?.content.string != content.code {
                     document = CodeDocument(content: content.code, language: content.language)
                }
            } else {
                document = nil
            }
        }
    }
    
    private var resizableDivider: some View {
        Divider()
            .frame(width: 4)
            .background(isHoveringOnDivider ? Color.blue.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { value in
                    let currentWidth = CGFloat(self.panelWidth)
                    let newWidth = currentWidth - value.translation.width
                    self.panelWidth = Double(min(max(newWidth, 400), 1200))
                }
            )
            .onHover { hovering in
                isHoveringOnDivider = hovering
                if hovering { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
    }
    
    private var panelContent: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            
            if let document = document {
                HighPerformanceCodeViewRepresentable(
                    document: document,
                    fontSize: fontSize
                )
                .id(document.id)
            } else {
                placeholderContent
            }
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: NSColor(hex: "#282a36")))
    }
    
    private var panelHeader: some View {
        HStack {
            Text(document?.language.id.rawValue.capitalized ?? "Code Viewer")
                .font(.headline)
                .padding(.leading)
            
            Spacer()
            
            Button(action: viewModel.hideCodeViewer) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .padding(.trailing)
        }
        .frame(height: 44)
        .background(Color.clear)
    }
    
    private var placeholderContent: some View {
        VStack {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))
                .padding(.bottom)
            Text("No Content")
                .font(.title2)
                .foregroundColor(.gray)
            Text("Select a code block to view it here.")
                .foregroundColor(.gray.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension CodeDocument: Identifiable {}


// MARK: - High-Performance NSViewControllerRepresentable
private struct HighPerformanceCodeViewRepresentable: NSViewControllerRepresentable {
    @ObservedObject var document: CodeDocument
    var fontSize: Double

    func makeNSViewController(context: Context) -> HighPerformanceCodeViewController {
        return HighPerformanceCodeViewController(document: document)
    }

    func updateNSViewController(_ nsViewController: HighPerformanceCodeViewController, context: Context) {
        nsViewController.update(document: document, fontSize: fontSize)
    }
}

// MARK: - High-Performance NSViewController
class HighPerformanceCodeViewController: NSViewController {
    
    private var document: CodeDocument
    private var cancellables = Set<AnyCancellable>()

    private var hostingController: NSHostingController<SourceEditor>?
    private var currentFontSize: Double = 14

    init(document: CodeDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // --- START: SIMPLIFICATION FIX ---
        // The entire view setup is now handled by a single method that
        // creates the SourceEditor with a direct binding to the data model.
        setupEditorView()
        // --- END: SIMPLIFICATION FIX ---
    }

    // --- START: SIMPLIFICATION FIX ---
    // This new method creates the SourceEditor and its hosting controller.
    // It's called once from viewDidLoad.
    private func setupEditorView() {
        // Create a two-way binding to the document's content.
        // This allows the SourceEditor to directly read and write to our model.
        let contentBinding = Binding<String>(
            get: { self.document.content.string },
            set: { newString in
                // When the user types in the editor, this setter is called.
                // We update our GapBuffer-based model with the new content.
                if self.document.content.string != newString {
                    self.document.content = GapBuffer(string: newString)
                }
            }
        )

        let editorView = SourceEditor(
            contentBinding, // Use the two-way binding here.
            language: document.language,
            configuration: .init(
                appearance: .init(
                    theme: .defaultDark,
                    font: .monospacedSystemFont(ofSize: currentFontSize, weight: .regular),
                    lineHeightMultiple: 1.2,
                    wrapLines: true
                ),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            state: .constant(.init())
        )
        
        let hosting = NSHostingController(rootView: editorView)
        self.hostingController = hosting
        
        // Add the hosting controller as a child and its view to our view hierarchy.
        // This is now the ONLY subview, eliminating all overlay and event conflicts.
        addChild(hosting)
        view.addSubview(hosting.view)
        
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    // This method now only updates the existing SourceEditor's properties
    // by replacing the rootView of the hosting controller.
    private func updatePresentationView() {
        let font = NSFont.monospacedSystemFont(ofSize: self.currentFontSize, weight: .regular)
        
        // Recreate the binding to ensure it captures the current document state.
        let contentBinding = Binding<String>(
            get: { self.document.content.string },
            set: { newString in
                if self.document.content.string != newString {
                    self.document.content = GapBuffer(string: newString)
                }
            }
        )
        
        let newEditorView = SourceEditor(
            contentBinding,
            language: self.document.language,
            configuration: .init(
                appearance: .init(
                    theme: .defaultDark,
                    font: font,
                    lineHeightMultiple: 1.2,
                    wrapLines: true
                ),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            state: .constant(.init())
        )
        // Update the root view of the existing hosting controller.
        // This is more efficient than recreating the controller itself.
        hostingController?.rootView = newEditorView
    }

    /// Entry point for updates from the SwiftUI Representable.
    func update(document: CodeDocument, fontSize: Double) {
        var needsViewUpdate = false
        
        if self.document != document {
            self.document = document
            needsViewUpdate = true
        }
        
        if self.currentFontSize != fontSize {
            self.currentFontSize = fontSize
            needsViewUpdate = true
        }
        
        if needsViewUpdate {
            updatePresentationView()
        }
    }
    // --- END: SIMPLIFICATION FIX ---
}
