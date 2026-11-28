import Foundation
import os

/// A data task's per-task delegate: hands the response and each chunk of the body to an async sequence as they
/// arrive, and keeps the task's metrics. URLSession calls it on its own queue.
final class StreamingTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {
    enum Event: @unchecked Sendable {
        case response(URLResponse)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let storage = OSAllocatedUnfairLock<ResponseTiming?>(initialState: nil)

    /// Where the time went; set when the task finishes, before `events` ends.
    var timing: ResponseTiming? { storage.withLock { $0 } }

    override init() {
        (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self, throwing: Error.self, bufferingPolicy: .unbounded)
        super.init()
    }

    /// Ends `events` when the consumer stops reading (its task was cancelled), so `onTermination` can cancel the data task.
    func onTermination(_ handler: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in handler() }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let timing = ResponseTiming(metrics: metrics)
        storage.withLock { $0 = timing }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
