//
//  NetworkStub.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Answers the app's HTTP requests from the test, without a server and without real network.
///
/// The follower and Nightscout managers use `URLSession.shared` directly, so the session cannot be
/// injected. `URLProtocol.registerClass` makes the shared session ask `NetworkStubURLProtocol`
/// first; the protocol hands every request to the stub that is currently installed. Requests that
/// no route answers fail with `URLError(.notConnectedToInternet)` and are kept in
/// `unexpectedRequests`, so a test never reaches a real server by accident. Code that accepts a
/// session can use `makeSession()` instead of the global registration.
///
/// `waitUntilIdle()` replaces fixed sleeps that wait for background uploads: it returns as soon as
/// no request has been in flight for a short quiet period.
///
/// Usage:
/// ```swift
/// let network = installNetworkStub()
/// network.on("POST", host: "ns.test", path: "/api/v1/entries") { _ in .json("[]") }
/// ... exercise the code ...
/// await network.waitUntilIdle()
/// XCTAssertEqual(network.requests(path: "/api/v1/entries").count, 1)
/// ```
final class NetworkStub {

    // MARK: - nested types

    /// A request as the server would have received it, body included.
    struct Request {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        var host: String { url.host ?? "" }
        var path: String { url.path }

        /// The body decoded as JSON, or nil when it is empty or not JSON.
        var jsonBody: Any? { try? JSONSerialization.jsonObject(with: body) }

        /// The value of a query item, e.g. `count` in `/api/v1/entries?count=10`.
        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
    }

    /// What the stub sends back for a request.
    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// When set, the request fails with this error instead of returning a response.
        var error: URLError.Code?

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func json(object: Any, status: Int = 200) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(statusCode: status, headers: ["Content-Type": "application/json"], body: body)
        }

        static func data(_ body: Data, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(statusCode: status, headers: headers, body: body)
        }

        static func status(_ statusCode: Int) -> Response {
            Response(statusCode: statusCode)
        }

        static func failure(_ code: URLError.Code) -> Response {
            Response(error: code)
        }
    }

    /// Returns a response for the request, or nil to let the next matching route answer.
    typealias Handler = (Request) -> Response?

    private struct Route {
        let method: String?
        let host: String?
        let path: String?
        let handler: Handler

        func matches(_ request: Request) -> Bool {
            (method == nil || method == request.method) && (host == nil || host == request.host) && (path == nil || path == request.path)
        }
    }

    // MARK: - static properties

    private static let lock = NSLock()

    /// The stub that receives the requests of `NetworkStubURLProtocol`; nil when none is installed.
    private static var installed: NetworkStub?

    /// The stub that currently answers requests, if any. Used by `NetworkStubURLProtocol`.
    static var current: NetworkStub? {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    // MARK: - private properties

    private let lock = NSLock()
    private var routes = [Route]()
    private var recorded = [Request]()
    private var unexpected = [Request]()
    private var inFlight = 0
    private var lastActivity = Date.distantPast

    // MARK: - installation

    /// Installs a new stub for `URLSession.shared` and returns it. Replaces any installed stub.
    static func install() -> NetworkStub {
        let stub = NetworkStub()
        lock.lock()
        installed = stub
        lock.unlock()
        // Returns a Bool on Linux and nothing on Apple platforms.
        _ = URLProtocol.registerClass(NetworkStubURLProtocol.self)
        return stub
    }

    /// Stops answering requests. Later requests reach the network stack again (and, in tests, the
    /// next stub that is installed).
    func uninstall() {
        Self.lock.lock()
        let wasInstalled = Self.installed === self
        if wasInstalled { Self.installed = nil }
        Self.lock.unlock()
        if wasInstalled {
            URLProtocol.unregisterClass(NetworkStubURLProtocol.self)
        }
    }

    /// A session for code that accepts a `URLSession` or builds its own configuration, which the
    /// global registration does not reach. It is answered by the installed stub.
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - routes

    /// Answers requests that match all the given parts (nil matches anything). Routes are tried in
    /// the order they were added; the first handler that returns a response wins.
    func on(_ method: String? = nil, host: String? = nil, path: String? = nil, respond handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, host: host, path: path, handler: handler))
    }

    /// Answers every matching request with the same response.
    func on(_ method: String? = nil, host: String? = nil, path: String? = nil, reply response: Response) {
        on(method, host: host, path: path) { _ in response }
    }

    // MARK: - recorded requests

    /// Every request that a route answered, in the order they arrived.
    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Requests that no route answered; they failed with `notConnectedToInternet`.
    var unexpectedRequests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return unexpected
    }

    /// Answered requests that match all the given parts.
    func requests(_ method: String? = nil, host: String? = nil, path: String? = nil) -> [Request] {
        requests.filter { Route(method: method, host: host, path: path, handler: { _ in nil }).matches($0) }
    }

    /// Forgets the recorded requests; routes stay.
    func resetRecordedRequests() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        unexpected = []
    }

    // MARK: - waiting

    /// Number of requests that have arrived but not been answered yet.
    var inFlightCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    /// Waits until no request is in flight and none has started or finished during `quietPeriod`,
    /// so a chain of requests (login, then download) is waited for as a whole. Returns false when
    /// `timeout` passes first.
    @discardableResult
    func waitUntilIdle(quietPeriod: TimeInterval = 0.05, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isIdle(quietPeriod: quietPeriod) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func isIdle(quietPeriod: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight == 0 && Date().timeIntervalSince(lastActivity) >= quietPeriod
    }

    // MARK: - used by NetworkStubURLProtocol

    /// Records the request and returns the response of the first route that answers it, or nil.
    fileprivate func respond(to request: Request) -> Response? {
        lock.lock()
        let candidates = routes.filter { $0.matches(request) }
        lock.unlock()
        // Handlers run without the lock, so they may read `requests` or add routes.
        let response = candidates.lazy.compactMap { $0.handler(request) }.first
        lock.lock()
        if response == nil { unexpected.append(request) } else { recorded.append(request) }
        lock.unlock()
        return response
    }

    fileprivate func noteActivity() {
        lock.lock(); defer { lock.unlock() }
        lastActivity = Date()
    }

    fileprivate func requestStarted() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        lastActivity = Date()
    }

    fileprivate func requestFinished() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        lastActivity = Date()
    }
}

/// The `URLProtocol` that forwards requests to the installed `NetworkStub`.
final class NetworkStubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        // Counted as activity so `waitUntilIdle` does not return between a request being created
        // and it being started.
        NetworkStub.current?.noteActivity()
        return NetworkStub.current != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let stub = NetworkStub.current, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        stub.requestStarted()
        defer { stub.requestFinished() }

        let recorded = NetworkStub.Request(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))

        guard let response = stub.respond(to: recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let httpResponse = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The body of a request: `httpBody`, or the stream the system moves it into for uploads.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension XCTestCase {

    /// Installs a `NetworkStub` for the rest of the test and uninstalls it in teardown, after
    /// waiting for requests still in flight so they cannot leak into the next test.
    ///
    /// - Parameter failOnUnexpectedRequests: when true, a request that no route answered fails the
    ///   test in teardown.
    func installNetworkStub(failOnUnexpectedRequests: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> NetworkStub {
        let stub = NetworkStub.install()
        addTeardownBlock {
            await stub.waitUntilIdle(timeout: 2)
            stub.uninstall()
            if failOnUnexpectedRequests, !stub.unexpectedRequests.isEmpty {
                let list = stub.unexpectedRequests.map { "\($0.method) \($0.url.absoluteString)" }.joined(separator: ", ")
                XCTFail("Requests without a route: \(list)", file: file, line: line)
            }
        }
        return stub
    }
}
