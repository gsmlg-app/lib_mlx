import Foundation

/// Exercise JSON's serialization boundary without loading MLX or allocating weights.
@main
struct JSONValueSmoke {
    static func main() throws {
        for input in ["0", "-9223372036854775808", "9223372036854775807",
                      "9223372036854775808", "18446744073709551615"] {
            let original = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])
            let converted = SendableValue(any: original)
            let encoded = try JSONSerialization.data(withJSONObject: converted.anyValue, options: [.fragmentsAllowed])
            let result = String(decoding: encoded, as: UTF8.self)
            guard result == input else {
                FileHandle.standardError.write(Data("JSON number changed: \(input) -> \(result)\n".utf8))
                exit(1)
            }
        }
        print("Five JSON integer boundary round-trips passed (including UInt64.max).")
    }
}
