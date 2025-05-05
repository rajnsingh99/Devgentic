// Services/GlobalShortcutService.swift
import Foundation
import Carbon // For Low-Level HotKey APIs (RegisterEventHotKey, etc.)
import Cocoa  // For NSEvent constants like optionKey and key codes like kVK_Space

// MARK: - Shortcut Handler Protocol

// Defines the requirement for an object that can react when the global shortcut is pressed.
// The OverlayWindowManager will conform to this.
protocol GlobalShortcutHandler: AnyObject {
    func handleShortcutActivation()
}

// MARK: - Global Shortcut Service

class GlobalShortcutService {

    // MARK: Properties

    // A weak reference to the object that will handle the shortcut activation.
    // Weak is important to prevent retain cycles if the handler also holds a reference to this service.
    private weak var handler: GlobalShortcutHandler?

    // A reference to the registered hotkey provided by the Carbon Event Manager.
    // This is needed to unregister the hotkey later.
    private var hotKeyRef: EventHotKeyRef?

    // A unique identifier for our hotkey within this application.
    // 'dvtc' is a FourCharCode representation (e.g., derived from "Devgentic").
    // The id (1) distinguishes it if you were to register multiple hotkeys.
    private let hotKeyId: EventHotKeyID

    // Define the desired shortcut combination.
    // You can find key codes using apps like "Key Codes" on the Mac App Store or online resources.
    // kVK_Space corresponds to the Space bar key (key code 49).
    private let keyCode: UInt32 = UInt32(kVK_Space)
    // optionKey corresponds to the Option/Alt key modifier.
    // Other common modifiers include cmdKey, controlKey, shiftKey.
    private let modifiers: UInt32 = UInt32(optionKey)

    // MARK: Initialization

    init(handler: GlobalShortcutHandler) {
        self.handler = handler
        // Create the unique ID using a FourCharCode signature and an integer ID.
        // It's good practice to use a signature related to your app bundle ID or name.
        self.hotKeyId = EventHotKeyID(signature: FourCharCode("dvtc".utf16.first!), id: 1)

        // Set up the low-level event handler immediately upon initialization.
        setupEventHandler()
        print("GlobalShortcutService initialized.")
    }

    // MARK: Lifecycle

    // Ensure the hotkey is unregistered if the service instance is deallocated.
    deinit {
        print("GlobalShortcutService deinit. Unregistering hotkey.")
        unregister()
    }

    // MARK: Public Methods

    /// Registers the system-wide hotkey.
    func register() {
        // Prevent double registration.
        guard hotKeyRef == nil else {
            print("Hotkey already registered.")
            return
        }

        // Define the type of event we are interested in: a key press event for a hotkey.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))

        // Attempt to register the hotkey with the system.
        // - keyCode: The virtual key code of the key (e.g., Space bar).
        // - modifiers: The modifier keys required (e.g., Option).
        // - hotKeyId: Our unique identifier for this hotkey.
        // - GetApplicationEventTarget(): The target for the event (our application).
        // - 0: Options (usually 0).
        // - &hotKeyRef: A pointer to store the reference to the registered hotkey.
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &hotKeyRef)

        // Check if registration was successful.
        if status != noErr {
            print("Error registering hotkey: \(status) - Code: \(keyCode), Modifiers: \(modifiers)")
            // Ensure the reference is nil if registration failed.
            hotKeyRef = nil
        } else {
            print("Hotkey registered successfully (KeyCode: \(keyCode), Modifiers: \(modifiers))")
        }
    }

    /// Unregisters the system-wide hotkey.
    func unregister() {
        // Only proceed if we have a valid hotkey reference.
        guard let ref = hotKeyRef else { return }

        // Tell the system to stop listening for this hotkey.
        UnregisterEventHotKey(ref)

        // Clear the reference now that it's invalid.
        hotKeyRef = nil
        print("Hotkey unregistered.")
    }

    // MARK: Private Methods

    /// Sets up the Carbon Event Handler to listen for our specific hotkey press event.
    private func setupEventHandler() {
        // Define the event type we want to handle (same as registration).
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))

        // Install an event handler on the application's event target.
        // This handler will be called whenever *any* hotkey event occurs system-wide.
        // We need to check inside the handler if it's *our* specific hotkey.
        InstallEventHandler(GetApplicationEventTarget(), {
            // --- This is the C-style callback function ---
            (nextHandler, event, userData) -> OSStatus in // OSStatus is Int32

            // 1. Extract the HotKeyID from the incoming event data.
            var pressedHotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, // The event reference
                UInt32(kEventParamDirectObject), // Parameter name: the direct object (the HotKeyID)
                UInt32(typeEventHotKeyID),       // Parameter type: expecting a HotKeyID
                nil,                             // Desired type (usually nil)
                MemoryLayout<EventHotKeyID>.size,// Size of the data to retrieve
                nil,                             // Actual type (usually nil)
                &pressedHotKeyID                 // Pointer to store the retrieved HotKeyID
            )

            // Check if we successfully got the HotKeyID.
            guard status == noErr else {
                print("Error getting hotkey ID from event: \(status)")
                // Return the error status, explicitly cast for clarity.
                return OSStatus(status)
            }

            // 2. Safely retrieve the reference to our `GlobalShortcutService` instance.
            // `userData` holds the pointer we passed during `InstallEventHandler`.
            guard let userData = userData else {
                print("Error: UserData is nil in event handler callback.")
                // Return parameter error status, explicitly cast for clarity.
                return OSStatus(paramErr) // FIX: Explicitly cast to OSStatus
            }
            // Convert the opaque pointer back to an unmanaged reference, then get the Swift object instance.
            // `takeUnretainedValue` is used because we passed `self` as unretained.
            let unsafeSelf = Unmanaged<GlobalShortcutService>.fromOpaque(userData).takeUnretainedValue()

            // 3. Compare the pressed hotkey's ID with our registered hotkey's ID.
            if pressedHotKeyID.signature == unsafeSelf.hotKeyId.signature && pressedHotKeyID.id == unsafeSelf.hotKeyId.id {
                // --- It's our hotkey! ---
                // Call the handler's method (e.g., toggle the overlay window).
                // IMPORTANT: Dispatch to the main thread for any UI updates.
                DispatchQueue.main.async {
                    unsafeSelf.handler?.handleShortcutActivation()
                }
                // Return noErr to indicate we handled the event. Explicitly cast for clarity.
                return OSStatus(noErr) // FIX: Explicitly cast to OSStatus
            } else {
                // --- It's not our hotkey ---
                // Pass the event to the next handler in the chain (if any).
                // Return eventNotHandledErr. Explicitly cast for clarity.
                return OSStatus(eventNotHandledErr) // FIX: Explicitly cast to OSStatus
            }
            // --- End of C-style callback function ---

        }, 1, &eventType, // Number of event types and the list of types
           Unmanaged.passUnretained(self).toOpaque(), // Pass a pointer to self as user data
           nil) // Handler reference (usually nil for application target)
    }
}

// MARK: - Helper Function (Optional)

/// Converts a FourCharCode (UInt32) to a human-readable String. Useful for debugging signatures.
/// Example: fourCharCodeToString(FourCharCode("abcd".utf16.first!)) -> "abcd"
func fourCharCodeToString(_ code: FourCharCode) -> String {
    let bytes: [CChar] = [
        CChar((code >> 24) & 0xFF), // Extract byte 1 (most significant)
        CChar((code >> 16) & 0xFF), // Extract byte 2
        CChar((code >> 8) & 0xFF),  // Extract byte 3
        CChar(code & 0xFF),         // Extract byte 4 (least significant)
        0                           // Null terminator for C string
    ]
    // Create a Swift String from the C character array.
    return String(cString: bytes)
}
