// FileSystemMonitor.swift

import Foundation
import CoreServices
import os

// The C-style callback function that FSEvents will call.
// It must be a global function or a static method that does not capture any context.
// It receives a pointer to the FileSystemMonitor instance via `clientCallBackInfo`
// and calls an instance method on it to handle the logic.
private func fsEventsCallback(
    stream: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    // Retrieve the FileSystemMonitor instance from the context info.
    guard let clientCallBackInfo = clientCallBackInfo else { return }
    let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    
    // Call an instance method on the monitor to handle the event.
    // This avoids capturing context in the C callback itself.
    monitor.handleEvents()
}


class FileSystemMonitor {
    private var stream: FSEventStreamRef?
    private let callback: (URL) -> Void // A callback that passes the root URL back.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "FileSystemMonitor")
    
    // Store the URL being monitored to pass to the callback.
    private var monitoringURL: URL?

    init(callback: @escaping (URL) -> Void) {
        self.callback = callback
    }

    func start(path: String) {
        // Ensure any existing stream is stopped before starting a new one.
        stop()
        
        self.monitoringURL = URL(fileURLWithPath: path)
        
        // The context passes a pointer to `self` (the FileSystemMonitor instance)
        // to the C callback function.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let pathsToWatch = [path] as CFArray
        
        stream = FSEventStreamCreate(
            nil,
            fsEventsCallback, // Pass the global C function as the callback.
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
            if FSEventStreamStart(stream) {
                logger.info("FSEventStream started successfully for path: \(path)")
            } else {
                logger.error("Failed to start FSEventStream for path: \(path)")
                // Clean up if starting fails.
                self.stream = nil
            }
        }
    }
    
    /// This instance method is called by the global `fsEventsCallback` function.
    fileprivate func handleEvents() {
        guard let url = monitoringURL else {
            logger.warning("handleEvents called but monitoringURL is nil.")
            return
        }
        // Execute the callback with the root URL.
        callback(url)
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        logger.info("FSEventStream stopped.")
    }

    deinit {
        stop()
    }
}
