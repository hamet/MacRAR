// MacRAR — WinRAR-style archive manager for macOS (ZIP + 7z + RAR + tar/tar.gz/tar.bz2)
//   tar family — full support via system bsdtar; add/delete work by repacking the archive.
//   RAR — read/extract/test via `unrar`; add/delete additionally require the
//         proprietary `rar` tool (both: brew install rar). Without them .rar won't open.
// Single-file AppKit app, no dependencies.
// Build:  swiftc -O -o MacRAR MacRAR.swift          (or use build-app.sh to make MacRAR.app)
// Run:    ./MacRAR [archive.zip|archive.7z]
// Requires macOS 11+.
//
// Backends:
//   ZIP — own central-directory parser for listing; /usr/bin/zip + /usr/bin/unzip for operations.
//   7z  — full support (add/delete/extract/test) via 7zz/7z from 7-Zip or p7zip, if installed
//         (brew install sevenzip). Without it: read-only fallback via /usr/bin/tar (bsdtar can
//         read 7z), i.e. list/extract/view/test work, add/delete do not.

import AppKit
import UniformTypeIdentifiers

// MARK: - Little-endian readers

extension Data {
    func le16(_ o: Int) -> UInt16 { UInt16(self[o]) | (UInt16(self[o+1]) << 8) }
    func le32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | (UInt32(self[o+1]) << 8) | (UInt32(self[o+2]) << 16) | (UInt32(self[o+3]) << 24)
    }
    func le64(_ o: Int) -> UInt64 { UInt64(le32(o)) | (UInt64(le32(o+4)) << 32) }
}

// MARK: - Shell helper

@discardableResult
func runTool(_ path: String, _ args: [String], cwd: URL? = nil, discardStdout: Bool = false) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd = cwd { p.currentDirectoryURL = cwd }
    let pipe = Pipe()
    if discardStdout {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = pipe
    } else {
        p.standardOutput = pipe
        p.standardError = pipe
    }
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
}

// MARK: - Preferences (UserDefaults-backed)

enum Pref {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "hideMacJunk": true,          // hide __MACOSX / .DS_Store / ._* in listings
            "skipJunkOnAdd": true,        // BetterZip: "Remove Mac specific stuff from archives"
            "revealAfterExtract": true,   // open destination folder in Finder
            "extractIntoSubfolder": false,// BetterZip: "Create an extra folder" named after archive
            "trashAfterExtract": false,   // BetterZip: "Move archive to Trash"
            "stripQuarantine": true,      // avoid Gatekeeper "could not verify" on double-click
            "compressionLevel": 2,        // 0 Store, 1 Fastest, 2 Normal, 3 Best (WinRAR-style)
            "solidArchives": false,       // WinRAR: "Create solid archive" (7z and RAR only)
        ])
    }
    static var hideMacJunk: Bool { d.bool(forKey: "hideMacJunk") }
    static var skipJunkOnAdd: Bool { d.bool(forKey: "skipJunkOnAdd") }
    static var revealAfterExtract: Bool { d.bool(forKey: "revealAfterExtract") }
    static var extractIntoSubfolder: Bool { d.bool(forKey: "extractIntoSubfolder") }
    static var trashAfterExtract: Bool { d.bool(forKey: "trashAfterExtract") }
    static var stripQuarantine: Bool { d.bool(forKey: "stripQuarantine") }
    static var compressionLevel: Int { d.integer(forKey: "compressionLevel") }
    static var solidArchives: Bool { d.bool(forKey: "solidArchives") }
}

/// Picks the flag for the current compression level from a 4-element table
func compressionChoice(_ options: [String]) -> String {
    options[max(0, min(options.count - 1, Pref.compressionLevel))]
}

/// true for __MACOSX folders, .DS_Store and AppleDouble ._* files anywhere in the path
func isMacJunk(_ path: String) -> Bool {
    for c in path.split(separator: "/") {
        if c == "__MACOSX" || c == ".DS_Store" || c.hasPrefix("._") { return true }
    }
    return false
}

/// Removes macOS service files from a directory tree (used before packing)
func removeMacJunk(in root: URL) {
    let fm = FileManager.default
    var victims: [URL] = []
    if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let u as URL in en {
            let n = u.lastPathComponent
            if n == "__MACOSX" || n == ".DS_Store" || n.hasPrefix("._") { victims.append(u) }
        }
    }
    for v in victims { try? fm.removeItem(at: v) }
}

// MARK: - Archive model

struct ArchiveEntry {
    var name: String            // normalized: directories end with "/"
    var isDirectory: Bool
    var uncompressedSize: UInt64
    var compressedSize: UInt64
    var crc32: UInt32
    var methodString: String
    var modified: Date?
    var encrypted: Bool
}

enum ArchiveError: Error, LocalizedError {
    case passwordRequired
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .passwordRequired: return "Password required"
        case .parse(let s): return s
        }
    }
}

func zipMethodName(_ m: UInt16) -> String {
    switch m {
    case 0: return "Stored"
    case 8: return "Deflated"
    case 9: return "Deflate64"
    case 12: return "BZip2"
    case 14: return "LZMA"
    case 93: return "Zstd"
    case 95: return "XZ"
    case 99: return "AES"
    default: return "Method \(m)"
    }
}

final class Archive {
    enum Kind { case zip, sevenZip, rar, tar }

    let url: URL
    let kind: Kind
    private(set) var entries: [ArchiveEntry] = []
    /// true when 7z is opened via bsdtar fallback (no 7zz installed) — modification unavailable
    private(set) var readOnly = false
    private(set) var backendDescription = ""

    /// Path to 7zz / 7z / 7za binary, if present
    static let sevenZipTool: String? = {
        let candidates = [
            "/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/opt/homebrew/bin/7za",
            "/usr/local/bin/7zz", "/usr/local/bin/7z", "/usr/local/bin/7za",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Path to the proprietary `rar` binary (needed for modifying .rar), if present
    static let rarTool: String? = {
        let candidates = ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Path to `unrar` (list/extract/test), falling back to `rar` which can do the same
    static let unrarTool: String? = {
        let candidates = ["/opt/homebrew/bin/unrar", "/usr/local/bin/unrar"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? rarTool
    }()

    static let tarSuffixes: [String] = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz"]

    /// "tar", "tar+gzip" or "tar+bzip2" depending on the file name
    static func tarVariant(for url: URL) -> String {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz") { return "tar+gzip" }
        if n.hasSuffix(".tar.bz2") || n.hasSuffix(".tbz2") || n.hasSuffix(".tbz") { return "tar+bzip2" }
        return "tar"
    }

    /// bsdtar compression flag for *creating* an archive with this name (reading is auto-detected)
    static func tarCompressionFlags(for url: URL) -> [String] {
        switch tarVariant(for: url) {
        case "tar+gzip": return ["-z"]
        case "tar+bzip2": return ["-j"]
        default: return []
        }
    }

    static func kind(for url: URL) -> Kind {
        let n = url.lastPathComponent.lowercased()
        if tarSuffixes.contains(where: { n.hasSuffix($0) }) { return .tar }
        switch url.pathExtension.lowercased() {
        case "7z": return .sevenZip
        case "rar": return .rar
        default: return .zip
        }
    }

    /// password is used only for 7z archives with encrypted headers
    init(url: URL, password: String?) throws {
        self.url = url
        self.kind = Archive.kind(for: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            switch kind {
            case .zip: backendDescription = "ZIP (new)"
            case .sevenZip: backendDescription = "7z (new)"
            case .rar: backendDescription = "RAR (new)"
            case .tar: backendDescription = "\(Archive.tarVariant(for: url)) (new)"
            }
            return // new archive, not created yet
        }
        switch kind {
        case .zip:
            backendDescription = "ZIP (Info-ZIP)"
            let data = try Data(contentsOf: url, options: [.alwaysMapped])
            try parseZip(data)
        case .sevenZip:
            if let tool = Archive.sevenZipTool {
                backendDescription = "7z (\((tool as NSString).lastPathComponent))"
                try parse7z(tool: tool, password: password)
            } else {
                backendDescription = "7z (bsdtar, read-only)"
                readOnly = true
                try parseTar(label: "7z")
            }
        case .rar:
            guard let lister = Archive.unrarTool else {
                throw ArchiveError.parse("RAR support requires unrar or rar (e.g. `brew install rar`).")
            }
            readOnly = (Archive.rarTool == nil)
            backendDescription = "RAR (\((lister as NSString).lastPathComponent)\(readOnly ? ", read-only" : ""))"
            try parseRar(tool: lister, password: password)
        case .tar:
            backendDescription = "\(Archive.tarVariant(for: url)) (bsdtar)"
            try parseTar(label: Archive.tarVariant(for: url))
        }
    }

    // MARK: ZIP central directory

    private func parseZip(_ data: Data) throws {
        let minEOCD = 22
        guard data.count >= minEOCD else { return }
        var eocd = -1
        let scanStart = max(0, data.count - minEOCD - 65535)
        var i = data.count - minEOCD
        while i >= scanStart {
            if data.le32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.parse("Not a ZIP archive (no end-of-central-directory record).") }
        var total = UInt64(data.le16(eocd + 10))
        var cdOffset = UInt64(data.le32(eocd + 16))
        if total == 0xFFFF || cdOffset == 0xFFFFFFFF {
            let locator = eocd - 20
            if locator >= 0, data.le32(locator) == 0x07064b50 {
                let z64 = Int(data.le64(locator + 8))
                if z64 >= 0, z64 + 56 <= data.count, data.le32(z64) == 0x06064b50 {
                    total = data.le64(z64 + 32)
                    cdOffset = data.le64(z64 + 48)
                }
            }
        }
        var off = Int(cdOffset)
        var parsed: [ArchiveEntry] = []
        var count: UInt64 = 0
        while count < total, off + 46 <= data.count, data.le32(off) == 0x02014b50 {
            let flags = data.le16(off + 8)
            let method = data.le16(off + 10)
            let dosTime = data.le16(off + 12)
            let dosDate = data.le16(off + 14)
            let crc = data.le32(off + 16)
            var csize = UInt64(data.le32(off + 20))
            var usize = UInt64(data.le32(off + 24))
            let nameLen = Int(data.le16(off + 28))
            let extraLen = Int(data.le16(off + 30))
            let commentLen = Int(data.le16(off + 32))
            let externalAttr = data.le32(off + 38)
            guard off + 46 + nameLen + extraLen <= data.count else { break }

            let nameData = data.subdata(in: (off + 46)..<(off + 46 + nameLen))
            let utf8 = (flags & 0x800) != 0
            var name = String(data: nameData, encoding: utf8 ? .utf8 : .isoLatin1)
                ?? String(data: nameData, encoding: .utf8) ?? "?"

            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF {
                var e = off + 46 + nameLen
                let end = e + extraLen
                while e + 4 <= end {
                    let id = data.le16(e), sz = Int(data.le16(e + 2))
                    if id == 0x0001 {
                        var f = e + 4
                        if usize == 0xFFFFFFFF, f + 8 <= end { usize = data.le64(f); f += 8 }
                        if csize == 0xFFFFFFFF, f + 8 <= end { csize = data.le64(f); f += 8 }
                        break
                    }
                    e += 4 + sz
                }
            }

            let isDir = name.hasSuffix("/") || (externalAttr & 0x10) != 0
            if isDir && !name.hasSuffix("/") { name += "/" }
            var comps = DateComponents()
            comps.year = 1980 + Int(dosDate >> 9)
            comps.month = Int((dosDate >> 5) & 0xF)
            comps.day = Int(dosDate & 0x1F)
            comps.hour = Int(dosTime >> 11)
            comps.minute = Int((dosTime >> 5) & 0x3F)
            comps.second = Int(dosTime & 0x1F) * 2
            let date = Calendar.current.date(from: comps)

            parsed.append(ArchiveEntry(name: name, isDirectory: isDir,
                                       uncompressedSize: usize, compressedSize: csize,
                                       crc32: crc, methodString: zipMethodName(method),
                                       modified: date, encrypted: (flags & 1) != 0))
            off += 46 + nameLen + extraLen + commentLen
            count += 1
        }
        entries = parsed
    }

    // MARK: 7z via 7zz (machine-readable `l -slt` listing)

    private func parse7z(tool: String, password: String?) throws {
        // "-p<pwd>" (or bare "-p" = empty password) keeps 7z non-interactive with encrypted headers
        let res = runTool(tool, ["l", "-slt", "-p\(password ?? "")", url.path])
        if res.status != 0 {
            let low = res.output.lowercased()
            if low.contains("password") || low.contains("cannot open encrypted") {
                throw ArchiveError.passwordRequired
            }
            throw ArchiveError.parse(res.output)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var parsed: [ArchiveEntry] = []
        var inEntries = false
        var cur: [String: String] = [:]
        func flush() {
            defer { cur = [:] }
            guard var name = cur["Path"], !name.isEmpty else { return }
            name = name.replacingOccurrences(of: "\\", with: "/")
            let attrs = cur["Attributes"] ?? ""
            let isDir = attrs.hasPrefix("D") || cur["Folder"] == "+"
            if isDir && !name.hasSuffix("/") { name += "/" }
            let size = UInt64(cur["Size"] ?? "") ?? 0
            let packed = UInt64(cur["Packed Size"] ?? "") ?? 0   // per solid block; often 0 for members
            let crc = UInt32(cur["CRC"] ?? "", radix: 16) ?? 0
            var date: Date? = nil
            if let m = cur["Modified"], m.count >= 19 { date = fmt.date(from: String(m.prefix(19))) }
            parsed.append(ArchiveEntry(name: name, isDirectory: isDir,
                                       uncompressedSize: size, compressedSize: packed,
                                       crc32: crc, methodString: cur["Method"] ?? "LZMA",
                                       modified: date, encrypted: cur["Encrypted"] == "+"))
        }
        for raw in res.output.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("----------") { inEntries = true; continue }
            guard inEntries else { continue }
            if line.isEmpty { flush(); continue }
            if let r = line.range(of: " = ") {
                cur[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
            }
        }
        flush()
        entries = parsed
    }

    // MARK: RAR via unrar `lt` (verbose technical listing, "Key: value" blocks)

    private func parseRar(tool: String, password: String?) throws {
        // "-p-" disables the interactive password prompt so we fail fast instead of hanging
        let res = runTool(tool, ["lt", password != nil ? "-p\(password!)" : "-p-", url.path])
        if res.status != 0 {
            if res.output.lowercased().contains("password") { throw ArchiveError.passwordRequired }
            throw ArchiveError.parse(res.output)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var parsed: [ArchiveEntry] = []
        var cur: [String: String] = [:]
        func flush() {
            defer { cur = [:] }
            guard var name = cur["Name"], !name.isEmpty else { return } // header blocks lack "Name"
            name = name.replacingOccurrences(of: "\\", with: "/")
            let isDir = cur["Type"] == "Directory"
            if isDir && !name.hasSuffix("/") { name += "/" }
            var date: Date? = nil
            if let m = cur["mtime"] ?? cur["Modified"], m.count >= 19 {
                date = fmt.date(from: String(m.prefix(19)))
            }
            let flags = (cur["Flags"] ?? "").lowercased()
            parsed.append(ArchiveEntry(name: name, isDirectory: isDir,
                                       uncompressedSize: UInt64(cur["Size"] ?? "") ?? 0,
                                       compressedSize: UInt64(cur["Packed size"] ?? "") ?? 0,
                                       crc32: UInt32(cur["CRC32"] ?? "", radix: 16) ?? 0,
                                       methodString: cur["Compression"] ?? "RAR",
                                       modified: date,
                                       encrypted: flags.contains("encrypted")))
        }
        for raw in res.output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let r = line.range(of: ": ") {
                cur[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
            }
        }
        flush()
        entries = parsed
    }

    // MARK: tar family (and 7z fallback) via bsdtar

    private func parseTar(label: String) throws {
        let res = runTool("/usr/bin/tar", ["-tvf", url.path])
        if res.status != 0 { throw ArchiveError.parse(res.output) }
        // bsdtar -tv line: "-rw-r--r--  0 user group   1234 Aug 29 10:00 path/name"
        let pattern = "^(\\S+)\\s+\\S+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+(\\S+\\s+\\S+\\s+\\S+)\\s+(.+)$"
        let re = try? NSRegularExpression(pattern: pattern)
        let fmtTime = DateFormatter(); fmtTime.locale = Locale(identifier: "en_US_POSIX")
        fmtTime.dateFormat = "MMM d HH:mm yyyy"
        let fmtYear = DateFormatter(); fmtYear.locale = Locale(identifier: "en_US_POSIX")
        fmtYear.dateFormat = "MMM d yyyy"
        let thisYear = Calendar.current.component(.year, from: Date())

        var parsed: [ArchiveEntry] = []
        for raw in res.output.components(separatedBy: "\n") where !raw.isEmpty {
            let ns = raw as NSString
            var mode = "", sizeStr = "", dateStr = "", name = raw
            if let m = re?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 5 {
                mode = ns.substring(with: m.range(at: 1))
                sizeStr = ns.substring(with: m.range(at: 2))
                dateStr = ns.substring(with: m.range(at: 3))
                name = ns.substring(with: m.range(at: 4))
            }
            var isDir = mode.hasPrefix("d") || name.hasSuffix("/")
            if name.hasSuffix("/") { isDir = true } else if isDir { name += "/" }
            let squashed = dateStr.replacingOccurrences(of: "  ", with: " ")
            var date = fmtYear.date(from: squashed)
            if date == nil { date = fmtTime.date(from: squashed + " \(thisYear)") }
            parsed.append(ArchiveEntry(name: name, isDirectory: isDir,
                                       uncompressedSize: UInt64(sizeStr) ?? 0, compressedSize: 0,
                                       crc32: 0, methodString: label,
                                       modified: date, encrypted: false))
        }
        entries = parsed
    }
}

// MARK: - Row model (what the table shows for the current folder)

struct Row {
    var name: String        // display name (last path component)
    var fullPath: String    // path inside archive ("" for "..")
    var isDir: Bool
    var isUp: Bool = false
    var entry: ArchiveEntry?
}

// MARK: - Main controller

final class MainController: NSObject, NSApplicationDelegate, NSWindowDelegate,
                            NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate,
                            NSSearchFieldDelegate, NSFilePromiseProviderDelegate {

    var window: NSWindow!
    var table: NSTableView!
    var pathField: NSTextField!
    var statusField: NSTextField!
    var searchField: NSSearchField!

    var archive: Archive?
    var archiveURL: URL?
    var currentPath = ""          // "" = root, otherwise "dir/sub/"
    var rows: [Row] = []
    var filter = ""
    var sortKey = "name"
    var sortAscending = true
    var lastPassword: String?
    var pendingOpen: URL?
    let promiseQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q
    }()

    let sizeFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "
        return f
    }()
    let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let url = pendingOpen {
            openArchive(url)
        } else {
            let args = CommandLine.arguments
            if args.count > 1 { openArchive(URL(fileURLWithPath: args[1])) }
        }
        updateStatus()
    }

    // Finder double-click / "Open With" (works when packaged as MacRAR.app)
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if window == nil { pendingOpen = url } else { openArchive(url) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingOpen = url } else { openArchive(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu

    func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacRAR",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacRAR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Archive…", action: #selector(newArchive), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Archive…", action: #selector(openArchiveDialog), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let cmdItem = NSMenuItem(); mainMenu.addItem(cmdItem)
        let cmdMenu = NSMenu(title: "Commands")
        cmdMenu.addItem(withTitle: "Add Files…", action: #selector(addFilesAction), keyEquivalent: "a")
        cmdMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        cmdMenu.addItem(withTitle: "Extract To…", action: #selector(extractAction), keyEquivalent: "e")
        cmdMenu.addItem(withTitle: "Test Archive", action: #selector(testAction), keyEquivalent: "t")
        cmdMenu.addItem(withTitle: "View File", action: #selector(viewAction), keyEquivalent: "v")
        cmdMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        cmdMenu.addItem(withTitle: "Delete", action: #selector(deleteAction), keyEquivalent: "\u{08}")
        cmdMenu.addItem(withTitle: "Archive Info", action: #selector(infoAction), keyEquivalent: "i")
        cmdItem.submenu = cmdMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Window / UI

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MacRAR"
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacRARMain")

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // Path bar
        let upButton = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Up")!,
                                target: self, action: #selector(goUp))
        upButton.bezelStyle = .texturedRounded
        pathField = NSTextField(labelWithString: "")
        pathField.font = NSFont.systemFont(ofSize: 12)
        pathField.lineBreakMode = .byTruncatingHead
        let pathBar = NSStackView(views: [upButton, pathField])
        pathBar.orientation = .horizontal
        pathBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 2, right: 8)

        // Table
        table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 20
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.fileURL])                        // drop from Finder = Add
        table.setDraggingSourceOperationMask(.copy, forLocal: false)     // drag out to Finder = Extract
        table.columnAutoresizingStyle = .noColumnAutoresizing

        addColumn("name", "Name", 300)
        addColumn("size", "Size", 90, right: true)
        addColumn("packed", "Packed", 90, right: true)
        addColumn("type", "Type", 150)
        addColumn("modified", "Modified", 130)
        addColumn("crc", "CRC32", 80)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // Status bar
        statusField = NSTextField(labelWithString: "")
        statusField.font = NSFont.systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        let statusBar = NSStackView(views: [statusField])
        statusBar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 4, right: 10)

        let content = NSStackView(views: [pathBar, scroll, statusBar])
        content.orientation = .vertical
        content.spacing = 2
        content.distribution = .fill
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        refreshPathBar()
    }

    func addColumn(_ id: String, _ title: String, _ width: CGFloat, right: Bool = false) {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title
        c.width = width
        c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        if right { c.headerCell.alignment = .right }
        table.addTableColumn(c)
    }

    // MARK: Toolbar

    enum TB: String, CaseIterable {
        case add, extract, test, view, delete, info
        var label: String {
            switch self {
            case .add: return "Add"
            case .extract: return "Extract To"
            case .test: return "Test"
            case .view: return "View"
            case .delete: return "Delete"
            case .info: return "Info"
            }
        }
        var symbol: String {
            switch self {
            case .add: return "plus.rectangle.on.folder"
            case .extract: return "tray.and.arrow.down"
            case .test: return "checkmark.seal"
            case .view: return "eye"
            case .delete: return "trash"
            case .info: return "info.circle"
            }
        }
        var action: Selector {
            switch self {
            case .add: return #selector(MainController.addFilesAction)
            case .extract: return #selector(MainController.extractAction)
            case .test: return #selector(MainController.testAction)
            case .view: return #selector(MainController.viewAction)
            case .delete: return #selector(MainController.deleteAction)
            case .info: return #selector(MainController.infoAction)
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        TB.allCases.map { NSToolbarItem.Identifier($0.rawValue) } +
        [.flexibleSpace, NSToolbarItem.Identifier("search")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.placeholderString = "Find"
            searchField = item.searchField
            return item
        }
        guard let tb = TB(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tb.label
        item.image = NSImage(systemSymbolName: tb.symbol, accessibilityDescription: tb.label)
        item.target = self
        item.action = tb.action
        item.isBordered = true
        return item
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField {
            filter = searchField.stringValue
            reloadRows()
        }
    }

    // MARK: Archive open / reload

    var openableTypes: [UTType] {
        var t: [UTType] = [.zip]
        for ext in ["7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "tbz"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }

    @objc func openArchiveDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = openableTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openArchive(url) }
    }

    @objc func newArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = openableTypes
        panel.nameFieldStringValue = "Archive.zip"
        // Format chooser (7z creation only when 7zz is installed)
        var formats = ["zip", "tar", "tar.gz", "tar.bz2"]
        if Archive.sevenZipTool != nil { formats.append("7z") }
        if Archive.rarTool != nil { formats.append("rar") }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        popup.addItems(withTitles: formats.map { "Format: " + $0.uppercased() })
        if formats.count > 1 {
            panel.accessoryView = popup
        }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        let ext = formats[max(0, popup.indexOfSelectedItem)]
        if !url.lastPathComponent.lowercased().hasSuffix("." + ext) {
            var base = url.deletingPathExtension()
            if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() } // name.tar.bz2 case
            url = URL(fileURLWithPath: base.path + "." + ext)
        }
        try? FileManager.default.removeItem(at: url)
        archiveURL = url
        currentPath = ""
        lastPassword = nil
        reloadArchive()
    }

    func openArchive(_ url: URL) {
        if Pref.stripQuarantine {
            // avoids the Gatekeeper "Apple could not verify…" warning on future double-clicks
            runTool("/usr/bin/xattr", ["-d", "com.apple.quarantine", url.path])
        }
        archiveURL = url
        currentPath = ""
        lastPassword = nil
        reloadArchive()
    }

    func reloadArchive() {
        guard let url = archiveURL else { return }
        do {
            archive = try Archive(url: url, password: lastPassword)
        } catch ArchiveError.passwordRequired {
            lastPassword = nil
            guard let pwd = askPassword() else { archive = nil; reloadRows(); return }
            lastPassword = pwd
            do { archive = try Archive(url: url, password: pwd) }
            catch { archive = nil; alert("Cannot open archive", error.localizedDescription) }
        } catch {
            archive = nil
            alert("Cannot open archive", error.localizedDescription)
        }
        if let a = archive {
            window.title = "MacRAR — \(url.lastPathComponent)" + (a.readOnly ? "  [read-only]" : "")
        }
        while !currentPath.isEmpty && !folderExists(currentPath) { goUpOneLevel() }
        reloadRows()
    }

    func folderExists(_ path: String) -> Bool {
        guard let a = archive else { return false }
        return a.entries.contains { $0.name.hasPrefix(path) }
    }

    // MARK: Rows for current folder

    func reloadRows() {
        var dirs: [String: Row] = [:]
        var files: [Row] = []
        if let a = archive {
            for e in a.entries {
                if Pref.hideMacJunk && isMacJunk(e.name) { continue }
                guard e.name.hasPrefix(currentPath), e.name != currentPath else { continue }
                let rest = String(e.name.dropFirst(currentPath.count))
                guard !rest.isEmpty else { continue }
                let comps = rest.split(separator: "/", omittingEmptySubsequences: false)
                let first = String(comps[0])
                let isChildDir = comps.count > 1 || e.isDirectory
                if isChildDir {
                    let full = currentPath + first + "/"
                    if dirs[first] == nil {
                        let dirEntry = (e.name == full && e.isDirectory) ? e : nil
                        dirs[first] = Row(name: first, fullPath: full, isDir: true, entry: dirEntry)
                    } else if e.name == full && e.isDirectory {
                        dirs[first]?.entry = e
                    }
                } else {
                    files.append(Row(name: first, fullPath: e.name, isDir: false, entry: e))
                }
            }
        }
        var list = Array(dirs.values) + files
        if !filter.isEmpty {
            list = list.filter { $0.name.range(of: filter, options: .caseInsensitive) != nil }
        }
        list.sort { a, b in
            if a.isDir != b.isDir { return a.isDir } // folders first, always
            let r: Bool
            switch sortKey {
            case "size":     r = (a.entry?.uncompressedSize ?? 0) < (b.entry?.uncompressedSize ?? 0)
            case "packed":   r = (a.entry?.compressedSize ?? 0) < (b.entry?.compressedSize ?? 0)
            case "modified": r = (a.entry?.modified ?? .distantPast) < (b.entry?.modified ?? .distantPast)
            case "crc":      r = (a.entry?.crc32 ?? 0) < (b.entry?.crc32 ?? 0)
            case "type":     r = typeString(a) < typeString(b)
            default:         r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sortAscending ? r : !r
        }
        if !currentPath.isEmpty {
            list.insert(Row(name: "..", fullPath: "", isDir: true, isUp: true), at: 0)
        }
        rows = list
        table.reloadData()
        refreshPathBar()
        updateStatus()
    }

    func refreshPathBar() {
        let name = archiveURL?.lastPathComponent ?? "(no archive)"
        pathField.stringValue = name + (currentPath.isEmpty ? "" : "  ▸  " + currentPath)
    }

    func updateStatus() {
        guard archive != nil || archiveURL != nil else {
            statusField.stringValue = "Open an archive (⌘O) or create a new one (⌘N)"
            return
        }
        let visible = rows.filter { !$0.isUp }
        let files = visible.filter { !$0.isDir }
        let total = files.reduce(UInt64(0)) { $0 + ($1.entry?.uncompressedSize ?? 0) }
        let sel = selectedRows()
        var s = "\(visible.count) item(s), \(fmtSize(total)) bytes"
        if !sel.isEmpty {
            let selTotal = sel.reduce(UInt64(0)) { $0 + ($1.entry?.uncompressedSize ?? 0) }
            s = "Selected: \(sel.count) item(s), \(fmtSize(selTotal)) bytes — " + s
        }
        if let a = archive, a.readOnly {
            s += a.kind == .rar
                ? "   |   RAR read-only mode: install `rar` (brew install rar) to add/delete"
                : "   |   7z read-only mode: install 7-Zip (brew install sevenzip) to add/delete"
        }
        statusField.stringValue = s
    }

    func fmtSize(_ v: UInt64) -> String {
        sizeFmt.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    func typeString(_ r: Row) -> String {
        if r.isUp { return "" }
        if r.isDir { return "Folder" }
        let ext = (r.name as NSString).pathExtension
        if !ext.isEmpty, let t = UTType(filenameExtension: ext), let d = t.localizedDescription {
            return d.prefix(1).uppercased() + d.dropFirst()
        }
        return ext.isEmpty ? "File" : ext.uppercased() + " file"
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let id = col.identifier.rawValue
        let reuse = NSUserInterfaceItemIdentifier("cell-" + id)
        var cell = table.makeView(withIdentifier: reuse, owner: self) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell!.identifier = reuse
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell!.textField = tf
            cell!.addSubview(tf)
            if id == "name" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell!.imageView = iv
                cell!.addSubview(iv)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                ])
                if id == "size" || id == "packed" { tf.alignment = .right }
            }
        }
        let tf = cell!.textField!
        switch id {
        case "name":
            var title = r.name
            if r.entry?.encrypted == true { title += " *" }
            tf.stringValue = title
            let icon: NSImage
            if r.isUp {
                icon = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: nil)!
            } else if r.isDir {
                icon = NSWorkspace.shared.icon(for: .folder)
            } else {
                let ext = (r.name as NSString).pathExtension
                let t = UTType(filenameExtension: ext) ?? .data
                icon = NSWorkspace.shared.icon(for: t)
            }
            cell!.imageView?.image = icon
        case "size":
            tf.stringValue = (r.isDir || r.isUp) ? "" : fmtSize(r.entry?.uncompressedSize ?? 0)
        case "packed":
            let packed = r.entry?.compressedSize ?? 0
            tf.stringValue = (r.isDir || r.isUp || packed == 0) ? "" : fmtSize(packed)
        case "type":
            tf.stringValue = typeString(r)
        case "modified":
            if let d = r.entry?.modified { tf.stringValue = dateFmt.string(from: d) } else { tf.stringValue = "" }
        case "crc":
            if let e = r.entry, !r.isDir, e.crc32 != 0 { tf.stringValue = String(format: "%08X", e.crc32) }
            else { tf.stringValue = "" }
        default:
            tf.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        sortAscending = d.ascending
        reloadRows()
    }

    // MARK: Drag & drop IN (add files by dropping onto the list)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // ignore our own drags
        if (info.draggingSource as? NSTableView) === table { return [] }
        return (archiveURL != nil && archive?.readOnly != true) ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        addFiles(urls)
        return true
    }

    // MARK: Drag OUT (drag entries to Finder = extract, via file promises)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        let r = rows[row]
        guard !r.isUp, archiveURL != nil else { return nil }
        let typeId: String
        if r.isDir {
            typeId = UTType.folder.identifier
        } else {
            let ext = (r.name as NSString).pathExtension
            typeId = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        }
        let provider = NSFilePromiseProvider(fileType: typeId, delegate: self)
        provider.userInfo = ["path": r.fullPath, "isDir": r.isDir, "name": r.name]
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? [String: Any])?["name"] as? String ?? "file"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let info = filePromiseProvider.userInfo as? [String: Any],
              let path = info["path"] as? String,
              let isDir = info["isDir"] as? Bool else {
            completionHandler(nil); return
        }
        let row = Row(name: (path as NSString).lastPathComponent, fullPath: path, isDir: isDir, entry: nil)
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macrar-drag-" + UUID().uuidString)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let res = extractSync([row], to: tmp)
        let inner = isDir ? String(path.dropLast()) : path
        let src = tmp.appendingPathComponent(inner)
        guard fm.fileExists(atPath: src.path) else {
            completionHandler(NSError(domain: "MacRAR", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Extraction failed: \(res.output)"]))
            return
        }
        do {
            try? fm.removeItem(at: url)
            try fm.moveItem(at: src, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    // MARK: Navigation

    @objc func doubleClicked() {
        let idx = table.clickedRow
        guard rows.indices.contains(idx) else { return }
        let r = rows[idx]
        if r.isUp { goUp(); return }
        if r.isDir {
            currentPath = r.fullPath
            reloadRows()
        } else {
            viewRow(r) // double-click on a file: extract to temp and open with default app
        }
    }

    @objc func goUp() {
        guard !currentPath.isEmpty else { return }
        goUpOneLevel()
        reloadRows()
    }

    func goUpOneLevel() {
        var comps = currentPath.split(separator: "/").map(String.init)
        if !comps.isEmpty { comps.removeLast() }
        currentPath = comps.isEmpty ? "" : comps.joined(separator: "/") + "/"
    }

    // MARK: Selection helpers

    func selectedRows() -> [Row] {
        table.selectedRowIndexes
            .compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            .filter { !$0.isUp }
    }

    /// unzip/zip wildcard patterns for the selected rows (folder -> subtree)
    func zipPatterns(for sel: [Row]) -> [String] {
        sel.flatMap { r -> [String] in
            r.isDir ? [r.fullPath, r.fullPath + "*"] : [r.fullPath]
        }
    }

    /// Explicit list of entry paths (folders expanded to their contents) for 7z/tar backends
    func explicitPaths(for sel: [Row], stripDirSlash: Bool) -> [String] {
        guard let a = archive else { return sel.map { $0.fullPath } }
        var out: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            let v = (stripDirSlash && s.hasSuffix("/")) ? String(s.dropLast()) : s
            if seen.insert(v).inserted { out.append(v) }
        }
        for r in sel {
            if r.isDir {
                push(r.fullPath)
                for e in a.entries where e.name.hasPrefix(r.fullPath) { push(e.name) }
            } else {
                push(r.fullPath)
            }
        }
        return out
    }

    // MARK: Core operations (backend routing)

    /// Synchronous extraction of selected rows (or everything, if empty) into `dest`.
    /// Safe to call from a background queue; password prompt hops to the main thread.
    func extractSync(_ sel: [Row], to dest: URL) -> (status: Int32, output: String) {
        guard let a = archive, let url = archiveURL else { return (-1, "No archive") }
        let needsPwd = a.entries.contains { $0.encrypted } || lastPassword != nil
        var pwd: String? = lastPassword
        if needsPwd && pwd == nil {
            pwd = askPasswordOnMain()
            if pwd == nil { return (-1, "Cancelled") }
        }
        switch a.kind {
        case .zip:
            var args = ["-o", "-q"]
            if let p = pwd { args += ["-P", p] }
            args += [url.path] + zipPatterns(for: sel) + ["-d", dest.path]
            return runTool("/usr/bin/unzip", args)
        case .sevenZip:
            if let tool = Archive.sevenZipTool {
                var args = ["x", "-y", "-o\(dest.path)"]
                if let p = pwd { args.append("-p\(p)") }
                args.append(url.path)
                args += explicitPaths(for: sel, stripDirSlash: true)
                return runTool(tool, args)
            } else {
                var args = ["-x", "-f", url.path, "-C", dest.path]
                args += explicitPaths(for: sel, stripDirSlash: false)
                return runTool("/usr/bin/tar", args)
            }
        case .rar:
            guard let tool = Archive.unrarTool else { return (-1, "unrar not installed") }
            var args = ["x", "-y", "-o+", pwd != nil ? "-p\(pwd!)" : "-p-", url.path]
            args += explicitPaths(for: sel, stripDirSlash: true)
            args.append(dest.path.hasSuffix("/") ? dest.path : dest.path + "/") // unrar wants trailing /
            return runTool(tool, args)
        case .tar:
            var args = ["-x", "-f", url.path, "-C", dest.path] // compression auto-detected on read
            args += explicitPaths(for: sel, stripDirSlash: false)
            return runTool("/usr/bin/tar", args)
        }
    }

    /// Rebuilds a tar archive (plain/gz/bz2): extract existing content into a temp tree,
    /// apply `mutate` to it, then re-create the archive with the right compression and
    /// atomically replace the original. tar can't delete or append-to-compressed in place.
    func repackTarSync(mutate: (URL) -> (Int32, String)?) -> (status: Int32, output: String) {
        guard let url = archiveURL else { return (-1, "No archive") }
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macrar-tar-" + UUID().uuidString)
        let tree = work.appendingPathComponent("tree")
        do { try fm.createDirectory(at: tree, withIntermediateDirectories: true) }
        catch { return (-1, error.localizedDescription) }
        defer { try? fm.removeItem(at: work) }
        if fm.fileExists(atPath: url.path) {
            let res = runTool("/usr/bin/tar", ["-xf", url.path, "-C", tree.path])
            if res.status != 0 { return res }
        }
        if let err = mutate(tree) { return err }
        let items = (try? fm.contentsOfDirectory(atPath: tree.path)) ?? []
        let newArc = work.appendingPathComponent("new-" + url.lastPathComponent)
        var args = ["-c"] + Archive.tarCompressionFlags(for: url) + ["-f", newArc.path]
        switch Archive.tarVariant(for: url) { // level via libarchive options (Store maps to 1, the minimum)
        case "tar+gzip":  args = ["--options", "gzip:compression-level=\(compressionChoice(["1", "1", "6", "9"]))"] + args
        case "tar+bzip2": args = ["--options", "bzip2:compression-level=\(compressionChoice(["1", "1", "6", "9"]))"] + args
        default: break
        }
        args += items.isEmpty ? ["-T", "/dev/null"] : items // -T /dev/null = valid empty archive
        let res = runTool("/usr/bin/tar", args, cwd: tree)
        if res.status != 0 { return res }
        do {
            try? fm.removeItem(at: url)
            try fm.moveItem(at: newArc, to: url)
        } catch { return (-1, error.localizedDescription) }
        return (0, "")
    }

    func modificationAllowed() -> Bool {
        if archive?.readOnly == true {
            let hint: String
            switch archive?.kind {
            case .rar:
                hint = "Only `unrar` was found — it can extract but not modify RAR archives. Modifying .rar requires the proprietary `rar` tool (brew install rar)."
            default:
                hint = "Modifying .7z requires 7-Zip. Install it (e.g. `brew install sevenzip` — sources: github.com/ip7z/7zip) and reopen the archive."
            }
            alert("Read-only archive", hint)
            return false
        }
        return true
    }

    // MARK: Actions

    @objc func addFilesAction() {
        guard ensureArchive(), modificationAllowed() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func addFiles(_ urls: [URL]) {
        guard let zipURL = archiveURL, !urls.isEmpty, modificationAllowed() else { return }
        let kind = archive?.kind ?? Archive.kind(for: zipURL)
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macrar-" + UUID().uuidString)
        let dest = currentPath.isEmpty ? tmp : tmp.appendingPathComponent(currentPath)
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) }
        catch { alert("Add failed", error.localizedDescription); return }

        busy("Adding \(urls.count) item(s)…") {
            if kind == .tar {
                try? fm.removeItem(at: tmp) // staging dir not needed for repack
                return self.repackTarSync { tree in
                    let dest2 = self.currentPath.isEmpty ? tree : tree.appendingPathComponent(self.currentPath)
                    do { try fm.createDirectory(at: dest2, withIntermediateDirectories: true) }
                    catch { return (-1, error.localizedDescription) }
                    for u in urls {
                        if Pref.skipJunkOnAdd && (u.lastPathComponent == ".DS_Store" || u.lastPathComponent.hasPrefix("._")) { continue }
                        let target = dest2.appendingPathComponent(u.lastPathComponent)
                        runTool("/usr/bin/ditto", [u.path, target.path])
                        if Pref.skipJunkOnAdd { removeMacJunk(in: target) }
                    }
                    return nil
                }
            }
            for u in urls {
                if Pref.skipJunkOnAdd && (u.lastPathComponent == ".DS_Store" || u.lastPathComponent.hasPrefix("._")) { continue }
                let target = dest.appendingPathComponent(u.lastPathComponent)
                runTool("/usr/bin/ditto", [u.path, target.path])
                if Pref.skipJunkOnAdd { removeMacJunk(in: target) }
            }
            let firstComps: [String]
            if self.currentPath.isEmpty {
                firstComps = urls.map { $0.lastPathComponent }
            } else {
                firstComps = [String(self.currentPath.split(separator: "/").first!)]
            }
            let res: (Int32, String)
            switch kind {
            case .zip:
                let lvl = compressionChoice(["-0", "-1", "-6", "-9"])
                res = runTool("/usr/bin/zip", ["-r", "-q", lvl, zipURL.path] + firstComps, cwd: tmp)
            case .sevenZip:
                let tool = Archive.sevenZipTool! // guarded by modificationAllowed()
                let lvl = compressionChoice(["-mx=0", "-mx=1", "-mx=5", "-mx=9"])
                let solid = Pref.solidArchives ? "-ms=on" : "-ms=off" // 7z is solid by default, so set explicitly
                res = runTool(tool, ["a", "-y", lvl, solid, zipURL.path] + firstComps, cwd: tmp)
            case .rar:
                let tool = Archive.rarTool! // guarded by modificationAllowed()
                let lvl = compressionChoice(["-m0", "-m1", "-m3", "-m5"])
                let solid = Pref.solidArchives ? "-s" : "-s-"
                res = runTool(tool, ["a", "-r", "-y", lvl, solid, zipURL.path] + firstComps, cwd: tmp)
            case .tar:
                res = (-1, "unreachable — handled by repack above")
            }
            try? fm.removeItem(at: tmp)
            return res
        } done: { res in
            if res.status != 0 { self.alert("Add failed", res.output) }
            self.reloadArchive()
        }
    }

    @objc func extractAction() {
        guard archiveURL != nil, archive != nil else { return }
        let sel = selectedRows()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        panel.message = sel.isEmpty ? "Extract entire archive to:" : "Extract \(sel.count) selected item(s) to:"
        guard panel.runModal() == .OK, var dest = panel.url else { return }
        if Pref.extractIntoSubfolder {
            dest = dest.appendingPathComponent(archiveBaseName())
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        }
        busy("Extracting…") {
            self.extractSync(sel, to: dest)
        } done: { res in
            if res.status == 0 || res.status == 1 { // unzip: 1 = warnings only
                if Pref.revealAfterExtract { NSWorkspace.shared.open(dest) }
                if Pref.trashAfterExtract { self.trashCurrentArchive() }
            } else if res.output != "Cancelled" {
                self.alert("Extraction failed", res.output)
            }
        }
    }

    @objc func testAction() {
        guard let a = archive, let url = archiveURL else { return }
        let pwd = lastPassword
        busy("Testing archive…") {
            switch a.kind {
            case .zip:
                var args = ["-t", "-q"]
                if a.entries.contains(where: { $0.encrypted }) {
                    guard let p = pwd ?? self.askPasswordOnMain() else { return (-1, "Cancelled") }
                    args += ["-P", p]
                }
                return runTool("/usr/bin/unzip", args + [url.path])
            case .sevenZip:
                if let tool = Archive.sevenZipTool {
                    return runTool(tool, ["t", "-p\(pwd ?? "")", url.path])
                } else {
                    // bsdtar: full decode to /dev/null is an integrity test
                    return runTool("/usr/bin/tar", ["-xf", url.path, "-O"], discardStdout: true)
                }
            case .rar:
                guard let tool = Archive.unrarTool else { return (-1, "unrar not installed") }
                var p2 = pwd
                if a.entries.contains(where: { $0.encrypted }) && p2 == nil {
                    guard let p = self.askPasswordOnMain() else { return (-1, "Cancelled") }
                    p2 = p
                }
                return runTool(tool, ["t", p2 != nil ? "-p\(p2!)" : "-p-", url.path])
            case .tar:
                // full decode to /dev/null is an integrity test
                return runTool("/usr/bin/tar", ["-xf", url.path, "-O"], discardStdout: true)
            }
        } done: { res in
            if res.output == "Cancelled" { return }
            let text = res.output.isEmpty ? (res.status == 0 ? "No errors detected." : "Exit code \(res.status)") : res.output
            self.textAlert(res.status == 0 ? "Test OK" : "Test found problems (exit \(res.status))", text)
        }
    }

    @objc func viewAction() {
        guard let r = selectedRows().first else { return }
        if r.isDir { currentPath = r.fullPath; reloadRows() } else { viewRow(r) }
    }

    func viewRow(_ r: Row) {
        guard archiveURL != nil else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macrar-view-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        busy("Extracting for viewing…") {
            self.extractSync([r], to: tmp)
        } done: { res in
            let f = tmp.appendingPathComponent(r.fullPath)
            if FileManager.default.fileExists(atPath: f.path) {
                NSWorkspace.shared.open(f)
            } else if res.output != "Cancelled" {
                self.alert("View failed", res.output)
            }
        }
    }

    @objc func deleteAction() {
        guard let zipURL = archiveURL, modificationAllowed() else { return }
        let sel = selectedRows()
        guard !sel.isEmpty else { return }
        let kind = archive?.kind ?? .zip
        let names = sel.map { $0.name }.joined(separator: ", ")
        let a = NSAlert()
        a.messageText = "Delete from archive?"
        a.informativeText = names
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy("Deleting…") {
            switch kind {
            case .zip:
                return runTool("/usr/bin/zip", ["-q", "-d", zipURL.path] + self.zipPatterns(for: sel))
            case .sevenZip:
                let tool = Archive.sevenZipTool!
                return runTool(tool, ["d", "-y", zipURL.path] + self.explicitPaths(for: sel, stripDirSlash: true))
            case .rar:
                let tool = Archive.rarTool! // guarded by modificationAllowed()
                return runTool(tool, ["d", "-y", zipURL.path] + self.explicitPaths(for: sel, stripDirSlash: true))
            case .tar:
                return self.repackTarSync { tree in
                    for r in sel {
                        try? FileManager.default.removeItem(at: tree.appendingPathComponent(r.fullPath))
                    }
                    return nil
                }
            }
        } done: { res in
            if res.status != 0 { self.alert("Delete failed", res.output) }
            self.reloadArchive()
        }
    }

    @objc func infoAction() {
        guard let a = archive, let url = archiveURL else { return }
        let files = a.entries.filter { !$0.isDirectory }
        let dirs = a.entries.count - files.count
        let total = files.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        let packed = files.reduce(UInt64(0)) { $0 + $1.compressedSize }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        // For 7z, per-file packed sizes are unreliable (solid blocks) — use archive size on disk
        let packedShown = packed > 0 ? packed : (onDisk ?? 0)
        let ratio = total > 0 ? Double(packedShown) / Double(total) * 100 : 0
        let methods = Set(files.map { $0.methodString }).sorted().joined(separator: ", ")
        let enc = files.contains { $0.encrypted }
        var text = """
        Archive: \(url.path)
        Format: \(a.backendDescription)
        Files: \(files.count)   Folders: \(dirs)
        Total size: \(fmtSize(total)) bytes
        Packed size: \(fmtSize(packedShown)) bytes
        Ratio: \(String(format: "%.1f", ratio))%
        Compression: \(methods.isEmpty ? "—" : methods)
        Encrypted entries: \(enc ? "yes" : "no")
        """
        if let d = onDisk { text += "\nFile on disk: \(fmtSize(d)) bytes" }
        textAlert("Archive Info", text)
    }

    // MARK: Password

    func askPassword() -> String? {
        if let p = lastPassword { return p }
        let a = NSAlert()
        a.messageText = "Archive is password protected"
        a.informativeText = "Enter password:"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        lastPassword = field.stringValue
        return field.stringValue
    }

    /// askPassword, but safe to call from any thread
    func askPasswordOnMain() -> String? {
        if Thread.isMainThread { return askPassword() }
        var result: String?
        DispatchQueue.main.sync { result = self.askPassword() }
        return result
    }

    // MARK: Preferences window

    var prefsWindow: NSWindow?

    @objc func showPreferences() {
        if let w = prefsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        func check(_ title: String, _ key: String, _ on: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(prefToggled(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.state = on ? .on : .off
            return b
        }

        let junk = check("Hide macOS service files (__MACOSX, .DS_Store, ._*)", "hideMacJunk", Pref.hideMacJunk)
        let skip = check("Don't pack macOS service files when adding", "skipJunkOnAdd", Pref.skipJunkOnAdd)
        let reveal = check("Reveal destination in Finder after extraction", "revealAfterExtract", Pref.revealAfterExtract)
        let sub = check("Extract into a subfolder named after the archive", "extractIntoSubfolder", Pref.extractIntoSubfolder)
        let trash = check("Move archive to Trash after successful extraction", "trashAfterExtract", Pref.trashAfterExtract)
        let quar = check("Remove quarantine attribute from opened archives", "stripQuarantine", Pref.stripQuarantine)
        let solid = check("Create solid archives (7z and RAR)", "solidArchives", Pref.solidArchives)

        let levelLabel = NSTextField(labelWithString: "Compression:")
        let level = NSPopUpButton()
        level.addItems(withTitles: ["Store (no compression)", "Fastest", "Normal", "Best"])
        level.selectItem(at: max(0, min(3, Pref.compressionLevel)))
        level.target = self
        level.action = #selector(prefLevelChanged(_:))
        let levelRow = NSStackView(views: [levelLabel, level])
        levelRow.orientation = .horizontal

        let note = NSTextField(wrappingLabelWithString:
            "Compression level applies when adding files to ZIP, 7z, RAR and tar.gz/tar.bz2. " +
            "Solid archives compress better but extract single files slower, and adding to them is slow. " +
            "Quarantine removal fixes the Gatekeeper \"Apple could not verify…\" warning on double-clicked archives.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 430

        let stack = NSStackView(views: [junk, skip, reveal, sub, trash, quar, solid, levelRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Preferences"
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
        w.isReleasedWhenClosed = false
        prefsWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    @objc func prefToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Pref.d.set(sender.state == .on, forKey: key)
        if key == "hideMacJunk" { reloadRows() } // takes effect immediately
    }

    @objc func prefLevelChanged(_ sender: NSPopUpButton) {
        Pref.d.set(sender.indexOfSelectedItem, forKey: "compressionLevel")
    }

    // MARK: Misc helpers

    /// Archive file name without its (possibly compound) extension — for the extraction subfolder
    func archiveBaseName() -> String {
        guard let url = archiveURL else { return "Archive" }
        var name = url.lastPathComponent
        let lower = name.lowercased()
        for s in Archive.tarSuffixes + [".zip", ".7z", ".rar"] where lower.hasSuffix(s) {
            name = String(name.dropLast(s.count))
            break
        }
        return name.isEmpty ? "Archive" : name
    }

    func trashCurrentArchive() {
        guard let url = archiveURL else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        archive = nil
        archiveURL = nil
        currentPath = ""
        window.title = "MacRAR"
        reloadRows()
    }

    func ensureArchive() -> Bool {
        if archiveURL != nil { return true }
        newArchive()
        return archiveURL != nil
    }

    func busy(_ message: String, _ work: @escaping () -> (status: Int32, output: String),
              done: @escaping ((status: Int32, output: String)) -> Void) {
        statusField.stringValue = message
        DispatchQueue.global(qos: .userInitiated).async {
            let res = work()
            DispatchQueue.main.async {
                done(res)
                self.updateStatus()
            }
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = String(text.prefix(1000))
        a.runModal()
    }

    func textAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        tv.string = text
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let sc = NSScrollView(frame: tv.frame)
        sc.documentView = tv
        sc.hasVerticalScroller = true
        a.accessoryView = sc
        a.runModal()
    }
}

// MARK: - main

Pref.register()
let app = NSApplication.shared
let controller = MainController()
app.delegate = controller
app.run()
