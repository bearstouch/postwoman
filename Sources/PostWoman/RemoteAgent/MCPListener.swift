import Darwin
import Foundation

enum MCPListenerError: Error, Equatable, Sendable {
    case invalidAddress
    case addressInUse
    case addressUnavailable
    case permissionDenied
    case io(Int32)

    /// Shown in Settings → Remote Agent.
    func message(port: UInt16) -> String {
        switch self {
        case .invalidAddress: "The interface address is not a valid IP address."
        case .addressInUse: "Port \(port) is already in use. Choose another port."
        case .addressUnavailable: "This interface address is no longer available on this Mac."
        case .permissionDenied: "macOS did not allow listening on this address and port."
        case .io(let code): "The server could not start (error \(code))."
        }
    }
}

/// TCP listener for the MCP endpoint. One thread per connection;
/// requests on a connection are answered strictly in order.
/// Bounded: 16 connections, 16 KiB headers, 1 MiB bodies, and a 30 s limit
/// for an idle connection or a request that is still arriving.
final class MCPListener: @unchecked Sendable {
    typealias Responder = @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse
    static let maximumConnections = 16
    static let timeout: TimeInterval = 30
    private let responder: Responder
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// Write end of the accept loop's wake pipe; the loop owns and closes the listening socket.
    private var wakeFD: Int32 = -1
    private var acceptExited: DispatchSemaphore?
    private var clients = Set<Int32>()

    init(responder: @escaping Responder) { self.responder = responder }

    /// Binds and starts accepting. Returns the bound port (useful with port 0 in tests).
    @discardableResult
    func start(address: String, port: UInt16) throws(MCPListenerError) -> UInt16 {
        guard let literal = IPAddressLiteral(address) else { throw .invalidAddress }
        let family: Int32
        switch literal {
        case .v4: family = AF_INET
        case .v6: family = AF_INET6
        }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .io(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let bound: Int32
        switch literal {
        case .v4(let raw):
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            sin.sin_addr = in_addr(s_addr: raw)
            bound = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        case .v6(let bytes):
            // "::" means IPv6 only; IPv4 clients use 0.0.0.0.
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: bytes) }
            bound = withUnsafePointer(to: &sin6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let failure = errno
            close(fd)
            switch failure {
            case EADDRINUSE: throw .addressInUse
            case EADDRNOTAVAIL: throw .addressUnavailable
            case EACCES, EPERM: throw .permissionDenied
            default: throw .io(failure)
            }
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let actual = withUnsafeMutablePointer(to: &storage) { pointer -> UInt16 in
            guard pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, { getsockname(fd, $0, &length) }) == 0 else { return port }
            return family == AF_INET
                ? pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
                : pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
        }
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else {
            let failure = errno
            close(fd)
            throw .io(failure)
        }
        for end in wake { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let exited = DispatchSemaphore(value: 0)
        lock.withLock {
            listenFD = fd; wakeFD = wake[1]; acceptExited = exited
        }
        let wakeRead = wake[0]
        let thread = Thread { [weak self] in
            self?.acceptLoop(fd, wake: wakeRead)
            close(fd); close(wakeRead)
            exited.signal()
        }
        thread.name = "PostWoman MCP accept"
        thread.start()
        return actual
    }

    /// Returns once the listening socket is closed, so the port can be bound again at once.
    func stop() {
        // Shut clients down under the lock so a reused fd is never hit.
        let (wake, exited) = lock.withLock { () -> (Int32, DispatchSemaphore?) in
            defer { listenFD = -1; wakeFD = -1; acceptExited = nil }
            for client in clients { shutdown(client, SHUT_RDWR) }
            return (wakeFD, acceptExited)
        }
        guard wake >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wake, &byte, 1)
        close(wake)
        exited?.wait()
    }

    var isRunning: Bool { lock.withLock { listenFD >= 0 } }
    var connectionCount: Int { lock.withLock { clients.count } }

    /// Polls the socket and the wake pipe, so stop() never races a blocked accept on a reused fd.
    private func acceptLoop(_ fd: Int32, wake: Int32) {
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                let failure = errno
                if failure == EINTR || failure == ECONNABORTED || failure == EAGAIN || failure == EWOULDBLOCK { continue }
                // Out of descriptors or buffers is transient; back off instead of silently ending the listener.
                if failure == EMFILE || failure == ENFILE || failure == ENOBUFS || failure == ENOMEM {
                    usleep(100_000)
                    continue
                }
                return
            }
            // Accepted sockets inherit O_NONBLOCK on Darwin; connection threads use blocking I/O with timeouts.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // Short receive timeouts let the loop enforce whole-request deadlines (slow senders).
            var tick = timeval(tv_sec: 1, tv_usec: 0), send = timeval(tv_sec: Int(Self.timeout), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tick, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
            let admitted = lock.withLock { () -> Bool in
                guard listenFD == fd, clients.count < Self.maximumConnections else { return false }
                clients.insert(client)
                return true
            }
            guard admitted else {
                // Over capacity: a best-effort 503 instead of a silent reset.
                _ = Self.write(MCPHTTPResponse.empty(503, headers: [("Retry-After", "1")]).serialized(keepAlive: false), to: client)
                close(client)
                continue
            }
            // Strong: an admitted fd must always reach serve(), which is the only place it is closed.
            let thread = Thread { self.serve(client) }
            thread.name = "PostWoman MCP connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var parser = MCPHTTPRequestParser()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // Only a completed request extends the deadline, so an idle or trickling client cannot hold a slot.
        var deadline = Date().addingTimeInterval(Self.timeout)
        connection: while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK, Date() < deadline else {
                    if parser.hasPartialRequest { _ = Self.write(MCPHTTPResponse.empty(408).serialized(keepAlive: false), to: fd) }
                    break
                }
                continue
            }
            guard count > 0, Date() < deadline else { break }
            let requests: [MCPHTTPRequest]
            do {
                requests = try parser.append(Data(buffer.prefix(count)))
            } catch {
                _ = Self.write(MCPHTTPResponse.empty(error.status).serialized(keepAlive: false), to: fd)
                break
            }
            for request in requests {
                let response = Self.wait { [responder] in await responder(request) }
                guard Self.write(response.serialized(keepAlive: request.keepAlive), to: fd), request.keepAlive else { break connection }
                deadline = Date().addingTimeInterval(Self.timeout)
            }
        }
        lock.withLock { _ = clients.remove(fd) }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Bridges a connection thread to async work; never called on the main thread.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
