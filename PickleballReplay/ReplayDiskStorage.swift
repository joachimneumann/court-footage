import CoreMedia
import Foundation

// The replay buffer serializes writes. The buffer and any pending exports share
// references to each temporary file, so eviction cannot remove media during a save.
final class ReplayDiskStorage {
    private static let directory = FileManager.default.temporaryDirectory
        .appending(path: "CourtFootageBuffer", directoryHint: .isDirectory)
    private static let chunkSize = 16 * 1_024 * 1_024
    private var currentChunk: OpenChunk?

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    func store(_ payload: CMBlockBuffer, byteCount: Int) throws -> Location {
        if let currentChunk, byteCount <= Self.chunkSize - currentChunk.offset {
            return try currentChunk.append(payload, byteCount: byteCount)
        }

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appending(path: UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = Chunk(url: url)
        let chunk = try OpenChunk(file: file)
        currentChunk = chunk
        return try chunk.append(payload, byteCount: byteCount)
    }

    struct Location: Sendable {
        fileprivate let file: Chunk
        fileprivate let offset: UInt64
        fileprivate let byteCount: Int
    }

    fileprivate final class Chunk: Sendable {
        let url: URL

        init(url: URL) { self.url = url }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private final class OpenChunk {
        private let file: Chunk
        private let handle: FileHandle
        private(set) var offset = 0

        init(file: Chunk) throws {
            self.file = file
            handle = try FileHandle(forWritingTo: file.url)
        }

        func append(_ payload: CMBlockBuffer, byteCount: Int) throws -> Location {
            var bytes = Data(count: byteCount)
            let status = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(payload, atOffset: 0, dataLength: byteCount,
                                           destination: destination.baseAddress!)
            }
            guard status == noErr else { throw CocoaError(.fileReadUnknown) }
            try handle.write(contentsOf: bytes)
            let location = Location(file: file, offset: UInt64(offset), byteCount: byteCount)
            offset += byteCount
            return location
        }
    }

    final class Reader {
        private var file: Chunk?
        private var handle: FileHandle?

        func read(_ location: Location) throws -> CMBlockBuffer {
            let handle: FileHandle
            if file === location.file, let currentHandle = self.handle {
                handle = currentHandle
            } else {
                handle = try FileHandle(forReadingFrom: location.file.url)
                self.handle = handle
                file = location.file
            }

            try handle.seek(toOffset: location.offset)
            guard let bytes = try handle.read(upToCount: location.byteCount),
                  bytes.count == location.byteCount else { throw CocoaError(.fileReadUnknown) }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block
            ) == noErr, let block else { throw CocoaError(.fileReadUnknown) }
            let status = bytes.withUnsafeBytes { source in
                CMBlockBufferReplaceDataBytes(with: source.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: bytes.count)
            }
            guard status == noErr else { throw CocoaError(.fileReadUnknown) }
            return block
        }
    }
}
