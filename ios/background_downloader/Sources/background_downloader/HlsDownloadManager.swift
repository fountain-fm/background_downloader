// HlsDownloadManager.swift
import AVFoundation

final class HlsDownloadManager: NSObject, AVAssetDownloadDelegate {

    static let shared = HlsDownloadManager.init()

  // MARK: - Session

  private static let sessionId: String = {
    let bundle = Bundle.main.bundleIdentifier ?? "com.bbflight.background_downloader"
    return bundle + ".hls.avasset"     // unique; do NOT reuse your normal URLSession id
  }()

  private var session: AVAssetDownloadURLSession!
  private var byNativeId = [Int: Task]()        // AVAssetDownloadTask.taskIdentifier -> Task
  private let lock = NSLock()

  private override init() {
    super.init()
    let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
    cfg.sessionSendsLaunchEvents = true
    cfg.isDiscretionary = false
    cfg.shouldUseExtendedBackgroundIdleMode = true

    session = AVAssetDownloadURLSession(configuration: cfg,
                                        assetDownloadDelegate: self,
                                        delegateQueue: .main)
  }

  // Call from AppDelegate to reattach on wake-up
  func handleBackgroundEvents(for identifier: String) -> Bool {
    return identifier == Self.sessionId
  }

  // MARK: - Public API

  /// Start an HLS background download. Prefer passing a variantUrl for exact quality.
  @discardableResult
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

    lock.lock(); byNativeId[dl.taskIdentifier] = task; lock.unlock()

    dl.priority = 1 - Float(task.priority) / 10
    dl.resume()
    return true
  }

  // MARK: - AVAssetDownloadDelegate

  func urlSession(_ session: URLSession,
                  assetDownloadTask: AVAssetDownloadTask,
                  didLoad timeRange: CMTimeRange,
                  totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                  timeRangeExpectedToLoad: CMTimeRange) {

    let loaded = loadedTimeRanges
      .map { $0.timeRangeValue }
      .reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
    let total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
    let progress = max(0.0, min(1.0, total > 0 ? loaded / total : 0.0))

    lock.lock(); let task = byNativeId[assetDownloadTask.taskIdentifier]; lock.unlock()
    guard let task else { return }

    // Throttle: only send when progress advanced by ≥1% or every ~300ms if you like.
      processProgressUpdate(task: task, progress: progress)
    if progress < 1.0 {
      processStatusUpdate(task: task, status: .running)
    }
  }

  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  didCompleteWithError error: Error?) {

    lock.lock(); let bdTask = byNativeId.removeValue(forKey: task.taskIdentifier); lock.unlock()
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
    
    func urlSession(_ session: AVAssetDownloadURLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
            // This is the *root folder* containing the HLS files
            let localPath = location.path
            print("Downloaded to \(localPath)")
        
    }
}
