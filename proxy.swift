import Foundation

// MARK: - Audio transcoding proxy (实验性功能, see docs/experimental/)

// Front door on the public port. Only runs while the audio-transcoding
// switch is ON (OFF = no proxy at all, the router binds the public port).
// Two jobs:
//  - "red lamp" requests (transcription uploads in a format llama.cpp
//    cannot decode) are transcoded to 16k mono WAV and re-forwarded
//  - everything else (chat SSE, model list, load/unload, health) is a
//    blind byte pipe to the router: no HTTP parsing, no buffering
//
// Implementation: BSD sockets + DispatchSource for the listener and the
// pipe (this CLT SDK's Network.framework ships no Swift NW* classes),
// URLSession for the HTTP-level transcription exchange.
final class AudioProxy {
    private let publicPort: Int
    private let routerPort: Int
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "com.penguinM.corral.proxy")
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    // Strong ownership of every live connection. Conn's read sources
    // capture Conn only weakly (no retain cycle), so this set is the
    // thing that keeps Conns — and with them their sources — alive.
    // Without it the Conn dies the moment the accept handler returns
    // and every source is silently cancelled (classic DispatchSource
    // lifetime trap).
    private var conns: Set<Conn> = []

    // dial-failure log rate limit (audit D13): with the router down for
    // a while, the 3s health poll turns one failure into ~2880 identical
    // lines/hour. Log the first failure, stay silent while it continues,
    // log one recovery line when a dial succeeds — the pair brackets the
    // outage. Only touched on the serial queue (pipeToRouter always runs
    // on it), no lock needed
    private var routerDialFailing = false

    init(publicPort: Int, routerPort: Int, log: @escaping (String) -> Void) {
        self.publicPort = publicPort
        self.routerPort = routerPort
        self.log = log
    }

    // returns error message, or nil on success
    func start() -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket() failed" }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(publicPort).bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        // NOTE: this CLT toolchain has no withMemoryRebound; go via raw pointer
        let bound = withUnsafePointer(to: &addr) {
            bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bound == 0 else {
            close(fd)
            return "bind 127.0.0.1:\(publicPort) failed (\(String(cString: strerror(errno))))"
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            return "listen() failed"
        }
        // non-blocking: acceptLoop drains with EAGAIN so the serial
        // queue can run the per-connection read work between accepts
        setNonBlocking(fd)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptLoop() }
        src.setCancelHandler { close(fd) }
        src.resume()
        listenFd = fd
        acceptSource = src
        log("[proxy] listening on 127.0.0.1:\(publicPort) -> router 127.0.0.1:\(routerPort)")
        return nil
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFd = -1
    }

    private func acceptLoop() {
        guard listenFd >= 0 else { return }
        while true {
            var peer = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = withUnsafeMutablePointer(to: &peer) {
                accept(listenFd, $0, &len)
            }
            // listen fd is non-blocking: EAGAIN = drained, let queued
            // connection work (readConn) run on this serial queue
            guard cfd >= 0 else { return }
            setNonBlocking(cfd)
            // inline, NOT queue.async: we are already on the serial
            // queue; async would enqueue behind this loop forever
            let c = Conn(cfd)
            c.owner = self
            conns.insert(c)
            readConn(c)
        }
    }

    // MARK: per-connection state

    // One persistent read source per client connection (armed in
    // readConn, never re-installed). All per-request state lives on
    // Conn; the handler is a state machine, so there is no recursive
    // closure capturing stale local state.
    // Hashable by identity: the conns set keeps one entry per live Conn
    private final class Conn: Hashable {
        let fd: Int32
        let wq = DispatchQueue(label: "com.penguinM.corral.proxy.write")
        var readSrc: DispatchSourceRead?
        var dead = false
        // inbound request state machine
        enum Mode { case headers, body(total: Int) }
        var mode: Mode = .headers
        var acc = Data()
        var req: Request?
        // set by pipeToRouter; installed by the request-read source's
        // cancel handler, which runs only after that source is fully
        // torn down (same-fd source swap must be strictly sequential)
        var pendingPump: Conn?
        weak var owner: AudioProxy?
        init(_ fd: Int32) { self.fd = fd }
        // The conns set is the only strong owner of a Conn (every read
        // source captures Conn weakly; pendingPump is cleared once the
        // pump is armed), so when the proxy tears down on a switch
        // toggle the Conns are deallocated. Close the socket here, or
        // the fd leaks as an ESTABLISHED-but-unread socket that the
        // client's keep-alive pool keeps reusing (permanent "failed to
        // fetch" until the whole process is quit).
        deinit {
            if !dead {
                readSrc?.cancel()
                SocketUtil.shutdownAndClose(fd)
            }
        }
        // identity-based Hashable (for the conns set)
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
        static func == (a: Conn, b: Conn) -> Bool { a === b }
        func close() {
            guard !dead else { return }
            dead = true
            readSrc?.cancel()
            owner?.conns.remove(self)
            // Defer fd teardown to the write queue: chunks are enqueued
            // on wq per recv, and the EOF that triggers this close arrives
            // on the serial queue right behind the last data event. A
            // synchronous shutdown+close here races the final queued
            // sendAll and silently drops the tail of the stream — the
            // client then sees a truncated chunked body (undici: "terminated",
            // pi auto-retries). Ordering the teardown after pending sends
            // on wq guarantees the last bytes (SSE [DONE] + terminating
            // chunk) are flushed first.
            // [fd] captures the fd value only (no self): Conn may be
            // deallocated before the teardown runs; deinit then sees
            // dead == true and skips, so the wq task is the one and
            // only closer of this fd
            wq.async { [fd] in
                SocketUtil.shutdownAndClose(fd)
            }
        }
    }

    private func setNonBlocking(_ fd: Int32) {
        // verified in-app: fcntl(F_SETFL) sets O_NONBLOCK (flags 2 -> 6);
        // the ioctl(FIONBIO) attempt did NOT stick, so fcntl is the one
        let fl = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
    }

    private static let headerCap = 64 * 1024
    private static let bodyCap = 25 * 1024 * 1024   // official shim contract

    // arms the single read source; the handler drains recv into c.acc
    // and drives the state machine until the connection is piped or
    // closed. EAGAIN leaves the source armed for the next arrival.
    private func readConn(_ c: Conn) {
        let s = DispatchSource.makeReadSource(fileDescriptor: c.fd, queue: queue)
        s.setEventHandler { [weak self, weak c] in
            guard let self, let c, !c.dead else { return }
            self.readConnTick(c)
        }
        // runs on the queue once this source is completely gone: the
        // safe moment to arm the pump on the same fd
        s.setCancelHandler { [weak self, weak c] in
            guard let self, let c, !c.dead, let r = c.pendingPump else { return }
            c.pendingPump = nil
            self.pump(c, r)
            self.pump(r, c)
        }
        s.resume()
        c.readSrc = s
    }

    private func readConnTick(_ c: Conn) {
        guard !c.dead else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(c.fd, &buf, buf.count, 0)
        if n > 0 {
            c.acc.append(contentsOf: buf[0..<n])
            switch c.mode {
            case .headers:
                guard c.acc.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if c.acc.count > Self.headerCap {
                        sendAll(c, Self.httpError(431, "header too large"))
                        c.close()
                    }
                    return
                }
                let head = c.acc
                c.acc = Data()
                decide(c, head: head)
                // If decide() entered .body and the whole body already
                // arrived in this same read (client sent headers+body in
                // one packet — common for small files over loopback), the
                // read source will NOT fire again (client is idle), so we
                // must process the body here or the request hangs forever.
                if case .body(let total) = c.mode, c.acc.count >= total {
                    let body = c.acc
                    c.acc = Data()
                    guard let req = c.req else { c.close(); return }
                    serveTranscription(c, req: req, body: body)
                }
            case .body(let total):
                guard c.acc.count >= total else { return }
                let body = c.acc
                c.acc = Data()
                guard let req = c.req else { c.close(); return }
                serveTranscription(c, req: req, body: body)
            }
        } else if n == 0 {
            c.close()
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            c.close()
        }
        // EAGAIN: nothing right now; the source stays armed
    }

    private struct Request {
        var method = ""
        var path = ""
        var head: Data = Data()   // everything up to and including "\r\n\r\n"
        var headers: [String: String] = [:]   // lower-cased keys
    }

    private func parseHead(_ head: Data) -> Request? {
        guard let hs = String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = hs.components(separatedBy: "\r\n")
        guard let reqLine = lines.first, !reqLine.isEmpty else { return nil }
        let parts = reqLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        var r = Request()
        r.method = String(parts[0])
        r.path = String(parts[1])
        r.head = head
        // Stop at the first blank line: past "\r\n\r\n" is body, and a
        // multipart body can contain its own "Content-Type: ..." lines
        // (per-part headers) that must NOT overwrite the request headers.
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let i = line.firstIndex(of: ":") {
                let k = line[line.startIndex..<i].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                r.headers[k] = v
            }
        }
        return r
    }

    private func decide(_ c: Conn, head: Data) {
        guard let req = parseHead(head) else { pipeToRouter(c, first: head); return }
        // match on the path portion only: a client that appends a query
        // string (?model=...) would break an exact match and silently skip
        // transcoding — the raw WebM would be piped through and the router
        // would 400 it. Forwarding still uses the full req.path, so the
        // router sees the original request line unchanged (audit D9).
        let pathOnly = req.path.split(separator: "?").first.map(String.init) ?? req.path
        let isTranscription = req.method == "POST"
            && (pathOnly == "/v1/audio/transcriptions" || pathOnly == "/audio/transcriptions")
        let contentType = req.headers["content-type"] ?? ""
        if isTranscription,
           contentType.lowercased().hasPrefix("multipart/form-data"),
           let cl = req.headers["content-length"], let len = Int(cl), len > 0, len <= Self.bodyCap {
            // keep reading on the same source; the body state machine
            // in readConnTick takes over. Some body bytes may already be in
            // `head` (same read as the headers) — keep them so the body
            // state machine doesn't lose them.
            if let term = head.range(of: Data("\r\n\r\n".utf8)) {
                c.acc = head[term.upperBound...]
            } else {
                c.acc = Data()
            }
            c.req = req
            c.mode = .body(total: len)
        } else {
            pipeToRouter(c, first: head)
        }
    }

    // MARK: red-lamp path

    // formats llama.cpp decodes natively (miniaudio built-ins: wav/mp3/flac).
    // ogg/opus/webm are NOT supported by llama.cpp → they must be transcoded,
    // so they are deliberately absent here and fall through to the transcode path.
    private static let nativeExts: Set<String> = ["wav", "mp3", "flac"]

    private func serveTranscription(_ c: Conn, req: Request, body: Data) {
        let ct = req.headers["content-type"] ?? ""
        guard var boundary = ct.components(separatedBy: "boundary=").last, !boundary.isEmpty else {
            forwardOriginal(c, request: req, body: body)
            return
        }
        // the boundary parameter may be quoted (RFC 7578)
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") && boundary.count >= 2 {
            boundary.removeFirst()
            boundary.removeLast()
        }
        guard let parts = Self.parseMultipart(body, boundary: boundary) else {
            sendAll(c, Self.httpError(400, "malformed multipart body"))
            c.close()
            return
        }
        guard let fi = parts.firstIndex(where: { $0.name == "file" && $0.filename != nil }) else {
            sendAll(c, Self.httpError(400, "no file part in multipart body"))
            c.close()
            return
        }
        let ext = (parts[fi].filename ?? "").lowercased()
            .split(separator: ".").last.map(String.init) ?? ""
        if Self.nativeExts.contains(ext) {
            // native format: no lamp, forward the original request as-is
            forwardOriginal(c, request: req, body: body)
            return
        }
        var newParts = parts
        do {
            let wav = try transcode(input: parts[fi].data, ext: ext.isEmpty ? "bin" : ext)
            newParts[fi].data = wav
            newParts[fi].filename = (parts[fi].filename ?? "audio").replacingOccurrences(of: ".", with: "_") + ".wav"
            newParts[fi].contentType = "audio/wav"
            log("[proxy] transcoded \(parts[fi].filename ?? "?") (\(parts[fi].data.count) B) -> 16k mono wav (\(wav.count) B)")
            let newBody = Self.buildMultipart(newParts, boundary: boundary)
            routerCall(c, method: req.method, path: req.path, headers: req.headers, body: newBody)
        } catch {
            log("[proxy] transcode failed: \(error.localizedDescription)")
            sendAll(c, Self.httpError(502, "audio transcode failed: \(error.localizedDescription)"))
            c.close()
        }
    }

    // full-request passthrough (native-format transcription): the whole
    // request is in memory, forward it and return the response
    private func forwardOriginal(_ c: Conn, request: Request, body: Data) {
        routerCall(c, method: request.method, path: request.path, headers: request.headers, body: body)
    }

    // HTTP-level exchange with the router via URLSession (the request
    // carries "Connection: close", so the response is complete when the
    // task finishes); the raw response is written back verbatim
    private func routerCall(_ c: Conn, method: String, path: String, headers: [String: String], body: Data) {
        guard let url = URL(string: "http://127.0.0.1:\(routerPort)\(path)") else {
            sendAll(c, Self.httpError(502, "bad request"))
            c.close()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // forward the original request headers; content-length and
        // connection are managed by URLSession itself
        for (k, v) in headers where k != "content-length" && k != "connection" {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        req.timeoutInterval = 300   // ASR on a big recording can take a while
        let task = URLSession.shared.dataTask(with: req) { [weak self, weak c] data, resp, err in
            guard let self else { return }
            guard let c, !c.dead else { return }
            queue.async {
                guard !c.dead else { return }
                if let err {
                    self.log("[proxy] router call failed: \(err.localizedDescription)")
                    self.sendAll(c, Self.httpError(502, "router unreachable"))
                    c.close()
                    return
                }
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 502
                let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Content-Length: \((data?.count ?? 0))\r\n"
                    + "Connection: close\r\n\r\n"
                SocketUtil.sendAll(c.fd, Data(head.utf8) + (data ?? Data()))
                c.close()
            }
        }
        task.resume()
        // watchdog: if the router never answers (e.g. it stalls on a bad
        // body), URLSession's 300s resource timeout won't save us and the
        // client connection would hang forever. Cancel after 120s so the
        // client gets a 502 instead of an infinite "transcribing".
        queue.asyncAfter(deadline: .now() + 120) { [weak c, weak task] in
            guard let c, !c.dead else { return }
            task?.cancel()   // completion fires with a cancel error -> 502
        }
    }

    // MARK: blind byte pipe (chat SSE, model list, everything else)

    // dial the router, then pump bytes both directions untouched
    private func pipeToRouter(_ c: Conn, first: Data) {
        let rfd = SocketUtil.dial(port: routerPort)
        guard rfd >= 0 else {
            if !routerDialFailing {
                log("[proxy] router dial failed")
                routerDialFailing = true
            }
            sendAll(c, Self.httpError(502, "router unreachable"))
            c.close()
            return
        }
        if routerDialFailing {
            log("[proxy] router reachable again")
            routerDialFailing = false
        }
        setNonBlocking(rfd)
        let r = Conn(rfd)
        r.owner = self
        conns.insert(r)   // keeps r alive so its pump source stays armed
        // the request head is already in hand: it goes upstream first
        r.wq.async {
            SocketUtil.sendAll(r.fd, first)
        }
        // the client fd still carries the request-read source; the pump
        // gets it back via that source's cancel handler (sequential)
        c.pendingPump = r
        c.readSrc?.cancel()
    }

    // copy bytes src -> dst until either side completes or errors.
    // the read source stays armed across events (persistent handler), so
    // this installs exactly ONE source per direction
    // one persistent read source per direction; EAGAIN keeps it armed
    private func pump(_ src: Conn, _ dst: Conn) {
        let srcFd = src.fd
        let s = DispatchSource.makeReadSource(fileDescriptor: srcFd, queue: queue)
        s.setEventHandler { [weak src, weak dst] in
            guard let src, let dst, !src.dead, !dst.dead else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(srcFd, &buf, buf.count, 0)
            if n > 0 {
                let chunk = Data(buf[0..<n])
                dst.wq.async {
                    SocketUtil.sendAll(dst.fd, chunk)
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                src.close()
                dst.close()
            }
            // EAGAIN: nothing right now, the source is still armed
        }
        s.setCancelHandler {}
        s.resume()
        src.readSrc = s
    }

    private func sendAll(_ c: Conn, _ data: Data) {
        c.wq.async {
            SocketUtil.sendAll(c.fd, data)
        }
    }

    // MARK: multipart

    struct MultipartPart {
        var name = ""
        var filename: String?
        var contentType: String?
        var data = Data()
    }

    // RFC 7578 multipart/form-data parser. Delimiters are consumed
    // explicitly: each part's data runs until "\r\n--boundary", and the
    // character pair after the boundary decides whether the body
    // continues ("\r\n") or ends ("--"). A marker prefix that is
    // followed by anything else is payload data and the search
    // continues past it.
    private static func parseMultipart(_ body: Data, boundary: String) -> [MultipartPart]? {
        let marker = Data(("\r\n--" + boundary).utf8)
        let first = Data(("--" + boundary).utf8)
        guard let f = body.range(of: first) else { return nil }
        var pos = f.upperBound
        guard body[pos...].starts(with: Data("\r\n".utf8)) else { return nil }
        pos += 2
        var parts: [MultipartPart] = []
        while true {
            guard let hh = body.range(of: Data("\r\n\r\n".utf8), in: pos..<body.endIndex) else { return nil }
            let headText = String(data: body[pos..<hh.lowerBound], encoding: .isoLatin1) ?? ""
            var part = MultipartPart()
            for line in headText.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition:") {
                    part.name = dispositionParameter(line, key: "name") ?? ""
                    part.filename = dispositionParameter(line, key: "filename")
                } else if lower.hasPrefix("content-type:") {
                    part.contentType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
            }
            // find the terminating delimiter, skipping marker prefixes
            // embedded in the payload
            var end: Range<Data.Index>?
            var searchFrom = hh.upperBound
            while let r = body.range(of: marker, in: searchFrom..<body.endIndex) {
                let after = r.upperBound
                if body[after...].starts(with: Data("\r\n".utf8)) { end = r; break }
                if body[after...].starts(with: Data("--".utf8)) { end = r; break }
                searchFrom = after
            }
            guard let e = end else { return nil }
            part.data = Data(body[hh.upperBound..<e.lowerBound])
            parts.append(part)
            let after = e.upperBound
            if body[after...].starts(with: Data("--".utf8)) { break }   // closing boundary
            guard body[after...].starts(with: Data("\r\n".utf8)) else { return nil }
            pos = after + 2
        }
        return parts.isEmpty ? nil : parts
    }

    // parameter-aware extraction from "Content-Disposition: form-data;
    // name=\"file\"; filename=\"a.webm\"": split on ";", exact key match
    // (case-insensitive), surrounding quotes stripped
    private static func dispositionParameter(_ line: String, key: String) -> String? {
        for piece in line.split(separator: ";", omittingEmptySubsequences: false).dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let k = piece[..<eq].trimmingCharacters(in: .whitespaces)
            guard k.lowercased() == key.lowercased() else { continue }
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.first == "\"", v.last == "\"" {
                v.removeFirst()
                v.removeLast()
            }
            return String(v)
        }
        return nil
    }

    private static func buildMultipart(_ parts: [MultipartPart], boundary: String) -> Data {
        var out = Data()
        for p in parts {
            out += Data(("--" + boundary + "\r\n").utf8)
            var disp = "Content-Disposition: form-data; name=\"\(p.name)\""
            if let f = p.filename { disp += "; filename=\"\(f)\"" }
            out += Data((disp + "\r\n").utf8)
            if let ct = p.contentType { out += Data(("Content-Type: \(ct)\r\n").utf8) }
            out += Data("\r\n".utf8)
            out += p.data
            out += Data("\r\n".utf8)
        }
        out += Data(("--" + boundary + "--\r\n").utf8)
        return out
    }

    // MARK: ffmpeg

    // GUI apps get a minimal PATH, so homebrew locations are checked
    // explicitly before falling back to PATH
    static func findFFmpeg() -> String? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "command -v ffmpeg"]
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardError = Pipe()
        do {
            try sh.run()
            sh.waitUntilExit()
            let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, fm.isExecutableFile(atPath: s) { return s }
        } catch {}
        return nil
    }

    private func transcode(input: Data, ext: String) throws -> Data {
        let ffmpeg = Self.findFFmpeg()
        guard let ff = ffmpeg else { throw TranscodeError.noFFmpeg }
        let tmp = NSTemporaryDirectory()
        let inPath = tmp + "corral-proxy-\(UUID().uuidString).\(ext)"
        let outPath = tmp + "corral-proxy-\(UUID().uuidString).wav"
        FileManager.default.createFile(atPath: inPath, contents: input)
        defer {
            try? FileManager.default.removeItem(atPath: inPath)
            try? FileManager.default.removeItem(atPath: outPath)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-y", "-loglevel", "error", "-i", inPath,
                       "-ar", "16000", "-ac", "1", "-f", "wav", outPath]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(p.terminationStatus)"
            throw TranscodeError.ffmpegFailed(msg)
        }
        let wav = try Data(contentsOf: URL(fileURLWithPath: outPath)) // read whole file
        guard !wav.isEmpty else { throw TranscodeError.emptyOutput }
        return wav
    }

    enum TranscodeError: LocalizedError {
        case noFFmpeg
        case ffmpegFailed(String)
        case emptyOutput
        var errorDescription: String? {
            switch self {
            case .noFFmpeg: return "ffmpeg not found (brew install ffmpeg)"
            case .ffmpegFailed(let m): return m
            case .emptyOutput: return "ffmpeg produced no output"
            }
        }
    }

    // MARK: raw HTTP responses (error paths + router response framing)

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        default: return "Unknown"
        }
    }

    private static func httpError(_ code: Int, _ msg: String) -> Data {
        let body = "{\"error\":{\"message\":\"\(msg.replacingOccurrences(of: "\"", with: "\\\""))\"}}"
        let head = "HTTP/1.1 \(code) \(reason(code))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + Data(body.utf8)
    }
}

// MARK: - Socket helpers

enum SocketUtil {
    // blocking connect for the short router dial (loopback only: succeeds
    // or gets ECONNREFUSED immediately, no timeout machinery needed)
    static func dial(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        // sin_len and sin_family share the first field: assign family LAST
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        addr.sin_family = sa_family_t(AF_INET)
        let r = withUnsafePointer(to: &addr) {
            connect(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                    socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        if r == 0 { return fd }
        close(fd)
        return -1
    }

    // write everything (non-blocking fd, polled), dropping on error
    static func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            let total = raw.count
            guard total > 0 else { return }
            while sent < total {
                // MSG_NOSIGNAL: a client that went away must surface as
                // EPIPE, not a SIGPIPE that kills the whole app
                let n = send(fd, raw.baseAddress!.advanced(by: sent), total - sent, Int32(MSG_NOSIGNAL))
                if n > 0 {
                    sent += n
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 200)
                } else {
                    return   // peer gone / error: drop, conn teardown follows
                }
            }
        }
    }

    static func shutdownAndClose(_ fd: Int32) {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }
}

// MARK: - Free port picker (router's internal port)

// bind 127.0.0.1:0, ask the kernel for the assigned port, release it.
// tiny race window (someone else grabbing the port before the router
// binds) is accepted: the router would fail to start and the existing
// recovery path handles it.
func pickFreePort() -> Int? {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    defer { close(s) }
    var addr = sockaddr_in()
    // sin_len and sin_family share the first field: assign family LAST
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    addr.sin_family = sa_family_t(AF_INET)
    let bound = withUnsafePointer(to: &addr) {
        bind(s, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
             socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    guard bound == 0 else { return nil }
    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &actual) {
        getsockname(s, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &len)
    }
    guard got == 0 else { return nil }
    return Int(UInt16(bigEndian: actual.sin_port))
}
