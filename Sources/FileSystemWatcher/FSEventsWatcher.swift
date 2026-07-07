import Foundation
#if canImport(CoreServices)
import CoreServices

/// macOS FSEvents-backed watcher. Fires per-file events via kFSEventStreamCreateFlagFileEvents.
public final class FSEventsWatcher: FileSystemWatcher, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    public init() {}

    public func start(root: URL, sink: @Sendable @escaping (FileEvent) async -> Void) async throws {
        let box = FSEventsSinkBox(sink: sink)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: { ptr -> UnsafeRawPointer? in
                guard let ptr else { return nil }
                return UnsafeRawPointer(Unmanaged<FSEventsSinkBox>.fromOpaque(ptr).retain().toOpaque())
            },
            release: { ptr in guard let ptr else { return }; Unmanaged<FSEventsSinkBox>.fromOpaque(ptr).release() },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &ctx,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        let queue = DispatchQueue(label: "alens.FSEvents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        lock.withLock { self.stream = stream }
    }

    public func stop() async {
        lock.withLock {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }
}

fileprivate final class FSEventsSinkBox: @unchecked Sendable {
    let sink: @Sendable (FileEvent) async -> Void
    init(sink: @Sendable @escaping (FileEvent) async -> Void) { self.sink = sink }
}

private let fsEventsCallback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
    guard let clientInfo else { return }
    let box = Unmanaged<FSEventsSinkBox>.fromOpaque(clientInfo).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self)
    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    for i in 0..<numEvents {
        let path = paths[i] as! String
        let f = flags[i]
        let kind: FileEvent.Kind
        if f & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { kind = .created }
        else if f & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { kind = .deleted }
        else { kind = .modified }
        let event = FileEvent(path: path, kind: kind)
        Task { await box.sink(event) }
    }
}
#endif
