import Foundation
import Network

/// Lightweight loopback-only HTTP server serving the bundled Qamus static site.
/// Using 127.0.0.1 gives WKWebView full ES Module support, persistent IndexedDB
/// across launches, and automatic CORS compatibility with the Cloudflare Sync Worker.
final class LocalWebServer: @unchecked Sendable {
    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.alqamus.webserver", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func start(preferredPort: UInt16 = 41932) throws -> URL {
        let portsToTry: [UInt16] = [preferredPort, preferredPort + 1, preferredPort + 2, 0]
        var lastError: Error?

        for candidate in portsToTry {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: candidate == 0 ? .any : NWEndpoint.Port(rawValue: candidate)!
                )

                let l = try NWListener(using: params)
                let ready = DispatchSemaphore(value: 0)
                final class ErrorBox: @unchecked Sendable { var error: Error? }
                let errorBox = ErrorBox()

                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        ready.signal()
                    case .failed(let err):
                        errorBox.error = err
                        ready.signal()
                    case .cancelled:
                        ready.signal()
                    default:
                        break
                    }
                }

                l.newConnectionHandler = { [weak self] conn in
                    self?.handle(connection: conn)
                }

                l.start(queue: queue)
                _ = ready.wait(timeout: .now() + 3)

                if let err = errorBox.error {
                    l.cancel()
                    lastError = err
                    continue
                }
                if let boundPort = l.port?.rawValue, boundPort > 0 {
                    self.listener = l
                    self.port = boundPort
                    return baseURL
                }
                l.cancel()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "LocalWebServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to bind loopback HTTP port"])
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil {
                connection.cancel()
                return
            }
            var acc = buffer
            if let data { acc.append(data) }

            let headerEnd = Data("\r\n\r\n".utf8)
            if acc.range(of: headerEnd) != nil || isComplete || acc.count > 65536 {
                self.respond(to: acc, on: connection)
            } else {
                self.receiveRequest(on: connection, buffer: acc)
            }
        }
    }

    private func respond(to rawRequest: Data, on connection: NWConnection) {
        guard let reqStr = String(data: rawRequest, encoding: .utf8),
              let firstLine = reqStr.split(separator: "\r\n", maxSplits: 1).first else {
            send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8), headOnly: false, on: connection)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8), headOnly: false, on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Method Not Allowed".utf8), headOnly: false, on: connection)
            return
        }

        let rawTarget = String(parts[1])
        let pathOnly = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        var decoded = pathOnly.removingPercentEncoding ?? pathOnly
        if decoded.hasSuffix("/") { decoded += "index.html" }
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Disable Service Worker inside the native Mac bundle so rebuilt assets always load fresh from disk.
        if trimmed == "sw.js" {
            let noopSW = """
            self.addEventListener('install', () => self.skipWaiting());
            self.addEventListener('activate', e => e.waitUntil(self.registration.unregister()));
            """
            send(status: "200 OK", contentType: "text/javascript; charset=utf-8", body: Data(noopSW.utf8), headOnly: method == "HEAD", on: connection)
            return
        }

        let candidateURL = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        guard candidateURL.path.hasPrefix(rootURL.path + "/") || candidateURL.path == rootURL.path else {
            send(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8), headOnly: method == "HEAD", on: connection)
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDir), !isDir.boolValue,
              let fileData = try? Data(contentsOf: candidateURL) else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8), headOnly: method == "HEAD", on: connection)
            return
        }

        send(status: "200 OK", contentType: mimeType(for: candidateURL.pathExtension), body: fileData, headOnly: method == "HEAD", on: connection)
    }

    private func send(status: String, contentType: String, body: Data, headOnly: Bool, on connection: NWConnection) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-cache",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var packet = Data(headers.utf8)
        if !headOnly { packet.append(body) }

        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
