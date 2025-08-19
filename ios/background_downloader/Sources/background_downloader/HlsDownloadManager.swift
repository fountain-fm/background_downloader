// HlsDownloadManager.swift
import AVFoundation

final class HlsDownloadManager: NSObject {
    static let shared = HlsDownloadManager()

    // MARK: - Session
    private let sessionId: String = {
        let _bundle = Bundle.main.bundleIdentifier ?? "com.bbflight.background_downloader"
        return _bundle + ".hls.avasset"
    }()

    private var _task_cache_native_id = [Int: Task]() // AVAssetDownloadTask.taskIdentifier -> Task
    private let _lock = NSLock()
    
    private lazy var _config: URLSessionConfiguration = {
        let _config = URLSessionConfiguration.background(withIdentifier: sessionId)
        _config.sessionSendsLaunchEvents = true
        _config.isDiscretionary = false
        _config.shouldUseExtendedBackgroundIdleMode = true
        return _config
    }()
    
    private lazy var _session: AVAssetDownloadURLSession = {
        return AVAssetDownloadURLSession(configuration: _config,
                                            assetDownloadDelegate: self,
                                            delegateQueue: .main)
    }()

    /// `start` - Start an HLS background download. Prefer passing a variantUrl for exact quality.
    func start(task: Task, bitrateHint: Int? = nil) -> Bool {
        let urlString = task.url

        guard let url = URL(string: urlString) else { return false }

        let asset = AVURLAsset(url: url)
        var options: [String: Any] = [:]
        if let hint = bitrateHint {
            options[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = hint
        }

        guard let dl = _session.makeAssetDownloadTask(
            asset: asset,
            assetTitle: task.filename,
            assetArtworkData: nil,
            options: options
        ) else { return false }

        _lock.lock(); _task_cache_native_id[dl.taskIdentifier] = task; _lock.unlock()

        dl.priority = 1 - Float(task.priority) / 10
        dl.resume()
        return true
    }

    /// `task` - returns optiona task from memory cache
    private func task(for nativeId: Int) -> Task? {
        _lock.lock()
        defer { _lock.unlock() }
        return _task_cache_native_id[nativeId]
    }
}

extension HlsDownloadManager: AVAssetDownloadDelegate {
    func urlSession(_: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didLoad _: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange)
    {
        let _loaded = loadedTimeRanges
            .map { $0.timeRangeValue }
            .reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        let _total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        let _progress = max(0.0, min(1.0, _total > 0 ? _loaded / _total : 0.0))

        _lock.lock()
        let _task = _task_cache_native_id[assetDownloadTask.taskIdentifier]
        _lock.unlock()
        guard let _task else { return }

        processProgressUpdate(task: _task, progress: _progress)
        if _progress < 1.0 { processStatusUpdate(task: _task, status: .running) }
    }

    func urlSession(_: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?)
    {
        _lock.lock()
        let _bd_task = _task_cache_native_id.removeValue(forKey: task.taskIdentifier)
        _lock.unlock()
        guard let _bd_task else { return }
        if let _err = error {
            let _ex = TaskException(type: .httpResponse, description: _err.localizedDescription)
            processStatusUpdate(task: _bd_task, status: .failed, taskException: _ex, responseBody: nil)
        } else {
            processProgressUpdate(task: _bd_task, progress: 0.0)
            processStatusUpdate(task: _bd_task, status: .complete)
        }
    }

    func urlSession(_: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        // get original task from cache
        guard let _bd_task = HlsDownloadManager.shared.task(for: assetDownloadTask.taskIdentifier) else {
            print("No Task for HLS completion")
            return
        }

        let _sub_dir = _bd_task.directory.isEmpty ? "" : _bd_task.directory
        // Move file
        do {
            try _moveFile(from: location, to: _sub_dir)
        } catch {
            let _err = error
            let _ex = TaskException(type: .httpResponse, description: _err.localizedDescription)
            processStatusUpdate(task: _bd_task, status: .failed, taskException: _ex, responseBody: nil)
        }
    }

    /// `_moveFile`
    private func _moveFile(from: URL, to: String) throws {
        let _manager = FileManager.default
        guard let _docs = _manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let _dest_dir = _docs.appendingPathComponent(to, isDirectory: true)
        let _dest_url = _dest_dir.appendingPathComponent(from.lastPathComponent, isDirectory: true)
  
        // Ensure destination directory exists
        try _manager.createDirectory(at: _dest_dir, withIntermediateDirectories: true)
        // If an older copy exists, remove it
        if _manager.fileExists(atPath: _dest_url.path) { try _manager.removeItem(at: _dest_url) }
        // Copy the entire .movpkg directory
        try _manager.copyItem(at: from, to: _dest_url)
        // Exclude from iCloud backup
        var _values = URLResourceValues()
        _values.isExcludedFromBackup = true
        var _mutable_dest_url = _dest_url
        try _mutable_dest_url.setResourceValues(_values)
        // Remove original system-managed copy
        try _manager.removeItem(at: from)
    }
}
