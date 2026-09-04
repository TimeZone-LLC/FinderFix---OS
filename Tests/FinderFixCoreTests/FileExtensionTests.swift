import XCTest
@testable import FinderFixCore

final class FileExtensionTests: XCTestCase {
    func testParserNormalizesAndDeduplicatesInFirstSeenOrder() throws {
        let parsed: [FileExtension] = try ExtensionListParser.parse(" .TXT, md\ntxt;JSON  .Md ")

        XCTAssertEqual(parsed.map(\.rawValue), ["txt", "md", "json"])
        XCTAssertEqual(parsed.map(\.displayValue), [".txt", ".md", ".json"])
    }

    func testParserAcceptsSingleExtension() throws {
        XCTAssertEqual(try ExtensionListParser.parse(".HEIC"), [try extensionValue("heic")])
    }

    func testParserRejectsEmptyInput() {
        XCTAssertThrowsError(try ExtensionListParser.parse(" , ; \n ")) { error in
            XCTAssertEqual(error as? ExtensionListParseError, .emptyInput)
        }
    }

    func testParserRejectsCompoundAndWildcardTokens() {
        XCTAssertThrowsError(try ExtensionListParser.parse("tar.gz")) { error in
            XCTAssertEqual(
                error as? ExtensionListParseError,
                .invalidToken(token: "tar.gz", reason: .containsInvalidCharacter("."))
            )
        }

        XCTAssertThrowsError(try ExtensionListParser.parse("*")) { error in
            XCTAssertEqual(
                error as? ExtensionListParseError,
                .invalidToken(token: "*", reason: .containsInvalidCharacter("*"))
            )
        }
    }

    func testFileExtensionCodableUsesNormalizedSingleString() throws {
        let fileExtension: FileExtension = try FileExtension(validating: ".PDF")
        let encoded: Data = try JSONEncoder().encode(fileExtension)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"pdf\"")
        XCTAssertEqual(try JSONDecoder().decode(FileExtension.self, from: encoded), fileExtension)
        XCTAssertThrowsError(
            try JSONDecoder().decode(FileExtension.self, from: Data("\"tar.gz\"".utf8))
        )
    }

    private func extensionValue(_ value: String) throws -> FileExtension {
        try FileExtension(validating: value)
    }
}
