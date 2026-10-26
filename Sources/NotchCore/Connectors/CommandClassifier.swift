import Foundation

/// Classifies a shell command as a build or a test, locally inside the hook.
/// Only the resulting category is forwarded; the command text never leaves.
public enum CommandClassifier {
    public enum Kind: String, Sendable { case build, test }

    // Test runners first: `xcodebuild test` and `make test` must not read as builds.
    private static let testPatterns: [String] = [
        #"\bswift\s+test\b"#,
        #"\bxcodebuild\b.*\btest(-without-building)?\b"#,
        #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?test(:\S+)?\b"#,
        #"\bbun\s+test\b"#,
        #"\b(python3?\s+-m\s+)?pytest\b"#,
        #"\b(npx\s+)?(jest|vitest|mocha|ava)\b"#,
        #"\bplaywright\s+test\b"#,
        #"\bcargo\s+(test|nextest)\b"#,
        #"\bgo\s+test\b"#,
        #"\b(bundle\s+exec\s+)?rspec\b"#,
        #"\b(mvn|mvnw|\./mvnw)\s+(\S+\s+)*test\b"#,
        #"\b(gradle|gradlew|\./gradlew)\s+(\S+\s+)*(test|check)\b"#,
        #"\bmake\s+(\S+\s+)*(test|check)\b"#,
        #"\b(phpunit|ctest|tox|nox)\b"#,
        #"\b(mix|deno|dotnet)\s+test\b"#,
        #"\bpython3?\s+-m\s+unittest\b"#,
    ]

    private static let buildPatterns: [String] = [
        #"\bswift\s+build\b"#,
        #"\bxcodebuild\b"#,
        #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?build(:\S+)?\b"#,
        #"\bcargo\s+(build|check)\b"#,
        #"\bgo\s+(build|vet)\b"#,
        #"\b(npx\s+)?tsc\b"#,
        #"\b(npx\s+)?(vite|next|nuxt|astro|webpack|rollup|esbuild)\s+build\b"#,
        #"\bdocker\s+(compose\s+)?build\b"#,
        #"\bcmake\s+--build\b"#,
        #"\b(bazel|bazelisk|buck2?)\s+build\b"#,
        #"\b(mvn|mvnw|\./mvnw)\s+(\S+\s+)*(compile|package|install|verify)\b"#,
        #"\b(gradle|gradlew|\./gradlew)\s+(\S+\s+)*(build|assemble)\w*\b"#,
        #"(^|[;&|]\s*)make(\s|$)"#,
        #"\b(dotnet|mix)\s+(build|compile)\b"#,
    ]

    private static let tests = testPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    private static let builds = buildPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    public static func classify(_ command: String) -> Kind? {
        let text = command.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        if tests.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return .test }
        if builds.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return .build }
        return nil
    }
}
