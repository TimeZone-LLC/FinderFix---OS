import Foundation

/// A normalized filename extension without a leading period.
public struct FileExtension: Hashable, Comparable, Sendable, RawRepresentable, Codable, CustomStringConvertible {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case tooLong(maximumLength: Int)
        case containsInvalidCharacter(Character)
    }

    public static let maximumLength: Int = 64

    public let rawValue: String

    public init?(rawValue: String) {
        guard let normalizedValue: String = try? Self.normalized(rawValue) else {
            return nil
        }
        self.rawValue = normalizedValue
    }

    public init(validating value: String) throws {
        self.rawValue = try Self.normalized(value)
    }

    public var description: String {
        rawValue
    }

    public var displayValue: String {
        ".\(rawValue)"
    }

    public static func < (lhs: FileExtension, rhs: FileExtension) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let value: String = try container.decode(String.self)

        do {
            self.rawValue = try Self.normalized(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid filename extension: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalized(_ value: String) throws -> String {
        var normalizedValue: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedValue.hasPrefix(".") {
            normalizedValue.removeFirst()
        }
        normalizedValue = normalizedValue.lowercased()

        guard !normalizedValue.isEmpty else {
            throw ValidationError.empty
        }
        guard normalizedValue.count <= maximumLength else {
            throw ValidationError.tooLong(maximumLength: maximumLength)
        }

        let forbiddenCharacters: Set<Character> = [".", "/", "\\", ":", ",", ";", "*", "?"]
        for character: Character in normalizedValue {
            let containsControlCharacter: Bool = character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
            if character.isWhitespace || containsControlCharacter {
                throw ValidationError.containsInvalidCharacter(character)
            }
            if forbiddenCharacters.contains(character) {
                throw ValidationError.containsInvalidCharacter(character)
            }
        }

        return normalizedValue
    }
}

public enum ExtensionListParseError: Error, Equatable, Sendable {
    case emptyInput
    case invalidToken(token: String, reason: FileExtension.ValidationError)
}

public enum ExtensionListParser {
    /// Parses comma-, semicolon-, or whitespace-delimited extensions and removes
    /// duplicates while retaining the user's first-seen order.
    public static func parse(_ input: String) throws -> [FileExtension] {
        let tokens: [Substring] = input.split { character in
            character == "," || character == ";" || character.isWhitespace
        }

        guard !tokens.isEmpty else {
            throw ExtensionListParseError.emptyInput
        }

        var seenExtensions: Set<FileExtension> = []
        var extensions: [FileExtension] = []
        extensions.reserveCapacity(tokens.count)

        for token: Substring in tokens {
            let value: String = String(token)
            let fileExtension: FileExtension
            do {
                fileExtension = try FileExtension(validating: value)
            } catch let error as FileExtension.ValidationError {
                throw ExtensionListParseError.invalidToken(token: value, reason: error)
            }

            if seenExtensions.insert(fileExtension).inserted {
                extensions.append(fileExtension)
            }
        }

        return extensions
    }
}
