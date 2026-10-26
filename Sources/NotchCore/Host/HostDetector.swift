import Darwin
import Foundation

/// Works out which app the agent is running in by walking up the process
/// tree from the hook. Pure Darwin calls, no AppKit, so the hook stays fast.
public enum HostDetector {
    public struct Result: Sendable {
        public var host: HostInfo
        public var agentPID: Int32?
    }

    /// `agentNames` are executable-name prefixes that identify the agent process.
    public static func detect(agentNames: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Result {
        var host = HostInfo()
        var agentPID: Int32?
        var tty: String?

        var pid = getppid()
        for _ in 0..<40 where pid > 1 {
            let path = executablePath(pid)
            let name = path.map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
            if agentPID == nil, agentNames.contains(where: { name.hasPrefix($0) }) || isAgentPath(path, agentNames) {
                agentPID = pid
            }
            if tty == nil { tty = terminal(of: pid) }
            if let path, let bundle = outermostAppBundle(in: path) {
                host.pid = pid
                host.bundleID = Bundle(path: bundle)?.bundleIdentifier
                host.name = appName(bundlePath: bundle)
                break
            }
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
        }

        if let agentPID, let agentTTY = terminal(of: agentPID) { tty = agentTTY }
        host.tty = tty

        // tmux, ssh or launchd break the chain; fall back to what the terminal advertised.
        if host.bundleID == nil {
            if let id = environment["__CFBundleIdentifier"], !id.isEmpty {
                host.bundleID = id
            } else if let program = environment["TERM_PROGRAM"], let id = bundleID(forTermProgram: program) {
                host.bundleID = id
            }
            if let id = host.bundleID, host.name == nil { host.name = knownName(for: id) }
        }
        return Result(host: host, agentPID: agentPID)
    }

    static func isAgentPath(_ path: String?, _ names: [String]) -> Bool {
        guard let path = path?.lowercased() else { return false }
        // Claude Code's native installer keeps versions under …/claude/versions/<v>.
        return names.contains { path.contains("/\($0)/versions/") || path.contains("/\($0)/releases/") }
    }

    /// "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/…" → the outer app.
    public static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func appName(bundlePath: String) -> String {
        if let info = Bundle(path: bundlePath)?.infoDictionary,
           let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String, !name.isEmpty {
            return name
        }
        return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public static func bundleID(forTermProgram program: String) -> String? {
        switch program {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "WezTerm": "com.github.wez.wezterm"
        default: nil
        }
    }

    public static func knownName(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal": "Terminal"
        case "com.googlecode.iterm2": "iTerm2"
        case "dev.warp.Warp-Stable": "Warp"
        case "com.microsoft.VSCode": "Visual Studio Code"
        case "com.todesktop.230313mzl4w4u92": "Cursor"
        case "com.mitchellh.ghostty": "Ghostty"
        case "com.github.wez.wezterm": "WezTerm"
        default: nil
        }
    }

    // MARK: Darwin process queries

    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parentPID(of pid: Int32) -> Int32? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func terminal(of pid: Int32) -> String? {
        guard let info = kinfo(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, dev != 0, let name = devname(dev, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.hasPrefix("ttys") || tty.hasPrefix("tty") ? "/dev/\(tty)" : nil
    }

    /// Whether a process is still running (used to expire requests from dead agents).
    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Human-readable project identity: the folder name of the git root, else
/// the working directory's own name. Never invents a name.
public enum ProjectName {
    public static func resolve(cwd: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let start = url
        for _ in 0..<24 {
            if url.path == home || url.path == "/" { break }
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        if start.path == home || start.path == "/" { return nil }
        return start.lastPathComponent
    }
}
