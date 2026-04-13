// RemoteTunnelManager.swift
// Clome — HTTP proxy for secure port forwarding from macOS localhost to iOS clients.
//
// Architecture: iOS sends `TunnelHTTPRequest` over the remote protocol. macOS
// uses URLSession to make the actual HTTP request to `http://localhost:{port}{path}`
// and returns the response wrapped in `TunnelHTTPResponse`. Per-request semantics
// (rather than a raw TCP tunnel) are simpler to reason about, handle keep-alive
// naturally, and integrate cleanly with WKWebView + WKURLSchemeHandler on iOS.

import Foundation

@MainActor
final class RemoteTunnelManager {

    private struct Tunnel {
        let id: String
        let port: UInt16
        let label: String?
        let sessionId: String
    }

    private var tunnels: [String: Tunnel] = [:]
    private let maxConcurrentTunnels = 5

    // Keep a dedicated URLSession per tunnel so cookies are isolated.
    private var urlSessions: [String: URLSession] = [:]

    // MARK: - Open / Close

    func openTunnel(port: UInt16, label: String?, sessionId: String) -> TunnelOpenedResponse {
        guard tunnels.count < maxConcurrentTunnels else {
            return TunnelOpenedResponse(
                tunnelId: "",
                port: port,
                success: false,
                error: "Max \(maxConcurrentTunnels) tunnels reached"
            )
        }

        let tunnelId = UUID().uuidString
        let tunnel = Tunnel(id: tunnelId, port: port, label: label, sessionId: sessionId)
        tunnels[tunnelId] = tunnel

        // Create an isolated session per tunnel with its own cookie storage and
        // a short timeout (dev servers should respond quickly).
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        urlSessions[tunnelId] = URLSession(configuration: config)

        print("[Tunnel] Opened \(tunnelId) → http://localhost:\(port)")

        return TunnelOpenedResponse(
            tunnelId: tunnelId,
            port: port,
            success: true,
            error: nil
        )
    }

    func closeTunnel(tunnelId: String) {
        tunnels.removeValue(forKey: tunnelId)
        if let session = urlSessions.removeValue(forKey: tunnelId) {
            session.invalidateAndCancel()
        }
        print("[Tunnel] Closed \(tunnelId)")
    }

    func closeAllTunnels(forSession sessionId: String) {
        let matching = tunnels.filter { $0.value.sessionId == sessionId || sessionId.isEmpty }
        for (id, _) in matching {
            closeTunnel(tunnelId: id)
        }
    }

    // MARK: - HTTP Proxy

    /// Performs an HTTP request to localhost:{port} and returns the wrapped response.
    /// Called on the main actor; the actual network IO happens on URLSession's queue.
    func handleHTTPRequest(_ req: TunnelHTTPRequest) async -> TunnelHTTPResponse {
        guard let tunnel = tunnels[req.tunnelId] else {
            return TunnelHTTPResponse(
                tunnelId: req.tunnelId,
                requestId: req.requestId,
                status: 0,
                headers: [:],
                body: nil,
                error: "Unknown tunnel"
            )
        }

        guard let session = urlSessions[req.tunnelId] else {
            return TunnelHTTPResponse(
                tunnelId: req.tunnelId,
                requestId: req.requestId,
                status: 0,
                headers: [:],
                body: nil,
                error: "Tunnel session missing"
            )
        }

        // Build URL: http://localhost:{port}{path}
        // Use "localhost" (not 127.0.0.1) so URLSession's resolver handles
        // both IPv4 and IPv6 loopback — many dev servers (Vite, Next.js)
        // bind only to ::1 by default, not 127.0.0.1.
        // req.path should already start with "/".
        let normalizedPath = req.path.hasPrefix("/") ? req.path : "/" + req.path
        let urlString = "http://localhost:\(tunnel.port)\(normalizedPath)"

        guard let url = URL(string: urlString) else {
            return TunnelHTTPResponse(
                tunnelId: req.tunnelId,
                requestId: req.requestId,
                status: 0,
                headers: [:],
                body: nil,
                error: "Invalid URL: \(urlString)"
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = req.method
        for (key, value) in req.headers {
            // Skip hop-by-hop / restricted headers that URLSession manages itself
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = req.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return TunnelHTTPResponse(
                    tunnelId: req.tunnelId,
                    requestId: req.requestId,
                    status: 0,
                    headers: [:],
                    body: nil,
                    error: "Not an HTTP response"
                )
            }

            // Copy response headers
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k] = v
                }
            }

            print("[Tunnel] \(req.method) \(normalizedPath) → \(http.statusCode) (\(data.count) bytes)")

            return TunnelHTTPResponse(
                tunnelId: req.tunnelId,
                requestId: req.requestId,
                status: http.statusCode,
                headers: headers,
                body: data,
                error: nil
            )
        } catch {
            print("[Tunnel] Request failed: \(error.localizedDescription)")
            return TunnelHTTPResponse(
                tunnelId: req.tunnelId,
                requestId: req.requestId,
                status: 0,
                headers: [:],
                body: nil,
                error: error.localizedDescription
            )
        }
    }
}
