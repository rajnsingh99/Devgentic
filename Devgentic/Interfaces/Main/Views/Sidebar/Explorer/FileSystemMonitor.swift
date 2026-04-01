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
    guard let clientCallBackInfo = clientCallBackInfo else { return }
    let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    
    // When kFSEventStreamCreateFlagUseCFTypes is used, eventPaths is a CFArrayRef
    let paths = unsafeBitCast(eventPaths, to: CFArray.self)
    var changedURLs: [URL] = []
    
    for i in 0..<numEvents {
        if let path = CFArrayGetValueAtIndex(paths, i) {
            let pathString = unsafeBitCast(path, to: CFString.self) as String
            changedURLs.append(URL(fileURLWithPath: pathString))
        }
    }
    
    monitor.handleEvents(changedURLs: changedURLs)
}


class FileSystemMonitor {
    private var stream: FSEventStreamRef?
    private let callback: @Sendable ([URL]) -> Void
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "FileSystemMonitor")

    private var monitoringURL: URL?

    init(callback: @escaping @Sendable ([URL]) -> Void) {
        self.callback = callback
    }

    func start(path: String, excludedPaths: [String] = []) {
        stop()

        self.monitoringURL = URL(fileURLWithPath: path)

        // Use passRetained to prevent dangling pointer if deinit races with a pending callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let pathsToWatch = [path] as CFArray
        
        stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        )

        if let stream = stream {
            // Apply exclusion paths if provided
            if !excludedPaths.isEmpty {
                FSEventStreamSetExclusionPaths(stream, excludedPaths as CFArray)
                logger.info("Set \(excludedPaths.count) exclusion paths for monitoring.")
            }
            
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
            if FSEventStreamStart(stream) {
                logger.info("FSEventStream started successfully for path: \(path)")
            } else {
                logger.error("Failed to start FSEventStream for path: \(path)")
                self.stream = nil
            }
        }
    }
    
    fileprivate func handleEvents(changedURLs: [URL]) {
        // Dispatch to main thread so callers can safely interact with @MainActor-isolated state
        DispatchQueue.main.async { [callback] in
            callback(changedURLs)
        }
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Balance the passRetained from start()
        Unmanaged.passUnretained(self).release()
        logger.info("FSEventStream stopped.")
    }

    deinit {
        // Only stop if stream is still active (stop() handles its own release)
        if stream != nil {
            stop()
        }
    }
}
