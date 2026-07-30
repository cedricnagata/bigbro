import Foundation

/// Deletes download scratch files a previous run left behind.
///
/// `URLSession` streams every download into `tmp` before it is anything else; the Hugging Face
/// client then copies the finished file into its blob store and deletes the scratch copy. A
/// process that dies mid-download — a crash, Stop in Xcode, a quit during a 12 GB pull — never
/// reaches that cleanup, so the partial file is stranded at whatever size it had reached.
///
/// They accumulate invisibly and at model scale: a handful of interrupted pulls is tens of
/// gigabytes, none of it reachable or attributable from anywhere in the app. Nothing else
/// reclaims them either — macOS only purges a sandboxed container's `tmp` under real disk
/// pressure, which is long after the disk was wanted.
enum TemporaryFileCleaner {

    /// `URLSession`'s scratch-file prefix.
    ///
    /// Deliberately narrow. `tmp` is shared with anything else wanting scratch space, so only
    /// files whose provenance is unambiguous are touched — a sweep of everything would be a
    /// sweep of things this type knows nothing about.
    private static let downloadPrefix = "CFNetworkDownload_"

    /// How long a file must have gone untouched to count as abandoned rather than live.
    ///
    /// This is what keeps the sweep from deleting a file out from under a download that is
    /// still running, which is possible despite this running at launch: a Debug build and an
    /// installed build share one container, so one can start while the other is mid-pull. A
    /// download in flight has its modification date bumped continuously, so anything this stale
    /// belongs to a process that is no longer writing.
    private static let staleAfter: TimeInterval = 10 * 60

    /// Removes abandoned scratch files, returning the bytes reclaimed.
    ///
    /// Best-effort throughout: a file that cannot be removed is logged and skipped rather than
    /// failing the sweep, since this is housekeeping and must never be the reason a launch
    /// fails.
    @discardableResult
    static func removeStaleDownloads(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let cutoff = Date().addingTimeInterval(-staleAfter)
        var reclaimed: Int64 = 0
        var removed = 0

        for url in entries where url.lastPathComponent.hasPrefix(downloadPrefix) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // No modification date means no way to tell live from abandoned, so leave it.
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }

            let size = Int64(values?.fileSize ?? 0)
            do {
                try fileManager.removeItem(at: url)
                reclaimed += size
                removed += 1
            } catch {
                print("[TemporaryFileCleaner] could not remove \(url.lastPathComponent): \(error)")
            }
        }

        if removed > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
            print("[TemporaryFileCleaner] removed \(removed) abandoned download(s), reclaimed \(formatted)")
        }
        return reclaimed
    }
}
