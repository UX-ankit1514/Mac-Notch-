import Foundation

/// Adds and removes our hook entries in an agent's JSON hook config without
/// disturbing anything else in it (PRD AC-14).
///
/// Both Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`)
/// use the same shape:
///
///     { "hooks": { "<Event>": [ { "matcher": "…", "hooks": [ { "type": "command", "command": "…" } ] } ] } }
///
/// Our entries are recognised by their command containing `marker` (the
/// installed helper's path). Everything else is preserved byte-for-byte in
/// meaning and order.
public struct HookInstaller: Sendable {
    public enum InstallError: Error, Equatable {
        case unreadable(String)
        case notAnObject
    }

    public struct Plan: Sendable, Equatable {
        public var added: [String]
        public var updated: [String]
        public var removed: [String]
        public var unchanged: [String]
        public var isNoOp: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
    }

    public let configURL: URL
    public let command: String
    public let marker: String
    public let registrations: [HookRegistration]
    public let timeoutSeconds: Int
    public let includeMatcher: Bool

    public init(configURL: URL, helperPath: String, agentArgument: String,
                registrations: [HookRegistration], timeoutSeconds: Int = 10, includeMatcher: Bool = true) {
        self.configURL = configURL
        self.command = "\"\(helperPath)\" \(agentArgument)"
        self.marker = helperPath
        self.registrations = registrations
        self.timeoutSeconds = timeoutSeconds
        self.includeMatcher = includeMatcher
    }

    public static func claudeCode(helperPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HookInstaller {
        HookInstaller(configURL: home.appendingPathComponent(".claude/settings.json"),
                      helperPath: helperPath, agentArgument: AgentKind.claudeCode.rawValue,
                      registrations: ClaudeCodeConnector().hookRegistrations)
    }

    public static func codex(helperPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HookInstaller {
        HookInstaller(configURL: home.appendingPathComponent(".codex/hooks.json"),
                      helperPath: helperPath, agentArgument: AgentKind.codex.rawValue,
                      registrations: CodexConnector().hookRegistrations, includeMatcher: false)
    }

    // MARK: Reading

    func load() throws(InstallError) -> JSONValue {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .object([]) }
        guard let data = FileManager.default.contents(atPath: configURL.path) else {
            throw .unreadable("Can't read \(configURL.path)")
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .object([]) }
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch {
            throw .unreadable("\(configURL.lastPathComponent) isn't valid JSON (\(error)); not touching it")
        }
        guard root.objectPairs != nil else { throw .notAnObject }
        return root
    }

    /// True when every registration is present with the current command.
    public func isInstalled() -> Bool {
        guard let root = try? load(), let hooks = root["hooks"] else { return false }
        return registrations.allSatisfy { reg in
            entries(in: hooks[reg.event]).contains { $0 == command }
        }
    }

    /// True when any of our entries exist (possibly stale).
    public func hasAnyEntries() -> Bool {
        guard let root = try? load(), let hooks = root["hooks"]?.objectPairs else { return false }
        return hooks.contains { pair in entries(in: pair.value).contains { $0.contains(marker) } }
    }

    private func entries(in eventValue: JSONValue?) -> [String] {
        (eventValue?.array ?? []).flatMap { group in
            (group["hooks"]?.array ?? []).compactMap { $0["command"]?.string }
        }
    }

    // MARK: Planning (pure)

    public func installed(into root: JSONValue) -> (JSONValue, Plan) {
        var plan = Plan(added: [], updated: [], removed: [], unchanged: [])
        var hooks = root["hooks"] ?? .object([])
        if hooks.objectPairs == nil { hooks = .object([]) }

        for reg in registrations {
            var groups = hooks[reg.event]?.array ?? []
            let ours = groups.indices.filter { groupContainsMarker(groups[$0]) }
            let current = ours.contains { i in
                groupCommands(groups[i]).contains(command) && groups[i]["matcher"]?.string == effectiveMatcher(reg)
            }
            if current && ours.count == 1 {
                plan.unchanged.append(reg.event)
                continue
            }
            if !ours.isEmpty {
                groups = groups.enumerated().compactMap { i, g in ours.contains(i) ? strippingOurs(g) : g }
                plan.updated.append(reg.event)
            } else {
                plan.added.append(reg.event)
            }
            groups.append(ourGroup(reg))
            hooks = hooks.setting(reg.event, to: .array(groups))
        }
        return (root.setting("hooks", to: hooks), plan)
    }

    public func uninstalled(from root: JSONValue) -> (JSONValue, Plan) {
        var plan = Plan(added: [], updated: [], removed: [], unchanged: [])
        guard var hooks = root["hooks"], let pairs = hooks.objectPairs else { return (root, plan) }
        for (event, value) in pairs {
            guard let groups = value.array, groups.contains(where: groupContainsMarker) else { continue }
            let kept = groups.compactMap { groupContainsMarker($0) ? strippingOurs($0) : $0 }
            hooks = kept.isEmpty ? hooks.removing(event) : hooks.setting(event, to: .array(kept))
            plan.removed.append(event)
        }
        let isEmpty = hooks.objectPairs?.isEmpty ?? true
        return (isEmpty && root["hooks"] != nil && plan.removed.count > 0
                ? root.removing("hooks") : root.setting("hooks", to: hooks), plan)
    }

    private func effectiveMatcher(_ reg: HookRegistration) -> String? {
        includeMatcher ? reg.matcher : nil
    }

    private func ourGroup(_ reg: HookRegistration) -> JSONValue {
        var pairs: [(key: String, value: JSONValue)] = []
        if let matcher = effectiveMatcher(reg) { pairs.append(("matcher", .string(matcher))) }
        pairs.append(("hooks", .array([.object([
            ("type", .string("command")),
            ("command", .string(command)),
            ("timeout", .number(String(timeoutSeconds))),
        ])])))
        return .object(pairs)
    }

    private func groupCommands(_ group: JSONValue) -> [String] {
        (group["hooks"]?.array ?? []).compactMap { $0["command"]?.string }
    }

    private func groupContainsMarker(_ group: JSONValue) -> Bool {
        groupCommands(group).contains { $0.contains(marker) }
    }

    /// Removes only our hook objects from a group; drops the group if nothing else is left.
    private func strippingOurs(_ group: JSONValue) -> JSONValue? {
        let remaining = (group["hooks"]?.array ?? []).filter { !($0["command"]?.string?.contains(marker) ?? false) }
        return remaining.isEmpty ? nil : group.setting("hooks", to: .array(remaining))
    }

    // MARK: Writing

    /// Applies the change with a timestamped backup and an atomic write.
    /// Returns the plan and the backup path (nil if nothing changed).
    @discardableResult
    public func install(now: Date = Date()) throws -> (Plan, URL?) {
        let (updated, plan) = installed(into: try load())
        guard !plan.isNoOp else { return (plan, nil) }
        return (plan, try write(updated, now: now))
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> (Plan, URL?) {
        let (updated, plan) = uninstalled(from: try load())
        guard !plan.isNoOp else { return (plan, nil) }
        return (plan, try write(updated, now: now))
    }

    private func write(_ root: JSONValue, now: Date) throws -> URL? {
        let fm = FileManager.default
        // Write through symlinks (dotfiles setups) instead of replacing the link.
        let target = configURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        var info = stat()
        let exists = stat(target.path, &info) == 0
        var backup: URL?
        if exists {
            let stamp = Self.stampFormatter.string(from: now)
            let url = configURL.deletingLastPathComponent()
                .appendingPathComponent("\(configURL.lastPathComponent).bak-notch-\(stamp)")
            if !fm.fileExists(atPath: url.path) { try fm.copyItem(at: target, to: url) }
            backup = url
        }
        let mode = exists ? Int(info.st_mode & 0o777) : 0o600

        // Same directory, then rename(2): the config is either old or new, never partial.
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).notch-tmp")
        unlink(temp.path)
        guard fm.createFile(atPath: temp.path, contents: Data(root.serialized().utf8),
                            attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return backup
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
