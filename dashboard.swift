import SwiftUI
import AppKit
import ServiceManagement

// =====================================================================
// Dashboard: native SwiftUI control panel (no HTTP server, no extra
// process). Embedded in the AppKit app via NSHostingController.
// Design decisions live in AGENTS.md ("控制面板设计" section).
// =====================================================================

// MARK: - Parameter catalog

// Values are written into .llm files verbatim, so defaults below are the
// llama.cpp official defaults (checked against `llama-server --help`).
// Empty field = not written to the file = llama.cpp uses its own default.
enum ParamKind {
    case text
    case path
    case num
    case bool
    case choice([String])
}

struct Param {
    let key: String      // preset key (llama-server long option name)
    let kind: ParamKind
    let def: String      // official default, shown as gray placeholder
    let group: Int       // 1...5, see GROUP_NAMES
}

let GROUP_NAMES: [Int: String] = [
    1: "上下文 & 缓存",
    2: "GPU & 设备",
    3: "采样",
    4: "推理 & 模板",
    5: "其他(多模态 / 服务器 / 投机解码 / 调试)",
]

private func P(_ key: String, _ kind: ParamKind, _ def: String, _ group: Int) -> Param {
    Param(key: key, kind: kind, def: def, group: group)
}

private let KV_TYPES: [String] = ["f16", "f32", "bf16", "q8_0", "q4_0", "q4_1", "iq4_nl", "q5_0", "q5_1"]

let PARAMS: [Param] = [
    // ---- group 1: context & cache ----
    P("ctx-size", .num, "0 (从模型读取)", 1),
    P("parallel", .num, "-1 (auto)", 1),
    P("batch-size", .num, "2048", 1),
    P("ubatch-size", .num, "512", 1),
    P("keep", .num, "0", 1),
    P("n-predict", .num, "-1 (无限)", 1),
    P("swa-full", .bool, "off", 1),
    P("kv-unified", .text, "auto (slots 为 auto 时启用)", 1),
    P("kv-unified-per-slot", .num, "未设置", 1),
    P("ctx-checkpoints", .num, "32", 1),
    P("checkpoint-min-step", .num, "8192", 1),
    P("cache-ram", .num, "8192", 1),
    P("cache-idle-slots", .bool, "on", 1),
    P("context-shift", .bool, "off", 1),
    P("cache-prompt", .bool, "on", 1),
    P("cache-reuse", .num, "0", 1),
    P("slot-prompt-similarity", .num, "0.10", 1),
    P("slot-save-path", .path, "disabled", 1),
    P("sleep-idle-seconds", .num, "-1 (disabled)", 1),
    P("warmup", .bool, "on", 1),
    P("rope-scaling", .choice(["none", "linear", "yarn"]), "linear (模型默认)", 1),
    P("rope-scale", .num, "模型默认", 1),
    P("rope-freq-base", .num, "模型默认", 1),
    P("rope-freq-scale", .num, "模型默认", 1),
    P("yarn-orig-ctx", .num, "0", 1),
    P("yarn-ext-factor", .num, "-1.00", 1),
    P("yarn-attn-factor", .num, "-1.00", 1),
    P("yarn-beta-slow", .num, "-1.00", 1),
    P("yarn-beta-fast", .num, "-1.00", 1),
    P("cache-type-k", .choice(KV_TYPES), "f16", 1),
    P("cache-type-v", .choice(KV_TYPES), "f16", 1),
    P("flash-attn", .choice(["auto", "on", "off"]), "auto", 1),
    // ---- group 2: gpu & device ----
    P("n-gpu-layers", .text, "auto (数字 / auto / all)", 2),
    P("split-mode", .choice(["none", "layer", "row", "tensor"]), "layer", 2),
    P("tensor-split", .text, "默认", 2),
    P("main-gpu", .num, "0", 2),
    P("device", .text, "默认", 2),
    P("threads", .num, "-1", 2),
    P("threads-batch", .num, "同 threads", 2),
    P("cpu-mask", .text, "", 2),
    P("cpu-range", .text, "", 2),
    P("cpu-strict", .num, "0", 2),
    P("prio", .num, "0 (low -1 / normal 0 / medium 1 / high 2 / realtime 3)", 2),
    P("poll", .num, "50", 2),
    P("cpu-mask-batch", .text, "同 cpu-mask", 2),
    P("cpu-range-batch", .text, "同 cpu-range", 2),
    P("cpu-strict-batch", .num, "同 cpu-strict", 2),
    P("prio-batch", .num, "0", 2),
    P("poll-batch", .num, "同 poll", 2),
    P("fit", .choice(["on", "off"]), "on", 2),
    P("fit-target", .text, "1024", 2),
    P("fit-ctx", .num, "4096", 2),
    P("load-mode", .choice(["auto", "none", "mmap", "mlock", "mmap+mlock", "dio"]), "auto", 2),
    P("lazy-mode", .choice(["on", "auto", "off"]), "auto", 2),
    P("kv-offload", .bool, "on", 2),
    P("repack", .bool, "on", 2),
    P("no-host", .bool, "off", 2),
    P("op-offload", .bool, "on", 2),
    P("numa", .choice(["distribute", "isolate", "numactl"]), "默认", 2),
    P("override-tensor", .text, "", 2),
    P("cpu-moe", .bool, "off", 2),
    P("n-cpu-moe", .num, "默认", 2),
    P("n-cpu-ffn", .num, "默认", 2),
    P("check-tensors", .bool, "off", 2),
    P("override-kv", .text, "", 2),
    P("lora", .path, "", 2),
    P("lora-scaled", .text, "格式 FNAME:SCALE", 2),
    P("control-vector", .path, "", 2),
    P("control-vector-scaled", .text, "格式 FNAME:SCALE", 2),
    P("control-vector-layer-range", .text, "START END", 2),
    // ---- group 3: sampling ----
    P("temp", .num, "0.80", 3),
    P("top-k", .num, "40", 3),
    P("top-p", .num, "0.95", 3),
    P("min-p", .num, "0.05", 3),
    P("typical-p", .num, "1.00", 3),
    P("top-nsigma", .num, "-1.00", 3),
    P("xtc-probability", .num, "0.00", 3),
    P("xtc-threshold", .num, "0.10", 3),
    P("repeat-last-n", .num, "64", 3),
    P("repeat-penalty", .num, "1.00", 3),
    P("presence-penalty", .num, "0.00", 3),
    P("frequency-penalty", .num, "0.00", 3),
    P("dry-multiplier", .num, "0.00", 3),
    P("dry-base", .num, "1.75", 3),
    P("dry-allowed-length", .num, "2", 3),
    P("dry-penalty-last-n", .num, "64", 3),
    P("dry-sequence-breaker", .text, "默认 (\\n : \" *)", 3),
    P("adaptive-target", .num, "-1.00", 3),
    P("adaptive-decay", .num, "0.90", 3),
    P("dynatemp-range", .num, "0.00", 3),
    P("dynatemp-exp", .num, "1.00", 3),
    P("mirostat", .choice(["0", "1", "2"]), "0 (disabled)", 3),
    P("mirostat-lr", .num, "0.10", 3),
    P("mirostat-ent", .num, "5.00", 3),
    P("seed", .num, "-1 (随机)", 3),
    P("samplers", .text, "默认顺序", 3),
    P("sampler-seq", .text, "edskypmxt", 3),
    P("ignore-eos", .bool, "off", 3),
    P("logit-bias", .text, "格式 TOKEN_ID(+/-)BIAS", 3),
    P("grammar", .text, "", 3),
    P("grammar-file", .path, "", 3),
    P("json-schema", .text, "", 3),
    P("json-schema-file", .path, "", 3),
    P("backend-sampling", .bool, "off", 3),
    // ---- group 4: reasoning & template ----
    P("jinja", .bool, "on", 4),
    P("chat-template", .text, "模型自带", 4),
    P("chat-template-file", .path, "模型自带", 4),
    P("chat-template-kwargs", .text, "JSON 对象字符串", 4),
    P("reasoning", .choice(["auto", "on", "off"]), "auto", 4),
    P("reasoning-format", .choice(["auto", "none", "deepseek", "deepseek-legacy"]), "auto", 4),
    P("reasoning-effort", .choice(["default", "minimal", "low", "medium", "high", "xhigh", "max"]), "default", 4),
    P("reasoning-budget", .num, "-1 (不限)", 4),
    P("reasoning-budget-message", .text, "无", 4),
    P("reasoning-preserve", .bool, "on", 4),
    P("skip-chat-parsing", .bool, "off", 4),
    P("prefill-assistant", .bool, "on", 4),
    P("special", .bool, "off", 4),
    // ---- group 5: misc (multimodal / server / speculative / debug) ----
    P("mmproj", .path, "", 5),
    P("mmproj-url", .text, "", 5),
    P("mmproj-auto", .bool, "on", 5),
    P("mmproj-offload", .bool, "on", 5),
    P("mmproj-device", .text, "auto", 5),
    P("image-min-tokens", .num, "读自模型", 5),
    P("image-max-tokens", .num, "读自模型", 5),
    P("mtmd-batch-max-tokens", .num, "1024", 5),
    P("video-fps", .num, "4.0", 5),
    P("video-timestamp-interval", .num, "5000", 5),
    P("video-ffmpeg-dir", .path, "在 PATH 中查找", 5),
    P("pooling", .choice(["none", "mean", "cls", "last", "rank"]), "模型默认", 5),
    P("embd-normalize", .num, "2", 5),
    P("embedding", .bool, "off", 5),
    P("rerank", .bool, "off", 5),
    P("alias", .text, "", 5),
    P("tags", .text, "", 5),
    P("host", .text, "127.0.0.1", 5),
    P("api-key", .text, "无", 5),
    P("api-key-file", .path, "无", 5),
    P("ssl-key-file", .path, "", 5),
    P("ssl-cert-file", .path, "", 5),
    P("cors-origins", .text, "*", 5),
    P("cors-methods", .text, "GET, POST, DELETE, OPTIONS", 5),
    P("cors-headers", .text, "*", 5),
    P("cors-credentials", .bool, "on", 5),
    P("api-prefix", .text, "", 5),
    P("timeout", .num, "3600", 5),
    P("sse-ping-interval", .num, "30", 5),
    P("threads-http", .num, "-1", 5),
    P("metrics", .bool, "off", 5),
    P("props", .bool, "off", 5),
    P("slots", .bool, "on", 5),
    P("media-path", .path, "disabled", 5),
    P("ui", .bool, "on (Web UI)", 5),
    P("tools", .text, "无 (all = 全部)", 5),
    P("tools-runtime", .text, "none", 5),
    P("mcp-servers-config", .path, "无", 5),
    P("mcp-servers-json", .text, "无", 5),
    P("agent", .bool, "off", 5),
    P("spec-type", .text, "none (逗号分隔: draft-simple, ngram-simple, ...)", 5),
    P("spec-draft-model", .path, "", 5),
    P("spec-draft-hf", .text, "", 5),
    P("spec-draft-n-max", .num, "3", 5),
    P("spec-draft-n-min", .num, "0", 5),
    P("spec-draft-p-split", .num, "0.10", 5),
    P("spec-draft-p-min", .num, "0.00", 5),
    P("spec-draft-type-k", .choice(KV_TYPES), "f16", 5),
    P("spec-draft-type-v", .choice(KV_TYPES), "f16", 5),
    P("spec-draft-threads", .num, "同 threads", 5),
    P("spec-draft-threads-batch", .num, "同 spec-draft-threads", 5),
    P("spec-draft-cpu-mask", .text, "同 cpu-mask", 5),
    P("spec-draft-cpu-range", .text, "同 cpu-range", 5),
    P("spec-draft-cpu-strict", .num, "同 cpu-strict", 5),
    P("spec-draft-prio", .num, "0", 5),
    P("spec-draft-poll", .num, "同 poll", 5),
    P("spec-draft-cpu-mask-batch", .text, "同 spec-draft-cpu-mask", 5),
    // NOTE: llama.cpp has --spec-draft-cpu-range-batch but it is registered
    // for the speculative example only — llama-server rejects it (verified
    // against build 52 / 73a43d1f6), so it is intentionally NOT in the catalog
    P("spec-draft-cpu-strict-batch", .num, "同 spec-draft-cpu-strict", 5),
    P("spec-draft-prio-batch", .num, "0", 5),
    P("spec-draft-poll-batch", .num, "同 spec-draft-poll", 5),
    P("spec-draft-override-tensor", .text, "", 5),
    P("spec-draft-cpu-moe", .bool, "off", 5),
    P("spec-draft-n-cpu-moe", .num, "默认", 5),
    P("spec-draft-device", .text, "默认", 5),
    P("spec-draft-ngl", .text, "auto", 5),
    P("spec-draft-backend-sampling", .bool, "on", 5),
    P("spec-synth-len", .num, "", 5),
    P("spec-synth-rates", .text, "", 5),
    P("spec-ngram-mod-n-min", .num, "48", 5),
    P("spec-ngram-mod-n-max", .num, "64", 5),
    P("spec-ngram-mod-n-match", .num, "24", 5),
    P("spec-ngram-simple-size-n", .num, "12", 5),
    P("spec-ngram-simple-size-m", .num, "48", 5),
    P("spec-ngram-simple-min-hits", .num, "1", 5),
    P("spec-ngram-map-k-size-n", .num, "12", 5),
    P("spec-ngram-map-k-size-m", .num, "48", 5),
    P("spec-ngram-map-k-min-hits", .num, "1", 5),
    P("spec-ngram-map-k4v-size-n", .num, "12", 5),
    P("spec-ngram-map-k4v-size-m", .num, "48", 5),
    P("spec-ngram-map-k4v-min-hits", .num, "1", 5),
    P("log-verbosity", .num, "3", 5),
    P("verbose", .bool, "off", 5),
    P("log-colors", .choice(["on", "off", "auto"]), "auto", 5),
    P("log-prefix", .bool, "on", 5),
    P("log-timestamps", .bool, "on", 5),
    P("log-file", .path, "", 5),
    P("offline", .bool, "off", 5),
    P("perf", .bool, "off", 5),
    P("escape", .bool, "on", 5),
    P("reverse-prompt", .text, "", 5),
    P("spm-infill", .bool, "off", 5),
]

let PARAM_INDEX: [String: Param] = Dictionary(uniqueKeysWithValues: PARAMS.map { ($0.key, $0) })

// Parameters pinned to the "基本" section by default (new models & legacy
// files without a pinned line).
let DEFAULT_PINS: [String] = [
    "n-gpu-layers", "ctx-size", "cache-type-k", "cache-type-v",
    "jinja", "chat-template-file",
    "reasoning", "reasoning-effort", "reasoning-budget", "reasoning-preserve",
    "temp", "top-p", "top-k", "min-p", "presence-penalty", "repeat-penalty",
    "flash-attn",
    "spec-type", "spec-draft-model", "spec-draft-type-k", "spec-draft-type-v",
]

// MARK: - .llm file (key = value lines + optional "# pinned:" comment)

// The pinned line is app-private metadata: it stays out of the router
// preset (buildPresetFile strips it), so llama.cpp never sees it.
struct LlmFile {
    var values: [String: String]
    var order: [String]      // key order as written to the file
    var pinned: [String]
    // display-only alias ("# display-name:" comment); the router model
    // id is always the GGUF's real name, never this
    var displayName = ""

    static func parse(_ text: String) -> LlmFile {
        var f = LlmFile(values: [:], order: [], pinned: [])
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let lower = line.lowercased()
                if lower.hasPrefix("# pinned:") {
                    f.pinned = line.dropFirst("# pinned:".count)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && PARAM_INDEX[$0] != nil }
                } else if lower.hasPrefix("# display-name:") {
                    f.displayName = String(line.dropFirst("# display-name:".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, f.values[k] == nil {
                f.order.append(k)
                f.values[k] = v
            }
        }
        return f
    }

    static func read(_ path: String) -> LlmFile {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return LlmFile(values: [:], order: [], pinned: [])
        }
        return parse(text)
    }

    func text() -> String {
        var out = ""
        for k in order {
            if let v = values[k], !v.isEmpty { out += k + " = " + v + "\n" }
        }
        if !displayName.isEmpty { out += "# display-name: " + displayName + "\n" }
        if !pinned.isEmpty { out += "# pinned: " + pinned.joined(separator: ", ") + "\n" }
        return out
    }
}

// MARK: - Shared log store (replaces the old AppKit log window)

final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    func append(_ line: String) {
        // @Published must mutate on the main thread; the audio proxy calls
        // in from its own queues (audit B11). Hop once; the cap logic and
        // ordering land on the main queue (FIFO), same as router lines.
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.append(line) }
            return
        }
        lines.append(line)
        // cap in-memory buffer (~200k chars, mirrors the old window)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }
}

// MARK: - Navigation state

enum DashPage: Hashable { case models, upgrade, logs, settings, experimental }
enum ModelsTab: Hashable { case global, add, list }

// NOTE: no @State anywhere in this file — @State is macro-based in the
// CLT Swift 6.4 toolchain and plain swiftc cannot find the macro plugin.
// View-local state lives in small ObservableObjects instead.
final class DashboardModel: ObservableObject {
    @Published var page: DashPage = .models
    // opening the panel lands on 全局参数 by default
    @Published var modelsTab: ModelsTab = .global
    @Published var selectedModel: String? = nil   // nil = 全局参数 / 添加新模型
    @Published var searchText = ""
    @Published var loadedIDs: Set<String> = []
    @Published var routerReady = false
    @Published var modelEntries: [ModelEntry] = []
    // survives page switches; the view observes the FormModel directly.
    // MUST be @Published: assigning it from a view body / onChange only
    // re-renders if this change is published (first version had it as a
    // plain var and the form never appeared on screen)
    @Published var form: FormModel?
}

// MARK: - Model parameter form

enum FormMode: Hashable, Equatable {
    case global              // settings/global.llm — template only, no pins
    case add                 // prefilled from global, writes config/<id>.llm
    case edit(id: String)    // reads/writes only that model's .llm
}

final class FormModel: ObservableObject {
    let mode: FormMode
    @Published var values: [String: String]
    @Published var order: [String]
    @Published var pinned: [String]
    @Published var ggufPath = ""     // "model" key (add/edit modes)
    @Published var customName = ""   // display-only alias (add + edit modes)
    @Published var errorMessage: String?
    @Published var justSaved = false
    // version-C section cards: collapsed by default, user expands what
    // they need (the pinned 基本 card stays fully visible on top)
    @Published var openGroups: Set<Int> = []

    init(mode: FormMode) {
        self.mode = mode
        if mode == .global { Self.seedGlobalFile() }
        switch mode {
        case .global:
            let f = LlmFile.read(GLOBAL_FILE)
            values = f.values; order = f.order
            pinned = f.pinned.isEmpty ? DEFAULT_PINS : f.pinned
        case .add:
            // 添加新模型 = 预填全局参数(值 + 置顶都来自全局文件)
            let f = LlmFile.read(GLOBAL_FILE)
            values = f.values; order = f.order
            pinned = f.pinned.isEmpty ? DEFAULT_PINS : f.pinned
        case .edit(let id):
            let f = LlmFile.read(CONFIG_DIR + "/" + id + CONFIG_EXT)
            values = f.values; order = f.order
            pinned = f.pinned.isEmpty ? DEFAULT_PINS : f.pinned
            ggufPath = f.values["model"] ?? ""
            customName = f.displayName
        }
    }

    // model id = always the GGUF filename without extension (stable,
    // visible to external tools); the custom name is display-only
    var targetID: String {
        URL(fileURLWithPath: ggufPath).deletingPathExtension().lastPathComponent
    }

    // single write path for parameter values: keeps `order` in sync.
    // (text() emits lines by walking `order`, so a key that only exists
    // in `values` would be silently dropped on save — the bug behind
    // "保存没有成功" when starting from a pinned-only global file)
    func setValue(_ key: String, _ v: String?) {
        justSaved = false
        if let v, !v.isEmpty {
            if values[key] == nil, !order.contains(key) { order.append(key) }
            values[key] = v
        } else {
            values[key] = nil
        }
    }

    // returns error message, or nil on success
    func save() -> String? {
        var v = values
        var o = order
        // belt & braces: any key present in values must be emitted
        for k in v.keys where !o.contains(k) { o.append(k) }
        if mode != .global {
            guard !ggufPath.isEmpty else { return T("模型路径必填") }
            v["model"] = ggufPath
            o.removeAll { $0 == "model" }
            o.insert("model", at: 0)
        }
        switch mode {
        case .global:
            try? LlmFile(values: v, order: o, pinned: pinned).text()
                .write(toFile: GLOBAL_FILE, atomically: true, encoding: .utf8)
        case .add:
            let id = targetID
            guard !id.isEmpty else { return T("模型路径必填") }
            try? LlmFile(values: v, order: o, pinned: pinned, displayName: customName).text()
                .write(toFile: CONFIG_DIR + "/" + id + CONFIG_EXT, atomically: true, encoding: .utf8)
        case .edit(let id):
            try? LlmFile(values: v, order: o, pinned: pinned, displayName: customName).text()
                .write(toFile: CONFIG_DIR + "/" + id + CONFIG_EXT, atomically: true, encoding: .utf8)
        }
        return nil
    }

    func togglePin(_ key: String) {
        if let i = pinned.firstIndex(of: key) { pinned.remove(at: i) }
        else { pinned.append(key) }
    }

    // First run: create settings/global.llm prefilled with the default
    // pinned params so 全局参数 opens with a usable template instead of
    // an empty form.
    static func seedGlobalFile() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: GLOBAL_FILE) else { return }
        var values: [String: String] = [:]
        var order: [String] = []
        for key in ["n-gpu-layers", "ctx-size", "cache-type-k", "cache-type-v",
                    "jinja", "reasoning", "temp", "top-p", "top-k", "min-p"] {
            values[key] = ""
            order.append(key)
        }
        let f = LlmFile(values: values, order: order, pinned: Array(DEFAULT_PINS))
        try? fm.createDirectory(atPath: SETTINGS_DIR, withIntermediateDirectories: true)
        try? f.text().write(toFile: GLOBAL_FILE, atomically: true, encoding: .utf8)
    }

    // 重置为默认:clear every value (empty = llama.cpp official default)
    func resetAll() {
        values = [:]
        order = []
    }

    func toggleGroup(_ g: Int) {
        if openGroups.contains(g) { openGroups.remove(g) } else { openGroups.insert(g) }
    }
}

// MARK: - Form views

// Dense form row (version-C style): key left, control right, pin icon.
// Set values render bold; unset fields show the gray "default (X)" hint.
struct DenseRow: View {
    @ObservedObject var fm: FormModel
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    let param: Param
    let canPin: Bool

    private var isPinned: Bool { fm.pinned.contains(param.key) }
    private var isSet: Bool { !(fm.values[param.key] ?? "").isEmpty }

    private var valueBinding: Binding<String> {
        Binding(
            get: { fm.values[self.param.key] ?? "" },
            set: { nv in fm.setValue(self.param.key, nv) })
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                let v = (fm.values[self.param.key] ?? "").lowercased()
                return v == "1" || v == "on" || v == "true"
            },
            set: { on in fm.setValue(self.param.key, on ? "1" : "0") })
    }

    // key column is fixed so every row aligns (175 fits the longest keys,
    // spec-draft-cpu-strict-batch = 25 chars at 11pt monospace); the
    // control column is flexible with a floor, so at the minimum window
    // size nothing overlaps and at larger sizes fields just get roomier.
    static let keyWidth: CGFloat = 175
    static let controlMinWidth: CGFloat = 140

    // hover tooltip: full default text, wrapped so long explanations
    // (AppKit tooltips are single-line by default and would run off
    // screen). Breaks at spaces when possible, hard-breaks for CJK.
    private var helpText: String? {
        guard !param.def.isEmpty else { return nil }
        // def stays Chinese in the catalog (source of truth); translated at render
        return T("默认: ") + Self.wrap(T(param.def), width: 28).joined(separator: "\n")
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var rest = text
        while rest.count > width {
            let idx = rest.index(rest.startIndex, offsetBy: width)
            let chunk = rest[..<idx]
            if let sp = chunk.lastIndex(of: " ") {
                lines.append(String(rest[..<sp]))
                rest = String(rest[rest.index(after: sp)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(String(chunk))
                rest = String(rest[idx...])
            }
        }
        if !rest.isEmpty { lines.append(rest) }
        return lines
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(param.key)
                .font(.system(size: isSet ? 13 : 12, design: .monospaced)
                    .weight(isSet ? .bold : .regular))
                .foregroundStyle(isSet ? .primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: DenseRow.keyWidth, alignment: .leading)
            control
                .frame(minWidth: DenseRow.controlMinWidth, maxWidth: .infinity, alignment: .leading)
            if canPin {
                Button {
                    fm.togglePin(param.key)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 9))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(isPinned ? T("取消置顶") : T("置顶到基本区"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
        // hovering anywhere on the row shows the full default text;
        // the pin button keeps its own (more specific) help
        .help(helpText ?? "")
    }

    // every branch is sized by the caller (flexible, min controlMinWidth),
    // so text fields, dropdowns, toggles and path rows all start at the
    // same x and their text is left-aligned inside the column
    @ViewBuilder
    private var control: some View {
        switch param.kind {
        case .bool:
            Toggle("", isOn: boolBinding)
                .labelsHidden()
                .controlSize(.small)
        case .choice(let choices):
            Picker("", selection: valueBinding) {
                Text("default (\(T(param.def)))").tag("")
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            // version-C look: a chosen value stands out in bold accent
            .foregroundStyle(isSet ? Color.accentColor : Color.primary)
        case .path:
            HStack(spacing: 6) {
                TextField("default (\(T(param.def)))", text: valueBinding)
                    .font(.system(size: 11, design: .monospaced)
                        .weight(isSet ? .semibold : .regular))
                    .foregroundStyle(isSet ? Color.accentColor : Color.primary)
                Button(T("浏览…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        fm.setValue(param.key, url.path)
                    }
                }
                .controlSize(.small)
            }
        default:
            TextField("default (\(T(param.def)))", text: valueBinding)
                .font(.system(size: 11, design: .monospaced)
                    .weight(isSet ? .semibold : .regular))
                // version-C look: entered values are bold blue
                .foregroundStyle(isSet ? Color.accentColor : Color.primary)
        }
    }
}

// Version-C form: dense two-column rows, collapsible section cards,
// search filter, pinned block on top, set values bold.
struct FormView: View {
    @ObservedObject var fm: FormModel
    @ObservedObject var dm: DashboardModel
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    let app: AppDelegate
    var onSaved: () -> Void
    var onDelete: (() -> Void)? = nil

    // pinning is available in all three modes; the pin list is stored in
    // each file (.llm / global.llm) as a '# pinned:' comment line
    private var canPin: Bool { true }
    private var q: String { dm.searchText.lowercased() }
    private func matches(_ p: Param) -> Bool { q.isEmpty || p.key.lowercased().contains(q) }

    private let grid = [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                basicCard
                ForEach(1...5, id: \.self) { g in sectionCard(g) }
                bottomBar
            }
            .padding(12)
            .padding(.horizontal, 50)   // 行内容留 50; 卡片背景靠 breakoutCard 外扩到窗口边
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // clicking empty space commits the focused field (same as
            // pressing Return) — children keep tap priority, so this only
            // fires on blank areas
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    // 基本: fixed fields (path + name) + all pinned params
    private var basicCard: some View {
        VStack(spacing: 0) {
            sectionHeader(title: T("基本 · 置顶"), count: pinnedRows.count, setCount: pinnedSetCount,
                          chevron: false, isOpen: true)
            if fm.mode == .add || fm.mode.isEdit {
                fixedFieldRow("model", value: $fm.ggufPath, placeholder: T("GGUF 文件路径(必填)"), browse: true,
                              readOnly: fm.mode.isEdit)
                // 显示别名: 只影响 UI 显示, 模型 ID 恒为 GGUF 真名
                fixedFieldRow(T("自定义名称"), value: $fm.customName, placeholder: T("留空 = 显示文件名"), browse: false)
                if fm.mode == .add, !fm.targetID.isEmpty {
                    Text(TF("将保存为 config/%@.llm", fm.targetID))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 12).padding(.bottom, 4)
                }
            }
            if pinnedRows.isEmpty && canPin {
                Text(T("点参数行右侧的图钉,把常用参数置顶到这里"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                LazyVGrid(columns: grid, spacing: 0) {
                    ForEach(pinnedRows, id: \.key) { p in
                        DenseRow(fm: fm, param: p, canPin: canPin)
                    }
                }
            }
        }
        .background(breakoutCard)
    }

    @ViewBuilder
    private func sectionCard(_ g: Int) -> some View {
        // 组内参数按字母序(用户定案 2026-09-10:原定义顺序观感乱)
        let rows = PARAMS.filter { $0.group == g && !fm.pinned.contains($0.key) && matches($0) }
            .sorted { $0.key < $1.key }
        if !rows.isEmpty {
            VStack(spacing: 0) {
                Button {
                    if !q.isEmpty { fm.openGroups = Set(1...5) } else { fm.toggleGroup(g) }
                } label: {
                    sectionHeader(title: T(GROUP_NAMES[g] ?? ""), count: rows.count,
                                  setCount: rows.filter { !(fm.values[$0.key] ?? "").isEmpty }.count,
                                  chevron: true,
                                  isOpen: fm.openGroups.contains(g) || !q.isEmpty)
                    // make the WHOLE row tappable, not just the text
                    // (Spacer regions are not hit-testable by default)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if fm.openGroups.contains(g) || !q.isEmpty {
                    LazyVGrid(columns: grid, spacing: 0) {
                        ForEach(rows, id: \.key) { p in
                            DenseRow(fm: fm, param: p, canPin: canPin)
                        }
                    }
                }
            }
            .background(breakoutCard)
        }
    }

    // 基本区钉上来的参数也按字母序(与分组 section 一致)
    private var pinnedRows: [Param] { PARAMS.filter { fm.pinned.contains($0.key) && matches($0) }
        .sorted { $0.key < $1.key } }
    private var pinnedSetCount: Int { pinnedRows.filter { !(fm.values[$0.key] ?? "").isEmpty }.count }

    // 卡片突破页面 50pt padding 填到窗口边缘(内容仍留 50):
    // 负 padding 只撑大绘制区,不影响布局 —— 卡片变大,行位置不变。
    // 半透明灰底,自动适配明暗模式。
    // 纵向不外扩: 外扩会让相邻卡片的灰底在 10pt 缝隙里重叠,
    // 露出「超长椭圆」边,且折叠时灰区大于可点的 header 行,易点错
    private var breakoutCard: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.14)))
            .padding(.horizontal, -50)
    }

    private func sectionHeader(title: String, count: Int, setCount: Int, chevron: Bool, isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(setCount > 0 ? TF("%d 项 · %d 已设置", count, setCount) : TF("%d 项", count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(Divider(), alignment: .bottom)
    }

    private func fixedFieldRow(_ label: String, value: Binding<String>, placeholder: String, browse: Bool, readOnly: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: DenseRow.keyWidth, alignment: .leading)
            TextField(placeholder, text: value)
                .font(.system(size: 11, design: .monospaced))
                .disabled(readOnly)   // 灰色只读(编辑模式:路径 = 模型身份,不可改)
            if browse && !readOnly {
                Button(T("浏览…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(T("保存")) {
                if let err = fm.save() { fm.errorMessage = err }
                else { fm.errorMessage = nil; fm.justSaved = true; onSaved() }
            }
            .keyboardShortcut(.defaultAction)
            if fm.justSaved {
                Text(T("已保存"))
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Button(T("重置为默认")) {
                // 二次确认,防误触
                let alert = NSAlert()
                alert.messageText = T("重置为默认")
                alert.informativeText = T("将清空所有已填参数(回到 llama.cpp 官方默认),置顶不受影响。点「保存」后才会写入文件。")
                alert.addButton(withTitle: T("重置"))
                alert.addButton(withTitle: T("取消"))
                if alert.runModal() == .alertFirstButtonReturn {
                    fm.resetAll()
                }
            }
            if let msg = fm.errorMessage {
                Text(msg).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            if let del = onDelete {
                Button(T("删除配置")) { del() }
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 2)
    }
}

private extension FormMode {
    var isEdit: Bool { if case .edit = self { return true }; return false }
}

// MARK: - Models page (全局参数 / 添加新模型 / 模型配置)

struct ModelsPage: View {
    @ObservedObject var dm: DashboardModel
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    let app: AppDelegate

    // 模型 dropdown: nil = nothing selected (prompt shown)
    private var modelSelection: Binding<String?> {
        Binding(
            get: { dm.modelsTab == .list ? dm.selectedModel : nil },
            set: { id in
                if let id { dm.modelsTab = .list; dm.selectedModel = id }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            if !dm.routerReady {
                HStack(spacing: 8) {
                    Text(T("llama.cpp 未就绪,模型暂不可用"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button(T("去环境页 →")) { dm.page = .upgrade }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            // 顶栏: 下拉 + 全局参数(突出) + 添加新模型 + 搜索(撑满剩余)
            // 总最小宽必须 < 窗口最小内容宽, 否则搜索框会被挤没
            HStack(spacing: 10) {
                Picker("", selection: modelSelection) {
                    Text(T("选择模型…")).tag(String?.none)
                    ForEach(dm.modelEntries, id: \.id) { m in
                        Text(m.label + (dm.loadedIDs.contains(m.id) ? T(" · 已加载") : "")).tag(String?.some(m.id))
                    }
                }
                .labelsHidden()
                .controlSize(.large)
                .frame(width: 380)
                // 选中 = 实心蓝底白字, 未选中 = 朴素; 重复点当前 tab 是 no-op
                // (guard 防止 dm.form = nil 丢掉已填的表单)
                Button {
                    guard dm.modelsTab != .global else { return }
                    dm.modelsTab = .global
                    dm.selectedModel = nil
                    dm.form = nil
                    dm.searchText = ""
                } label: {
                    Text(T("全局参数"))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(dm.modelsTab == .global ? Color.accentColor : Color.primary.opacity(0.10)))
                        .foregroundStyle(dm.modelsTab == .global ? .white : .primary)
                }
                .buttonStyle(.plain)
                Button {
                    guard dm.modelsTab != .add else { return }
                    dm.modelsTab = .add
                    dm.selectedModel = nil
                    dm.form = nil
                    dm.searchText = ""
                } label: {
                    Text(T("添加新模型"))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(dm.modelsTab == .add ? Color.accentColor : Color.primary.opacity(0.10)))
                        .foregroundStyle(dm.modelsTab == .add ? .white : .primary)
                }
                .buttonStyle(.plain)
                TextField(T("搜索参数…(如 temp / gpu / cache)"), text: $dm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                // 一键清空: 非空才显示。独立按钮放框外(不叠在框内,
                // 否则悬停时底下文本框的 I 型光标会透出来)
                if !dm.searchText.isEmpty {
                    Button { dm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .padding(.horizontal, 50)   // 顶栏留 50; 卡片所在 ScrollView 通到窗口边
            // GGUF 真名(传给其他 agent 的模型名): 选中模型才显示,
            // 与状态栏「复制模型名」对应
            if dm.modelsTab == .list, let id = dm.selectedModel {
                HStack(spacing: 8) {
                    Text(app.ggufModelName(id: id))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button(T("复制")) { app.copyModelName(id: id) }
                        .controlSize(.mini)
                    Spacer()
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 2)
            }
            Divider()
            content
        }
        .padding(.horizontal, 0)
        .padding(.top, 12)
        .padding(.bottom, 50)
        .onChange(of: dm.selectedModel) { dm.form = nil }
        .onAppear { refreshEntries() }
    }

    // Form creation happens in the body (not in onChange): assigning
    // dm.form must land in the same render pass, otherwise the form
    // view never appears until some unrelated state change.
    private func currentForm() -> FormModel? {
        switch dm.modelsTab {
        case .global:
            if dm.form?.mode == .global { return dm.form }
            dm.form = FormModel(mode: .global)
        case .add:
            if dm.form?.mode == .add { return dm.form }
            dm.form = FormModel(mode: .add)
        case .list:
            guard let id = dm.selectedModel else { return nil }
            if dm.form?.mode == .edit(id: id) { return dm.form }
            dm.form = FormModel(mode: .edit(id: id))
        }
        return dm.form
    }

    @ViewBuilder
    private var content: some View {
        switch dm.modelsTab {
        case .global:
            if let f = currentForm() {
                FormView(fm: f, dm: dm, app: app, onSaved: {
                    app.appendLogLine("[dashboard] global params saved")
                })
            }
        case .add:
            if let f = currentForm() {
                FormView(fm: f, dm: dm, app: app, onSaved: {
                    app.modelsDidChange()
                    app.appendLogLine("[dashboard] model added: \(f.targetID)")
                    dm.modelsTab = .list
                    dm.selectedModel = f.targetID
                    dm.form = nil
                    refreshEntries()
                })
            }
        case .list:
            if let id = dm.selectedModel, let f = currentForm() {
                FormView(fm: f, dm: dm, app: app,
                         onSaved: {
                    app.modelsDidChange()
                    app.appendLogLine("[dashboard] model config saved: \(id)")
                },
                         onDelete: {
                    if let m = dm.modelEntries.first(where: { $0.id == id }) { deleteModel(m) }
                })
            } else {
                Text(dm.modelEntries.isEmpty
                     ? T("config/ 里没有模型,点上方「添加新模型」")
                     : T("从上方「模型」下拉菜单选择要配置的模型"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func deleteModel(_ m: ModelEntry) {
        if dm.loadedIDs.contains(m.id) {
            showAlert(T("无法删除"), T("模型正在加载,请先卸载模型"))
            return
        }
        let alert = NSAlert()
        alert.messageText = TF("删除模型 %@", m.label)
        alert.informativeText = T("确认删除参数配置(不会删除模型本体)")
        alert.addButton(withTitle: T("确认"))
        alert.addButton(withTitle: T("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(atPath: m.path)
        if dm.selectedModel == m.id { dm.selectedModel = nil; dm.form = nil }
        app.modelsDidChange()
        app.appendLogLine("[dashboard] model config deleted: \(m.id)")
        refreshEntries()
    }

    private func refreshEntries() {
        dm.modelEntries = loadModelEntries()
    }

    private func showAlert(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Upgrade page (git pull + cmake build of the user's llama.cpp)

// Runs a shell command in its OWN process group so the whole tree
// (zsh + git/cmake/ninja/compilers) can be killed as a unit (audit A4).
// fork+exec, not Process: on macOS the parent cannot regroup a
// posix_spawned child (setpgid after Process.run() → EPERM, verified),
// so a group-killable command has to be forked. Parent-side
// setpgid(child, child) is the pattern proven in RouterProc (audit A2).
final class GroupRunner {
    private(set) var pid: pid_t = 0
    private(set) var pgid: pid_t = 0
    private var readHandle: FileHandle?
    private var pending = Data()
    // set by whichever reaps first (EOF handler or killTree()); exit code,
    // -1 if the process died by signal or was never reaped
    private var exitStatus: Int32? = nil
    // both callbacks are delivered on the main queue
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private static func codeOf(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }

    // returns error message, or nil on success
    func start(command: String) -> String? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return "pipe() failed" }
        let writeFd = fds[1]
        let cZsh = strdup("/bin/zsh"), cLc = strdup("-lc"), cCmd = strdup(command)
        var argv: [UnsafeMutablePointer<CChar>?] = [cZsh, cLc, cCmd, nil]
        let child = sys_fork()
        if child < 0 {
            close(fds[0]); close(writeFd)
            free(cZsh); free(cLc); free(cCmd)
            return "fork() failed"
        }
        if child == 0 {
            // child: stdout/stderr -> pipe, then exec. Only
            // async-signal-safe C calls from here on (RouterProc discipline).
            // dup2 returns the NEW fd on success (1 / 2), -1 on error —
            // checking != 0 would always "fail" and kill the child (caught
            // by /tmp replica: 8/8 runs died at the first dup2)
            if dup2(writeFd, 1) == -1 { _exit(127) }
            if dup2(writeFd, 2) == -1 { _exit(127) }
            if writeFd > 2 { close(writeFd) }
            execv(cZsh, &argv)
            _exit(127)
        }
        close(writeFd)
        free(cZsh); free(cLc); free(cCmd)   // child has its own address space
        pid = child
        pgid = (setpgid(child, child) == 0) ? child : 0
        let h = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        readHandle = h
        h.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                // EOF: every writer (zsh + all children) is gone, so the
                // wait returns immediately. Reap, flush a trailing line
                // without newline (audit D1), close the fd exactly once.
                var status: Int32 = 0
                if self.pid > 0, waitpid(self.pid, &status, 0) == self.pid {
                    self.pid = 0
                    self.exitStatus = Self.codeOf(status)
                }
                if !self.pending.isEmpty {
                    let rest = String(data: self.pending, encoding: .utf8) ?? ""
                    self.pending = Data()
                    DispatchQueue.main.async { self.onLine?(rest) }
                }
                handle.closeFile()
                self.readHandle = nil
                self.pgid = 0
                let code = self.exitStatus ?? -1
                DispatchQueue.main.async { self.onExit?(code) }
                return
            }
            self.pending.append(data)
            while let idx = self.pending.firstIndex(of: 0x0A) {
                let line = String(data: self.pending.subdata(in: 0..<idx), encoding: .utf8)
                self.pending.removeSubrange(0..<idx + 1)
                if let line { DispatchQueue.main.async { self.onLine?(line) } }
            }
        }
        return nil
    }

    // SIGTERM the whole group, wait up to 5s, escalate to SIGKILL.
    // Safe to call when the tree is already gone (no-op).
    func killTree() {
        let g = pgid
        guard pid > 0 || g > 0 else { return }
        let useGroup = g > 0 && g != getpgid(0)
        if useGroup { kill(-g, SIGTERM) } else if pid > 0 { kill(pid, SIGTERM) }
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if pid > 0 {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    pid = 0
                    exitStatus = Self.codeOf(status)
                }
            }
            let gone = useGroup ? kill(-g, 0) != 0 : (pid == 0 || kill(pid, 0) != 0)
            if gone { break }
            usleep(100_000)
        }
        if useGroup, kill(-g, 0) == 0 {
            kill(-g, SIGKILL)
            if pid > 0 { waitpid(pid, nil, 0); pid = 0; exitStatus = -1 }
        } else if !useGroup, pid > 0, kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
            pid = 0
            exitStatus = -1
        }
    }
}

// Shared across all UpgradeRunner instances: only one build pipeline may run
// at a time. The env-page (llama.cpp 升级) and settings-page (Corral 自更新)
// runners are separate instances with separate `running` flags; without this
// a user could trigger both and they'd race on teardown (both end by stopping
// the router / relaunching the app). Pages observe this to disable their
// update buttons while any pipeline is busy (audit D11).
final class PipelineState: ObservableObject {
    static let shared = PipelineState()
    @Published var busy = false
}

final class UpgradeRunner: ObservableObject {
    @Published var lines: [String] = []
    @Published var running = false
    @Published var finished: String? = nil
    // success/failure drives the finished-line color — never key off the
    // display text (it changes with the UI language)
    @Published var finishedOK = true
    private var runner: GroupRunner?
    // set by cancel(): the finished line then says 已取消 instead of 失败
    private var cancelled = false

    // runs a command via a login shell (PATH: homebrew cmake) in its own
    // process group, so cancel() can kill the whole tree
    private func run(_ command: String, done: @escaping (Bool) -> Void) {
        let r = GroupRunner()
        runner = r
        cancelled = false
        r.onLine = { [weak self] line in self?.lines.append(line) }
        r.onExit = { [weak self] code in
            self?.runner = nil
            done(code == 0)
        }
        if let err = r.start(command: command) {
            runner = nil
            lines.append(err)
            done(false)
        }
    }

    // done(ok) fires on the main queue once the whole pipeline finished
    private func pipeline(_ commands: [(String, String)], done: @escaping (Bool) -> Void) {
        guard !commands.isEmpty else { done(true); return }
        let (label, cmd) = commands[0]
        lines.append(label)
        run(cmd) { [weak self] ok in
            guard let self else { return }
            guard ok else { done(false); return }
            self.pipeline(Array(commands.dropFirst()), done: done)
        }
    }

    // upgrade an existing self-built checkout (git pull + rebuild);
    // on success the router is restarted so the new binary takes effect.
    // pull=false (编译并生效) compiles exactly what's in the tree — pulling
    // is 开始升级's job; hasUpstream=false skips the pull step with a note
    // instead of dying on "no tracking information" (audit A7). Real pull
    // failures (conflict/network) still fail the pipeline either way.
    // doneMessage: the caller still has post-steps (record built, restart
    // router) after done(ok), so the "finished" line must not claim the
    // whole job is over — the caller supplies the accurate wording
    func start(src: String, pull: Bool = true, hasUpstream: Bool = true,
               doneMessage: String? = nil, done: @escaping (Bool) -> Void) {
        guard !running, !PipelineState.shared.busy else { return }
        running = true
        PipelineState.shared.busy = true
        finished = nil
        lines = []
        var steps: [(String, String)] = []
        if pull {
            if hasUpstream {
                steps.append(("$ git -C \(src) pull", "git -C \"\(src)\" pull"))
            } else {
                note(T("当前分支无上游,跳过 pull 直接编译"))
            }
        }
        steps.append(("$ cmake --build \(src)/build -j 8", "cmake --build \"\(src)/build\" -j 8"))
        pipeline(steps) { ok in
            self.running = false
            PipelineState.shared.busy = false
            self.finishedOK = ok
            self.finished = ok ? (doneMessage ?? T("升级完成")) : (self.cancelled ? T("已取消") : T("升级失败,查看上方输出"))
            done(ok)
        }
    }

    // Corral 自身一键更新: 自己源码仓库里 pull + 重编
    func selfUpdate(repo: String, done: @escaping (Bool) -> Void) {
        guard !running, !PipelineState.shared.busy else { return }
        running = true
        PipelineState.shared.busy = true
        finished = nil
        lines = []
        pipeline([
            ("$ git -C \(repo) pull", "git -C \"\(repo)\" pull"),
            ("$ ./build.sh", "cd \"\(repo)\" && ./build.sh"),
        ]) { ok in
            self.running = false
            PipelineState.shared.busy = false
            self.finishedOK = ok
            self.finished = ok ? T("更新完成") : (self.cancelled ? T("已取消") : T("更新失败,查看上方输出"))
            done(ok)
        }
    }

    // assisted install: official one-line installer (prebuilt binary,
    // lands in ~/.llama-app — the app does not manage that tree itself)
    func installOfficial(done: @escaping (Bool) -> Void) {
        guard !running else { return }
        running = true
        finished = nil
        lines = []
        pipeline([("$ curl -LsSf https://llama.app/install.sh | sh",
                   "curl -LsSf https://llama.app/install.sh | sh")]) { ok in
            self.running = false
            self.finishedOK = ok
            self.finished = ok ? T("官方版安装完成") : (self.cancelled ? T("已取消") : T("官方版安装失败,查看上方输出"))
            done(ok)
        }
    }

    // assisted install: self-built. The checkout stays where the user put
    // it (normal llama.cpp layout); the app only runs the commands and
    // records the resulting paths. Existing checkouts get pull + rebuild.
    func installSource(dir: String, done: @escaping (Bool) -> Void) {
        guard !running else { return }
        let fm = FileManager.default
        _ = try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exists = fm.fileExists(atPath: dir + "/.git")
        running = true
        finished = nil
        lines = []
        let steps: [(String, String)] = [
            (exists ? "$ git -C \(dir) pull"
                    : "$ git clone https://github.com/ggml-org/llama.cpp \(dir)",
             exists ? "git -C \"\(dir)\" pull"
                    : "git clone https://github.com/ggml-org/llama.cpp \"\(dir)\""),
            ("$ cmake -S \(dir) -B \(dir)/build -DCMAKE_BUILD_TYPE=Release",
             "cmake -S \"\(dir)\" -B \"\(dir)/build\" -DCMAKE_BUILD_TYPE=Release"),
            ("$ cmake --build \(dir)/build -j 8",
             "cmake --build \"\(dir)/build\" -j 8"),
        ]
        pipeline(steps) { ok in
            self.running = false
            self.finishedOK = ok
            self.finished = ok ? T("源码版安装完成") : (self.cancelled ? T("已取消") : T("源码版安装失败,查看上方输出"))
            done(ok)
        }
    }

    // kill the WHOLE command tree (zsh + git/cmake/ninja/compilers), not
    // just the shell — a SIGTERM to the shell alone left the build running
    // in the background while the UI said "stopped" (audit A4)
    func cancel() {
        guard let r = runner else { return }
        cancelled = true
        // killTree() blocks up to 5s (SIGKILL escalation) — off the main thread
        DispatchQueue.global().async { r.killTree() }
    }

    // plain status line (branch switch results etc.)
    func note(_ line: String) {
        lines.append(line)
    }
}

enum EnvTab: Hashable { case upgrade, adopt, branches }

// 环境 page: detects which llama.cpp the machine runs (official prebuilt /
// self-built / none) and offers the matching upgrade or install flow.
final class EnvPageModel: ObservableObject {
    @Published var env: AppDelegate.LlamaEnv = .none
    @Published var version = ""
    @Published var sourceDir = NSHomeDirectory() + "/llama.cpp"
    @Published var missingTools: [String] = []
    @Published var tab: EnvTab = .upgrade
    // which tab started the current pipeline (nil = 官方/未安装单页);
    // log/finished/cancel render on the originating tab only
    @Published var pipelineOrigin: EnvTab? = nil
    @Published var currentBranch = ""
    @Published var branches: [String] = []
    @Published var branchDiff: [String: (ahead: Int, behind: Int)] = [:]
    @Published var branchSearch = ""
    @Published var adoptDirPath = ""
    @Published var adoptName = ""
    @Published var updateLine = ""     // 更新检查状态行
    @Published var hasUpdate = false
    // 状态派生(非动作派生): built != head 就亮, 终端 checkout 也能感知
    // (审计 B13)。built 为空(app 内没编过/外部接入)不亮 —— "二进制旧"
    // 要有正向知识, 未知情况由 branchNotes 事件消息覆盖。
    @Published var needsRebuild = false
    @Published var currentBehindUpstream: Int?     // 当前分支落后自己上游几个提交
    // 更新检查的 git fetch 与升级流水线的 git pull 都更新同一仓库的
    // refs/remotes/*,并发会撞 ref 锁(真机见过:打开页面时的检查 fetch
    // 撞上升级 pull → "cannot lock ref ... unable to update local ref")。
    // 用 checkInFlight 串行化:检查在飞时 startUpgrade 挂起(pendingUpgrade),
    // 检查完成立刻补跑;流水线在跑时检查直接跳过(下次打开页面再查)。
    private var checkInFlight = false
    private var pendingUpgrade: (() -> Void)?
    // 每个 tab 自己的信息区(不共用升级的流水线日志)
    @Published var branchNotes: [String] = []
    @Published var adoptNotes: [String] = []
    let app: AppDelegate
    init(app: AppDelegate) { self.app = app }

    // detection re-runs on every page open — no separate 重新检测 button;
    // the update check runs here too (A 方案: 打开页面即查, 不做定时)
    func refresh() {
        env = app.detectEnv()
        version = ""
        missingTools = []
        updateLine = ""
        hasUpdate = false
        needsRebuild = false
        currentBehindUpstream = nil
        // 只重置"打开即查"的自动查询; 用户输入(tab/adoptDirPath/adoptName/
        // branchSearch)、事件记录(branchNotes/adoptNotes, append-only, 只随
        // app 重置, 2026-09-10 定案)、流水线便签(pipelineOrigin)和分支列表
        // (手动查询结果, 按钮保持「刷新」, 用户点刷新才重新 fetch, 2026-09
        // 验证时定案)都不动 —— model 由 app 主体保管, 切页天然存活
        queryVersion()
        if env == .source {
            queryBranch()
            checkSourceUpdate()
        }
    }

    // 源码版: fetch(只动远程标记) + 数当前分支落后上游几个提交
    func checkSourceUpdate() {
        guard !checkInFlight else { return }
        guard !app.upgradeRunner.running else { return }
        checkInFlight = true
        updateLine = T("检查更新中…")
        let src = app.settings.src
        DispatchQueue.global().async {
            guard self.app.gitFetch(src) else {
                DispatchQueue.main.async {
                    self.finishCheck()
                    self.updateLine = T("检查更新失败(网络?),下次打开页面再试")
                }
                return
            }
            let info = self.app.gitBehindInfo(src)
            let built = self.app.settings.built
            let head = self.app.gitHead(src)
            DispatchQueue.main.async {
                self.finishCheck()
                if info == nil {
                    self.updateLine = T("当前分支无对应远程分支,跳过检查")
                } else {
                    // 分支列表当前行的 ⬆N 常显(0 = 与上游同步)
                    self.currentBehindUpstream = info!.count
                    if !built.isEmpty, built != head {
                        // 代码比二进制新(切分支/pull/点过 origin/* 但没编译)
                        self.updateLine = T("⚠️ 代码已更新,当前二进制还是旧版 —— 需要编译")
                        self.hasUpdate = true
                    } else if info!.count == 0 {
                        self.updateLine = built.isEmpty
                            ? T("✅ 代码已是最新(未在 app 内编译过,二进制新旧未知)")
                            : T("✅ 已是最新")
                    } else {
                        self.updateLine = TF("⬆️ 官方有 %d 个新提交 · 最新: %@", info!.count, info!.latest)
                        self.hasUpdate = true
                    }
                }
            }
        }
    }

    // 官方版: 官方安装脚本就是从 latest 这个纯文本文件读版本号的,
    // 我们 curl 同一个文件(几百字节)和本地版本号里的 bXXXX 构建号比大小
    func checkOfficialUpdate(local: String) {
        updateLine = T("检查更新中…")
        guard let url = URL(string: "https://huggingface.co/buckets/ggml-org/install.sh/resolve/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let remote = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard !remote.isEmpty else {
                    self.updateLine = T("检查更新失败(网络?),下次打开页面再试")
                    return
                }
                if let l = Self.buildTag(local), let r = Self.buildTag(remote) {
                    if r > l {
                        self.updateLine = TF("⬆️ 有新版本(当前 b%d → 新 b%d)", l, r)
                        self.hasUpdate = true
                    } else {
                        self.updateLine = T("✅ 已是最新")
                    }
                } else {
                    self.updateLine = TF("官方最新: %@", remote)
                }
            }
        }.resume()
    }

    // first b<number> token (llama.cpp build tag, e.g. "b5123")
    static func buildTag(_ s: String) -> Int? {
        for tok in s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let t = String(tok)
            if t.hasPrefix("b"), let n = Int(t.dropFirst()) { return n }
        }
        return nil
    }

    private func queryBranch() {
        let src = app.settings.src
        DispatchQueue.global().async {
            // an empty repo (fresh git init, no commits) still reports its
            // unborn HEAD name ("master") — hide the branch until there
            // are actual commits
            let b = self.app.gitCurrentBranch(src)
            let head = self.app.gitHead(src)
            let hasCommits = !head.isEmpty
            DispatchQueue.main.async {
                self.currentBranch = hasCommits ? b : ""
                self.needsRebuild = !self.app.settings.built.isEmpty && self.app.settings.built != head
            }
        }
    }

    func queryBranches() {
        let src = app.settings.src
        DispatchQueue.global().async {
            self.app.gitFetch(src)   // 让列表里的远程分支也是新的
            let list = self.app.gitListBranches(src)
            // 每行相对当前分支的 ±提交数: 纯本地计数, 不联网
            var diff: [String: (Int, Int)] = [:]
            for b in list where b != self.app.gitCurrentBranch(src) {
                if let ab = self.app.gitAheadBehind(src, b) { diff[b] = ab }
            }
            let cur = self.app.gitCurrentBranch(src)
            let head = self.app.gitHead(src)
            DispatchQueue.main.async {
                self.branches = list
                self.branchDiff = diff
                // 刷新按钮也要重算横幅/当前分支: 终端 checkout 后点刷新
                // 应该能亮/灭横幅(审计 B13)
                self.currentBranch = cur
                self.needsRebuild = !self.app.settings.built.isEmpty && self.app.settings.built != head
            }
        }
    }

    var filteredBranches: [String] {
        guard !branchSearch.isEmpty else { return branches }
        return branches.filter { $0.lowercased().contains(branchSearch.lowercased()) }
    }

    // 分支管理: confirm -> dirty check (hard switch is deliberately NOT
    // offered — the user commits/stashes in their own terminal) -> checkout
    func selectBranch(_ name: String) {
        let confirm = NSAlert()
        confirm.messageText = TF("切换到 %@?", name)
        confirm.informativeText = TF("将执行 git checkout %@,需要重新 cmake 编译后才生效。", name)
        confirm.addButton(withTitle: T("确认切换"))
        confirm.addButton(withTitle: T("取消"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let src = app.settings.src
        let dirty = app.gitDirtyCount(src)
        guard dirty == 0 else {
            let a = NSAlert()
            a.messageText = TF("当前有未提交的改动(%d 项)", dirty)
            a.informativeText = T("请先在终端 commit 或 stash 后再切换分支。")
            a.addButton(withTitle: T("知道了"))
            a.runModal()
            return
        }
        // checkout -B resets a same-named local branch to the remote,
        // discarding its unpushed commits — block instead of doing that
        // silently (same terminal-policy as the dirty check above)
        if name.contains("/") {
            let local = (name as NSString).lastPathComponent
            if let ahead = app.gitRevCount(src, name + ".." + local), ahead > 0 {
                let a = NSAlert()
                a.messageText = TF("本地分支 %@ 有 %d 个未推送提交", local, ahead)
                a.informativeText = T("切换到远程分支会把本地分支重置到远程状态,这些提交将被丢弃。请先在终端 push 或处理后再切换。")
                a.addButton(withTitle: T("知道了"))
                a.runModal()
                return
            }
        }

        DispatchQueue.global().async {
            let err = self.app.gitCheckout(src, name)
            DispatchQueue.main.async {
                if let err {
                    self.branchNotes.append(TF("git checkout 失败:\n%@", err))
                } else {
                    let local = name.contains("/") ? (name as NSString).lastPathComponent : name
                    self.currentBranch = local
                    // 切到的代码和已编译的 commit 一致吗? 一致就不用编
                    // (built 未知时保守提示, app 内编过一次后即精确)
                    let head = self.app.gitHead(src)
                    if !self.app.settings.built.isEmpty, self.app.settings.built == head {
                        self.needsRebuild = false
                        self.branchNotes.append(TF("已切换到 %@(与当前编译版本一致,无需重新编译)", local))
                    } else {
                        self.needsRebuild = !self.app.settings.built.isEmpty
                        self.branchNotes.append(TF("已切换到 %@ —— 需要重新编译,点「编译并生效」", local))
                    }
                }
            }
        }
    }

    private func queryVersion() {
        let bin = app.settings.bin + "/llama"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", "\"\(bin)\" version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            var first = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                first = (String(data: data, encoding: .utf8) ?? "")
                    .split(separator: "\n").first.map(String.init) ?? ""
            } catch {}
            DispatchQueue.main.async {
                self.version = first
                // 官方版的更新检查要等本地版本号出来才能比
                if self.env == .official { self.checkOfficialUpdate(local: first) }
            }
        }
    }

    // 源码编译 is recommended; before running, verify the build tools the
    // app deliberately does NOT install for the user
    func beginSourceInstall() {
        let (clt, cmake) = app.checkBuildTools()
        var missing: [String] = []
        if !clt { missing.append("Xcode 命令行工具") }
        if !cmake { missing.append("CMake") }
        missingTools = missing
        if missing.isEmpty { runSourceInstall() }
    }

    func runSourceInstall() {
        missingTools = []
        let dir = sourceDir
        app.upgradeRunner.installSource(dir: dir) { [weak self] ok in
            guard let self else { return }
            if ok { self.app.finishInstall(official: false, sourceDir: dir) }
            self.refresh()
        }
    }

    func runOfficialInstall() {
        app.upgradeRunner.installOfficial { [weak self] ok in
            guard let self else { return }
            if ok { self.app.finishInstall(official: true) }
            self.refresh()
        }
    }

    // 检查完(成功或失败)都走这里:放行挂起的升级启动
    private func finishCheck() {
        checkInFlight = false
        let p = pendingUpgrade
        pendingUpgrade = nil
        p?()
    }

    func startUpgrade(from tab: EnvTab) {
        // 页面打开时的更新检查可能还在 fetch —— 等它完成再启动,
        // 否则我们的 git pull 会和它撞 ref 锁(真机见过)
        if checkInFlight {
            pendingUpgrade = { [weak self] in self?.startUpgrade(from: tab) }
            return
        }
        pipelineOrigin = tab
        let src = app.settings.src
        // 开始升级 = pull + 编;编译并生效 = 只编当前树(无上游分支上
        // pull 必败,且语义上就不该 pull —— audit A7)
        app.upgradeRunner.start(src: src,
                                pull: tab == .upgrade,
                                hasUpstream: app.gitHasUpstream(src),
                                doneMessage: T("编译完成,正在重启 router 生效…")) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.app.recordBuiltCommit()
                self.app.settings.save()   // recordBuiltCommit only sets memory — persist it
                self.needsRebuild = false   // built == head 刚成立
                // the running router still has the old binary
                self.app.restartRouterNow()
                self.app.upgradeWaitInFlight = true   // 挂起健康恢复, 120s 等待自己掌舵(审计 B8)
                self.queryVersion()
                self.waitRouterHealthy(attempt: 0)
            }
        }
    }

    // the restarted router can take a minute+ (Metal shader compilation);
    // poll /health so the "正在重启…" line resolves instead of hanging
    private func waitRouterHealthy(attempt: Int) {
        guard attempt < 40 else {
            app.upgradeRunner.finishedOK = false
            app.upgradeRunner.finished = T("router 仍未就绪,请查看日志页")
            // 标志清零 = 健康路径接管: router 还活着但不健康 → ~6s 后
            // (2 次轮询)正常杀掉; 碰巧此刻健康 → 不杀。挂起不瘫痪(审计 B8)
            app.upgradeWaitInFlight = false
            return
        }
        DispatchQueue.global().async { [weak self] in
            let ok = self?.app.api.health() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.app.upgradeRunner.finishedOK = true
                    self.app.upgradeRunner.finished = T("✅ 升级完成,router 已生效")
                    self.app.upgradeWaitInFlight = false
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.waitRouterHealthy(attempt: attempt + 1)
                    }
                }
            }
        }
    }

    // 我已有其他编译版 tab
    // 已录用 list: 当前目录(使用中,永远在最上) + 已录入记录,按路径去重。
    // 当前目录即使从未录入也显示 —— 那是当前状态的展示,不是一条记录。
    struct AdoptRow {
        let path: String
        let name: String
        let current: Bool
        let missing: Bool
        let official: Bool   // 官方版: 检测出的固定行, 置顶第二, 不可删
        let managed: Bool    // 官方源码编译版: 安装流程扶植的目录, 置顶第一, 不可删
    }

    static func displayName(path: String, name: String) -> String {
        name.isEmpty ? (path as NSString).lastPathComponent : name
    }

    // 顺序: 身份行置顶(官方源码编译版 → 官方版), 其余按 当前目录 → 记录。
    // 「使用中」徽章不决定位置, 只标记当前生效的行。
    func adoptRows() -> [AdoptRow] {
        let fm = FileManager.default
        let managed = app.settings.managedSrc
        var rows: [AdoptRow] = []
        var seen = Set<String>()
        // ① 官方源码编译版: 当前目录或已录入时才出现(两者都无 = 切不回去, 不显示)
        if !managed.isEmpty,
           managed == app.settings.src || app.settings.sources.contains(where: { $0.path == managed }) {
            let rec = app.settings.sources.first { $0.path == managed }
            rows.append(AdoptRow(path: managed,
                                 name: Self.displayName(path: managed, name: rec?.name ?? ""),
                                 current: managed == app.settings.src,
                                 missing: !fm.fileExists(atPath: managed + "/.git"),
                                 official: false, managed: true))
            seen.insert(managed)
        }
        // ② 官方版: 不是记录而是系统检测出的固定位置 —— 存在就显示,
        // 保证接入源码目录后仍有切回官方版的 UI 入口
        if let od = app.officialInstallDir() {
            rows.append(AdoptRow(path: od, name: T("官方版"),
                                 current: od == app.settings.bin, missing: false,
                                 official: true, managed: false))
            seen.insert(od)
        }
        // ③ 当前目录(未被上面覆盖时)
        if !app.settings.src.isEmpty, !seen.contains(app.settings.src) {
            let rec = app.settings.sources.first { $0.path == app.settings.src }
            rows.append(AdoptRow(path: app.settings.src,
                                 name: Self.displayName(path: app.settings.src, name: rec?.name ?? ""),
                                 current: true, missing: false, official: false, managed: false))
            seen.insert(app.settings.src)
        }
        // ④ 其余记录
        for e in app.settings.sources where !seen.contains(e.path) {
            rows.append(AdoptRow(path: e.path,
                                 name: Self.displayName(path: e.path, name: e.name),
                                 current: false,
                                 missing: !fm.fileExists(atPath: e.path + "/.git"),
                                 official: false, managed: false))
            seen.insert(e.path)
        }
        return rows
    }

    // 升级按钮的目标名: 当前(接入的)目录的显示名
    var currentDisplayName: String {
        let rec = app.settings.sources.first { $0.path == app.settings.src }
        return Self.displayName(path: app.settings.src, name: rec?.name ?? "")
    }

    // 切换编译版 = 重启 router —— 有模型加载时先确认(与 restartRouter 同模式)
    private func confirmRouterRestart(_ what: String) -> Bool {
        guard !app.loadedNames.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = T("重启 router")
        alert.informativeText = TF("%@。重启会卸载所有已加载的模型,确认继续吗?", what)
        alert.addButton(withTitle: T("重启"))
        alert.addButton(withTitle: T("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func adopt() {
        let dir = adoptDirPath.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return }
        guard confirmRouterRestart(T("正在接入其他编译版")) else { return }
        if let err = app.adoptSourceDir(dir, name: adoptName.trimmingCharacters(in: .whitespaces)) {
            adoptNotes.append(TF("接入失败:\n%@", err))
        } else {
            refresh()   // 刷新环境/已录用列表; adoptNotes 是 append-only, 顺序无约束
            adoptNotes.append(TF("已接入 %@,router 已重启", dir))
            adoptDirPath = ""
            adoptName = ""
        }
    }

    func switchTo(_ row: AdoptRow) {
        let what = row.official ? T("正在切换回官方版") : T("正在接入其他编译版")
        guard confirmRouterRestart(what) else { return }
        if row.official {
            app.switchToOfficial()
            refresh()
            adoptNotes.append(TF("已切换到 %@,router 已重启", row.name))
            return
        }
        if let err = app.adoptSourceDir(row.path, name: row.name) {
            adoptNotes.append(TF("接入失败:\n%@", err))
        } else {
            refresh()
            adoptNotes.append(TF("已切换到 %@,router 已重启", row.name))
        }
    }

    func removeEntry(_ path: String) {
        let alert = NSAlert()
        alert.messageText = T("删除这条记录?")
        alert.informativeText = T("只删除这条记录,不会删除目录和二进制文件。")
        alert.addButton(withTitle: T("删除"))
        alert.addButton(withTitle: T("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.removeSourceEntry(path)
        refresh()
    }
}

struct EnvPage: View {
    let app: AppDelegate
    @ObservedObject var runner: UpgradeRunner
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    @ObservedObject var pipelineState = PipelineState.shared   // 跨页互斥: 任一流水线在跑就禁用本页更新按钮
    @ObservedObject var m: EnvPageModel   // app 主体保管(app.envModel), 切页不销毁

    init(app: AppDelegate, runner: UpgradeRunner) {
        self.app = app
        self.runner = runner
        _m = ObservedObject(wrappedValue: app.envModel)
    }

    var body: some View {
        // 内容整体顶部对齐(底部 Spacer 吸走剩余高度),不垂直居中
        VStack(alignment: .leading, spacing: 10) {
            if m.env == .source {
                // 方案 B: 标题左 + tab 右 同一行, 路径·版本做次行
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((app.srcIsManaged ? T("✅ 官方源码编译版") : T("✅ 其他编译版"))
                             + (m.currentBranch.isEmpty ? "" : "  ·  " + TF("分支: %@", m.currentBranch)))
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(app.settings.src)\(m.version.isEmpty ? "" : "  ·  \(m.version)")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 2) {
                        tabButton(T("升级"), .upgrade)
                        tabButton(T("我已有其他编译版"), .adopt)
                        tabButton(T("分支管理"), .branches)
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.885)))
                }
                Divider()
                tabContent
            } else {
                // 官方/未安装页头(方案 B 重构时 source 页头内联了,这两页的
                // 页头被孤儿化 —— 审计 C1 恢复)
                stateHeader
                if m.env == .official {
                    HStack {
                        updateLineView
                        Spacer()
                    }
                }
                HStack {
                    if m.env == .official {
                        Button(T("升级(重跑官方安装脚本)")) { m.runOfficialInstall() }
                            .disabled(runner.running)
                    } else {
                        Button(T("源码编译(推荐)")) { m.beginSourceInstall() }
                            .disabled(runner.running || !m.missingTools.isEmpty)
                        Button(T("官方版·一键安装")) { m.runOfficialInstall() }
                            .disabled(runner.running)
                    }
                    Spacer()
                }
                // 官方/未安装页面: 有已录入的编译版时给出列表, 保证能切回去
                // (.none 也要: 当前 bin 坏了但 sources 里有健康目录时, 这是
                // 唯一的 UI 切回入口 —— 审计 B10)
                if m.env == .official || m.env == .none, m.adoptRows().contains(where: { !$0.official }) {
                    Divider()
                    Text(T("可用编译版(点击切换)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    adoptedList
                }
                if m.env == .none {
                    // 点「源码编译」后缺工具: 按钮会 disabled, 警告卡必须在这里
                    // 渲染(源码版 tab 内的两张卡只覆盖已装好源码版的状态)
                    if !m.missingTools.isEmpty {
                        toolsWarning
                    }
                    HStack(spacing: 8) {
                        Text(T("目录")).font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("~/llama.cpp", text: $m.sourceDir)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: 420)
                        Button(T("浏览…")) { pickDir(into: $m.sourceDir) }
                            .controlSize(.small)
                    }
                }
            }
            // 源码版: 流水线三件套(日志/完成/取消)跟随发起 tab(见 tabContent);
            // 官方/未安装单页: 全局显示
            if m.env != .source {
                if runner.running {
                    Button(T("取消")) { runner.cancel() }
                }
                finishedLine
                Divider()
                logBox(runner.lines)
            }
            Spacer(minLength: 0)
        }
        .padding(50)
        .onAppear { m.refresh() }
    }

    // 已录用列表(源码版接入 tab 与官方版页面共用):
    // 使用中条目置顶不可删; 官方版是检测出的固定行,不可删;
    // 缺失目录灰色禁点; 其余可点切换/可删
    @ViewBuilder
    private var adoptedList: some View {
        let rows = m.adoptRows()
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(rows, id: \.path) { row in
                    HStack(spacing: 4) {
                        Button {
                            m.switchTo(row)
                        } label: {
                            HStack(spacing: 8) {
                                Text(row.name)
                                    .font(.system(size: 12))
                                    .fontWeight(row.current ? .semibold : .regular)
                                if row.managed {
                                    Text(T("官方源码编译版"))
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(.green))
                                }
                                if row.current {
                                    Text(T("使用中"))
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor))
                                }
                                if row.missing {
                                    Text(T("目录不存在"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(row.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(row.current || row.missing)
                        .opacity(row.missing ? 0.5 : 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        if !row.current && !row.official && !row.managed {
                            Button { m.removeEntry(row.path) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.96)))
        }
    }

    @ViewBuilder
    private var stateHeader: some View {
        // source 状态的页头在 body 里(方案 B: 与 tab 同行),这里只剩官方/未安装
        switch m.env {
        case .source: EmptyView()
        case .official:
            Text(T("✅ 官方预编译版"))
                .font(.system(size: 13, weight: .semibold))
            Text("\(app.settings.bin)\(m.version.isEmpty ? "" : "  ·  \(m.version)")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        case .none:
            Text(T("❌ 未检测到 llama.cpp"))
                .font(.system(size: 13, weight: .semibold))
            Text(T("选一种方式安装,全程无需打开终端(源码版需先备好编译工具,见下方提示)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // 源码版的三个并列页(与模型页顶部入口同款交互)
    @ViewBuilder
    private var tabContent: some View {
        switch m.tab {
        case .upgrade:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(T("git pull 拉取最新代码并重新编译,完成后自动重启 router 生效。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(app.srcIsManaged ? T("开始升级") : TF("升级 %@", m.currentDisplayName)) { m.startUpgrade(from: .upgrade) }
                        .disabled(runner.running || pipelineState.busy)
                    Spacer()
                    updateLineView
                }
                if m.pipelineOrigin == .upgrade {
                    pipelineArea
                }
                if !m.missingTools.isEmpty {
                    toolsWarning
                }
            }
        case .adopt:
            VStack(alignment: .leading, spacing: 8) {
                Text(T("接入一个你自己 clone + 编译过的 llama.cpp 目录(自动检测覆盖不了任意路径的存量安装)。接入后升级/分支管理都指向它。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                adoptedList
                HStack(spacing: 8) {
                    TextField(T("目录路径"), text: $m.adoptDirPath)
                        .font(.system(size: 11, design: .monospaced))
                    TextField(T("名字(留空 = 取目录名)"), text: $m.adoptName)
                        .font(.system(size: 11))
                        .frame(maxWidth: 180)
                    Button(T("浏览…")) { pickDir(into: $m.adoptDirPath) }
                        .controlSize(.small)
                    Button(T("接入")) { m.adopt() }
                        .disabled(runner.running)
                }
                // 接入 tab 自己的信息区
                logBox(m.adoptNotes)
            }
        case .branches:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(T("列出本仓库的分支(本地 + 已 fetch 的远程)。切换后需到「升级」页重新编译。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(m.branches.isEmpty ? T("查询分支") : T("刷新")) { m.queryBranches() }
                        .controlSize(.small)
                }
                if !m.branches.isEmpty {
                    HStack {
                        TextField(T("搜索分支…"), text: $m.branchSearch)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        // 一键清空: 非空才显示, 框外独立按钮(与模型页参数搜索框同款)
                        if !m.branchSearch.isEmpty {
                            Button { m.branchSearch = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        // 图例: 说清 +/− 的基准, 避免"跟谁比"的歧义
                        if !m.currentBranch.isEmpty {
                            Text(TF("+/− 相对当前分支 %@", m.currentBranch))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(m.filteredBranches, id: \.self) { b in
                                let isCurrent = b == m.currentBranch
                                Button {
                                    if !isCurrent { m.selectBranch(b) }
                                } label: {
                                    HStack {
                                        Text(b)
                                            .font(.system(size: 12, design: .monospaced))
                                        if isCurrent {
                                            Text(T("当前"))
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.accentColor))
                                        }
                                        Spacer()
                                        // 行尾右对齐(与其他行的 +/− 同一列):
                                        // 其他行 +N 绿(切过去能拿到的)/−N 红(切过去会留下的);
                                        // 当前行 ⬆N = 相对自己上游的落后数(另一种语义, 用 ⬆ 区分),
                                        // 常显 —— 0 = 与上游同步(灰), >0 = 可升级(绿)
                                        if isCurrent {
                                            if let n = m.currentBehindUpstream {
                                                Text("⬆ \(n)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(n > 0 ? .green : .secondary)
                                            }
                                        } else if let d = m.branchDiff[b] {
                                            if d.ahead > 0 {
                                                Text("+\(d.ahead)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.green)
                                            }
                                            if d.behind > 0 {
                                                Text("−\(d.behind)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.red)
                                                    .padding(.leading, 4)
                                            }
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // 构建运行中禁切分支: checkout 和后台构建对撞
                                // 会改到正被编译的源码树 (接入按钮已有同款 disabled)
                                .disabled(isCurrent || runner.running)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .help(isCurrent
                                        ? (m.currentBehindUpstream.map { $0 > 0 ? TF("上游领先 %d 个提交,「升级」可更新", $0) : T("与上游同步") } ?? "")
                                        : diffHelp(b))
                                .background(isCurrent
                                            ? AnyView(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                                            : AnyView(Color.clear))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                // 切换后需要编译: 就地给编译入口, 不用跑去「升级」页
                if m.needsRebuild && !m.currentBranch.isEmpty {
                    HStack(spacing: 10) {
                        Text(TF("当前分支 %@ 未编译,需要重新编译才生效", m.currentBranch))
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button(T("编译并生效")) { m.startUpgrade(from: .branches) }
                            .disabled(runner.running || pipelineState.busy)
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
                }
                // 分支 tab 自己的信息区
                logBox(m.branchNotes)
                // 「编译并生效」发起的流水线也显示在这里
                if m.pipelineOrigin == .branches {
                    pipelineArea
                }
                if !m.missingTools.isEmpty {
                    toolsWarning
                }
            }
        }
    }

    // 流水线三件套: 日志 → 完成提示(结果在日志下方读着更顺) + 取消按钮
    @ViewBuilder
    private var pipelineArea: some View {
        logBox(runner.lines)
        finishedLine
        if runner.running {
            Button(T("取消")) { runner.cancel() }
        }
    }

    // 自定义分段 tab(系统 segmented 控件会把三段撑得很宽、字很大,
    // 这里按原型控制 13pt 字号和紧凑宽度)
    private func tabButton(_ title: String, _ tag: EnvTab) -> some View {
        Button { m.tab = tag } label: {
            Text(title)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(m.tab == tag ? Color.white : Color.clear)
                        .shadow(color: m.tab == tag ? Color.black.opacity(0.15) : .clear, radius: 1, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // 流水线完成/失败提示(绿=成功, 红=失败/未就绪)
    @ViewBuilder
    private var finishedLine: some View {
        if let f = runner.finished {
            Text(f)
                .foregroundStyle(runner.finishedOK ? .green : .red)
                .font(.callout)
        }
    }

    // 各 tab 独立的信息区(等宽字体、可选中、自动滚到底)
    private func logBox(_ lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("tail")
            }
            .frame(maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .onChange(of: lines.count) {
                proxy.scrollTo("tail", anchor: .bottom)
            }
            .onAppear {
                // 页面重建后首次显示停在末尾(不是第一行); async 等布局完成
                DispatchQueue.main.async { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    // 更新检查状态行: 有更新橙色 / 已是最新绿色 / 其余灰色
    @ViewBuilder
    private var updateLineView: some View {
        if !m.updateLine.isEmpty {
            Text(m.updateLine)
                .font(.callout)
                .foregroundStyle(m.hasUpdate ? Color.orange
                                : m.updateLine.hasPrefix("✅") ? Color.green
                                : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func diffHelp(_ b: String) -> String {
        guard let d = m.branchDiff[b] else { return "" }
        let base = m.currentBranch.isEmpty ? T("当前分支") : TF("当前分支 %@", m.currentBranch)
        var parts: [String] = []
        if d.ahead > 0 { parts.append(TF("比%@多 %d 个提交", base, d.ahead)) }
        if d.behind > 0 { parts.append(TF("比%@少 %d 个提交", base, d.behind)) }
        return parts.isEmpty ? TF("与%@同步", base) : parts.joined(separator: ",")
    }

    private func pickDir(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }

    // prominent notice for missing build tools; the app deliberately does
    // not install these — it points at the official instructions instead
    private var toolsWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            // tool names are internal ids (compared with contains elsewhere);
            // translate only at the display site
            Text(TF("缺少编译工具:%@", m.missingTools.map { T($0) }.joined(separator: ", ")))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            if m.missingTools.contains(T("Xcode 命令行工具")) {
                Text(T("• Xcode 命令行工具:终端执行 xcode-select --install 并按弹窗安装,或到 Mac App Store 搜索 Command Line Tools 安装"))
                    .font(.system(size: 11))
            }
            if m.missingTools.contains("CMake") {
                Text(T("• CMake:官网 cmake.org/download 下载 macOS 安装包,或终端执行 brew install cmake"))
                    .font(.system(size: 11))
            }
            Button(T("我已装好,继续")) {
                let (clt, cmake) = app.checkBuildTools()
                var missing: [String] = []
                if !clt { missing.append("Xcode 命令行工具") }
                if !cmake { missing.append("CMake") }
                m.missingTools = missing
                if missing.isEmpty { m.runSourceInstall() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
    }
}

// MARK: - Logs page

// Per-panel state. Lives in LogPageModel (AppDelegate-owned, like
// envModel/settingsModel) so page switches don't drop it.
final class LogPanelModel: ObservableObject {
    @Published var paused = false            // 暂停滚动
    @Published var historyMode = false       // 查找历史
    @Published var days: [String] = []       // rotated days, newest first
    @Published var day: String? = nil        // selected day (historyMode only)
    @Published var historyLines: [String] = []
    @Published var hint = false              // 「默认状态」点击提示, 2s 自灭

    func refreshDays(_ file: String) { days = logHistoryDays(forFile: file) }

    func toggleHistory(_ file: String) {
        refreshDays(file)
        if historyMode {
            historyMode = false
            day = nil
            historyLines = []
            return
        }
        guard let d = days.first else { return }   // 还没有轮转文件
        historyMode = true
        selectDay(d, file: file)
    }

    func selectDay(_ d: String, file: String) {
        day = d
        historyLines = logHistoryFile(forFile: file, day: d).map { logTailLines($0, n: 4000) } ?? []
    }

    func openDayFile(_ file: String) {
        guard let d = day, let p = logHistoryFile(forFile: file, day: d) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    // 回默认: 今天的实时视图 + 自动滚动
    func reset() {
        historyMode = false
        day = nil
        historyLines = []
        paused = false
        hint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.hint = false }
    }
}

final class LogPageModel: ObservableObject {
    let router = LogPanelModel()
    let app = LogPanelModel()
}

struct LogsPage: View {
    let app: AppDelegate

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LogPanel(m: app.logPageModel.router, store: app.routerLogStore,
                         file: LOG_FILE, title: "Router Log")
                LogPanel(m: app.logPageModel.app, store: app.appLogStore,
                         file: APP_LOG_FILE, title: "App Log")
            }
            .padding(50)
        }
        .onAppear {
            // 轮转文件只在跨天/超体积时新增, 打开页面刷新一次足够
            app.logPageModel.router.refreshDays(LOG_FILE)
            app.logPageModel.app.refreshDays(APP_LOG_FILE)
        }
    }
}

// 一个日志面板: 按钮行 + (历史模式下的日期行) + 400pt 日志区
struct LogPanel: View {
    @ObservedObject var m: LogPanelModel
    @ObservedObject var store: LogStore
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    let file: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                segButton(T("暂停滚动"), on: m.paused, disabled: m.historyMode) { m.paused.toggle() }
                // 文件夹紧贴「查找历史」成一对: 历史模式下打开所选天最新分片
                // 的全文(实时视图下置灰: 今天的文件还在写)
                HStack(spacing: 2) {
                    segButton(T("查找历史"), on: m.historyMode, disabled: m.days.isEmpty && !m.historyMode) { m.toggleHistory(file) }
                    Button { m.openDayFile(file) } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!m.historyMode || m.day == nil)
                }
                // 与历史单元拉开距离, 三个大按钮整体靠左一点点
                segButton(T("默认状态"), on: false, disabled: !m.historyMode && !m.paused) { m.reset() }
                    .padding(.leading, 24)
            }
            if m.historyMode {
                HStack(spacing: 6) {
                    ForEach(m.days, id: \.self) { d in
                        Button { m.selectDay(d, file: file) } label: {
                            Text(d)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(m.day == d ? Color.accentColor : Color.primary.opacity(0.10)))
                                .foregroundStyle(m.day == d ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if m.hint {
                Text(T("实时日志 + 自动滚动"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            content
                .frame(height: 400)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
    }

    @ViewBuilder
    private var content: some View {
        if m.historyMode {
            // 只读快照: 文件已封口, 无自动滚动
            ScrollView {
                Text(m.historyLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(store.lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("tail")
                }
                .onChange(of: store.lines.count) {
                    if !m.paused { proxy.scrollTo("tail", anchor: .bottom) }
                }
                .onChange(of: m.paused) {
                    // 取消暂停 = 回到实时尾部
                    if !m.paused { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
        }
    }

    // 分段语义: 选中 = 实心蓝底白字, 未选中 = 朴素(与模型页顶栏同款)。
    // 整体 1.2 倍(2026-09 用户定): 字号 15.6 / 内边距 14.4,4.8 / 圆角 7.2
    private func segButton(_ label: String, on: Bool, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15.6))
                .padding(.horizontal, 14.4)
                .padding(.vertical, 4.8)
                .background(RoundedRectangle(cornerRadius: 7.2)
                    .fill(on ? Color.accentColor : Color.primary.opacity(0.10)))
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Settings page

// llama-server 全部可用端点(来自 llama.cpp tools/server/server.cpp 的路由
// 注册;legacy 的 /completion、/embedding 和带占位符的 /slots/:id 已剔除——
// 复制了也不能直接用)。v1 组客户端只需 base URL …/v1,这里列出仅供
// 非标准用法(如 /v1/rerank)查完整路径。
let apiEndpointsV1: [String] = [
    "/v1/health", "/v1/models", "/v1/completions", "/v1/chat/completions",
    "/v1/chat/completions/control", "/v1/chat/completions/input_tokens",
    "/v1/responses", "/v1/responses/input_tokens", "/v1/audio/transcriptions",
    "/v1/messages", "/v1/messages/count_tokens", "/v1/embeddings",
    "/v1/rerank", "/v1/reranking",
]
let apiEndpointsNonV1: [String] = [
    "/health", "/metrics", "/props", "/models",
    "/completions", "/chat/completions", "/responses", "/audio/transcriptions",
    "/infill", "/embeddings", "/rerank", "/reranking",
    "/tokenize", "/detokenize", "/apply-template",
    "/chat/completions/input_tokens", "/responses/input_tokens",
    "/models/load", "/models/unload", "/models/sse",
    "/slots", "/lora-adapters",
]

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

final class SettingsFormModel: ObservableObject {
    @Published var host: String
    @Published var port: String
    @Published var pinned: Set<String>
    @Published var endpointsOpen = false
    @Published var saved = false
    @Published var updateLine = ""
    @Published var updateCount = 0    // >0 = 有更新
    let app: AppDelegate
    // 端口输入合法性: 空(= 默认)或 1-65535 的数字; 其余(非数字/0/负数/
    // >65535)非法 —— 非法时确认按钮置灰, 0/99999 这类合法 Int 不能再
    // 存进去把 router 搞到 crash-loop(审计 B5)
    var portValid: Bool {
        let p = port.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return true }
        guard let n = Int(p) else { return false }
        return (1...65535).contains(n)
    }
    init(app: AppDelegate) {
        self.app = app
        host = app.settings.host
        port = app.settings.port.map(String.init) ?? ""
        pinned = Set(app.settings.pinnedEndpoints)
    }

    // 有显式保存按钮的输入, 没保存切页就该回退(2026-09 验证时定案);
    // endpointsOpen 无保存概念, 是视图状态, 保留
    func resetConnectionDraft() {
        host = app.settings.host
        port = app.settings.port.map(String.init) ?? ""
    }

    // 打开页面即查(与环境页同模式): 自己源码仓库 fetch + 数落后上游几个提交
    func checkUpdate() {
        updateLine = T("检查更新中…")
        updateCount = 0
        guard let repo = app.ownSourceRepo() else {
            updateLine = T("无法定位源码目录(本 app 不在 git clone 中),请重新下载最新源码并运行 ./build.sh")
            return
        }
        DispatchQueue.global().async {
            guard self.app.gitFetch(repo) else {
                DispatchQueue.main.async { self.updateLine = T("检查更新失败(网络?),下次打开页面再试") }
                return
            }
            let info = self.app.gitBehindInfo(repo)
            DispatchQueue.main.async {
                if let info {
                    self.updateCount = info.count
                    self.updateLine = info.count == 0
                        ? T("✅ 已是最新")
                        : TF("⬆️ GitHub 上有 %d 个新提交 · 最新: %@", info.count, info.latest)
                } else {
                    self.updateLine = T("无法判断是否有更新(当前分支无上游)")
                }
            }
        }
    }

    // 一键更新 = git pull + ./build.sh。点按钮即确认,成功后自动退出并拉起;
    // 有模型加载时先确认(重启会中断 router 并卸模型)
    func startSelfUpdate(runner: UpgradeRunner) {
        guard updateCount > 0, let repo = app.ownSourceRepo() else { return }
        if !app.loadedNames.isEmpty {
            let alert = NSAlert()
            alert.messageText = T("更新 Corral")
            alert.informativeText = T("更新完成后 app 将自动重启,router 会短暂中断并卸载所有已加载的模型,确认继续吗?")
            alert.addButton(withTitle: T("更新"))
            alert.addButton(withTitle: T("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        runner.selfUpdate(repo: repo) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.updateLine = T("更新完成,正在重启…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.app.relaunchSelf()
                }
            } else {
                self.updateLine = T("更新失败,查看上方输出")
            }
        }
    }
}

struct SettingsPage: View {
    let app: AppDelegate
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    @ObservedObject var pipelineState = PipelineState.shared   // 跨页互斥: 任一流水线在跑就禁用本页更新按钮
    @ObservedObject var m: SettingsFormModel   // app 主体保管(app.settingsModel), 切页不销毁
    @ObservedObject var ur: UpgradeRunner      // app 主体保管, 本页专用, 与环境页的 runner 互不干扰

    init(app: AppDelegate) {
        self.app = app
        _m = ObservedObject(wrappedValue: app.settingsModel)
        _ur = ObservedObject(wrappedValue: app.selfUpdateRunner)
    }

    // 留空 = llama.cpp 默认; 输入实时驱动 API 地址预览(点确认才真正生效)
    private var hostShown: String { m.host.isEmpty ? "127.0.0.1" : m.host }
    private var portShown: String { m.port.isEmpty ? "8080" : m.port }
    private var baseURL: String { "http://\(hostShown):\(portShown)/v1" }

    private let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        // 端点列表展开后超出窗口, 需要可滚动(与其他页一致)
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            // 通用: 界面语言 —— 切换即生效(重绘 SwiftUI + 重建 AppKit 菜单),
            // 持久化到 settings/app 的 lang: 行;选项用自名(中文/English)
            VStack(alignment: .leading, spacing: 10) {
                Text(T("通用")).font(.headline)
                HStack {
                    Text(T("界面语言")).frame(width: 120, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { l10n.lang },
                        set: { app.setLanguage($0) })) {
                        Text("中文").tag(Lang.zh)
                        Text("English").tag(Lang.en)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                }
            }

            // 连接: host/port + 确认(保存并立即重启 router)
            VStack(alignment: .leading, spacing: 10) {
                Text(T("连接")).font(.headline)
                // 与状态栏菜单同一个开关(单一状态源 SMAppService)
                Toggle(T("开机启动"), isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { _ in app.toggleLogin() }))
                // 主机/端口同行:确认按钮同时保存两者,分行会误以为只确认端口
                HStack(spacing: 8) {
                    Text(T("主机"))
                    TextField(T("127.0.0.1(留空 = 默认)"), text: $m.host)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(m.host.isEmpty ? Color.secondary : .primary)
                        .frame(width: 160)
                        .onChange(of: m.host) { m.saved = false }
                    Text(T("端口"))
                    TextField(T("8080(留空 = 默认)"), text: $m.port)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(m.port.isEmpty ? Color.secondary : .primary)
                        .frame(width: 100)
                        .onChange(of: m.port) { m.saved = false }
                    Button(T("确认")) {
                        // 结束编辑态:光标消失,不用先点空白处
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        app.saveConnection(host: m.host, port: Int(m.port.trimmingCharacters(in: .whitespaces)))
                        m.saved = true
                    }
                    .disabled(!m.portValid)
                    if m.saved {
                        Text(T("已保存")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !m.portValid {
                    Text(T("端口需为 1-65535 的数字"))
                        .font(.caption).foregroundStyle(.red)
                        .padding(.leading, 4)
                }
            }

            // API 地址: 默认只给 base URL(…/v1), 完整端点收进折叠区
            VStack(alignment: .leading, spacing: 10) {
                Text(T("API 地址")).font(.headline)
                HStack(spacing: 8) {
                    Text(baseURL)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button(T("复制")) { copyToClipboard(baseURL) }
                        .controlSize(.small)
                    Spacer()
                }
                // 与模型页分区卡片同款: 整行可点 + 10% 透明灰卡片底
                Button {
                    m.endpointsOpen.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(m.endpointsOpen ? 90 : 0))
                        Text(TF("更多端点(v1 %d · 非 v1 %d)", apiEndpointsV1.count, apiEndpointsNonV1.count))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if m.endpointsOpen {
                    VStack(alignment: .leading, spacing: 12) {
                        endpointGroup(T("v1 端点"), apiEndpointsV1)
                        endpointGroup(T("非 v1 端点"), apiEndpointsNonV1)
                    }
                    .padding(.top, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.14)))
                    .padding(.horizontal, -50)
                    .padding(.vertical, -14)
            )

            // 置顶的端点提升到卡片/折叠区外: 钉了 = 常显, 和 base URL 同档
            if !m.pinned.isEmpty {
                endpointGroup(T("置顶"), m.pinned.sorted())
            }

            // llama.cpp 路径不设输入框: 它在环境页管理(自动检测/接入),
            // 这里只展示当前值(旧输入框从未接保存逻辑, 7dc0d88 起就是死的)
            HStack {
                Text(T("llama.cpp 路径")).frame(width: 120, alignment: .leading)
                Text(app.settings.bin.isEmpty ? T("未设置(到环境页检测/接入)") : app.settings.bin)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(app.settings.bin.isEmpty ? Color.secondary : .primary)
                    .textSelection(.enabled)
            }

            Text(T("主机/端口是 llama.cpp router 的监听地址,本应用自身不监听任何端口。点「确认」保存并立即重启 router 生效。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 更新(最底部): 打开页面即查(环境页同模式); 状态行 + 按钮一行,
            // 无更新 = 灰色禁用按钮, 有更新 = 蓝色可用; 一键更新 = git pull +
            // ./build.sh, 成功后自动退出并拉起新 app
            VStack(alignment: .leading, spacing: 10) {
                Text(T("Corral 更新")).font(.headline)
                HStack {
                    if !m.updateLine.isEmpty {
                        Text(m.updateLine)
                            .font(.system(size: 11))
                            .foregroundStyle(m.updateCount > 0 ? Color.orange
                                        : m.updateLine.hasPrefix("✅") ? Color.green : .secondary)
                    }
                    Spacer()
                    Button(T("更新")) { m.startSelfUpdate(runner: ur) }
                        .disabled(ur.running || pipelineState.busy || m.updateCount == 0)
                }
                if ur.running {
                    Button(T("取消")) { ur.cancel() }
                }
                if let f = ur.finished {
                    Text(f)
                        .foregroundStyle(ur.finishedOK ? .green : .red)
                        .font(.callout)
                }
                if ur.running || ur.finished != nil {
                    updateLogBox(ur.lines)
                }
            }
        }
        .padding(50)
        .onAppear {
            m.checkUpdate()
            m.saved = false   // 「已保存」提示不跨次访问残留(model 现在常驻)
            m.resetConnectionDraft()   // 没点确认的 host/port 切页回退
        }
        }
        // 点空白处 = 提交当前输入框(同模型表单), 提示符随之消失
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    // 与 EnvPage.logBox 同款(那边是 private, 不为此动它的可见性)
    private func updateLogBox(_ lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("tail")
            }
            .frame(maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .onChange(of: lines.count) {
                proxy.scrollTo("tail", anchor: .bottom)
            }
            .onAppear {
                // 同 EnvPage.logBox: 页面重建后首次显示停在末尾
                DispatchQueue.main.async { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    private func endpointGroup(_ title: String, _ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(paths, id: \.self) { p in endpointRow(p) }
            }
        }
    }

    // 与模型表单 DenseRow 同款: 图钉 | 路径(等宽) | 复制
    private func endpointRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Button {
                if m.pinned.contains(path) { m.pinned.remove(path) }
                else { m.pinned.insert(path) }
                // sorted (not Array(set)): a Set's iteration order is
                // non-deterministic, so Array(m.pinned) would rewrite the
                // pinned-endpoints line in a random order on every save.
                // Sorted matches the 置顶 group's display order (audit D10).
                app.settings.pinnedEndpoints = m.pinned.sorted()
                app.settings.save()
            } label: {
                Image(systemName: m.pinned.contains(path) ? "pin.fill" : "pin")
                    .font(.system(size: 9))
                    .foregroundStyle(m.pinned.contains(path) ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(m.pinned.contains(path) ? T("取消置顶") : T("置顶到列表顶部"))
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(T("复制")) { copyToClipboard("http://\(hostShown):\(portShown)\(path)") }
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Root view + window host

// MARK: - Experimental page (实验性功能)
// 代理常驻公开端口, 这里的开关只控制「接不接红灯泡」, 即时生效、
// 不重启 router、不动已加载模型(见 docs/experimental/实验性扩展-语音转文字.md)
struct ExperimentalPage: View {
    let app: AppDelegate
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    @ObservedObject var proxyState = ProxyState.shared   // re-render on switch toggle

    var body: some View {
        ScrollView {
            // spacing 44 = 两张灰底卡片各凸出 14pt(负 vertical padding)后, 留 16pt 可见间隙
            VStack(alignment: .leading, spacing: 44) {
                // 顶部总描述: 讲清"实验性"是什么(适用所有实验功能)
                VStack(alignment: .leading, spacing: 10) {
                    Text(T("实验性功能")).font(.headline)
                    Text(T("这里的功能是测试性质的:可能不稳定、可能有 bug、默认全部关闭,且只做了有限测试,不保证在所有场景下都正常工作。如果你不使用相关功能,请保持关闭;如果开启后出现问题,直接关闭对应功能即可恢复原有行为,不会损坏模型或数据。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
                        .padding(.horizontal, -50)
                        .padding(.vertical, -14)
                )

                // 实验功能卡片: 音频转码(每个实验功能一张独立卡片)
                VStack(alignment: .leading, spacing: 10) {
                    Text(T("音频转码")).font(.headline)
                    Text(T("让本地语音转写支持 WebM 等格式")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle(T("音频转码代理"), isOn: Binding(
                        get: { proxyState.enabled },
                        set: { proxyState.enabled = $0; app.confirmAudioProxy($0) }))
                    Text(T("为什么有这个功能:llama.cpp 的本地语音转写只认 WAV / MP3 / FLAC 三种音频,而 OpenWhispr 等听写软件录的是 WebM/Opus,两者对不上、直接转写会报 400。本功能在中间实时把 WebM 等转成 ASR 能读的 16kHz 单声道 WAV。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(T("为什么是实验性:目前只在 OpenWhispr 上验证过;对其他听写软件大概率可用,但未逐一测试、不保证效果。不使用语音转写软件请保持关闭(默认关闭)。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(T("监听端口")).frame(width: 120, alignment: .leading)
                        Text(TF("与设置页连接端口一致(当前 %d)", app.currentPublicPort))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack {
                        Text("ffmpeg").frame(width: 120, alignment: .leading)
                        if let p = app.ffmpegPath {
                            Text(p).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text(T("未找到 — 请安装: brew install ffmpeg"))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.14)))
                        .padding(.horizontal, -50)
                        .padding(.vertical, -14)
                )
            }
            .padding(50)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    let app: AppDelegate

    // oMLX-style shell: pinned sidebar (never collapses, no toolbar
    // toggle) + balanced columns + frame on the view itself, so the
    // hosting window sizes correctly on first open.
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding(
                get: { model.page },
                set: { model.page = $0 ?? .models })) {
                Label(T("模型"), systemImage: "cpu").tag(DashPage.models)
                Label(T("环境"), systemImage: "arrow.up.circle").tag(DashPage.upgrade)
                Label(T("日志"), systemImage: "text.alignleft").tag(DashPage.logs)
                Label(T("设置"), systemImage: "gear").tag(DashPage.settings)
                Label(T("实验性功能"), systemImage: "flask").tag(DashPage.experimental)
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch model.page {
            case .models:   ModelsPage(dm: model, app: app)
            case .upgrade:  EnvPage(app: app, runner: app.upgradeRunner)
            case .logs:     LogsPage(app: app)
            case .settings: SettingsPage(app: app)
            case .experimental: ExperimentalPage(app: app)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // minWidth must fit the dense two-column form at the minimum size
        // (2 x (key 175 + control 140) + row paddings + 50pt insets + sidebar)
        .frame(minWidth: 1040, idealWidth: 1200, minHeight: 560, idealHeight: 720)
    }
}

final class DashboardApp: NSObject {
    let model = DashboardModel()
    private var window: NSWindow?
    private var app: AppDelegate!

    func attach(_ app: AppDelegate) {
        self.app = app
    }

    func show(page: DashPage, modelsTab: ModelsTab, editing: String?) {
        model.page = page
        model.modelsTab = modelsTab
        model.selectedModel = editing
        model.form = nil
        if window == nil {
            // open at a usable size out of the box — the dense two-column
            // form needs width, and users should never have to resize first
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = T("Corral 控制面板")
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: DashboardView(model: model, app: app))
            w.setContentSize(NSSize(width: 1080, height: 720))
            w.minSize = NSSize(width: 880, height: 540)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // retitle on language switch (the title is set once at window creation)
    func retitle() {
        window?.title = T("Corral 控制面板")
    }
}
