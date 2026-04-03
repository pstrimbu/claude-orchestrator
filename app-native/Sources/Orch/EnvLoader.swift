import Foundation

enum EnvLoader {
    static func load(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIdx])
            let value = String(trimmed[trimmed.index(after: eqIdx)...])

            // Only valid env var names
            let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            guard key.unicodeScalars.allSatisfy({ validChars.contains($0) }) else { continue }

            setenv(key, value, 1)
        }
    }
}
