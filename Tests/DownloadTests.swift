import XCTest

/// Lo scaricamento dei modelli: se la connessione cade a metà si riprende da dove si era fermato (Range),
/// e un file già scaricato in parte non ricomincia da zero. Un server finto (URLProtocol), niente internet.
final class DownloadTests: XCTestCase {

    /// Il server finto: 1 MB di dati. La prima richiesta senza Range si interrompe a metà.
    final class Stub: URLProtocol {
        static var body = Data((0..<1_048_576).map { UInt8($0 % 251) })
        static var ranges: [String?] = []
        static var breakFirst = true

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let range = request.value(forHTTPHeaderField: "Range")
            Stub.ranges.append(range)
            let url = request.url!
            if let r = range, let from = Int(r.dropFirst("bytes=".count).dropLast()) {
                let rest = Stub.body.subdata(in: from..<Stub.body.count)
                let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(rest.count)"])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: rest)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(Stub.body.count)"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if Stub.breakFirst {
                Stub.breakFirst = false
                client?.urlProtocol(self, didLoad: Stub.body.prefix(400_000))
                // La connessione cade poco dopo: se l'errore arriva insieme ai dati, URLSession a volte
                // non consegna i dati (succedeva 1 volta su qualche decina: prova instabile, non l'app)
                let client = client
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
            } else {
                client?.urlProtocol(self, didLoad: Stub.body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prova-\(UUID().uuidString).parziale")
    }

    func testResumesAfterConnectionLost() async throws {
        Stub.ranges = []
        Stub.breakFirst = true
        let dest = temp()
        defer { try? FileManager.default.removeItem(at: dest) }
        let notes = Notes()
        var last = 0.0
        try await ModelStore.fetch(URL(string: "https://prova.invalid/modello.zip")!, to: dest, session: session(),
                                   status: { notes.add($0) }) { last = $0 }
        XCTAssertEqual(try Data(contentsOf: dest), Stub.body, "il file ripreso deve essere identico all'originale")
        XCTAssertNil(Stub.ranges.first ?? "manca", "la prima richiesta è senza Range")
        XCTAssertEqual(Stub.ranges.last ?? "manca", "bytes=400000-", "la seconda riprende da dove si era fermata")
        XCTAssertEqual(last, 1, accuracy: 1e-9)
        XCTAssertTrue(notes.all.contains { $0.contains("riprovo a scaricare tra 2 s") }, "dice che riprova: \(notes.all)")
        XCTAssertTrue(notes.all.contains { $0.hasPrefix("Riprendo a scaricare da") }, "dice da dove riprende: \(notes.all)")
    }

    func testPartialFileContinues() async throws {
        Stub.ranges = []
        Stub.breakFirst = false
        let dest = temp()
        defer { try? FileManager.default.removeItem(at: dest) }
        try Stub.body.prefix(700_000).write(to: dest)
        try await ModelStore.fetch(URL(string: "https://prova.invalid/modello.zip")!, to: dest, session: session(),
                                   status: { _ in }) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), Stub.body)
        XCTAssertEqual(Stub.ranges, ["bytes=700000-"], "con una parte già scaricata si chiede solo il resto")
    }

    final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var all: [String] { lock.withLock { list } }
    }
}

/// Il registro dei tempi: una riga leggibile per separazione, si tengono le ultime, niente esce dal Mac.
final class TimingLogTests: XCTestCase {
    func testLineAndTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tempi-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = TimingLog.line(date: Date(timeIntervalSince1970: 0), quality: "Massima", songSeconds: 222, seconds: 130,
                                  steps: [("Voce", 50.2), ("Strumenti", 60)], engine: "Neural Engine",
                                  peakBytes: 2_254_857_830, machine: "Mac14,2 Apple M2 16 GB")
        XCTAssertTrue(line.contains("Massima · canzone 3:42 · 2:10"), line)
        XCTAssertTrue(line.contains("Voce 50 s, Strumenti 60 s"), line)
        XCTAssertTrue(line.contains("memoria max 2,1 GB"), line)
        for i in 0..<510 { TimingLog.add("riga \(i)", to: url) }
        let tail = TimingLog.tail(20, from: url)
        XCTAssertEqual(tail.count, 20)
        XCTAssertEqual(tail.last, "riga 509")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 500, "si tengono le ultime 500")
    }

    func testMemoryMeter() {
        let m = MemoryMeter()
        m.start()
        XCTAssertGreaterThan(m.stop(), 1_000_000, "un processo usa almeno qualche MB")
    }
}
