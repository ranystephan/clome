import Foundation

/// Watches files and directories for changes using FSEvents.
/// Used to detect when an AI agent modifies files externally.
class FileWatcher {
    typealias ChangeHandler = @Sendable (_ paths: [String]) -> Void

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let handler: ChangeHandler
    private let latency: CFTimeInterval

    init(paths: [String], latency: CFTimeInterval = 0.3, handler: @escaping ChangeHandler) {
        self.paths = paths
        self.handler = handler
        self.latency = latency
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let cfPaths = paths as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
                let changedPaths = Array(paths.prefix(numEvents))
                let handler = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().handler
                DispatchQueue.main.async { @Sendable in
                    handler(changedPaths)
                }
            },
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(flags)
        )

        guard let stream else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

/// Watches a single file for modifications.
/// Notifies when the file is written to by an external process.
class SingleFileWatcher {
    typealias ChangeHandler = () -> Void

    private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let handler: ChangeHandler

    init(path: String, handler: @escaping ChangeHandler) {
        self.path = path
        self.handler = handler
    }

    func start() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handler()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
