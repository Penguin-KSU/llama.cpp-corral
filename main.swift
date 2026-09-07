import AppKit
import ServiceManagement

// fork() is marked unavailable in the Swift overlay ("use posix_spawn").
// We need the fork+exec pattern because the child must become a process
// group leader BEFORE exec — posix_spawn cannot express that on macOS
// (SETPGROUP with pgid 0 leaves the child in the parent's group). The
// child only performs async-signal-safe C calls before exec, the safe
// usage pattern for fork in a multithreaded app.
@_silgen_name("fork")
func sys_fork() -> pid_t

// MARK: - Paths

// Data lives in the standard macOS per-user location (Apple HIG convention).
// Directories are created + seeded on first launch (see firstRunSetup).
let ROOT = NSHomeDirectory() + "/Library/Application Support/Corral"
let SETTINGS    = ROOT + "/settings"            // legacy: single file
let SETTINGS_DIR  = ROOT + "/settings"          // current: directory
let SETTINGS_FILE = SETTINGS_DIR + "/app"
let GLOBAL_FILE   = SETTINGS_DIR + "/global.llm" // dashboard: global param template
let CONFIG_DIR  = ROOT + "/config"
let LOG_DIR     = ROOT + "/logs"
let LOG_FILE    = LOG_DIR + "/router.log"
let PRESET_FILE = ROOT + "/.router-preset.ini"
let CONFIG_EXT  = ".llm"
// set by the SIGTERM handler so the app can shut down cleanly (and stop the
// router) when it is killed from the shell — without this, `kill`/`pkill`
// on the app leaves the router orphaned on the port, which is exactly what
// triggers the "残留 llama.cpp 进程" modal on the next launch
var g_sigtermRequested = false
func sigtermHandler(_ sig: Int32) { g_sigtermRequested = true }

// MARK: - Settings

// 我已有其他编译版 tab 的已录用条目: 目录 + 可选显示名
struct SourceEntry {
    var path: String
    var name: String   // display name; empty = derive from the folder name
}

struct Settings {
    var bin  = ""          // dir containing the `llama` executable
    var src  = ""          // llama.cpp source dir (self-built installs only)
    var built = ""         // commit sha the current binary was built from
    var sources: [SourceEntry] = []   // dirs adopted via 我已有其他编译版 (one line each in the file)
    var managedSrc = ""   // the dir installed via the 源码编译 flow; the only one that may show as 源码编译版
    var host = ""          // router listen address; empty = llama.cpp default (127.0.0.1)
    var port: Int? = nil   // nil = llama.cpp official default (8080); shown empty/gray in the UI
    var pinnedEndpoints: [String] = []   // 设置页 API 端点「置顶」(应用级,与模型无关)
    var lang = ""          // UI language: "zh" / "en"; empty = follow system (see L10n)

    static func load() -> Settings {
        var s = Settings()
        // new location first, fall back to the legacy single-file path
        let text = (try? String(contentsOfFile: SETTINGS_FILE, encoding: .utf8))
            ?? (try? String(contentsOfFile: SETTINGS, encoding: .utf8))
        guard let text else { return s }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if k == "bin",   !v.isEmpty { s.bin = v }
            if k == "src",   !v.isEmpty { s.src = v }
            if k == "built", !v.isEmpty { s.built = v }
            if k == "host",  !v.isEmpty { s.host = v }
            if k == "port", let p = Int(v) { s.port = p }
            if k == "pinned-endpoints" {
                s.pinnedEndpoints = v.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            if k == "lang", !v.isEmpty { s.lang = v }
            if k == "managed-src", !v.isEmpty { s.managedSrc = v }
            if k == "sources" {
                // one entry per line: "<path>::<name>" (name may be empty).
                // a "::" inside a path would misparse — accepted edge case.
                let parts = v.split(separator: "::", maxSplits: 1)
                let p = String(parts[0]).trimmingCharacters(in: .whitespaces)
                guard !p.isEmpty else { continue }
                let n = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                s.sources.append(SourceEntry(path: p, name: n))
            }
        }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: SETTINGS_DIR, withIntermediateDirectories: true)
        var out = "bin:  \(bin)\n"
        if !src.isEmpty { out += "src:  \(src)\n" }
        if !built.isEmpty { out += "built: \(built)\n" }
        if !host.isEmpty { out += "host: \(host)\n" }
        if let p = port { out += "port: \(p)\n" }
        if !pinnedEndpoints.isEmpty { out += "pinned-endpoints: \(pinnedEndpoints.joined(separator: ", "))\n" }
        if !lang.isEmpty { out += "lang: \(lang)\n" }
        if !managedSrc.isEmpty { out += "managed-src: \(managedSrc)\n" }
        for e in sources { out += "sources: \(e.path)\(e.name.isEmpty ? "" : "::" + e.name)\n" }
        try? out.write(toFile: SETTINGS_FILE, atomically: true, encoding: .utf8)
    }

    static func firstRunSetup() {
        let fm = FileManager.default
        // migrate the legacy single `settings` file into settings/app
        // (settings becomes a directory that also holds global.llm).
        // Only a regular file triggers this — never a directory.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: SETTINGS, isDirectory: &isDir), !isDir.boolValue {
            let tmp = SETTINGS + ".migrating"
            try? fm.moveItem(atPath: SETTINGS, toPath: tmp)
            try? fm.createDirectory(atPath: SETTINGS_DIR, withIntermediateDirectories: true)
            if fm.fileExists(atPath: SETTINGS_FILE) {
                try? fm.removeItem(atPath: tmp)
            } else {
                try? fm.moveItem(atPath: tmp, toPath: SETTINGS_FILE)
            }
        }
        try? fm.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: LOG_DIR,  withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: SETTINGS_DIR, withIntermediateDirectories: true)
        // no settings/model seed: a fresh install starts empty (empty port =
        // llama.cpp default 8080; models are added via the dashboard)
        // give extensionless config files the .llm extension so Finder
        // knows which app opens them
        for f in (try? fm.contentsOfDirectory(atPath: CONFIG_DIR)) ?? [] where !f.hasPrefix(".") {
            if !f.hasSuffix(CONFIG_EXT) {
                let dst = CONFIG_DIR + "/" + f + CONFIG_EXT
                if !fm.fileExists(atPath: dst) {
                    try? fm.moveItem(atPath: CONFIG_DIR + "/" + f, toPath: dst)
                }
            }
        }
    }
}

// MARK: - Model entries

struct ModelEntry {
    let name: String   // filename in config/
    let path: String
    // model id = filename without the .llm extension. The filename is
    // always the GGUF's real name (migrateConfigFiles renames legacy
    // files), so the id is stable and visible to external tools.
    // The optional "# display-name:" comment is display-only.
    var id: String { name.hasSuffix(CONFIG_EXT) ? String(name.dropLast(CONFIG_EXT.count)) : name }
    var displayName: String { LlmFile.read(path).displayName }
    var label: String { displayName.isEmpty ? id : displayName }
}

func loadModelEntries() -> [ModelEntry] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: CONFIG_DIR) else { return [] }
    return names
        .filter { !$0.hasPrefix(".") }
        .sorted()
        .map { ModelEntry(name: $0, path: CONFIG_DIR + "/" + $0) }
}

// merge config/*.ini into the single preset file the router reads
func buildPresetFile() {
    var out = "# generated by Corral, do not edit\n"
    for m in loadModelEntries() {
        // strip the app-private "# pinned:" line: it is dashboard metadata,
        // not a llama.cpp argument
        let body = ((try? String(contentsOfFile: m.path, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
            .filter { line -> Bool in
                let t = line.trimmingCharacters(in: .whitespaces).lowercased()
                // app-private metadata lines: stay out of the router preset
                return !t.hasPrefix("# pinned:") && !t.hasPrefix("# display-name:")
            }
            .joined(separator: "\n")
        out += "\n[\(m.id)]\n" + body + "\n"
    }
    try? out.write(toFile: PRESET_FILE, atomically: true, encoding: .utf8)
}

// One-time migration: config files used to be named after the optional
// custom name, which made the custom name the live router model id.
// Now the id is always the GGUF's real name; the old name moves into a
// "# display-name:" comment. Returns log messages (may be empty).
func migrateConfigFiles() -> [String] {
    var msgs: [String] = []
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: CONFIG_DIR) else { return msgs }
    for name in names where name.hasSuffix(CONFIG_EXT) {
        let id = String(name.dropLast(CONFIG_EXT.count))
        let path = CONFIG_DIR + "/" + name
        let f = LlmFile.read(path)
        guard let modelPath = f.values["model"], !modelPath.isEmpty else { continue }
        let gguf = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        if gguf.isEmpty || gguf == id { continue }
        let target = CONFIG_DIR + "/" + gguf + CONFIG_EXT
        guard !FileManager.default.fileExists(atPath: target) else {
            msgs.append("config migration: \(name) -> \(gguf) skipped (target exists)")
            continue
        }
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if f.displayName.isEmpty { text += "# display-name: \(id)\n" }
        do {
            try text.write(toFile: target, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: path)
            msgs.append("config migration: \(name) -> \(gguf) (display name kept)")
        } catch {
            msgs.append("config migration failed for \(name): \(error.localizedDescription)")
        }
    }
    return msgs
}

// MARK: - Icons

// MARK: - Log sink

final class LogSink {
    private let queue = DispatchQueue(label: "logsink")
    private var fh: FileHandle?
    private var pending = Data()
    var onLine: ((String) -> Void)?

    init(file: String) {
        try? FileManager.default.createDirectory(atPath: LOG_DIR, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file) {
            try? "".write(toFile: file, atomically: false, encoding: .utf8)
        }
        fh = FileHandle(forWritingAtPath: file)
    }

    func append(_ data: Data) {
        queue.async {
            self.fh?.write(data)
            self.pending.append(data)
            while let idx = self.pending.firstIndex(of: 0x0A) {
                let lineData = self.pending.subdata(in: 0..<idx + 1)
                self.pending.removeSubrange(0..<idx + 1)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    DispatchQueue.main.async { self.onLine?(line) }
                }
            }
        }
    }
}

// MARK: - Router process

final class RouterProc {
    private(set) var pid: pid_t = 0
    // process group of the whole tree (router + model servers it spawns).
    // The router runs as its own group leader; children it forks stay in
    // that group, so kill(-pgid, ...) reaches them even after the router
    // itself is dead (orphans keep their group).
    private(set) var pgid: pid_t = 0
    // bumped on every start(); onExit reports the generation of the tree
    // that actually exited, so a stale EOF from a tree we stopped ourselves
    // (queued on the main queue while stop() was waiting) can be dropped
    // instead of being mistaken for a crash
    private(set) var generation = 0
    private var readHandle: FileHandle?
    var onExit: ((Int) -> Void)?

    var isAlive: Bool { pid > 0 && kill(pid, 0) == 0 }

    // returns error message, or nil on success
    func start(executable: String, args: [String], cwd: String, log: LogSink) -> String? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return "pipe() failed" }
        let writeFd = fds[1]

        // Build the NULL-terminated argv and all C strings in the parent:
        // the forked child must stay async-signal-safe (no Swift runtime
        // calls) before it execs. (macOS posix_spawn also needs a
        // NULL-terminated argv; a bare Swift array reads past its end and
        // fails with EFAULT.)
        let cArgs = ([executable] + args).map { strdup($0) }
        let cExe = cArgs[0]
        let cCwd = strdup(cwd)
        var argvBuf: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]

        // fork+exec: the child makes itself a process group leader before
        // exec, so the whole tree (router + the model servers it forks)
        // can be signaled as a unit, even after the router is gone.
        let child = sys_fork()
        if child < 0 {
            close(fds[0]); close(writeFd)
            free(cCwd); cArgs.forEach { free($0) }
            return "fork() failed"
        }
        if child == 0 {
            // child: group leader, stdout/stderr -> log pipe, then exec.
            // Only async-signal-safe C calls from here on.
            setpgid(0, 0)
            if chdir(cCwd) != 0 { _exit(127) }
            dup2(writeFd, 1)
            dup2(writeFd, 2)
            if writeFd > 2 { close(writeFd) }
            execv(cExe, &argvBuf)
            _exit(127)
        }
        close(writeFd)
        free(cCwd)
        cArgs.forEach { free($0) } // child has its own copy of the address space

        generation += 1
        pid = child
        let g = getpgid(child)
        // 0 => the child did not become a group leader; stop() must then
        // never group-kill (the group would be the app's own)
        pgid = (g == child) ? child : 0
        let h = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        readHandle = h
        h.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                // reap the exited child so it does not linger as a zombie
                if let self, self.pid > 0 { waitpid(self.pid, nil, 0); self.pid = 0 }
                let gen = self?.generation ?? 0
                DispatchQueue.main.async { self?.onExit?(gen) }
                return
            }
            log.append(data)
        }
        return nil
    }

    // Shut down the WHOLE tree, not just the router: SIGTERM the process
    // group (router + every model server it spawned), wait up to 8s, then
    // SIGKILL whatever is left. Reaps the router so no zombie is left
    // behind. Safe to call when the tree is already gone (no-op).
    func stop() {
        let g = pgid
        guard pid > 0 || g > 0 else { return }
        // group-kill only when the router leads its own group; never our
        // own group (defense in depth against any spawn regression)
        let useGroup = g > 0 && g != getpgid(0)
        if useGroup { kill(-g, SIGTERM) } else if pid > 0 { kill(pid, SIGTERM) }
        let start = Date()
        // reap the router via WNOHANG: once it exits it is a zombie and
        // kill(pid, 0) keeps succeeding, so polling kill() alone would
        // waste the whole 8s window. kill(-g, 0) tells us whether ANY
        // group member (e.g. an orphaned model server) is still alive.
        while Date().timeIntervalSince(start) < 8 {
            if pid > 0 {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { pid = 0 }
            }
            let gone = useGroup ? kill(-g, 0) != 0 : (pid == 0 || kill(pid, 0) != 0)
            if gone { break }
            usleep(100_000)
        }
        if useGroup, kill(-g, 0) == 0 {
            // something in the tree ignored SIGTERM: kill the whole group
            kill(-g, SIGKILL)
            if pid > 0 { waitpid(pid, nil, 0); pid = 0 } // reap, no zombie
        } else if !useGroup, pid > 0, kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
            pid = 0
        }
        readHandle?.readabilityHandler = nil
        readHandle?.closeFile()
        readHandle = nil
        pid = 0
        pgid = 0
    }
}

// MARK: - Router HTTP API

struct ModelInfo { let id: String; let status: String }

func isRunningStatus(_ s: String) -> Bool {
    return s == "loaded" || s == "loading" || s == "sleeping"
}

final class RouterAPI {
    let port: Int
    init(port: Int) { self.port = port }

    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func request(_ req: URLRequest) -> (Data, HTTPURLResponse)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, HTTPURLResponse)?
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let http = resp as? HTTPURLResponse {
                result = (data, http)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + req.timeoutInterval + 2)
        return result
    }

    func health() -> Bool {
        var req = URLRequest(url: url("/health"))
        req.timeoutInterval = 2
        guard let (_, http) = request(req) else { return false }
        return http.statusCode == 200
    }

    func models() -> [ModelInfo]? {
        var req = URLRequest(url: url("/models"))
        req.timeoutInterval = 3
        guard let (data, http) = request(req), http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return nil }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let status = (m["status"] as? [String: Any])?["value"] as? String ?? "unknown"
            return ModelInfo(id: id, status: status)
        }
    }

    // returns error message, or nil on success
    func load(_ name: String) -> String? { post("/models/load", name) }
    func unload(_ name: String) -> String? { post("/models/unload", name) }

    func reload() {
        var req = URLRequest(url: url("/models?reload=1"))
        req.timeoutInterval = 10
        _ = request(req)
    }

    private func post(_ path: String, _ name: String) -> String? {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        req.timeoutInterval = 15
        guard let (data, http) = request(req) else { return "request to router failed" }
        if http.statusCode >= 400 {
            return "HTTP \(http.statusCode): " + (String(data: data, encoding: .utf8) ?? "")
        }
        return nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var settings = Settings.load()
    var api: RouterAPI!
    var proc = RouterProc()
    var log: LogSink!
    var statusItem: NSStatusItem!
    var timer: Timer?

    var loadedNames = Set<String>()
    var routerDead = false
    // true once a spawn succeeded; gates the health-check recovery so a
    // failed start (already handled by startRouter's alert) doesn't also
    // trigger recoverRouter
    var routerUp = false
    var unhealthyPolls = 0
    // when the current router was started; health failures inside this
    // grace window are ignored (a fresh llama build can take well over a
    // minute to compile Metal shaders before /health answers — killing it
    // for "unresponsiveness" during startup used to loop the whole tree)
    var routerStartedAt = Date.distantPast
    var recovering = false
    var restartTimes: [Date] = []

    var modelsSubmenu: NSMenu!
    var loginItem: NSMenuItem!
    let dashboard = DashboardApp()
    let logStore = LogStore()
    let upgradeRunner = UpgradeRunner()

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.firstRunSetup()
        settings = Settings.load()
        api = RouterAPI(port: settings.port ?? 8080)

        log = LogSink(file: LOG_FILE)
        log.onLine = { [weak self] line in self?.appendLogLine(line) }

        // rename legacy config files (custom-name filenames) to the
        // GGUF's real name before the first preset build
        for msg in migrateConfigFiles() { appendLogLine("[menubar] " + msg) }

        // 激活到前台: app 常被 nohup/开机自启在后台拉起, 后台状态下
        // Dock 右键菜单的「退出」不响应 —— 启动即激活, Dock 菜单随时可用
        NSApp.activate(ignoringOtherApps: true)

        dashboard.attach(self)

        setupMainMenu()

        proc.onExit = { [weak self] gen in
            guard let self, !self.routerDead else { return }
            // a stale exit event from a tree we stopped ourselves (upgrade
            // restart) must not be treated as a crash
            guard gen == self.proc.generation else { return }
            self.routerUp = false
            self.appendLogLine("[menubar] router process exited unexpectedly")
            self.recoverRouter()
        }

        // A SIGTERM (kill/pkill on the app) must run the same bounded
        // cleanup as a normal quit — otherwise the router is left orphaned
        // on the port and the next launch shows the leftover modal. The
        // signal handler can only set a flag; the 3s timer acts on it.
        signal(SIGTERM, sigtermHandler)

        setupStatusItem()

        // find llama.cpp before trying to start anything (cheap: a few
        // file-existence checks on fixed paths, no scanning/network)
        if detectEnv() == .none {
            appendLogLine("[menubar] no llama.cpp found — open the Environment page to install")
        }

        // detect a leftover router from a previous abnormal exit
        if api.health() {
            let alert = NSAlert()
            alert.messageText = T("检测到残留的 llama.cpp 进程")
            alert.informativeText = TF("端口 %d 被上次未正常退出的 llama.cpp 实例占用，要杀掉它并重新开始吗？", settings.port ?? 8080)
            alert.addButton(withTitle: T("杀掉"))
            alert.addButton(withTitle: T("取消"))
            if alert.runModal() == .alertFirstButtonReturn {
                killLeftoverOnPort(settings.port ?? 8080)
                Thread.sleep(forTimeInterval: 1)
            } else {
                NSApp.terminate(nil)
                return
            }
        }

        if detectEnv() != .none { startRouter() }

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            if g_sigtermRequested {
                g_sigtermRequested = false
                self?.quit()
                return
            }
            self?.refreshState()
        }
    }

    // MARK: status item and menu

    // 标准主菜单: app 没有它时 ⌘V/⌘C/⌘X/⌘A 全部失效(快捷键由主菜单的
    // Edit 菜单分发), 而右键粘贴走 NSText 自己的上下文菜单所以不受影响 ——
    // 这就是「右键能粘、快捷键不能粘」的根因。oMLX 有主菜单所以正常。
    func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 Corral", action: #selector(quit), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusIcon(filled: false)

        let menu = NSMenu()
        menu.delegate = self
        populateStatusMenu(menu)
        statusItem.menu = menu
    }

    // (Re)builds the static status-bar menu items — called at launch and
    // again on language switch (the models submenu rebuilds itself on open).
    func populateStatusMenu(_ menu: NSMenu) {
        let modelsItem = NSMenuItem(title: T("模型"), action: nil, keyEquivalent: "")
        modelsSubmenu = NSMenu()
        modelsSubmenu.delegate = self
        modelsItem.submenu = modelsSubmenu
        menu.addItem(modelsItem)

        menu.addItem(NSMenuItem(title: T("控制面板"), action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: T("添加新模型"), action: #selector(addModel), keyEquivalent: ""))
        loginItem = NSMenuItem(title: T("开机启动"), action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: T("退出"), action: #selector(quit), keyEquivalent: ""))

        for item in menu.items { item.target = self }
    }

    func rebuildStatusMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        populateStatusMenu(menu)
    }

    // Language switch: persist + republish (SwiftUI re-renders via L10n
    // observation), rebuild the AppKit menu, retitle the dashboard window.
    func setLanguage(_ l: Lang) {
        L10n.shared.set(l)
        rebuildStatusMenu()
        dashboard.retitle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === modelsSubmenu { rebuildModelsSubmenu() }
        if menu === statusItem.menu { refreshLoginItemState() }
    }

    func rebuildModelsSubmenu() {
        modelsSubmenu.removeAllItems()
        for m in loadModelEntries() {
            let item = NSMenuItem(title: m.label, action: nil, keyEquivalent: "")
            item.state = loadedNames.contains(m.id) ? .on : .off
            let sub = NSMenu()
            let act: NSMenuItem
            if loadedNames.contains(m.id) {
                act = NSMenuItem(title: T("卸载模型"), action: #selector(unloadModel(_:)), keyEquivalent: "")
            } else {
                act = NSMenuItem(title: T("加载模型"), action: #selector(loadModel(_:)), keyEquivalent: "")
            }
            act.target = self
            act.representedObject = m.id
            sub.addItem(act)
            let copy = NSMenuItem(title: T("复制模型名"), action: #selector(copyModelNameItem(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = m.id
            sub.addItem(copy)
            let cfg = NSMenuItem(title: T("配置文件"), action: #selector(openConfig(_:)), keyEquivalent: "")
            cfg.target = self
            cfg.representedObject = m.id
            sub.addItem(cfg)
            item.submenu = sub
            modelsSubmenu.addItem(item)
        }
        if loadModelEntries().isEmpty {
            let empty = NSMenuItem(title: T("(config/ 里没有模型)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            modelsSubmenu.addItem(empty)
        }
    }

    func refreshLoginItemState() {
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // MARK: llama.cpp environment detection (环境 page)

    enum LlamaEnv { case none, official, source }

    // Cheap detection chain, safe to run on every launch:
    //  1. a recorded source dir that still looks like a working build
    //  2. the official one-line install location (~/.llama-app)
    //  3. a copy on PATH (~/.local/bin, where the official installer puts one)
    // Results are persisted so the next launch starts from the same place.
    func detectEnv() -> LlamaEnv {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // 0. an explicitly configured bin that still works wins —
        //    covers users who filled 设置 by hand (incl. legacy setups).
        //    bin = <src>/build/bin, so two levels up is the checkout;
        //    if it is a git repo we can recover the source dir too.
        if !settings.bin.isEmpty, fm.isExecutableFile(atPath: settings.bin + "/llama") {
            if settings.src.isEmpty {
                let guessed = URL(fileURLWithPath: settings.bin)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path
                if fm.fileExists(atPath: guessed + "/.git") {
                    settings.src = guessed
                    settings.save()
                }
            }
            return settings.src.isEmpty ? .official : .source
        }
        if !settings.src.isEmpty,
           fm.fileExists(atPath: settings.src + "/.git"),
           fm.isExecutableFile(atPath: settings.src + "/build/bin/llama") {
            settings.bin = settings.src + "/build/bin"
            settings.save()
            return .source
        }
        if fm.isExecutableFile(atPath: home + "/.llama-app/llama") {
            settings.bin = home + "/.llama-app"
            settings.src = ""
            settings.save()
            appendLogLine("[menubar] detected official llama.cpp at ~/.llama-app")
            return .official
        }
        if fm.isExecutableFile(atPath: home + "/.local/bin/llama") {
            settings.bin = home + "/.local/bin"
            settings.src = ""
            settings.save()
            appendLogLine("[menubar] detected llama at ~/.local/bin/llama")
            return .official
        }
        return .none
    }

    // user picked an existing self-built checkout (env page, 我已有其他编译版).
    // dir may come from the text field with a leading "~".
    func adoptSourceDir(_ dir: String, name: String = "") -> String? {
        let fm = FileManager.default
        let d = (dir.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: d + "/.git") else { return T("该目录不是 git 仓库(找不到 .git)") }
        guard fm.isExecutableFile(atPath: d + "/build/bin/llama") else {
            return TF("%@/build/bin/llama 不存在 —— 这个源码目录还没编译过,请先编译(参考 llama.cpp docs/build.md)", d)
        }
        settings.src = d
        settings.bin = d + "/build/bin"
        settings.built = ""   // external binary: its commit is unknown to the app
        // record the entry (or refresh its name) in the 已录用 list
        if let i = settings.sources.firstIndex(where: { $0.path == d }) {
            if !name.isEmpty { settings.sources[i].name = name }
        } else {
            settings.sources.append(SourceEntry(path: d, name: name))
        }
        settings.save()
        // stop the old router first: starting over a live one makes the new
        // process fail to bind the port and crash-loop until the recovery
        // logic eventually kills the old tree (the 反复崩溃 false alarm)
        proc.stop()
        startRouter()
        return nil
    }

    // 官方一键安装的本体目录。只认 ~/.llama-app —— ~/.local/bin 是 PATH
    // 便利位,用户可能把任意二进制软链过去(例如自编译版),认了会误判身份;
    // nil = 这台机器没有官方安装
    func officialInstallDir() -> String? {
        let dir = NSHomeDirectory() + "/.llama-app"
        return FileManager.default.isExecutableFile(atPath: dir + "/llama") ? dir : nil
    }

    // 我们自己的源码仓库(如果 app 是从 git clone 构建的): bundleURL 即
    // <repo>/Corral.app, 上一级即仓库; nil = 不在 git 仓库里(例如用户把
    // 文件夹拷走了)
    func ownSourceRepo() -> String? {
        let p = Bundle.main.bundleURL.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: p.path + "/.git") ? p.path : nil
    }

    // 一键更新收尾: 先停 router(释放端口, 新实例的 router 才能直接绑定),
    // 拉起新 app, 旧实例稍后退出。本地构建的 bundle 无隔离属性, 可直接启动
    func relaunchSelf() {
        proc.stop()
        loadedNames = []
        updateIcon()
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }

    // 切回官方安装(环境页 已录用列表的 官方版 行)。和 finishInstall(official:)
    // 同样的状态变化,但针对已存在的安装: 清掉 src 让检测链重新落到官方位置。
    func switchToOfficial() {
        guard let dir = officialInstallDir() else { return }
        settings.src = ""
        settings.built = ""
        settings.bin = dir
        settings.save()
        proc.stop()
        startRouter()
    }

    // drop an entry from the 已录用 list. Record only — the directory and its
    // binaries are never touched. The UI only offers this for non-current rows.
    func removeSourceEntry(_ path: String) {
        settings.sources.removeAll { $0.path == path }
        settings.save()
    }

    // 源码编译版 vs 其他编译版: the identity follows the directory, not the
    // button — only the path recorded by the 源码编译 install flow (sticky,
    // survives delete + re-adopt) may show as 源码编译版; every other checkout
    // (adopted, hand-configured) is 其他编译版
    var srcIsManaged: Bool {
        !settings.src.isEmpty && settings.src == settings.managedSrc
    }

    // called by the 环境 page after an assisted install finished
    func finishInstall(official: Bool, sourceDir: String? = nil) {
        if official {
            settings.src = ""
            settings.built = ""
            settings.bin = NSHomeDirectory() + "/.llama-app"
        } else if let dir = sourceDir {
            settings.src = dir
            settings.bin = dir + "/build/bin"
            settings.managedSrc = dir   // grants the 源码编译版 identity (sticky per path)
            recordBuiltCommit()
        }
        settings.save()
        appendLogLine("[menubar] install finished, starting router")
        startRouter()
    }

    // 记住"当前二进制是从哪个 commit 编的" —— 分支切换后靠它判断
    // 要不要重新编译(unknown 时保守提示, 用户 app 内编一次后即精确)
    func recordBuiltCommit() {
        guard !settings.src.isEmpty else { return }
        let sha = gitRun(["-C", settings.src, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sha.isEmpty { settings.built = sha }
    }

    func gitHead(_ src: String) -> String {
        gitRun(["-C", src, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // build-tool availability for the self-built path (checked on demand,
    // not at launch). The app never installs these — it only tells the
    // user how (环境 page shows the official instructions).
    func checkBuildTools() -> (clt: Bool, cmake: Bool) {
        func ok(_ cmd: String, _ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd)
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
        }
        let clt = ok("/usr/bin/xcode-select", ["-p"])
        let cmake = { () -> Bool in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "command -v cmake >/dev/null"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
        }()
        return (clt, cmake)
    }

    // 升级/分支切换重新编译后:router 还跑着旧二进制,必须重启才生效。
    // proc.stop() 是同步的(等整棵树退出并清掉读 handler),所以 stop →
    // start 之间不存在 onExit 竞态
    func restartRouterNow() {
        guard routerUp || proc.isAlive else { startRouter(); return }
        if !loadedNames.isEmpty {
            let alert = NSAlert()
            alert.messageText = T("重启 router")
            alert.informativeText = T("重启会卸载所有已加载的模型,确认继续吗?")
            alert.addButton(withTitle: T("重启"))
            alert.addButton(withTitle: T("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        appendLogLine("[menubar] restarting router after upgrade")
        loadedNames = []
        updateIcon()
        proc.stop()
        startRouter()
    }

    // MARK: git helpers for the 分支管理 tab (all read-only except checkout)

    func gitCurrentBranch(_ src: String) -> String {
        let out = gitRun(["-C", src, "branch", "--show-current"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitListBranches(_ src: String) -> [String] {
        let out = gitRun(["-C", src, "branch", "-a", "--format=%(refname:short)"])
        // refs/remotes/<remote>/HEAD shortens to the bare remote name
        // ("origin") — that is a remote, not a branch, so drop it
        let remotes = Set(gitRun(["-C", src, "remote"])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "HEAD" && !remotes.contains($0) }
    }

    func gitDirtyCount(_ src: String) -> Int {
        let out = gitRun(["-C", src, "status", "--porcelain"])
        return out.split(separator: "\n").count
    }

    // returns error message or nil on success. Remote names (origin/foo)
    // get a local tracking branch named foo; plain names check out as-is.
    func gitCheckout(_ src: String, _ name: String) -> String? {
        let args: [String]
        if name.contains("/") {
            let local = (name as NSString).lastPathComponent
            args = ["-C", src, "checkout", "-B", local, name]
        } else {
            args = ["-C", src, "checkout", name]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = errPipe
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return TF("git checkout 失败: %@", error.localizedDescription) }
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return p.terminationStatus == 0 ? nil : (msg.isEmpty ? T("git checkout 失败") : msg)
    }

    // fetch only moves the remote markers (origin/*), never local code
    @discardableResult
    func gitFetch(_ src: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", src, "fetch"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    // ahead/behind of `ref` relative to the CURRENT branch — pure local
    // object-db counting (no network; fetch already brought the history
    // down). ahead = commits you'd gain by switching, behind = commits
    // you'd leave behind.
    func gitAheadBehind(_ src: String, _ ref: String) -> (ahead: Int, behind: Int)? {
        func count(_ range: String) -> Int? {
            let c = gitRun(["-C", src, "rev-list", "--count", range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(c)
        }
        guard let ahead = count("HEAD.." + ref),
              let behind = count(ref + "..HEAD") else { return nil }
        return (ahead, behind)
    }

    // how far the current branch trails its upstream ("官方领先 N 个提交")
    // plus the upstream's latest commit line; nil = no upstream configured
    func gitBehindInfo(_ src: String) -> (count: Int, latest: String)? {
        let up = gitRun(["-C", src, "rev-parse", "--abbrev-ref", "@{upstream}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !up.isEmpty else { return nil }
        let c = gitRun(["-C", src, "rev-list", "--count", "HEAD.." + up])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(c) else { return nil }
        let latest = gitRun(["-C", src, "log", "-1", "--format=%h %s", up])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (n, latest)
    }

    private func gitRun(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    // MARK: router lifecycle

    func startRouter() {
        buildPresetFile()
        let exe = settings.bin + "/llama"
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            // no hard alert: a fresh machine simply has nothing installed
            // yet, and the 环境 page is where that gets fixed
            appendLogLine("[menubar] no llama executable at \(exe) — router not started")
            return
        }
        var args = ["serve"]
        if let p = settings.port { args += ["--port", String(p)] }
        args += ["--models-preset", PRESET_FILE]
        if !settings.host.isEmpty { args += ["--host", settings.host] }
        if let err = proc.start(executable: exe, args: args, cwd: settings.bin, log: log) {
            appendLogLine("[menubar] router start failed: \(err)")
            let alert = NSAlert()
            alert.messageText = T("router 启动失败")
            alert.informativeText = err
            alert.addButton(withTitle: T("重试"))
            alert.addButton(withTitle: T("退出"))
            if alert.runModal() == .alertFirstButtonReturn {
                startRouter()
            } else {
                NSApp.terminate(nil)
            }
            return
        }
        appendLogLine("[menubar] router started: \(exe) \(args.joined(separator: " "))")
        routerUp = true
        unhealthyPolls = 0
        routerStartedAt = Date()
    }

    var refreshing = false

    func refreshState() {
        guard !refreshing, !routerDead else { return }
        refreshing = true
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            // health() is the reliable liveness signal: the model servers
            // inherit the log pipe, so its EOF (proc.onExit) only fires once
            // the whole tree is gone — a router that was killed while its
            // model children live would otherwise go completely unnoticed.
            let healthy = self.api.health()
            let list = healthy ? self.api.models() : nil
            DispatchQueue.main.async {
                self.refreshing = false
                if healthy { self.unhealthyPolls = 0 }
                else if Date().timeIntervalSince(self.routerStartedAt) > 90 {
                    self.noteRouterUnhealthy()
                } else {
                    self.unhealthyPolls = 0 // don't bank failures across the grace boundary
                }
                guard let list else { return }
                self.loadedNames = Set(list.filter { isRunningStatus($0.status) }.map { $0.id })
                self.dashboard.model.loadedIDs = self.loadedNames
                self.dashboard.model.routerReady = healthy
                self.updateIcon()
            }
        }
    }

    // two consecutive failed polls (~6s) = router is really gone
    func noteRouterUnhealthy() {
        guard routerUp else { return } // failed startup: startRouter's alert handles it
        unhealthyPolls += 1
        guard unhealthyPolls >= 2 else { return }
        unhealthyPolls = 0
        routerUp = false
        recoverRouter()
    }

    // The router died (or was killed from outside, e.g. by an agent).
    // Take back control: kill the ENTIRE process group — orphaned model
    // servers keep running with the model in GPU memory otherwise — then
    // restart the router so this app stays the single manager. Models are
    // re-loaded on demand by the router, so clients just keep working.
    func recoverRouter() {
        guard !routerDead, !recovering else { return }
        recovering = true
        appendLogLine("[menubar] router unresponsive; killing leftover llama processes")
        let proc = self.proc
        DispatchQueue.global().async {
            proc.stop()
            DispatchQueue.main.async {
                self.recovering = false
                guard !self.routerDead else { return }
                self.loadedNames = []
                self.updateIcon()
                // crash-loop guard: 3 restarts within 60s => give up
                let now = Date()
                self.restartTimes.removeAll { now.timeIntervalSince($0) > 60 }
                if self.restartTimes.count >= 3 {
                    self.appendLogLine("[menubar] router keeps crashing; giving up")
                    self.showAlert(T("router 反复崩溃"),
                        T("router 在 60 秒内多次退出，已停止自动重启。请查看 log 排查原因后重新打开本应用。"))
                    return
                }
                self.restartTimes.append(now)
                self.appendLogLine("[menubar] restarting router")
                self.startRouter()
            }
        }
    }

    func updateIcon() {
        statusItem.button?.image = statusIcon(filled: !loadedNames.isEmpty)
    }

    func killLeftoverOnPort(_ port: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
        // if a leftover leads its own process group (as this app spawns
        // routers), kill the whole group so the model servers it spawned
        // don't survive as orphans. A process running in someone else's
        // group (e.g. a terminal) is killed alone — never its group.
        for pid in pids {
            if let pg = processGroup(of: pid), pg == pid { kill(-pg, SIGTERM) }
            else { kill(pid, SIGTERM) }
        }
        Thread.sleep(forTimeInterval: 3)
        for pid in pids {
            if let pg = processGroup(of: pid), pg == pid, kill(-pg, 0) == 0 {
                kill(-pg, SIGKILL)
            } else if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    func processGroup(of pid: pid_t) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pgid=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        // if run() fails, no process ever took the pipe's write end, so
        // reading it would block forever — bail out instead
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return pid_t((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces))
    }

    // MARK: menu actions

    @objc func loadModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let err = self.api.load(name)
            DispatchQueue.main.async {
                if let err { self.showAlert(TF("加载失败: %@", name), err) }
                else { self.appendLogLine("[menubar] loading model: \(name)"); self.refreshState() }
            }
        }
    }

    @objc func unloadModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let err = self.api.unload(name)
            DispatchQueue.main.async {
                if let err { self.showAlert(TF("卸载失败: %@", name), err) }
                else { self.appendLogLine("[menubar] unloading model: \(name)"); self.refreshState() }
            }
        }
    }

    // 模型 → 配置文件: open the dashboard on that model's config form
    @objc func openConfig(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dashboard.show(page: .models, modelsTab: .list, editing: id)
    }

    // GGUF 真名(传给其他 agent 用的模型名): 解析 .llm 里的 model 路径
    // 取文件名去 .gguf —— 不依赖「自定义名称留空」的约定, 任何时候都正确
    func ggufModelName(id: String) -> String {
        guard let text = try? String(contentsOfFile: CONFIG_DIR + "/\(id)\(CONFIG_EXT)", encoding: .utf8) else { return id }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces) == "model" {
                let path = parts[1].trimmingCharacters(in: .whitespaces)
                return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            }
        }
        return id
    }

    // 复制 GGUF 真名到剪贴板(状态栏子菜单和控制面板共用)
    func copyModelName(id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ggufModelName(id: id), forType: .string)
    }

    @objc func copyModelNameItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        copyModelName(id: id)
    }

    // double-clicking a .llm config file in Finder launches us with the file
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.path.hasSuffix(CONFIG_EXT) {
            let id = (url.lastPathComponent as NSString).deletingPathExtension
            dashboard.show(page: .models, modelsTab: .list, editing: id)
        }
    }

    @objc func openDashboard() {
        dashboard.show(page: .models, modelsTab: .global, editing: nil)
    }

    @objc func addModel() {
        dashboard.show(page: .models, modelsTab: .add, editing: nil)
    }

    // called by the dashboard after a .llm file was added/edited/deleted:
    // regenerate the router preset and let the router re-read it
    func modelsDidChange() {
        buildPresetFile()
        rebuildModelsSubmenu()
        refreshState()
        DispatchQueue.global().async { [weak self] in
            self?.api.reload()
        }
    }

    // 设置页「连接」确认: 保存 host/port 并立即重启 router 生效
    // 空值 = llama.cpp 官方默认(host 127.0.0.1 / port 8080), 不是"沿用旧值"
    func saveConnection(host: String, port: Int?) {
        settings.host = host.trimmingCharacters(in: .whitespaces)
        settings.port = port
        settings.save()
        appendLogLine("[menubar] connection saved (host=\(settings.host.isEmpty ? "default" : settings.host), port=\(port.map(String.init) ?? "default")) — restarting router")
        restartRouter(message: T("连接设置已保存,正在重启 router 生效"))
    }

    func restartRouter(message: String) {
        guard routerUp || proc.isAlive else { startRouter(); return }
        if !loadedNames.isEmpty {
            let alert = NSAlert()
            alert.messageText = T("重启 router")
            alert.informativeText = TF("%@。重启会卸载所有已加载的模型,确认继续吗?", message)
            alert.addButton(withTitle: T("重启"))
            alert.addButton(withTitle: T("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        loadedNames = []
        updateIcon()
        proc.stop()
        startRouter()
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            showAlert(T("开机启动"), TF("设置登录项失败: %@", error.localizedDescription))
        }
        refreshLoginItemState()
    }

    @objc func quit() {
        // oMLX pattern: terminate on the main thread; the actual cleanup
        // (unload models, stop router) happens bounded inside
        // applicationWillTerminate — no background thread, no exit(0) hack.
        NSApp.terminate(nil)
    }

    // clicking the Dock icon of the already-running app: open the
    // control panel (a fresh launch is handled by LaunchServices, this
    // only fires when an instance is up)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

    // NOTE: no applicationShouldTerminate override — d00fcbd 加的
    // .terminateNow 让 Dock 右键「退出」失效(后台 app + terminateNow 不响应),
    // 4117f3a 改 .terminateLater 也没修好。默认行为(.terminateLater 路径)
    // 会走 applicationWillTerminate 的 proc.stop() 清理, 且 Dock/状态栏退出都正常。

    func applicationWillTerminate(_ notification: Notification) {
        // Bounded synchronous cleanup, mirrors oMLX's applicationWillTerminate.
        // proc.stop() signals the whole process group (router + every model
        // server it spawned) and escalates to SIGKILL, so nothing survives
        // even if the router would not unload its children itself.
        timer?.invalidate()
        routerDead = true
        proc.stop()
    }

    // MARK: log (viewed in the dashboard's 日志 page)

    func appendLogLine(_ line: String) {
        logStore.append(line)
    }

    // MARK: helpers

    func showAlert(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
