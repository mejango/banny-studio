import Foundation
import BannyMedia
#if canImport(Darwin)
import Darwin
#endif

/// Creation-admission limits for one Banny Live authority.
///
/// These limits never delete recordings. Operators must archive or remove old
/// rooms deliberately when either limit is reached.
public struct LiveRoomHostLimits: Equatable, Sendable {
    public static let defaultMaximumRooms = 100
    public static let defaultMaximumStorageBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024

    public var maximumRooms: Int
    public var maximumStorageBytes: UInt64

    public init(
        maximumRooms: Int = Self.defaultMaximumRooms,
        maximumStorageBytes: UInt64 = Self.defaultMaximumStorageBytes
    ) {
        self.maximumRooms = maximumRooms
        self.maximumStorageBytes = maximumStorageBytes
    }
}

enum LiveRoomStorageAccountingError: Error, Equatable {
    case invalidRoot
    case invalidEntrySize
    case byteCountOverflow
}

struct LiveRoomStorageSnapshot: Equatable {
    let roomDirectoryNames: Set<String>
    let bytes: UInt64
}

/// Logical-byte accounting is deliberately conservative: sparse files and
/// hard links are charged by each directory entry. Symlink inode bytes count,
/// but their targets are never traversed.
enum LiveRoomStorageAccounting {
    /// Initial room creation temporarily holds the decoded uploads and their
    /// packaged copies. Animated stills can additionally produce a bounded
    /// GIF, and atomic show.json publication needs a small fixed work budget.
    private static let documentWorkingBytes: UInt64 = 4 * 1_024 * 1_024

    static func creationReservationBytes(animateStill: Bool) -> UInt64 {
        let media = UInt64(LiveRoomPackageBuilder.maximumDecodedMediaBytes)
        let shimmer = animateStill ? UInt64(ShimmerEncoder.maximumOutputBytes) : 0
        return (media * 2) + shimmer + documentWorkingBytes
    }

    static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw LiveRoomStorageAccountingError.byteCountOverflow
        }
        return sum
    }

    static func snapshot(
        at storageURL: URL,
        excludingActiveRoomIDs: Set<String>
    ) throws -> LiveRoomStorageSnapshot {
        let root = try metadata(at: storageURL)
        guard root.isDirectory, !root.isSymbolicLink else {
            throw LiveRoomStorageAccountingError.invalidRoot
        }

        var bytes: UInt64 = 0
        var roomDirectoryNames: Set<String> = []
        let topLevel = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: nil,
            options: [])
        var pending: [URL] = []

        for entry in topLevel {
            let name = entry.lastPathComponent
            if belongsToActiveCreation(name, roomIDs: excludingActiveRoomIDs) {
                continue
            }
            let item = try metadata(at: entry)
            bytes = try checkedAdd(bytes, item.size)
            if item.isDirectory && !item.isSymbolicLink {
                if !name.hasPrefix(".") {
                    roomDirectoryNames.insert(name)
                }
                pending.append(entry)
            }
        }

        while let directory = pending.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [])
            for child in children {
                let item = try metadata(at: child)
                bytes = try checkedAdd(bytes, item.size)
                if item.isDirectory && !item.isSymbolicLink {
                    pending.append(child)
                }
            }
        }
        return LiveRoomStorageSnapshot(
            roomDirectoryNames: roomDirectoryNames,
            bytes: bytes)
    }

    private static func belongsToActiveCreation(
        _ name: String,
        roomIDs: Set<String>
    ) -> Bool {
        if roomIDs.contains(name) { return true }
        guard name.first == ".", name.hasSuffix(".tmp") else { return false }
        return roomIDs.contains { roomID in
            name.hasPrefix(".\(roomID)-")
        }
    }

    private struct Metadata {
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let size: UInt64
    }

    private static func metadata(at url: URL) throws -> Metadata {
        #if canImport(Darwin)
        var info = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &info)
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        guard info.st_size >= 0, let size = UInt64(exactly: info.st_size) else {
            throw LiveRoomStorageAccountingError.invalidEntrySize
        }
        let kind = info.st_mode & mode_t(S_IFMT)
        return Metadata(
            isDirectory: kind == mode_t(S_IFDIR),
            isSymbolicLink: kind == mode_t(S_IFLNK),
            size: size)
        #else
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard let rawSize = values.fileSize, rawSize >= 0 else {
            throw LiveRoomStorageAccountingError.invalidEntrySize
        }
        return Metadata(
            isDirectory: values.isDirectory == true,
            isSymbolicLink: values.isSymbolicLink == true,
            size: UInt64(rawSize))
        #endif
    }
}
