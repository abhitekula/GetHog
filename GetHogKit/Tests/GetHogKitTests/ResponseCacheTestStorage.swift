import Foundation

@testable import GetHogKit

final class ResponseCacheTestStorage: ResponseCacheStorage, @unchecked Sendable {
    enum Failure: Error {
        case syntheticRead
        case syntheticWrite
        case syntheticRemoval
        case syntheticListing
    }

    private struct StoredFile {
        let data: Data
        let modifiedAt: Date
    }

    private let lock = NSLock()
    private var files: [URL: StoredFile] = [:]
    private var blockedRemovalNames: Set<String> = []
    private var dataWritesFail = false
    private var markerWritesFail = false
    private var listingsFail = false

    func createDirectory(at url: URL) throws {}

    func read(from url: URL) throws -> Data {
        try lock.withLock {
            guard let file = files[url] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return file.data
        }
    }

    func write(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if dataWritesFail, ResponseCache.isDataFilename(url.lastPathComponent) {
                throw Failure.syntheticWrite
            }
            if markerWritesFail, !ResponseCache.isDataFilename(url.lastPathComponent) {
                throw Failure.syntheticWrite
            }
            files[url] = StoredFile(data: data, modifiedAt: Date())
        }
    }

    func contents(of directory: URL) throws -> [ResponseCacheStoredFile] {
        try lock.withLock {
            if listingsFail { throw Failure.syntheticListing }
            return files.map { url, file in
                ResponseCacheStoredFile(
                    url: url,
                    size: file.data.count,
                    modifiedAt: file.modifiedAt
                )
            }
        }
    }

    func remove(_ url: URL) throws {
        try lock.withLock {
            if blockedRemovalNames.contains(url.lastPathComponent) {
                throw Failure.syntheticRemoval
            }
            files.removeValue(forKey: url)
        }
    }

    func seed(_ data: Data, named name: String, in directory: URL) {
        lock.withLock {
            files[directory.appendingPathComponent(name)] = StoredFile(
                data: data,
                modifiedAt: Date()
            )
        }
    }

    func blockRemoval(named name: String) {
        _ = lock.withLock { blockedRemovalNames.insert(name) }
    }

    func unblockRemoval(named name: String) {
        _ = lock.withLock { blockedRemovalNames.remove(name) }
    }

    func setDataWritesFail(_ fail: Bool) {
        lock.withLock { dataWritesFail = fail }
    }

    func setMarkerWritesFail(_ fail: Bool) {
        lock.withLock { markerWritesFail = fail }
    }

    func setListingsFail(_ fail: Bool) {
        lock.withLock { listingsFail = fail }
    }

    func names() -> Set<String> {
        lock.withLock { Set(files.keys.map(\.lastPathComponent)) }
    }
}
