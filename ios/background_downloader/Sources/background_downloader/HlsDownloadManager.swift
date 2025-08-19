// HlsDownloadManager.swift
import AVFoundation

final class HlsDownloadManager: NSObject {
    static let shared = HlsDownloadManager()

    // MARK: - Session

    private static let sessionId: String = {
        let bundle = Bundle.main.bundleIdentifier ?? "com.bbflight.background_downloader"
        return bundle + ".hls.avasset"
    }()

    private var session: AVAssetDownloadURLSession!
    private var taskCacheByNativeID = [Int: Task]() // AVAssetDownloadTask.taskIdentifier -> Task
    private let lock = NSLock()

    override private init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.shouldUseExtendedBackgroundIdleMode = true

        session = AVAssetDownloadURLSession(configuration: cfg,
                                            assetDownloadDelegate: self,
                                            delegateQueue: .main)
    }

    /// `start` - Start an HLS background download. Prefer passing a variantUrl for exact quality.
    func start(task: Task, bitrateHint: Int? = nil) -> Bool {
        let urlString = task.url

        guard let url = URL(string: urlString) else { return false }

        let asset = AVURLAsset(url: url)
        var options: [String: Any] = [:]
        if let hint = bitrateHint {
            options[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = hint
        }

        guard let dl = session.makeAssetDownloadTask(
            asset: asset,
            assetTitle: task.filename,
            assetArtworkData: nil,
            options: options
        ) else { return false }

        lock.lock(); taskCacheByNativeID[dl.taskIdentifier] = task; lock.unlock()

        dl.priority = 1 - Float(task.priority) / 10
        dl.resume()
        return true
    }

    /// `task`
    private func task(for nativeId: Int) -> Task? {
        lock.lock(); defer { lock.unlock() }
        return taskCacheByNativeID[nativeId]
    }
}

extension HlsDownloadManager: AVAssetDownloadDelegate {
    func urlSession(_: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didLoad _: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange)
    {
        let loaded = loadedTimeRanges
            .map { $0.timeRangeValue }
            .reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        let total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        let progress = max(0.0, min(1.0, total > 0 ? loaded / total : 0.0))

        lock.lock(); let task = taskCacheByNativeID[assetDownloadTask.taskIdentifier]; lock.unlock()
        guard let task else { return }

        // Throttle: only send when progress advanced by ≥1% or every ~300ms if you like.
        processProgressUpdate(task: task, progress: progress)
        if progress < 1.0 {
            processStatusUpdate(task: task, status: .running)
        }
    }

    func urlSession(_: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?)
    {
        lock.lock(); let bdTask = taskCacheByNativeID.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let bdTask else { return }

        if let e = error {
            //      let ex = TaskException(reason: e.localizedDescription,
            //                             1,
            //                             url: bdTask.url,
            //                             userMessage: e.localizedDescription)
            //      processStatusUpdate(task: bdTask, status: .failed, taskException: ex, responseBody: nil)
        } else {
            //      processProgressUpdate(taskId: bdTask, progress: 1.0)
            processStatusUpdate(task: bdTask, status: .complete)
        }
    }

    func urlSession(_: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let task = HlsDownloadManager.shared.task(for: assetDownloadTask.taskIdentifier) else {
            print("No Task for HLS completion")
            return
        }

        let subdir = task.directory.isEmpty ? "" : task.directory // e.g. "video"
        do {
            try _moveFile(from: location, to: subdir)
        } catch {}
    }

    /// `_moveFile`
    private func _moveFile(from: URL, to: String) throws {
        let _manager = FileManager.default
        guard let _docs = _manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let _dest_dir = _docs.appendingPathComponent(to, isDirectory: true)
        var _dest_url = _dest_dir.appendingPathComponent(from.lastPathComponent, isDirectory: true)
        // Exclude from iCloud backup
        var _values = URLResourceValues()
        _values.isExcludedFromBackup = true
        var mutableDestURL = _dest_url
        try _dest_url.setResourceValues(_values)
        // Ensure destination directory exists
        try _manager.createDirectory(at: _dest_dir, withIntermediateDirectories: true)
        // If an older copy exists, remove it
        if _manager.fileExists(atPath: _dest_url.path) {
            try _manager.removeItem(at: _dest_url)
        }
        // Copy the entire .movpkg directory
        try _manager.copyItem(at: from, to: _dest_url)
        // Remove original system-managed copy
        try _manager.removeItem(at: from)
    }
}
