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
    let hint: String     // 中文一行说明, 双行行的第二行; "" = 名字自解释不画
    let group: Int       // 1...5, see GROUP_NAMES
    // llama.cpp one-way flag (no --no-X negation): the preset key being
    // present enables it no matter the value, so 'off' is not expressible
    // and the picker only offers default/off... i.e. default + on
    let oneWay: Bool
    // free-form value beyond the fixed choice list (only reasoning-effort:
    // some model templates accept effort names not in the list — custom
    // reasoning/instruct modes like "spoon"/"ispoon")
    let allowCustom: Bool
}

let GROUP_NAMES: [Int: String] = [
    1: "上下文 & 缓存",
    2: "GPU & 设备",
    3: "采样",
    4: "推理 & 模板",
    5: "其他(多模态 / 服务器 / 投机解码 / 调试)",
]

private func P(_ key: String, _ kind: ParamKind, _ def: String, _ hint: String, _ group: Int, oneWay: Bool = false, allowCustom: Bool = false) -> Param {
    Param(key: key, kind: kind, def: def, hint: hint, group: group, oneWay: oneWay, allowCustom: allowCustom)
}

private let KV_TYPES: [String] = ["f16", "f32", "bf16", "q8_0", "q4_0", "q4_1", "iq4_nl", "q5_0", "q5_1"]

let PARAMS: [Param] = [
    // ---- group 1: context & cache ----
    P("ctx-size", .num, "0 (从模型读取)", "上下文窗口大小(token 数)", 1),
    P("parallel", .num, "-1 (auto)", "并行 slot 数(auto = 按内存自动)", 1),
    P("batch-size", .num, "2048", "批处理大小(预填充一次处理的 token 数)", 1),
    P("ubatch-size", .num, "512", "微批大小(把 batch 再细分, 省内存)", 1),
    P("keep", .num, "0", "从上下文开头保留的 token 数", 1),
    P("n-predict", .num, "-1 (无限)", "单次请求最多生成的 token 数", 1),
    P("swa-full", .bool, "off", "滑动窗口模型按全窗口计算(更费内存)", 1, oneWay: true),
    P("kv-unified", .text, "auto (slots 为 auto 时启用)", "KV 缓存统一模式", 1),
    P("kv-unified-per-slot", .num, "未设置", "KV 缓存统一模式(每 slot)", 1),
    P("ctx-checkpoints", .num, "32", "上下文检查点数量(供缓存复用)", 1),
    P("checkpoint-min-step", .num, "8192", "检查点之间的最小步长(token 数)", 1),
    P("cache-ram", .num, "8192", "提示词缓存的 token 上限", 1),
    P("cache-idle-slots", .bool, "on", "空闲 slot 保留缓存供复用", 1),
    P("context-shift", .bool, "off", "到达上下文上限时向前滚动丢弃最旧内容", 1),
    P("cache-prompt", .bool, "on", "启用提示词缓存(相同前缀不重复计算)", 1),
    P("cache-reuse", .num, "0", "最大缓存复用 token 数", 1),
    P("slot-prompt-similarity", .num, "0.10", "提示词相似度达到该值时复用 slot", 1),
    P("slot-save-path", .path, "disabled", "slot 状态保存目录", 1),
    P("sleep-idle-seconds", .num, "-1 (disabled)", "空闲 N 秒后休眠释放内存", 1),
    P("warmup", .bool, "on", "启动时跑一次预热计算", 1),
    P("rope-scaling", .choice(["none", "linear", "yarn"]), "linear (模型默认)", "RoPE 上下文扩展方式", 1),
    P("rope-scale", .num, "模型默认", "RoPE 缩放因子", 1),
    P("rope-freq-base", .num, "模型默认", "RoPE 频率基值", 1),
    P("rope-freq-scale", .num, "模型默认", "RoPE 频率缩放", 1),
    P("yarn-orig-ctx", .num, "0", "YaRN 训练的原始上下文长度", 1),
    P("yarn-ext-factor", .num, "-1.00", "YaRN 外推因子", 1),
    P("yarn-attn-factor", .num, "-1.00", "YaRN 注意力缩放因子", 1),
    P("yarn-beta-slow", .num, "-1.00", "YaRN 插值参数 beta slow", 1),
    P("yarn-beta-fast", .num, "-1.00", "YaRN 插值参数 beta fast", 1),
    P("cache-type-k", .choice(KV_TYPES), "f16", "K 缓存的存储数据类型", 1),
    P("cache-type-v", .choice(KV_TYPES), "f16", "V 缓存的存储数据类型", 1),
    P("flash-attn", .choice(["auto", "on", "off"]), "auto", "Flash Attention(省内存加速)", 1),
    // ---- group 2: gpu & device ----
    P("n-gpu-layers", .text, "auto (数字 / auto / all)", "卸载到 GPU 的层数", 2),
    P("split-mode", .choice(["none", "layer", "row", "tensor"]), "layer", "多 GPU 分层方式", 2),
    P("tensor-split", .text, "默认", "多 GPU 算力分配比例", 2),
    P("main-gpu", .num, "0", "主 GPU 索引", 2),
    P("device", .text, "默认", "计算设备指定", 2),
    P("threads", .num, "-1", "CPU 线程数", 2),
    P("threads-batch", .num, "同 threads", "预填充阶段的 CPU 线程数", 2),
    P("cpu-mask", .text, "", "CPU 核心掩码(位图)", 2),
    P("cpu-range", .text, "", "CPU 核心号范围", 2),
    P("cpu-strict", .num, "0", "CPU 亲和严格程度", 2),
    P("prio", .num, "0 (low -1 / normal 0 / medium 1 / high 2 / realtime 3)", "CPU 进程优先级", 2),
    P("poll", .num, "50", "CPU 轮询级别(0-100, 越高越省电)", 2),
    P("cpu-mask-batch", .text, "同 cpu-mask", "预填充的 CPU 核心掩码", 2),
    P("cpu-range-batch", .text, "同 cpu-range", "预填充的 CPU 核心号范围", 2),
    P("cpu-strict-batch", .num, "同 cpu-strict", "预填充的 CPU 亲和严格程度", 2),
    P("prio-batch", .num, "0", "预填充的 CPU 进程优先级", 2),
    P("poll-batch", .num, "同 poll", "预填充的 CPU 轮询级别", 2),
    P("fit", .choice(["on", "off"]), "on", "自动计算放得下的 GPU 层数", 2),
    P("fit-target", .text, "1024", "自动适配时预留的目标内存(MB)", 2),
    P("fit-ctx", .num, "4096", "自动适配估算用的上下文长度", 2),
    P("load-mode", .choice(["auto", "none", "mmap", "mlock", "mmap+mlock", "dio"]), "auto", "模型文件加载方式", 2),
    P("lazy-mode", .choice(["on", "auto", "off"]), "auto", "计算图懒加载模式", 2),
    P("kv-offload", .bool, "on", "KV 缓存卸载到 GPU", 2),
    P("repack", .bool, "on", "重排模型数据提升访问效率", 2),
    P("no-host", .bool, "off", "完全不用 CPU 参与计算", 2, oneWay: true),
    P("op-offload", .bool, "on", "算子计算卸载到 GPU", 2),
    P("numa", .choice(["distribute", "isolate", "numactl"]), "默认", "NUMA 内存策略(多路 CPU)", 2),
    P("override-tensor", .text, "", "指定张量强制用某设备计算", 2),
    P("cpu-moe", .bool, "off", "MoE 专家层留在 CPU 计算", 2, oneWay: true),
    P("n-cpu-moe", .num, "默认", "留在 CPU 的 MoE 层数", 2),
    P("n-cpu-ffn", .num, "默认", "留在 CPU 的 FFN 层数", 2),
    P("check-tensors", .bool, "off", "启动时校验张量完整性", 2, oneWay: true),
    P("override-kv", .text, "", "指定 KV 缓存的存储设备", 2),
    P("lora", .path, "", "LoRA 适配器文件", 2),
    P("lora-scaled", .text, "格式 FNAME:SCALE", "LoRA 适配器及缩放系数", 2),
    P("control-vector", .path, "", "控制向量文件", 2),
    P("control-vector-scaled", .text, "格式 FNAME:SCALE", "控制向量及缩放系数", 2),
    P("control-vector-layer-range", .text, "START END", "控制向量作用的层范围", 2),
    // ---- group 3: sampling ----
    P("temp", .num, "0.80", "采样温度(越低越确定)", 3),
    P("top-k", .num, "40", "只保留概率最高的 K 个候选", 3),
    P("top-p", .num, "0.95", "累积概率截断(核采样)", 3),
    P("min-p", .num, "0.05", "相对最高概率 token 的最低概率", 3),
    P("typical-p", .num, "1.00", "局部典型概率采样", 3),
    P("top-nsigma", .num, "-1.00", "高斯 sigma 截断采样", 3),
    P("xtc-probability", .num, "0.00", "XTC 采样的触发概率", 3),
    P("xtc-threshold", .num, "0.10", "XTC 采样的概率阈值", 3),
    P("repeat-last-n", .num, "64", "重复惩罚回看窗口(token 数)", 3),
    P("repeat-penalty", .num, "1.00", "重复惩罚(1.0 = 关闭)", 3),
    P("presence-penalty", .num, "0.00", "存在惩罚(抑制已出现的 token)", 3),
    P("frequency-penalty", .num, "0.00", "频率惩罚(按出现次数抑制)", 3),
    P("dry-multiplier", .num, "0.00", "DRY 采样乘数(0 = 关闭)", 3),
    P("dry-base", .num, "1.75", "DRY 采样底数", 3),
    P("dry-allowed-length", .num, "2", "DRY 允许的重复长度", 3),
    P("dry-penalty-last-n", .num, "64", "DRY 惩罚回看窗口", 3),
    P("dry-sequence-breaker", .text, "默认 (\\n : \" *)", "DRY 不计为重复的序列", 3),
    P("adaptive-target", .num, "-1.00", "自适应温度的目标困惑度", 3),
    P("adaptive-decay", .num, "0.90", "自适应温度衰减率", 3),
    P("dynatemp-range", .num, "0.00", "动态温度波动范围(0 = 关闭)", 3),
    P("dynatemp-exp", .num, "1.00", "动态温度指数", 3),
    P("mirostat", .choice(["0", "1", "2"]), "0 (disabled)", "Mirostat 动态困惑度控制(0 = 关闭)", 3),
    P("mirostat-lr", .num, "0.10", "Mirostat 学习率", 3),
    P("mirostat-ent", .num, "5.00", "Mirostat 目标熵", 3),
    P("seed", .num, "-1 (随机)", "随机种子(-1 = 每次随机)", 3),
    P("samplers", .text, "默认顺序", "自定义采样器", 3),
    P("sampler-seq", .text, "edskypmxt", "采样器链顺序", 3),
    P("ignore-eos", .bool, "off", "忽略结束标记(不自动停)", 3, oneWay: true),
    P("logit-bias", .text, "格式 TOKEN_ID(+/-)BIAS", "对指定 token 的 logits 加减偏置", 3),
    P("grammar", .text, "", "GBNF 语法约束输出", 3),
    P("grammar-file", .path, "", "GBNF 语法约束文件", 3),
    P("json-schema", .text, "", "JSON Schema 约束输出", 3),
    P("json-schema-file", .path, "", "JSON Schema 约束文件", 3),
    P("backend-sampling", .bool, "off", "采样在计算后端(GPU)执行", 3, oneWay: true),
    // ---- group 4: reasoning & template ----
    P("jinja", .bool, "on", "使用模型内置 Jinja 对话模板", 4),
    P("chat-template", .text, "模型自带", "自定义对话模板", 4),
    P("chat-template-file", .path, "模型自带", "自定义对话模板文件", 4),
    P("chat-template-kwargs", .text, "JSON 对象字符串", "对话模板的额外参数", 4),
    P("reasoning", .choice(["auto", "on", "off"]), "auto", "推理模式(DeepSeek-R1 等推理模型)", 4),
    P("reasoning-format", .choice(["auto", "none", "deepseek", "deepseek-legacy"]), "auto", "推理输出格式", 4),
    P("reasoning-effort", .choice(["default", "minimal", "low", "medium", "high", "xhigh", "max"]), "default", "推理 effort 等级", 4, allowCustom: true),
    P("reasoning-budget", .num, "-1 (不限)", "推理 token 数上限", 4),
    P("reasoning-budget-message", .text, "无", "推理超预算时的提示消息", 4),
    P("reasoning-preserve", .bool, "on", "历史消息中保留推理内容", 4),
    P("skip-chat-parsing", .bool, "off", "跳过对话模板解析(原样发送)", 4),
    P("prefill-assistant", .bool, "on", "预填充 assistant 消息", 4),
    P("special", .bool, "off", "输出中包含特殊 token", 4, oneWay: true),
    // ---- group 5: misc (multimodal / server / speculative / debug) ----
    P("mmproj", .path, "", "多模态投影文件(mmproj)", 5),
    P("mmproj-url", .text, "", "多模态投影文件下载地址", 5),
    P("mmproj-auto", .bool, "on", "自动下载多模态投影文件", 5),
    P("mmproj-offload", .bool, "on", "多模态计算卸载到 GPU", 5),
    P("mmproj-device", .text, "跟随 device (none = 不卸载)", "多模态投影计算设备", 5),
    P("image-min-tokens", .num, "读自模型", "图像最少预留 token 数", 5),
    P("image-max-tokens", .num, "读自模型", "图像最多预留 token 数", 5),
    P("mtmd-batch-max-tokens", .num, "1024", "多模态批处理 token 上限", 5),
    P("video-fps", .num, "4.0", "视频抽帧帧率", 5),
    P("video-timestamp-interval", .num, "5000", "视频时间戳间隔(毫秒)", 5),
    P("video-ffmpeg-dir", .path, "在 PATH 中查找", "ffmpeg 所在目录", 5),
    P("pooling", .choice(["none", "mean", "cls", "last", "rank"]), "模型默认", "嵌入向量池化方式", 5),
    P("embd-normalize", .num, "2", "嵌入向量归一化方式", 5),
    P("embedding", .bool, "off", "嵌入模式(只算向量不生成文本)", 5, oneWay: true),
    P("rerank", .bool, "off", "重排序(rerank)模式", 5, oneWay: true),
    P("tags", .text, "", "模型标签(逗号分隔)", 5),
    P("cors-origins", .text, "*", "CORS 允许的源", 5),
    P("cors-methods", .text, "GET, POST, DELETE, OPTIONS", "CORS 允许的方法", 5),
    P("cors-headers", .text, "*", "CORS 允许的请求头", 5),
    P("cors-credentials", .bool, "on", "CORS 允许携带凭证", 5),
    P("api-prefix", .text, "", "API 路径前缀", 5),
    P("timeout", .num, "3600", "请求超时(秒)", 5),
    P("sse-ping-interval", .num, "30", "SSE 心跳间隔(秒)", 5),
    P("threads-http", .num, "-1", "HTTP 服务线程数", 5),
    P("metrics", .bool, "off", "启用 /metrics 指标端点", 5, oneWay: true),
    P("props", .bool, "off", "启用 /props 端点", 5, oneWay: true),
    P("slots", .bool, "on", "多 slot 并发模式", 5),
    P("media-path", .path, "disabled", "媒体文件保存目录", 5),
    P("ui", .bool, "on (Web UI)", "启用内置 Web 界面", 5),
    P("tools", .text, "无 (all = 全部)", "启用的工具列表", 5),
    P("tools-runtime", .text, "宿主环境 (docker:/podman:/ssh:)", "工具执行环境", 5),
    P("mcp-servers-config", .path, "无", "MCP 服务器配置文件", 5),
    P("mcp-servers-json", .text, "无", "MCP 服务器 JSON 配置", 5),
    P("agent", .bool, "off", "启用 agent 模式", 5),
    P("spec-type", .text, "none (逗号分隔: draft-simple, ngram-simple, ...)", "投机解码方式", 5),
    P("spec-draft-model", .path, "", "投机解码草稿模型", 5),
    P("spec-draft-hf", .text, "", "从 Hugging Face 下载草稿模型", 5),
    P("spec-draft-n-max", .num, "3", "投机草稿最大长度", 5),
    P("spec-draft-n-min", .num, "0", "投机草稿最小长度", 5),
    P("spec-draft-p-split", .num, "0.10", "投机解码分裂概率", 5),
    P("spec-draft-p-min", .num, "0.00", "投机解码最低接受概率", 5),
    P("spec-draft-type-k", .choice(KV_TYPES), "f16", "草稿模型 K 缓存类型", 5),
    P("spec-draft-type-v", .choice(KV_TYPES), "f16", "草稿模型 V 缓存类型", 5),
    P("spec-draft-threads", .num, "同 threads", "草稿模型 CPU 线程数", 5),
    P("spec-draft-threads-batch", .num, "同 spec-draft-threads", "草稿模型预填充线程数", 5),
    P("spec-draft-cpu-mask", .text, "同 cpu-mask", "草稿模型 CPU 核心掩码", 5),
    P("spec-draft-cpu-range", .text, "同 cpu-range", "草稿模型 CPU 核心号范围", 5),
    P("spec-draft-cpu-strict", .num, "同 cpu-strict", "草稿模型 CPU 亲和严格程度", 5),
    P("spec-draft-prio", .num, "0", "草稿模型 CPU 优先级", 5),
    P("spec-draft-poll", .num, "同 poll", "草稿模型 CPU 轮询级别", 5),
    P("spec-draft-cpu-mask-batch", .text, "同 spec-draft-cpu-mask", "草稿模型预填充 CPU 掩码", 5),
    // NOTE: llama.cpp has --spec-draft-cpu-range-batch but it is registered
    // for the speculative example only — llama-server rejects it (verified
    // against build 52 / 73a43d1f6), so it is intentionally NOT in the catalog
    P("spec-draft-cpu-strict-batch", .num, "同 spec-draft-cpu-strict", "草稿模型预填充 CPU 亲和", 5),
    P("spec-draft-prio-batch", .num, "0", "草稿模型预填充 CPU 优先级", 5),
    P("spec-draft-poll-batch", .num, "同 spec-draft-poll", "草稿模型预填充 CPU 轮询级别", 5),
    P("spec-draft-override-tensor", .text, "", "草稿模型张量设备覆盖", 5),
    P("spec-draft-cpu-moe", .bool, "off", "草稿模型 MoE 层留在 CPU", 5, oneWay: true),
    P("spec-draft-n-cpu-moe", .num, "默认", "草稿模型 CPU MoE 层数", 5),
    P("spec-draft-device", .text, "默认", "草稿模型计算设备", 5),
    P("spec-draft-ngl", .text, "auto", "草稿模型 GPU 层数", 5),
    P("spec-draft-backend-sampling", .bool, "on", "草稿模型采样在后端执行", 5),
    P("spec-synth-len", .num, "", "投机合成长度", 5),
    P("spec-synth-rates", .text, "", "投机合成速率", 5),
    P("spec-ngram-mod-n-min", .num, "48", "ngram-mod 最小 n", 5),
    P("spec-ngram-mod-n-max", .num, "64", "ngram-mod 最大 n", 5),
    P("spec-ngram-mod-n-match", .num, "24", "ngram-mod 匹配长度", 5),
    P("spec-ngram-simple-size-n", .num, "12", "ngram-simple 的 n-gram 长度", 5),
    P("spec-ngram-simple-size-m", .num, "48", "ngram-simple 的匹配上下文长度", 5),
    P("spec-ngram-simple-min-hits", .num, "1", "ngram-simple 最小命中次数", 5),
    P("spec-ngram-map-k-size-n", .num, "12", "ngram-map-k 的 n-gram 长度", 5),
    P("spec-ngram-map-k-size-m", .num, "48", "ngram-map-k 的匹配上下文长度", 5),
    P("spec-ngram-map-k-min-hits", .num, "1", "ngram-map-k 最小命中次数", 5),
    P("spec-ngram-map-k4v-size-n", .num, "12", "ngram-map-k4v 的 n-gram 长度", 5),
    P("spec-ngram-map-k4v-size-m", .num, "48", "ngram-map-k4v 的匹配上下文长度", 5),
    P("spec-ngram-map-k4v-min-hits", .num, "1", "ngram-map-k4v 最小命中次数", 5),
    P("log-verbosity", .num, "3", "日志详细级别(0-4)", 5),
    P("verbose", .bool, "off", "详细日志输出", 5, oneWay: true),
    P("log-colors", .choice(["on", "off", "auto"]), "auto", "日志彩色输出", 5),
    P("log-prefix", .bool, "off", "日志行前缀", 5),
    P("log-timestamps", .bool, "off", "日志时间戳", 5),
    P("log-file", .path, "", "日志输出文件", 5),
    P("offline", .bool, "off", "离线模式(不访问网络)", 5, oneWay: true),
    P("perf", .bool, "off", "输出性能统计", 5),
    P("escape", .bool, "on", "输出转义特殊字符", 5),
    P("reverse-prompt", .text, "", "出现该文本时停止生成", 5),
    P("spm-infill", .bool, "off", "SPM 代码补全(infill)模式", 5, oneWay: true),
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

// MARK: - .llm file (key = value lines + app-private comment lines)

// The "# pinned:" / "# manual:" lines are app-private metadata: they stay
// out of the router preset (buildPresetFile strips them), so llama.cpp
// never sees them. pinned = right column of the 基本 card (order is
// meaningless, rendered alphabetically); manual = left column (order IS
// the display order). The two lists are mutually exclusive: a parameter
// appears in exactly one place in the whole form.
struct LlmFile {
    var values: [String: String]
    var order: [String]      // key order as written to the file
    var pinned: [String]
    var manual: [String] = []
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
                } else if lower.hasPrefix("# manual:") {
                    f.manual = line.dropFirst("# manual:".count)
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
        if !manual.isEmpty { out += "# manual: " + manual.joined(separator: ", ") + "\n" }
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

enum DashPage: Hashable, CaseIterable {
    case models, upgrade, logs, settings, experimental
    // Single source of truth for page names: the sidebar label and the
    // titlebar title both render from here (oMLX pattern), so they can
    // never drift apart.
    var titleKey: String {
        switch self {
        case .models:         return "模型参数"
        case .upgrade:        return "Llama.cpp 版本"
        case .logs:           return "日志"
        case .settings:       return "设置"
        case .experimental:   return "实验性功能"
        }
    }
    var symbol: String {
        switch self {
        case .models:         return "cpu"
        case .upgrade:        return "arrow.up.circle"
        case .logs:           return "text.alignleft"
        case .settings:       return "gear"
        case .experimental:   return "flask"
        }
    }
}
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
    // One live form per mode: switching tabs / models just swaps which
    // form is shown — drafts survive all switches (2026-09 ruling). Only
    // 重置 / model deletion / a successful add-save / app restart discard
    // a form. MUST be @Published: inserting from a view body only
    // re-renders if this change is published.
    @Published var forms: [FormMode: FormModel] = [:]
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
    @Published var manual: [String] = []   // 基本 card left column (ordered)
    @Published var ggufPath = ""     // "model" key (add/edit modes)
    @Published var customName = ""   // display-only alias (add + edit modes)
    @Published var justSaved = false
    @Published var dirty = false      // 有未保存修改(底部栏橙色圆点)
    // 状态式 dirty:baseline = 加载/上次保存/上次重播种时的参数面。
    // 每次变更实时比较——改了又改回去,圆点立刻灭(事件式要手动保存
    // 才消)。模型路径/自定义名称不进 baseline(填路径不亮点的旧语义)
    private var baseline: (values: [String: String], pinned: [String], manual: [String]) = ([:], [], [])

    // values 里空值 = 键不存在(setValue 写入 nil 即删键);防御性过滤
    // 解析自畸形文件的空串行
    private var effectiveValues: [String: String] {
        var e: [String: String] = [:]
        for (k, v) in values where !v.isEmpty { e[k] = v }
        return e
    }

    private func refreshDirty() {
        dirty = effectiveValues != baseline.values
            || pinned != baseline.pinned
            || manual != baseline.manual
    }
    // 分组卡默认折叠, 用户按需展开
    @Published var openGroups: Set<Int> = []
    // 基本卡也加入可折叠家族(2026-09 二轮): 默认展开, 不持久化
    @Published var basicOpen = true
    // 基本卡内两区各自可折叠(2026-09): 默认展开, 不持久化, 搜索时强制展开
    @Published var manualOpen = true
    @Published var pinOpen = true
    // green + picker (view-local state; no @State in this toolchain)
    @Published var pickerOpen = false
    @Published var pickerQuery = ""
    // allowCustom 参数(现仅 reasoning-effort)当前处于「自定义」输入模式的集合。
    // 独立标志: 只由用户动作(选「自定义」/ 点 ×/ 选标准项)改变, 不跟值实时
    // 反推 —— 反推的话, 自定义框里打到某个标准值(如 "low")的瞬间控件就换掉,
    // 光标被抢。加载表单时按值初始化一次(见 syncCustomKeys)
    @Published var customKeys: Set<String> = []

    init(mode: FormMode) {
        self.mode = mode
        if mode == .global { Self.seedGlobalFile() }
        switch mode {
        case .global:
            let f = LlmFile.read(GLOBAL_FILE)
            values = f.values; order = f.order; manual = f.manual
            pinned = Self.fallbackPins(f)
        case .add:
            // 添加新模型 = 预填全局参数(值 + 置顶都来自全局文件)
            let f = LlmFile.read(GLOBAL_FILE)
            values = f.values; order = f.order; manual = f.manual
            pinned = Self.fallbackPins(f)
        case .edit(let id):
            let f = LlmFile.read(CONFIG_DIR + "/" + id + CONFIG_EXT)
            values = f.values; order = f.order; manual = f.manual
            pinned = Self.fallbackPins(f)
            ggufPath = f.values["model"] ?? ""
            customName = f.displayName
        }
        syncCustomKeys()
        baseline = (values: effectiveValues, pinned: pinned, manual: manual)
    }

    // 打开表单时把「值非空且不在选项列表里」的 allowCustom 参数还原进自定义
    // 模式(如已存 reasoning-effort = einstein)。只在这里(值静止时)推断,
    // 之后全程跟用户动作走
    private func syncCustomKeys() {
        var s: Set<String> = []
        for p in PARAMS where p.allowCustom {
            if case .choice(let choices) = p.kind,
               let v = values[p.key], !v.isEmpty, !choices.contains(v) {
                s.insert(p.key)
            }
        }
        customKeys = s
    }

    // Legacy files have no pin metadata at all -> default pins. A file
    // that has a manual line but an empty pinned line means the user
    // deliberately cleared the right column; respect that.
    private static func fallbackPins(_ f: LlmFile) -> [String] {
        (f.pinned.isEmpty && f.manual.isEmpty) ? DEFAULT_PINS : f.pinned
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
        let nv: String? = (v?.isEmpty == false) ? v : nil
        // SwiftUI's TextField calls the binding setter with the current
        // value on focus / re-render; a no-change write must not mark the
        // form dirty (just clicking a field lit the orange dot)
        guard values[key] != nv else { return }
        justSaved = false
        if nv != nil, !order.contains(key) { order.append(key) }
        values[key] = nv
        refreshDirty()
    }

    // returns error message, or nil on success
    func save() -> String? {
        var v = values
        var o = order
        // belt & braces: any key present in values must be emitted
        for k in v.keys where !o.contains(k) { o.append(k) }
        if mode != .global {
            guard !ggufPath.isEmpty else { return T("模型路径必填") }
            // Validate against the real filesystem: expand ~, require the
            // file to exist and to be .gguf (llama.cpp only loads GGUF).
            // The expanded path is what gets written — the router has no
            // shell to expand ~ for it.
            let expanded = (ggufPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue
            else { return T("找不到该路径的文件") }
            guard expanded.lowercased().hasSuffix(".gguf") else {
                return T("不是 .gguf 文件(llama.cpp 只支持 GGUF 格式)")
            }
            ggufPath = expanded
            v["model"] = expanded
            o.removeAll { $0 == "model" }
            o.insert("model", at: 0)
        }
        switch mode {
        case .global:
            try? LlmFile(values: v, order: o, pinned: pinned, manual: manual).text()
                .write(toFile: GLOBAL_FILE, atomically: true, encoding: .utf8)
        case .add:
            let id = targetID
            guard !id.isEmpty else { return T("模型路径必填") }
            try? LlmFile(values: v, order: o, pinned: pinned, manual: manual, displayName: customName).text()
                .write(toFile: CONFIG_DIR + "/" + id + CONFIG_EXT, atomically: true, encoding: .utf8)
        case .edit(let id):
            try? LlmFile(values: v, order: o, pinned: pinned, manual: manual, displayName: customName).text()
                .write(toFile: CONFIG_DIR + "/" + id + CONFIG_EXT, atomically: true, encoding: .utf8)
        }
        baseline = (values: effectiveValues, pinned: pinned, manual: manual)
        dirty = false
        return nil
    }

    func togglePin(_ key: String) {
        justSaved = false
        if let i = pinned.firstIndex(of: key) { pinned.remove(at: i) }
        else { pinned.append(key) }
        refreshDirty()
    }

    // left column (manual) mutators: order = display order
    func addManual(_ key: String) {
        justSaved = false
        guard !manual.contains(key) else { return }
        pinned.removeAll { $0 == key }   // a parameter lives in one place only
        manual.append(key)
        pickerOpen = false
        pickerQuery = ""
        refreshDirty()
    }

    func removeManual(_ key: String) {
        justSaved = false
        if let i = manual.firstIndex(of: key) { manual.remove(at: i) }
        refreshDirty()
    }

    // 手动区重排(2026-09): 菜单一次挪到任意位置, 取代逐格 chevron。
    // .front = 第 1 位; .after(t) = t 的下一位; .end = 末尾。
    // (t 不在列表时退到末尾, 防御性, 正常菜单不会构造出这种目标)
    enum ManualDest { case front, end, after(String) }
    func moveManual(_ key: String, to dest: ManualDest) {
        guard let i = manual.firstIndex(of: key) else { return }
        let item = manual.remove(at: i)
        switch dest {
        case .front: manual.insert(item, at: 0)
        case .end: manual.append(item)
        case .after(let t):
            if let j = manual.firstIndex(of: t) { manual.insert(item, at: j + 1) }
            else { manual.append(item) }
        }
        justSaved = false
        refreshDirty()
    }

    // First run: create settings/global.llm as a starter template — the
    // curated param list (manual + pinned sections, no values: empty =
    // llama.cpp official defaults). The user reshapes it in the dashboard.
    static func seedGlobalFile() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: GLOBAL_FILE) else { return }
        let f = LlmFile(values: [:], order: [],
                        pinned: ["flash-attn", "spec-type"],
                        manual: ["ctx-size", "temp", "n-predict", "top-p", "top-k",
                                 "presence-penalty", "repeat-penalty", "cache-type-k",
                                 "cache-type-v", "reasoning", "reasoning-effort",
                                 "reasoning-preserve", "jinja", "chat-template-file"])
        try? fm.createDirectory(atPath: SETTINGS_DIR, withIntermediateDirectories: true)
        try? f.text().write(toFile: GLOBAL_FILE, atomically: true, encoding: .utf8)
    }

    // 整体重播种:参数面(值/顺序/图钉/手动区)整体换成 global.llm 的内容。
    // 两条对齐路共用:自动(全局页「保存」成功后)+ 手动(添加页
    // 「重置为全局参数」)。路径与自定义名称不碰(模型专属信息,不属于
    // 全局种子)。对齐后的内容不是用户的待保存劳动,橙点灭。
    func reseedFromGlobal() {
        let f = LlmFile.read(GLOBAL_FILE)
        values = f.values; order = f.order; manual = f.manual
        pinned = Self.fallbackPins(f)
        syncCustomKeys()
        justSaved = false
        baseline = (values: effectiveValues, pinned: pinned, manual: manual)
        dirty = false
    }

    // 重置为默认:clear every value (empty = llama.cpp official default)
    func resetAll() {
        values = [:]
        order = []
        customKeys = []
        justSaved = false
        refreshDirty()   // 文件本来就是全默认 → 重置后内容 = baseline,圆点不亮
    }

    func toggleGroup(_ g: Int) {
        if openGroups.contains(g) { openGroups.remove(g) } else { openGroups.insert(g) }
    }
}

// 原生式输入框(2026-09 用户定案): 全项目文本输入的唯一框实现。
// 浅灰半透明底 + 细实线边 + 5pt 圆角, 半透明 primary 自动适配明暗模式。
// 用法: plain TextField 套 .nativeFieldBox()。原生 pop-up/segmented/Toggle
// 自带边框, 不用(见 DenseRow.needsBox 的「框中框」教训)。
// 零参数: 哪天真要单独优化某个框, 那时再加参数(YAGNI, 2026-09 定案)。
struct NativeFieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

extension View {
    func nativeFieldBox() -> some View { modifier(NativeFieldBox()) }
}

// 全 app 统一的滑动开关(2026-09 用户定案): small × 0.9 尺寸。
// 调用点: 设置页开机启动 + 实验页音频转码, 必须同款, 改尺寸只改这里。
struct AppSwitch: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)   // ≈80% 原生尺寸
            .scaleEffect(0.9)      // 再小 10%(controlSize 只有离散档, 精确 90% 只能缩放)
    }
}

extension View {
    func appSwitch() -> some View { modifier(AppSwitch()) }
}

// MARK: - Design tokens (方案 B 色块卡片风格, 2026-09-11 mockup 定案)

// 每个分区/卡片一个色相; 卡片 = 浅色底 + 柔和阴影 + 2.5pt 顶部色条。
// 颜色全部带 opacity 使用, 明暗模式自适应(底色取系统 textBackground)。
enum UIStyle {
    static let hue1 = Color(red: 0.04, green: 0.52, blue: 1.00)  // 蓝
    static let hue2 = Color(red: 0.35, green: 0.34, blue: 0.84)  // 紫
    static let hue3 = Color(red: 1.00, green: 0.58, blue: 0.00)  // 橙
    static let hue4 = Color(red: 0.19, green: 0.78, blue: 0.40)  // 绿
    static let hue5 = Color(red: 0.56, green: 0.56, blue: 0.58)  // 灰
    static let hues: [Color] = [hue1, hue2, hue3, hue4, hue5]
    static let groupIcons = ["memorychip", "cpu", "slider.horizontal.3", "brain", "gearshape.2"]
    // 基本卡双区: 手动区绿 / 图钉区蓝
    static let manualTint = hue4
    static let pinTint = hue1
}

// 方案 B 卡片: 浅色底 + 阴影 + 可选顶部色条。调用方自己加 breakout
// padding(模型页 -50 横向 / 设置页 -50,-14), 这里只管形状。
struct CardChrome: View {
    var accent: Color? = nil
    var radius: CGFloat = 12
    var body: some View {
        // 色条 = CSS border 几何: 整卡色块减掉「下移 2.5pt、半径小 2.5 的
        // 内层圆角矩形」, 剩下一条顶部边框带 —— 拐角处沿弧线贴住侧边
        // 下探 2.5pt(2026-09-11 用户标注: 水平条裁角在角上收细到零,
        // 没有下探)。内层填充用卡片同色「挖」出边框带, 整体再按卡片
        // 形状裁剪(色条单独设圆角/裁剪都会因高度 2.5 退化)。
        RoundedRectangle(cornerRadius: radius)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .top) {
                if let accent {
                    ZStack(alignment: .top) {
                        Rectangle().fill(accent.opacity(0.75))
                        RoundedRectangle(cornerRadius: max(radius - 2.5, 0))
                            .fill(Color(nsColor: .textBackgroundColor))
                            .offset(y: 2.5)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(0.08)))
    }
}

// 分区标题的图标方块(同色浅底 + 同色图标)
struct IconBadge: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.12)))
    }
}

// MARK: - Page scaffold (限宽, 2026-09)

// oMLX 式限宽: 内容列钉死 720pt 且左对齐, 拉宽窗口时多余宽度分给
// sidebar(balanced)和右侧留白, 文字/卡片永不拉伸。卡片 -50 负 padding
// breakout 的参照系随之从「窗口边」变为「内容列边」(机制不变)。
// 内容列上限(五页共用; 调宽度只改这一处)
private let pageContentMaxWidth: CGFloat = 720

struct PageScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: pageContentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

// hover 局部状态(本工具链禁 @State, 见文件头 NOTE)
final class HoverState: ObservableObject { @Published var on = false }

// 幽灵图标按钮: 无静态边框, 悬停才浮现圆形底色 + 变色。
// 行内小控件统一语言: 排序 chevron / 删除 xmark / 📌 图钉。
struct GhostIcon: View {
    var symbol: String? = nil
    var emoji: String? = nil
    var size: CGFloat = 13
    var tint: Color = .secondary
    var hoverTint: Color = .primary
    var hoverBg: Color = Color.primary.opacity(0.08)
    var dimmed = false      // 平时弱化(如分组卡的灰图钉), 悬停点亮
    var ring: Color? = nil  // 静态圆圈(16pt, 与 GhostPlus 同径; 命中区仍 20pt): 平时 0.35, 悬停 0.8
    var disabled = false
    let action: () -> Void
    @ObservedObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Group {
                if let emoji {
                    Text(emoji).font(.system(size: size))
                } else {
                    Image(systemName: symbol ?? "")
                        .font(.system(size: size, weight: .semibold))
                }
            }
            .foregroundStyle(hover.on ? AnyShapeStyle(hoverTint) : AnyShapeStyle(tint))
            .opacity(disabled ? 0.3 : (dimmed && !hover.on ? 0.35 : 1))
            .frame(width: 20, height: 20)
            .background(Circle().fill(hover.on ? hoverBg : .clear))
            .overlay {
                if let ring {
                    Circle().stroke(ring.opacity(hover.on ? 0.8 : 0.35), lineWidth: 1)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover.on = $0 }
    }
}

// 幽灵菜单按钮(2026-09): GhostIcon 同款幽灵语言(弱化/悬停点亮/无 tooltip),
// 但本体是 Menu。目前唯一用途 = 手动区行首重排菜单。
struct GhostMenu<Content: View>: View {
    var symbol: String
    var size: CGFloat = 13
    var tint: Color = .secondary
    var hoverTint: Color = .primary
    var hoverBg: Color = Color.primary.opacity(0.08)
    var dimmed = false
    @ViewBuilder let content: () -> Content
    @ObservedObject private var hover = HoverState()

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hover.on ? AnyShapeStyle(hoverTint) : AnyShapeStyle(tint))
                .opacity(dimmed && !hover.on ? 0.35 : 1)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hover.on ? hoverBg : .clear))
        }
        .menuIndicator(.hidden)
        // 去 macOS 原生 Menu 的方形 button bezel: 只要裸符号 + 悬停圆底
        .menuStyle(.button)
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

// 行内绿色 +(16pt): 平时浅绿弱化, 悬停点亮; 点击 = 参数进手动区。
struct GhostPlus: View {
    var size: CGFloat = 16
    let action: () -> Void
    @ObservedObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: size - 5, weight: .bold))
                .foregroundStyle(hover.on ? Color.green : Color.green.opacity(0.45))
                .frame(width: size, height: size)
                .background(Circle().fill(hover.on ? Color.green.opacity(0.15) : .clear))
                .overlay(Circle().stroke(Color.green.opacity(hover.on ? 0.8 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

// Shared scrolling log box (env page + settings update card, kapa P2-5):
// auto-scrolls to the tail on new lines and after page rebuilds.
struct TailLogView: View {
    // 显示上限: Text 排版非增量, 全量编译日志(数千行)下每来一行全量
    // 重排, 成本平方增长 → 越编越卡(v2.0 检查 P2-3)。只留尾部 1000 行,
    // 每行成本恒定; 编译日志的有用信息(报错/链接/完成)都在尾部
    private static let maxLines = 1000
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.suffix(Self.maxLines).joined(separator: "\n"))
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
}

// MARK: - Form views

// Which row controls a DenseRow shows (2026-09 二轮, 单列行):
// .group  — 分组卡: 行首绿 + (进手动区) + 行尾灰 📌 (置顶)
// .pin    — 基本卡图钉区: 行尾彩色 📌 (取消置顶) + 绿 + (转入手动区)
// .manual — 基本卡手动区: 行首幽灵菜单重排(移到最前/最后/X 之后) + 行尾幽灵 ✕
enum RowSide { case group, pin, manual }

// Dense form row (2026-09 二轮, oMLX 双行风格): key 系统字在左,
// 值靠右(已设 = 蓝框蓝字, 空 = 虚线框灰字, 等宽字体)。
struct DenseRow: View {
    @ObservedObject var fm: FormModel
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    let param: Param
    let side: RowSide

    private var isPinned: Bool { fm.pinned.contains(param.key) }
    private var isSet: Bool { !(fm.values[param.key] ?? "").isEmpty }

    private var valueBinding: Binding<String> {
        Binding(
            get: { fm.values[self.param.key] ?? "" },
            set: { nv in fm.setValue(self.param.key, nv) })
    }

    // 「自定义」选项的 Picker tag: ‹› 不出现在任何选项值里, 不会与真值撞车
    private static let customTag = "‹custom›"

    // allowCustom 参数的下拉: 选「自定义」只翻模式标志(值原样保留在输入框里
    // 接着改), 选标准项 = 退出自定义 + 写值。不选自定义时走 valueBinding
    private var customChoiceBinding: Binding<String> {
        Binding(
            get: { fm.values[self.param.key] ?? "" },
            set: { nv in
                if nv == Self.customTag {
                    self.fm.customKeys.insert(self.param.key)
                } else {
                    self.fm.customKeys.remove(self.param.key)
                    fm.setValue(self.param.key, nv)
                } })
    }

    // 自定义模式行: [幽灵红 ×][输入框] 替换下拉。× = 回 7 项下拉并清空值
    // (完全默认态, 2026-09 定案)。× 用现成 GhostIcon 幽灵语言(平时暗、
    // 悬停点亮、无 tooltip)。输入框样式 = 普通文本参数行, 占位同全表单
    private var customChoiceControl: some View {
        HStack(spacing: 6) {
            GhostIcon(symbol: "xmark", size: 11, tint: .red, hoverTint: .red,
                      hoverBg: Color.red.opacity(0.10), dimmed: true, ring: .red) {
                fm.customKeys.remove(param.key)
                fm.setValue(param.key, nil)
            }
            TextField("default (\(T(param.def)))", text: valueBinding)
                .textFieldStyle(.plain)
                // 已设值 = 常规正文字色(primary, 明暗自动适配; 2026-09 修订:
                // 蓝 + semibold 推翻, 深色模式下蓝字对比度低看不清); 空值灰占位
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSet ? Color.primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // bools render as a picker: default (unset, not written to the .llm
    // file, llama.cpp default applies) / on / off. Legacy "1"/"0" values
    // written by the old toggle map onto on/off for display.
    // One-way flags (no --no-X in llama.cpp) only offer default + on:
    // the preset key being present enables them regardless of value, so
    // 'off' is not expressible. Any stored value (even legacy "0", which
    // is actually ON at runtime) displays as on.
    private var boolValueBinding: Binding<String> {
        Binding(
            get: {
                let v = (fm.values[self.param.key] ?? "").lowercased()
                if param.oneWay { return v.isEmpty ? "" : "on" }
                if v == "1" || v == "on" || v == "true" { return "on" }
                if v == "0" || v == "off" || v == "false" { return "off" }
                return ""
            },
            set: { nv in fm.setValue(self.param.key, nv) })
    }

    // 值列宽按控件类型分档(oMLX 式: 右对齐, 宽度随类型, 不必齐平);
    // 路径行最宽(要装下长路径 + 浏览按钮)
    static let controlWidth: CGFloat = 130
    static let pathControlWidth: CGFloat = 300

    // 原生式值列(2026-09 用户定案): 文本类控件(plain TextField 自身无框)
    // 包一层浅灰半透明底 + 细实线边 + 5pt 圆角的原生式输入框, 框恒定不变形,
    // 状态只靠字色表达(空 = 灰占位 / 已设 = 黑正文), 半透明 primary 自动适配
    // 明暗模式。原生 pop-up 自带白底圆角边框, 不再外包, 否则「框中框」
    // (里白外灰双层边)。bool 和 choice 都渲染成 pop-up(布尔 = default/on/off
    // 三选项下拉), 两个分支都要豁免
    private var needsBox: Bool {
        if case .bool = param.kind { return false }
        if case .choice = param.kind {
            return param.allowCustom && fm.customKeys.contains(param.key)
        }
        return true
    }

    @ViewBuilder
    private var framedControl: some View {
        let base = control
            .frame(width: controlColumnWidth, alignment: .trailing)
        if needsBox { base.nativeFieldBox() } else { base }
    }

    // ParamKind 带 associated value 不是 Equatable, 用 if case 判路径行
    private var controlColumnWidth: CGFloat {
        if case .path = param.kind { return Self.pathControlWidth }
        return Self.controlWidth
    }

    var body: some View {
        // 双行行(mockup V2): 左 = 参数名 + 提示小灰字, 右 = 值控件垂直居中;
        // 手动区的行首/行尾图标顶对齐贴名字行(其余区图标居中)
        HStack(spacing: 8) {
            if side == .manual {
                VStack(alignment: .leading, spacing: 0) { moveMenu; Spacer(minLength: 0) }
            }
            if side == .group {
                GhostPlus { fm.addManual(param.key) }
            }
            if side == .pin {
                // 2026-09 用户定案: 绿 + 在行首与分组卡对齐(原在行尾 📌 之后)
                GhostPlus { fm.addManual(param.key) }
            }
            VStack(alignment: .leading, spacing: 1) {
                // 参数名恒黑(2026-09-12 用户定案: 3abead3 的「恒常规」被推翻,
                // 名一律 semibold; 颜色仍恒黑)
                Text(param.key)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(T(param.hint))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                framedControl
                Spacer(minLength: 0)
            }
            switch side {
            case .group:
                GhostIcon(emoji: "📌", size: 12, tint: .secondary, hoverTint: Color.accentColor,
                          hoverBg: Color.accentColor.opacity(0.12), dimmed: true) { fm.togglePin(param.key) }
            case .pin:
                GhostIcon(emoji: "📌", size: 12, tint: Color.accentColor, hoverTint: Color.accentColor,
                          hoverBg: Color.accentColor.opacity(0.12)) { fm.togglePin(param.key) }
            case .manual:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    GhostIcon(symbol: "xmark", size: 11, tint: .secondary, hoverTint: .red,
                              hoverBg: Color.red.opacity(0.10)) { fm.removeManual(param.key) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // 手动区重排菜单: 幽灵 ⇅(GhostIcon 同款语言), 一次挪到任意位置。
    // 参照物是参数名不是序号(用户心智 = 「放在 X 后面」)。
    private var moveMenu: some View {
        GhostMenu(symbol: "arrow.up.arrow.down", dimmed: true) {
            Button(T("移到最前")) { fm.moveManual(param.key, to: .front) }
            Button(T("移到最后")) { fm.moveManual(param.key, to: .end) }
            Divider()
            ForEach(fm.manual.filter { $0 != param.key }, id: \.self) { k in
                Button(TF("移到 %@ 之后", k)) { fm.moveManual(param.key, to: .after(k)) }
            }
        }
    }

    // every branch is sized by the caller (fixed width per kind,
    // right-aligned in the oMLX-style value column)
    @ViewBuilder
    private var control: some View {
        switch param.kind {
        case .bool:
            Picker("", selection: boolValueBinding) {
                // default 选项恒带括号显示真实默认值(2026-09 修正: 非 oneWay
                // 原来裸 "default" 漏括号; oneWay 原来硬编码 "off" 改从 def 取,
                // 两分支统一, 值以 llama.cpp 源码默认为准)
                if param.oneWay {
                    Text("default (\(T(param.def)))").tag("")
                    Text("on").tag("on")
                } else {
                    Text("default (\(T(param.def)))").tag("")
                    Text("on").tag("on")
                    Text("off").tag("off")
                }
            }
            .labelsHidden()
            .controlSize(.small)
            // 原生 pop-up 只认颜色不认字重(2026-09-12 真机验证, d40e614 的
            // 下拉加粗无效已回退): 已设 = 正文字色, 空 = 灰占位
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(isSet ? Color.primary : .secondary)
        case .choice(let choices):
            if param.allowCustom, fm.customKeys.contains(param.key) {
                customChoiceControl
            } else {
                Picker("", selection: param.allowCustom ? customChoiceBinding : valueBinding) {
                    Text("default (\(T(param.def)))").tag("")
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                    if param.allowCustom { Text(T("自定义")).tag(Self.customTag) }
                }
                .labelsHidden()
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSet ? Color.primary : .secondary)
            }
        case .path:
            HStack(spacing: 6) {
                TextField("default (\(T(param.def)))", text: valueBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSet ? Color.primary : .secondary)
                    .lineLimit(1)
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
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSet ? Color.primary : .secondary)
        }
    }
}

// Version-C form: dense two-column rows, collapsible section cards,
// search filter, pinned block on top.
struct FormView: View {
    @ObservedObject var fm: FormModel
    @ObservedObject var dm: DashboardModel
    @ObservedObject var l10n = L10n.shared   // re-render on language switch
    var onSaved: () -> Void
    var onDelete: (() -> Void)? = nil
    // 功能栏(模型页顶栏): 固定不动, 无底色无分隔线(2026-09-11 用户定案
    // 去掉磨砂灰底), 内容在栏下方滚动, 不从栏底下穿过
    let header: AnyView

    private var q: String { dm.searchText.lowercased() }

    // fzf 式模糊搜索(2026-09 用户定案): 输入的字母/汉字按序出现在目标里
    // 即可(不要求连续); 打分 = 连续命中/串首/词首加分, 分高排前。
    // 贪心首匹配扫描(fzf DP 的简化版, 208 个 key 足够用)。目标是谁由
    // score() 决定: 参数名 / 提示两个独立值
    private static func fuzzyScore(_ query: [Character], _ target: [Character]) -> Int? {
        guard !query.isEmpty else { return 0 }
        var score = 0
        var qi = 0
        var prev = -2
        for (ti, ch) in target.enumerated() where qi < query.count {
            guard ch == query[qi] else { continue }
            var s = 1
            if ti == prev + 1 { s += 4 }   // 连续命中
            if ti == 0 { s += 4 }          // 串首命中
            if ti > 0, target[ti-1] == "-" || target[ti-1] == " " { s += 2 }   // 词首命中
            score += s
            prev = ti
            qi += 1
        }
        return qi == query.count ? score : nil
    }

    // nil = 不命中; 非 nil = 命中及得分(越高越好)。q 为空时恒 nil(matches 放行)
    private func score(_ p: Param) -> Int? {
        guard !q.isEmpty else { return nil }
        // 查询里的空格免费(不要求目标同位置有空格) = 等价于拆词
        let query = q.filter { $0 != " " }
        guard !query.isEmpty else { return nil }
        let qChars = Array(query)
        // 参数名 / 提示是两个独立可搜值(2026-09 用户定案: 416 个值不是
        // 208 个拼接串): 查询须完整命中其中一个, 不许跨值拼接(杀鬼命中);
        // 两值都中 = 参数命中一次, 取较高分排序
        let scores = [Self.fuzzyScore(qChars, Array(p.key.lowercased())),
                      Self.fuzzyScore(qChars, Array(T(p.hint).lowercased()))]
            .compactMap { $0 }
        return scores.max()
    }
    private func matches(_ p: Param) -> Bool { q.isEmpty || score(p) != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                // 卡片间距 14: 10 时太挤, 分组之间要有呼吸感
                VStack(spacing: 14) {
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
                    basicCard
                    ForEach(1...5, id: \.self) { g in sectionCard(g) }
                }
                .padding(12)
                .padding(.horizontal, 50)   // 行内容留 50; 卡片背景靠 CardChrome 外扩到窗口边
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // clicking empty space commits the focused field (same as
                // pressing Return) — children keep tap priority, so this only
                // fires on blank areas
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            // 方案 B: 操作栏钉在窗口底部, 不随内容滚动
            Divider()
            bottomBar
                // 与顶栏同定案: 去 50pt 内缩, 贴列边
                .padding(.vertical, 9)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
    }

    // 基本: fixed fields (path + name) + 上下两区: 上 = 手动区(用户顺序,
    // 行尾绿 +), 下 = 图钉区(字母序, 行首绿 + / 行尾 📌)。可折叠(默认
    // 展开, 2026-09 二轮)。搜索时对齐分组卡(2026-09 修正): 两区各自
    // 过滤, 无命中的区隐藏, 两区都空 = 整卡消失; 固定行和绿 + 隐藏,
    // 强制展开, 计数为过滤后数量。
    @ViewBuilder
    private var basicCard: some View {
        let searching = !q.isEmpty
        let showManual = !manualRows.isEmpty
        let showPin = !pinnedRows.isEmpty
        if !(searching && !showManual && !showPin) {
        VStack(spacing: 0) {
            Button {
                if searching { fm.basicOpen = true } else { fm.basicOpen.toggle() }
            } label: {
                sectionHeader(title: T("常用参数"), count: manualRows.count + pinnedRows.count,
                              setCount: (manualRows + pinnedRows).filter { !(fm.values[$0.key] ?? "").isEmpty }.count,
                              chevron: true, isOpen: fm.basicOpen || searching)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if fm.basicOpen || searching {
            if !searching, fm.mode == .add || fm.mode.isEdit {
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
            // 上下两区(2026-09 限宽重构): 上 = 手动区(淡绿), 下 = 图钉区(淡蓝);
            // 区头行可点折叠整区(默认展开不持久化, 折叠时绿 + 隐藏);
            // 空区恒显区头(2026-09, 旧空态提示行被区头灰字覆盖后删除);
            // 搜索时各自过滤 + 强制展开, 无命中的区不渲染
            VStack(spacing: 0) {
                if !searching || showManual {
                    VStack(alignment: .leading, spacing: 0) {
                        zoneHeader(title: T("通用参数"), color: UIStyle.manualTint,
                                   isOpen: fm.manualOpen || searching,
                                   action: { if searching { fm.manualOpen = true } else { fm.manualOpen.toggle() } }) {
                            HStack(spacing: 4) {
                                Text(T("点击"))
                                plusIcon(size: 12, stroke: 1)
                                Text(T("添加 · 允许自由排序"))
                            }
                        }
                        if fm.manualOpen || searching {
                            ForEach(manualRows, id: \.key) { p in
                                DenseRow(fm: fm, param: p, side: .manual)
                            }
                            if !searching { plusCell }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(Rectangle().fill(UIStyle.manualTint.opacity(0.05)))
                    if !searching || showPin { Divider() }
                }
                if !searching || showPin {
                    VStack(alignment: .leading, spacing: 0) {
                        zoneHeader(title: T("模型微调参数"), color: UIStyle.pinTint,
                                   isOpen: fm.pinOpen || searching,
                                   action: { if searching { fm.pinOpen = true } else { fm.pinOpen.toggle() } }) {
                            Text(T("点击📌添加 · 按字母排序"))
                        }
                        if fm.pinOpen || searching {
                            ForEach(pinnedRows, id: \.key) { p in
                                DenseRow(fm: fm, param: p, side: .pin)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(Rectangle().fill(UIStyle.pinTint.opacity(0.04)))
                }
            }
            .padding(6)
            }
        }
        .background(CardChrome().padding(.horizontal, -50))
        }
    }

    // 绿圈 + 图标(2026-09): plusCell 大号(23.4pt)与区头提示迷你号(12pt)共用,
    // 提示里指代的就是这个图标本体, 不是裸 ➕ emoji
    private func plusIcon(size: CGFloat, stroke: CGFloat) -> some View {
        Image(systemName: "plus")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.green)
            .frame(width: size, height: size)
            .background(Circle().stroke(Color.green.opacity(0.5), lineWidth: stroke))
    }

    // 双区区头行(2026-09): 区名 + 灰字添加提示 + chevron, 整行可点折叠本区;
    // 字号定案: 区名 11 > 提示 10(2026-09 用户定案, 原来反过来); chevron 旋转
    // 语言同 sectionHeader
    private func zoneHeader<Hint: View>(title: String, color: Color, isOpen: Bool,
                                        action: @escaping () -> Void,
                                        @ViewBuilder hint: () -> Hint) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(color)
                hint()
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // green +: idle = plus button; active = key-substring search field
    // with up to 5 alphabetical candidates. Params already in the manual
    // zone never appear; pinned-zone params are selectable (marked),
    // picking one moves them to the manual zone.
    @ViewBuilder
    private var plusCell: some View {
        if fm.pickerOpen {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    TextField(T("输入参数名…"), text: $fm.pickerQuery)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.plain)
                        .nativeFieldBox()
                        .onSubmit { confirmPicker() }
                        .onExitCommand {
                            fm.pickerOpen = false
                            fm.pickerQuery = ""
                        }
                    pickerCloseButton
                }
                ForEach(pickerCandidates, id: \.key) { p in
                    Button { fm.addManual(p.key) } label: {
                        HStack(spacing: 6) {
                            Text(p.key).font(.system(size: 11, design: .monospaced))
                            if fm.pinned.contains(p.key) {
                                Text(T("已置顶")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else {
            Button {
                fm.pickerOpen = true
            } label: {
                HStack(spacing: 8) {
                    // 方案 B: 大号绿 +(原 26pt, 2026-09 缩至 90% = 23.4pt)
                    plusIcon(size: 23.4, stroke: 1.5)
                    // 灰字说明(2026-09 用户定案, 与 tooltip 同文案)
                    Text(T("添加常用参数"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // 打开 picker 后, 大 + 原位变同款红 ×(2026-09 二轮: Esc 有效但不直观,
    // 可见的关闭途径才是正解); 点 × = 关闭并清空输入
    private var pickerCloseButton: some View {
        Button {
            fm.pickerOpen = false
            fm.pickerQuery = ""
        } label: {
            // 与绿 + 同径(同为 90% = 23.4pt)
            Image(systemName: "xmark")
                .font(.system(size: 11.7, weight: .bold))
                .foregroundStyle(.red)
                .frame(width: 23.4, height: 23.4)
                .background(Circle().stroke(Color.red.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var pickerCandidates: [Param] {
        let s = fm.pickerQuery.lowercased()
        guard !s.isEmpty else { return [] }
        return Array(PARAMS
            .filter { $0.key.lowercased().contains(s) && !fm.manual.contains($0.key) }
            .sorted { $0.key < $1.key }
            .prefix(5))
    }

    // Enter confirms only on an exact key match or a single candidate
    private func confirmPicker() {
        let s = fm.pickerQuery.lowercased()
        if let exact = PARAM_INDEX[s], !fm.manual.contains(exact.key) {
            fm.addManual(exact.key)
            return
        }
        let c = pickerCandidates
        if c.count == 1 { fm.addManual(c[0].key) }
    }

    // 组内参数按字母序(用户定案 2026-09-10:原定义顺序观感乱);
    // 搜索时改按命中得分降序(fzf 式, 2026-09); 基本区参数不出现在分组卡片
    private func groupRows(_ g: Int) -> [Param] {
        var rows = PARAMS.filter { $0.group == g && !fm.pinned.contains($0.key) && !fm.manual.contains($0.key) && matches($0) }
        if q.isEmpty {
            rows.sort { $0.key < $1.key }
        } else {
            rows.sort { a, b in
                let sa = score(a) ?? 0, sb = score(b) ?? 0
                return sa == sb ? a.key < b.key : sa > sb
            }
        }
        return rows
    }

    @ViewBuilder
    private func sectionCard(_ g: Int) -> some View {
        let rows = groupRows(g)
        if !rows.isEmpty {
            VStack(spacing: 0) {
                Button {
                    if !q.isEmpty { fm.openGroups = Set(1...5) } else { fm.toggleGroup(g) }
                } label: {
                    sectionHeader(title: T(GROUP_NAMES[g] ?? ""),
                                  icon: UIStyle.groupIcons[g-1], iconColor: UIStyle.hues[g-1],
                                  count: rows.count,
                                  setCount: rows.filter { !(fm.values[$0.key] ?? "").isEmpty }.count,
                                  chevron: true,
                                  isOpen: fm.openGroups.contains(g) || !q.isEmpty)
                    // make the WHOLE row tappable, not just the text
                    // (Spacer regions are not hit-testable by default)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if fm.openGroups.contains(g) || !q.isEmpty {
                    // 单列(2026-09 限宽); 行首绿 + 进手动区, 行尾灰 📌 置顶;
                    // 搜索时控件照常显示(2026-09 二轮)
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.key) { p in
                            DenseRow(fm: fm, param: p, side: .group)
                        }
                    }
                }
            }
            // 方案 B: 每个分区一个色相(顶部色条 + 标题图标方块)
            .background(CardChrome(accent: UIStyle.hues[g-1]).padding(.horizontal, -50))
        }
    }

    // 图钉区: pinned params, alphabetical (与分组 section 一致), 搜索时
    // 按得分降序(同分组卡);
    // 手动区: manual params, in file order(用户顺序神圣, 搜索只过滤不重排)。
    // 两区同分组卡一样参与搜索(2026-09 修正: 原「不参与搜索」是误听)
    private var pinnedRows: [Param] {
        let rows = PARAMS.filter { fm.pinned.contains($0.key) && matches($0) }
        if q.isEmpty { return rows.sorted { $0.key < $1.key } }
        return rows.sorted { a, b in
            let sa = score(a) ?? 0, sb = score(b) ?? 0
            return sa == sb ? a.key < b.key : sa > sb
        }
    }
    private var manualRows: [Param] { fm.manual.compactMap { PARAM_INDEX[$0] }.filter(matches) }

    // 卡片突破页面 50pt padding 填到窗口边缘(内容仍留 50):
    // 负 padding 只撑大绘制区,不影响布局 —— 卡片变大,行位置不变。
    // 纵向不外扩: 外扩会让相邻卡片的灰底在 10pt 缝隙里重叠,
    // 露出「超长椭圆」边,且折叠时灰区大于可点的 header 行,易点错
    private func sectionHeader(title: String, icon: String? = nil, iconColor: Color? = nil,
                               count: Int, setCount: Int, chevron: Bool, isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon, let iconColor {
                IconBadge(symbol: icon, color: iconColor)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
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
        // 折叠卡片要够高才有「抽屉」质感(7pt 太扁 → 10 仍嫌窄 → 13)
        .padding(.vertical, 13)
        .overlay(Divider(), alignment: .bottom)
    }

    private func fixedFieldRow(_ label: String, value: Binding<String>, placeholder: String, browse: Bool, readOnly: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .nativeFieldBox()
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
                if let err = fm.save() { infoAlert(T("保存失败"), err) }
                else { fm.justSaved = true; onSaved() }
            }
            .keyboardShortcut(.defaultAction)
            if fm.justSaved {
                Text(T("已保存"))
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            if fm.dirty && !fm.justSaved {
                // 方案 B: 未保存指示(橙点 + 灰字)
                HStack(spacing: 5) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(T("有未保存的修改")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(fm.mode == .add ? T("重置为全局参数") : T("重置为默认")) {
                // 二次确认,防误触。添加页的重置 = 整体重播种(与全局
                // 保存后的自动对齐同一动作),其余两页 = 清参数值
                if fm.mode == .add {
                    if confirmAlert(T("重置为全局参数"), T("将清空所有已填参数并对齐到当前已保存的全局参数(模型路径与自定义名称不受影响)。点「保存」后才会写入文件。"), ok: T("重置")) {
                        fm.reseedFromGlobal()
                    }
                } else {
                    if confirmAlert(T("重置为默认"), T("将清空所有已填参数(回到 llama.cpp 官方默认),置顶不受影响。点「保存」后才会写入文件。"), ok: T("重置")) {
                        fm.resetAll()
                    }
                }
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
        Group {
            content
        }
        .onAppear { refreshEntries() }
    }

    // 功能栏(模型页顶栏): 两行, 固定不动, 无底色无分隔线(2026-09-11:
    // 磨砂灰底被用户定案去掉, 内容不再从栏底下穿过)。
    // 第一行 = 下拉(撑满剩余) + 两个分段按钮; 第二行 = 搜索框整行;
    // 选中模型时第三行 = GGUF 真名 + 复制
    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                    Picker("", selection: modelSelection) {
                        Text(T("选择模型…")).tag(String?.none)
                        ForEach(dm.modelEntries, id: \.id) { m in
                            Text(m.label + (dm.loadedIDs.contains(m.id) ? T(" · 已加载") : "")).tag(String?.some(m.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    // 2026-09 用户定案: 下拉贴左边缘(原 .frame 默认居中,
                    // 内容宽度的 pop-up 悬在剩余空间中间), 与搜索框左对齐
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 选中 = 实心蓝底白字, 未选中 = 朴素; 重复点当前 tab 是 no-op
                    // (guard 防止重复点击清空搜索框)
                    Button {
                        guard dm.modelsTab != .global else { return }
                        dm.modelsTab = .global
                        dm.selectedModel = nil
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
                }
                HStack(spacing: 8) {
                    TextField(T("搜索参数…(中英文皆可,如 temp / 上下文)"), text: $dm.searchText)
                        .textFieldStyle(.plain)
                        // 2026-09 用户定案: 搜索框加高 ~1.2 倍(上边不动往下扩),
                        // 框内上下各加 2pt 垫高
                        .padding(.vertical, 2)
                        .nativeFieldBox()
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
            }
        }
        .padding(10)
        // 2026-09 用户定案: 顶栏去 50pt 内缩, 贴内容列边缘, 与卡片右边缘齐平
        // (原内缩是卡片突破到边缘之前的对齐线, 突破后变成 50pt 台阶)
    }
    // into dm.forms must land in the same render pass, otherwise the
    // form view never appears until some unrelated state change.
    // One FormModel per mode, cached in dm.forms: drafts survive
    // tab / model switches (2026-09 ruling).
    private func currentForm() -> FormModel? {
        let mode: FormMode
        switch dm.modelsTab {
        case .global: mode = .global
        case .add: mode = .add
        case .list:
            guard let id = dm.selectedModel else { return nil }
            mode = .edit(id: id)
        }
        if let f = dm.forms[mode] { return f }
        let f = FormModel(mode: mode)
        dm.forms[mode] = f
        return f
    }

    @ViewBuilder
    private var content: some View {
        switch dm.modelsTab {
        case .global:
            if let f = currentForm() {
                FormView(fm: f, dm: dm, onSaved: {
                    app.appendLogLine("[dashboard] global params saved")
                    // 保存全局 = 模板重新广播:无条件重播种添加表单
                    // (脏了也覆盖,2026-09 定案);编辑表单不参与
                    dm.forms[.add]?.reseedFromGlobal()
                }, header: AnyView(headerBar))
            }
        case .add:
            if let f = currentForm() {
                FormView(fm: f, dm: dm, onSaved: {
                    app.modelsDidChange()
                    app.appendLogLine("[dashboard] model added: \(f.targetID)")
                    dm.modelsTab = .list
                    dm.selectedModel = f.targetID
                    dm.forms[.add] = nil
                    refreshEntries()
                }, header: AnyView(headerBar))
            }
        case .list:
            if let id = dm.selectedModel, let f = currentForm() {
                FormView(fm: f, dm: dm,
                         onSaved: {
                    app.modelsDidChange()
                    app.appendLogLine("[dashboard] model config saved: \(id)")
                },
                         onDelete: {
                    if let m = dm.modelEntries.first(where: { $0.id == id }) { deleteModel(m) }
                },
                         header: AnyView(headerBar))
            } else {
                VStack(spacing: 0) {
                    headerBar
                    Text(dm.modelEntries.isEmpty
                         ? T("config/ 里没有模型,点上方「添加新模型」")
                         : T("从上方「模型」下拉菜单选择要配置的模型"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func deleteModel(_ m: ModelEntry) {
        if dm.loadedIDs.contains(m.id) {
            app.showAlert(T("无法删除"), T("模型正在加载,请先卸载模型"))
            return
        }
        guard confirmAlert(TF("删除模型 %@", m.label), T("确认删除参数配置(不会删除模型本体)")) else { return }
        try? FileManager.default.removeItem(atPath: m.path)
        if dm.selectedModel == m.id { dm.selectedModel = nil; dm.forms[.edit(id: m.id)] = nil }
        app.modelsDidChange()
        app.appendLogLine("[dashboard] model config deleted: \(m.id)")
        refreshEntries()
    }

    private func refreshEntries() {
        dm.modelEntries = loadModelEntries()
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
        guard !running, !PipelineState.shared.busy else { return }
        running = true
        PipelineState.shared.busy = true
        finished = nil
        lines = []
        pipeline([("$ curl -LsSf https://llama.app/install.sh | sh",
                   "curl -LsSf https://llama.app/install.sh | sh")]) { ok in
            self.running = false
            PipelineState.shared.busy = false
            self.finishedOK = ok
            self.finished = ok ? T("官方版安装完成") : (self.cancelled ? T("已取消") : T("官方版安装失败,查看上方输出"))
            done(ok)
        }
    }

    // assisted install: self-built. The checkout stays where the user put
    // it (normal llama.cpp layout); the app only runs the commands and
    // records the resulting paths. Existing checkouts get pull + rebuild.
    func installSource(dir: String, done: @escaping (Bool) -> Void) {
        guard !running, !PipelineState.shared.busy else { return }
        let fm = FileManager.default
        _ = try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exists = fm.fileExists(atPath: dir + "/.git")
        running = true
        PipelineState.shared.busy = true
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
            PipelineState.shared.busy = false
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
        guard confirmAlert(TF("切换到 %@?", name), TF("将执行 git checkout %@,需要重新 cmake 编译后才生效。", name), ok: T("确认切换")) else { return }

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
            // stderr 不排空 → nullDevice(v2.0 检查 P1-4 同族; stdout 这边
            // 本来就是先排空再走, 无死锁)
            p.standardError = FileHandle.nullDevice
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
        return confirmAlert(T("重启 router"), TF("%@。重启会卸载所有已加载的模型,确认继续吗?", what), ok: T("重启"))
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
        guard confirmAlert(T("删除这条记录?"), T("只删除这条记录,不会删除目录和二进制文件。"), ok: T("删除")) else { return }
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
                    // 系统分段控件: 深浅色自适应由系统保证(旧自定义 tab 钉死
                    // 浅色, 深色模式下是刺眼亮块, v2.0 检查 P2-1);
                    // fixedSize 防分段控件在宽容器里被拉满整行
                    Picker("", selection: $m.tab) {
                        Text(T("升级")).tag(EnvTab.upgrade)
                        Text(T("我已有其他编译版")).tag(EnvTab.adopt)
                        Text(T("分支管理")).tag(EnvTab.branches)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 12)
                // 方案 B: 页头(身份 + tab)卡片化; 突破到内容列边缘
                .background(CardChrome().padding(.horizontal, -50))
                tabContent
            } else {
                // 官方/未安装页头(方案 B 重构时 source 页头内联了,这两页的
                // 页头被孤儿化 —— 审计 C1 恢复); 视觉重构后包进卡片
                VStack(alignment: .leading, spacing: 10) {
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
                                .disabled(runner.running || pipelineState.busy)
                        } else {
                            Button(T("源码编译(推荐)")) { m.beginSourceInstall() }
                                .disabled(runner.running || pipelineState.busy || !m.missingTools.isEmpty)
                            Button(T("官方版·一键安装")) { m.runOfficialInstall() }
                                .disabled(runner.running || pipelineState.busy)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 14)
                .background(CardChrome(accent: m.env == .official ? UIStyle.hues[3] : UIStyle.hues[4]).padding(.horizontal, -50))
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
                            .textFieldStyle(.plain)
                            .frame(maxWidth: 420)
                            .nativeFieldBox()
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
                TailLogView(lines: runner.lines)
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
            .padding(.vertical, 14)
            // 方案 B: 三个 tab 各领一个色相(升级=蓝 / 接入=紫 / 分支=橙);
            // 突破到内容列边缘
            .background(CardChrome(accent: UIStyle.hues[0]).padding(.horizontal, -50))
        case .adopt:
            VStack(alignment: .leading, spacing: 8) {
                Text(T("接入一个你自己 clone + 编译过的 llama.cpp 目录(自动检测覆盖不了任意路径的存量安装)。接入后升级/分支管理都指向它。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                adoptedList
                HStack(spacing: 8) {
                    TextField(T("目录路径"), text: $m.adoptDirPath)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.plain)
                        .nativeFieldBox()
                    TextField(T("名字(留空 = 取目录名)"), text: $m.adoptName)
                        .font(.system(size: 11))
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 180)
                        .nativeFieldBox()
                    Button(T("浏览…")) { pickDir(into: $m.adoptDirPath) }
                        .controlSize(.small)
                    Button(T("接入")) { m.adopt() }
                        .disabled(runner.running)
                }
                // 接入 tab 自己的信息区
                TailLogView(lines: m.adoptNotes)
            }
            .padding(.vertical, 14)
            .background(CardChrome(accent: UIStyle.hues[1]).padding(.horizontal, -50))
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
                            .textFieldStyle(.plain)
                            .frame(maxWidth: 260)
                            .nativeFieldBox()
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
                TailLogView(lines: m.branchNotes)
                // 「编译并生效」发起的流水线也显示在这里
                if m.pipelineOrigin == .branches {
                    pipelineArea
                }
                if !m.missingTools.isEmpty {
                    toolsWarning
                }
            }
            .padding(.vertical, 14)
            .background(CardChrome(accent: UIStyle.hues[2]).padding(.horizontal, -50))
        }
    }

    // 流水线三件套: 日志 → 完成提示(结果在日志下方读着更顺) + 取消按钮
    @ViewBuilder
    private var pipelineArea: some View {
        TailLogView(lines: runner.lines)
        finishedLine
        if runner.running {
            Button(T("取消")) { runner.cancel() }
        }
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
            // re-check + start-if-ready: same action as 源码编译 (kapa P2-10)
            Button(T("我已装好,继续")) {
                m.beginSourceInstall()
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
        historyLines = []   // 先清空再后台加载, 新日期下不先露前一天的内容
        // 历史分片单个可达 50MB, 主线程读+切几十万行会冻住整个面板
        // (v2.0 检查 P2-4); 挪后台, 快照语义不变(历史文件是只读快照)
        DispatchQueue.global().async {
            let lines = logHistoryFile(forFile: file, day: d).map { logTailLines($0, n: 4000) } ?? []
            DispatchQueue.main.async {
                // 快速连点多个日期: 迟到的旧响应丢弃, 只认当前选中的日期
                guard self.day == d else { return }
                self.historyLines = lines
            }
        }
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
                // 方案 B: 两面板卡片化, Router=蓝 / App=绿
                LogPanel(m: app.logPageModel.router, store: app.routerLogStore,
                         file: LOG_FILE, title: "Router Log", accent: UIStyle.hues[0])
                LogPanel(m: app.logPageModel.app, store: app.appLogStore,
                         file: APP_LOG_FILE, title: "App Log", accent: UIStyle.hues[3])
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
    let accent: Color   // 方案 B 顶部色条

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
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
        .padding(.vertical, 12)
        .background(CardChrome(accent: accent).padding(.horizontal, -50))
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
    @Published var apiKey: String
    @Published var apiKeyFile: String
    @Published var pinned: Set<String>
    @Published var endpointsOpen = false
    // 2026-09 设置卡改版: 三个活口各自一份状态。
    // baseline = 上次落盘值(普通 var: 保存时 justSaved 的发布触发重渲染,
    // dirty 渲染时重算, 无需单独观察); dirty = 当前值偏离 baseline
    // (状态式, 与模型表单橙点同机制), 决定「确认」按钮是否点亮;
    // justSaved = 事件式, 仅该行「确认」成功瞬间亮起, 改回 baseline 不复亮
    // (避免「没点确认怎么已保存」歧义), 切页清零(确认是即刻动作, 无留存价值)
    var savedHost = ""
    var savedPort = ""
    var savedKey = ""
    var savedKeyFile = ""
    @Published var justSavedConn = false
    @Published var justSavedKey = false
    @Published var justSavedKeyFile = false
    var dirtyConn: Bool { host != savedHost || port != savedPort }
    var dirtyKey: Bool { apiKey != savedKey }
    var dirtyKeyFile: Bool { apiKeyFile != savedKeyFile }
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
    // 主机输入合法性: 空(= 默认)或能构造出合法 URL —— 判据与 RouterAPI.url
    // 的崩溃点完全一致(含同款 IPv6 括号处理), 能构造 = 不会强解包崩
    // (v2.0 检查 P1-1; 含空格等非法字符的输入在此拦住)
    var hostValid: Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return true }
        let hh = h.contains(":") ? "[\(h)]" : h
        return URL(string: "http://\(hh):8080/") != nil
    }
    init(app: AppDelegate) {
        self.app = app
        host = app.settings.host
        port = app.settings.port.map(String.init) ?? ""
        apiKey = app.settings.apiKey
        apiKeyFile = app.settings.apiKeyFile
        pinned = Set(app.settings.pinnedEndpoints)
        // baseline = 初始值; 必须在所有存储属性初始化完才能读 self
        savedHost = host
        savedPort = port
        savedKey = apiKey
        savedKeyFile = apiKeyFile
    }

    // 有显式保存按钮的输入, 没保存切页就该回退(2026-09 验证时定案);
    // endpointsOpen 无保存概念, 是视图状态, 保留
    func resetConnectionDraft() {
        host = app.settings.host
        port = app.settings.port.map(String.init) ?? ""
        apiKey = app.settings.apiKey
        apiKeyFile = app.settings.apiKeyFile
    }

    // 保存成功后: baseline = 当前值(dirty 自动清 → 按钮变灰) + 点亮事件标志
    func commitConn() {
        savedHost = host
        savedPort = port
        justSavedConn = true
    }
    func commitKey() {
        savedKey = apiKey
        justSavedKey = true
    }
    func commitKeyFile() {
        savedKeyFile = apiKeyFile
        justSavedKeyFile = true
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
            guard confirmAlert(T("更新 Corral"), T("更新完成后 app 将自动重启,router 会短暂中断并卸载所有已加载的模型,确认继续吗?"), ok: T("更新")) else { return }
        }
        runner.selfUpdate(repo: repo) { [weak self] ok in
            guard let self else { return }
            if ok {
                // ✅ 前缀 = 状态行绿色的颜色依据(约定: 纯展示的状态行颜色取自
                // 自己的 emoji 前缀; 带按钮逻辑的状态才用标志,见 kapa 报告 P1-2 定案)
                self.updateLine = T("✅ 更新完成,正在重启…")
                self.updateCount = 0   // 更新完 = 已最新; 也顺便让「更新」按钮在重启前置灰防双击
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
    // 复制用 app 自己拨号的同一地址(currentPublicHost/Port: 含 0.0.0.0→
    // 回环、代理 ON 恒回环等全部语义), 不用输入框草稿 —— 改了没点确认
    // 时草稿 ≠ router 实际监听地址, 复制出去是连不通的(v2.0 检查 P2-13)。
    // 显示保持草稿当预览
    private var savedHostShown: String { app.currentPublicHost }
    private var savedPortShown: String { String(app.currentPublicPort) }

    private let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    // 「已保存」槽位: 恒占宽(未亮时 opacity 0 占位), 让三个「确认」钉在
    // 同一条固定线(右缘 − 槽宽)上, 亮/灭不漂移
    private func savedSlot(_ lit: Bool) -> some View {
        Text(T("已保存"))
            .font(.caption)
            .foregroundStyle(.green)
            .opacity(lit ? 1 : 0)
    }

    // 灰条占位行: llama.cpp 支持但 Corral 未实现(参数已从模型表单移出,
    // router 模式下这些是死参数, 留在表单只会误导)。不可交互
    private func placeholderRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Text(T("不支持")).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    var body: some View {
        // 端点列表展开后超出窗口, 需要可滚动(与其他页一致)
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            // 通用: 界面语言 —— 切换即生效(重绘 SwiftUI + 重建 AppKit 菜单),
            // 持久化到 settings/app 的 lang: 行;选项用自名(中文/English)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "gearshape", color: UIStyle.hues[4])
                    Text(T("通用")).font(.system(size: 13, weight: .semibold))
                }
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
            .padding(.vertical, 14)
            // 方案 B: 每节一张卡片(通用=灰 / 连接=蓝 / API=紫 / 更新=绿);
            // 水平 -50 突破到内容列边缘 = 全 app 唯一卡片写法(见 AGENTS.md)
            .background(CardChrome(accent: UIStyle.hues[4]).padding(.horizontal, -50))

            // 连接: host/port + 确认(保存并立即重启 router)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "network", color: UIStyle.hues[0])
                    Text(T("连接")).font(.system(size: 13, weight: .semibold))
                }
                // 与状态栏菜单同一个开关(单一状态源 SMAppService);
                // 滑动开关: 紧跟标签右边, 不对齐任何竖线
                HStack(spacing: 10) {
                    Text(T("开机启动"))
                    Toggle("", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { _ in app.toggleLogin() }))
                        .appSwitch()
                    Spacer()
                }
                // 主机/端口同行:确认按钮同时保存两者,分行会误以为只确认端口
                HStack(spacing: 8) {
                    Text(T("主机"))
                    TextField(T("127.0.0.1(留空 = 默认)"), text: $m.host)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(m.host.isEmpty ? Color.secondary : .primary)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                        .nativeFieldBox()
                        .onChange(of: m.host) { m.justSavedConn = false }
                    Text(T("端口"))
                    TextField(T("8080(留空 = 默认)"), text: $m.port)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(m.port.isEmpty ? Color.secondary : .primary)
                        .textFieldStyle(.plain)
                        .frame(width: 100)
                        .nativeFieldBox()
                        .onChange(of: m.port) { m.justSavedConn = false }
                    Spacer()
                    Button(T("确认")) {
                        // 结束编辑态:光标消失,不用先点空白处
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        app.saveConnection(host: m.host, port: Int(m.port.trimmingCharacters(in: .whitespaces)))
                        m.commitConn()
                    }
                    .disabled(!m.portValid || !m.hostValid || !m.dirtyConn)
                    savedSlot(m.justSavedConn)
                }
                if !m.portValid {
                    Text(T("端口需为 1-65535 的数字"))
                        .font(.caption).foregroundStyle(.red)
                        .padding(.leading, 4)
                }
                if !m.hostValid {
                    Text(T("主机需为合法的主机名或 IP 地址（不可含空格）"))
                        .font(.caption).foregroundStyle(.red)
                        .padding(.leading, 4)
                }
                // api-key: 空 = 无鉴权(与发布版行为一致); 填了 = router 要求
                // 所有客户端带 Authorization: Bearer <key>, app 自己的请求
                // 自动带第一把(多把逗号分隔)。三个活口各自确认、各自重启
                HStack(spacing: 8) {
                    Text(T("API 密钥"))
                    TextField(T("留空 = 无密钥"), text: $m.apiKey)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(m.apiKey.isEmpty ? Color.secondary : .primary)
                        .textFieldStyle(.plain)
                        .frame(width: 260)
                        .nativeFieldBox()
                        .onChange(of: m.apiKey) { m.justSavedKey = false }
                    Spacer()
                    Button(T("确认")) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        app.saveApiKey(m.apiKey)
                        m.commitKey()
                    }
                    .disabled(!m.dirtyKey)
                    savedSlot(m.justSavedKey)
                }
                // api-key-file: 纯文本一行一把钥匙(# = 注释), 与 api-key 并集
                // 生效。文件不存在时 llama.cpp 直接 throw, 所以确认前校验
                HStack(spacing: 8) {
                    Text(T("API 密钥文件"))
                    TextField(T("路径(留空 = 不使用)"), text: $m.apiKeyFile)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(m.apiKeyFile.isEmpty ? Color.secondary : .primary)
                        .textFieldStyle(.plain)
                        .frame(width: 260)
                        .nativeFieldBox()
                        .onChange(of: m.apiKeyFile) { m.justSavedKeyFile = false }
                    Button(T("浏览…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            m.apiKeyFile = url.path
                        }
                    }
                    .controlSize(.small)
                    Spacer()
                    Button(T("确认")) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        let p = m.apiKeyFile.trimmingCharacters(in: .whitespaces)
                        // 空 = 关闭该项, 直接保存; 非空必须指向存在的普通文件
                        var isDir: ObjCBool = false
                        // 存在且不是目录(符号链接到文件也放行)
                        if p.isEmpty || FileManager.default.fileExists(atPath: app.expandTilde(p), isDirectory: &isDir) && !isDir.boolValue {
                            app.saveApiKeyFile(p)
                            m.commitKeyFile()
                        } else {
                            infoAlert(T("保存失败"), T("找不到该路径的文件"))
                        }
                    }
                    .disabled(!m.dirtyKeyFile)
                    savedSlot(m.justSavedKeyFile)
                }
                // 连接区灰条: 从参数目录移出的 router 死参数(填了也会被
                // router 覆盖/清除), 占位待对应功能开发
                placeholderRow(T("SSL 密钥文件"))
                placeholderRow(T("SSL 证书文件"))
                placeholderRow(T("模型别名"))
                // llama.cpp 路径不设输入框: 它在环境页管理(自动检测/接入),
                // 这里只展示当前值(旧输入框从未接保存逻辑, 7dc0d88 起就是死的)。
                // 2026-09 二轮: 从卡片外裸行收进本卡
                HStack {
                    Text(T("llama.cpp 路径")).frame(width: 120, alignment: .leading)
                    Text(app.settings.bin.isEmpty ? T("未设置(到环境页检测/接入)") : app.settings.bin)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(app.settings.bin.isEmpty ? Color.secondary : .primary)
                        .textSelection(.enabled)
                }
                // 卡底脚注(原为卡片外裸文字, 2026-09 二轮收进卡内)
                Text(T("主机/端口是 llama.cpp router 的监听地址,本应用自身不监听任何端口。点「确认」保存并立即重启 router 生效。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            .background(CardChrome(accent: UIStyle.hues[0]).padding(.horizontal, -50))

            // API 地址: 默认只给 base URL(…/v1), 完整端点收进折叠区
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "link", color: UIStyle.hues[1])
                    Text(T("API 地址")).font(.system(size: 13, weight: .semibold))
                }
                HStack(spacing: 8) {
                    Text(baseURL)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button(T("复制")) { copyToClipboard("http://\(savedHostShown):\(savedPortShown)/v1") }
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
                CardChrome(accent: UIStyle.hues[1])
                    .padding(.horizontal, -50)
                    .padding(.vertical, -14)
            )

            // 置顶的端点提升到卡片/折叠区外: 钉了 = 常显, 和 base URL 同档
            if !m.pinned.isEmpty {
                endpointGroup(T("置顶"), m.pinned.sorted())
            }

            // 更新(最底部): 打开页面即查(环境页同模式); 状态行 + 按钮一行,
            // 无更新 = 灰色禁用按钮, 有更新 = 蓝色可用; 一键更新 = git pull +
            // ./build.sh, 成功后自动退出并拉起新 app
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "arrow.down.circle", color: UIStyle.hues[3])
                    Text(T("Corral 更新")).font(.system(size: 13, weight: .semibold))
                }
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
                    TailLogView(lines: ur.lines)
                }
            }
            .padding(.vertical, 14)
            .background(CardChrome(accent: UIStyle.hues[3]).padding(.horizontal, -50))
        }
        .padding(50)
        .onAppear {
            m.checkUpdate()
            // 「已保存」纯事件式: 不跨次访问残留(确认是即刻动作, 无留存价值)
            m.justSavedConn = false
            m.justSavedKey = false
            m.justSavedKeyFile = false
            m.resetConnectionDraft()   // 没点确认的 host/port 切页回退
        }
        }
        // 点空白处 = 提交当前输入框(同模型表单), 提示符随之消失
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
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

    // 与模型表单 DenseRow 同款: 📌 图钉 | 路径(等宽) | 复制
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
                // 📌 emoji 与模型表单同语言: 已钉 = 全色, 未钉 = 弱化
                Text("📌")
                    .font(.system(size: 10))
                    .opacity(m.pinned.contains(path) ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(T("复制")) { copyToClipboard("http://\(savedHostShown):\(savedPortShown)\(path)") }
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Root view + window host

// MARK: - Experimental page (实验性功能)
// 音频转码开关 = 确认框 → 保存 → 重启 router(已加载模型先卸载);
// OFF 时代理进程不存在, router 直连公开端口。设计细节见 AGENTS.md asr-proxy 条目
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
                    Text(T("这里的功能是测试性质的:可能不稳定、可能有 bug、默认全部关闭,且只做了有限测试,不保证在所有场景下都正常工作。如果你不使用相关功能,请保持关闭;如果开启后出现问题,直接关闭对应功能即可恢复原有行为,不会损坏模型或数据。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .background(
                    // 方案 B: 总描述 = 灰色卡片
                    CardChrome(accent: UIStyle.hues[4])
                        .padding(.horizontal, -50)
                        .padding(.vertical, -14)
                )

                // 实验功能卡片: 音频转码(每个实验功能一张独立卡片)
                VStack(alignment: .leading, spacing: 10) {
                    Text(T("音频转码")).font(.headline)
                    Text(T("让本地语音转写支持 WebM 等格式")).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Text(T("音频转码代理"))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { proxyState.enabled },
                            set: { proxyState.enabled = $0; app.confirmAudioProxy($0) }))
                            .appSwitch()   // 与设置页开机启动同款, 贴右缘(原勾选框位置)
                    }
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
                    // 方案 B: 实验功能 = 橙色卡片(警告色语义)
                    CardChrome(accent: UIStyle.hues[2])
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

    // oMLX 0.6.4 shell: plain NavigationSplitView — system sidebar toggle
    // in the left toolbar, collapsible sidebar, 50pt unified titlebar with
    // separator + material, balanced columns, frame on the view itself so
    // the hosting window sizes correctly on first open.
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.page },
                set: { model.page = $0 ?? .models })) {
                // 名字 + 图标来自 DashPage(单一数据源, 与标题条标题共用)
                ForEach(DashPage.allCases, id: \.self) { p in
                    Label(T(p.titleKey), systemImage: p.symbol).tag(p)
                }
            }
            .listStyle(.sidebar)
            // 拖动范围锁在 180-240(参照 oMLX):max 240 + 720 限宽内容列
            // = 960 窗口最小宽,侧边栏永远挤不爆右侧内容
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 240)
        } detail: {
            // 五页统一限宽 720(单点套壳, 参照 oMLX ContentScaffold)
            PageScaffold {
                switch model.page {
                case .models:   ModelsPage(dm: model, app: app)
                case .upgrade:  EnvPage(app: app, runner: app.upgradeRunner)
                case .logs:     LogsPage(app: app)
                case .settings: SettingsPage(app: app)
                case .experimental: ExperimentalPage(app: app)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // 页面标题走系统标题栏(oMLX 式: 无自定义页头条), 数据源同侧边栏
        .navigationTitle(T(model.page.titleKey))
        // minWidth = sidebar + 720pt 限宽内容列 + 余量(2026-09 限宽重构;
        // 单列表单后不再需要旧双列的 1040)
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 560, idealHeight: 720)
    }
}

final class DashboardApp: NSObject {
    let model = DashboardModel()
    private var window: NSWindow?
    private var app: AppDelegate!

    func attach(_ app: AppDelegate) {
        self.app = app
    }

    // 显式导航:重置页面状态再打开(菜单栏「模型 → 配置文件」/「添加新模型」
    // 用,必须定位到指定位置)
    func show(page: DashPage, modelsTab: ModelsTab, editing: String?) {
        model.page = page
        model.modelsTab = modelsTab
        model.selectedModel = editing
        show()
    }

    // 纯打开:只建窗口/拉到前台,不碰导航状态 —— Dock 点击和菜单栏
    // 「控制面板」走这里,回到用户上次留下的页面(DashboardModel 挂在
    // AppDelegate 上比窗口长寿,切页状态留存语义;会话内记忆,重启回模型页)
    func show() {
        if window == nil {
            // 打开即 ideal 尺寸(2026-09 限宽: 内容列钉 720, 初始宽度
            // 只需容纳列 + sidebar + 一点留白)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            // 标题栏全走系统默认(与 oMLX 0.6.4 一致, 零自定义配置):
            // 材质背景(滚动时毛玻璃)+ 分隔细线 + 左侧系统切换按钮;
            // 标题文字 = 当前页名(由 .navigationTitle 持续驱动, 初值只是
            // 首帧渲染前的兜底)
            w.titleVisibility = .visible
            w.title = T("Corral 控制面板")
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: DashboardView(model: model, app: app))
            w.setContentSize(NSSize(width: 1100, height: 720))
            w.minSize = NSSize(width: 960, height: 560)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}
