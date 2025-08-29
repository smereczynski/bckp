import XCTest
@testable import BackupCore

private class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
    guard let handler = MockURLProtocol.handler, request.url != nil else { return }
        let (resp, data) = handler(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let data = data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AzureBlobClientTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testExistsHead200And404() throws {
        let base = URL(string: "https://acct.blob.core.windows.net/container?sv=x&sig=y")!
        let client = AzureBlobClient(containerSASURL: base, session: session())
        // 200
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        XCTAssertTrue(try client.exists(blobPath: "foo"))
        // 404
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        XCTAssertFalse(try client.exists(blobPath: "foo"))
    }

    func testListParsesNamesAndPrefixes() throws {
        let base = URL(string: "https://acct.blob.core.windows.net/container?sv=x&sig=y")!
        let client = AzureBlobClient(containerSASURL: base, session: session())
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <EnumerationResults>
          <Blobs>
            <Blob><Name>a/b/file1.txt</Name></Blob>
            <BlobPrefix><Name>a/b/</Name></BlobPrefix>
          </Blobs>
        </EnumerationResults>
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!
            return (resp, xml)
        }
        let res = try client.list(prefix: "a/", delimiter: "/")
        XCTAssertEqual(res.blobs, ["a/b/file1.txt"])
        XCTAssertEqual(res.prefixes, ["a/b/"])
    }
}
