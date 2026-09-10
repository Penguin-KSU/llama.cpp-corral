import Foundation
import SwiftUI

// MARK: - i18n (zh / en)

// Lightweight L10n: the Chinese source string is the key, the English
// translation lives in one dictionary. Why not the standard .lproj/.strings
// system (oMLX-style): we build with plain swiftc (no Xcode project, so no
// actool/string-catalog pipeline) and we want an in-app language switch that
// takes effect immediately — .lproj resolution follows the system locale,
// not app state. Missing keys fall back to the Chinese original (never a
// blank or a raw key) and log a warning.
//
// T()  — static strings:      T("保存")
// TF() — templates:           TF("删除模型 %@", id)   (%d for Int, %@ for String)

enum Lang: String {
    case zh
    case en
}

final class L10n: ObservableObject {
    static let shared = L10n()
    @Published var lang: Lang

    private init() {
        // explicit choice wins; otherwise follow the system language
        let saved = Settings.load().lang
        if let l = Lang(rawValue: saved) {
            lang = l
        } else {
            let code = Locale.current.language.languageCode?.identifier
            lang = (code == "zh") ? .zh : .en
        }
    }

    func set(_ l: Lang) {
        lang = l
        var s = Settings.load()
        s.lang = l.rawValue
        s.save()
    }
}

// Catalog default hints like "default" / "auto" are already English —
// only strings containing CJK are translation candidates.
private func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
}

func T(_ zh: String) -> String {
    guard L10n.shared.lang == .en, hasCJK(zh) else { return zh }
    guard let en = enDict[zh] else {
        NSLog("L10n miss: %@", zh)
        return zh
    }
    return en
}

func TF(_ zh: String, _ args: CVarArg...) -> String {
    let tmpl: String
    if L10n.shared.lang == .zh || !hasCJK(zh) {
        tmpl = zh
    } else if let en = enDict[zh] {
        tmpl = en
    } else {
        NSLog("L10n miss: %@", zh)
        tmpl = zh
    }
    return String(format: tmpl, arguments: args)
}

// English translations. Keys are the exact Chinese strings in the code
// (including the parameter-catalog default hints, translated at render
// time). Parameter names, endpoint paths, model names and log output are
// data, never translated.
let enDict: [String: String] = [
    // ── status bar menu / AppKit alerts (main.swift) ──
    "检测到残留的 llama.cpp 进程": "Stale llama.cpp process detected",
    "端口 %d 被上次未正常退出的 llama.cpp 实例占用，要杀掉它并重新开始吗？": "Port %d is still held by a llama.cpp instance from an abnormal exit. Kill it and start over?",
    "杀掉": "Kill",
    "取消": "Cancel",
    "更新": "Update",
    "Corral 更新": "Corral Update",
    "更新 Corral": "Update Corral",
    "更新完成后 app 将自动重启,router 会短暂中断并卸载所有已加载的模型,确认继续吗?": "When the update finishes, the app restarts itself — the router is briefly interrupted and all loaded models are unloaded. Continue?",
    "无法定位源码目录(本 app 不在 git clone 中),请重新下载最新源码并运行 ./build.sh": "Source directory not found (this app is not in a git clone) — download the latest source and run ./build.sh",
    "无法判断是否有更新(当前分支无上游)": "Cannot check for updates (current branch has no upstream)",
    "更新完成,正在重启…": "Update complete — restarting…",
    "更新完成": "Update complete",
    "更新失败,查看上方输出": "Update failed — see the output above",
    "模型": "Models",
    "控制面板": "Dashboard",
    "开机启动": "Start at Login",
    "退出": "Quit",
    "卸载模型": "Unload Model",
    "加载模型": "Load Model",
    "复制模型名": "Copy Model Name",
    "配置文件": "Config File",
    "(config/ 里没有模型)": "(no models in config/)",
    "该目录不是 git 仓库(找不到 .git)": "Not a git repository (.git not found)",
    "%@/build/bin/llama 不存在 —— 这个源码目录还没编译过,请先编译(参考 llama.cpp docs/build.md)": "%@/build/bin/llama is missing — this source tree has not been built yet (see llama.cpp docs/build.md)",
    "重启 router": "Restart router",
    "重启会卸载所有已加载的模型,确认继续吗?": "Restarting unloads all loaded models. Continue?",
    "重启": "Restart",
    "git checkout 失败: %@": "git checkout failed: %@",
    "git checkout 失败": "git checkout failed",
    "router 启动失败": "router failed to start",
    "重试": "Retry",
    "router 反复崩溃": "router crash loop",
    "router 在 60 秒内多次退出，已停止自动重启。请查看 log 排查原因后重新打开本应用。": "The router exited repeatedly within 60 seconds, so auto-restart is disabled. Check the log, fix the cause, then relaunch this app.",
    "加载失败: %@": "Load failed: %@",
    "卸载失败: %@": "Unload failed: %@",
    "连接设置已保存,正在重启 router 生效": "Connection settings saved; restarting the router to apply",
    "%@。重启会卸载所有已加载的模型,确认继续吗?": "%@ Restarting unloads all loaded models. Continue?",
    "设置登录项失败: %@": "Failed to set the login item: %@",

    // ── models page / parameter form ──
    "模型路径必填": "Model path is required",
    "默认: ": "Default: ",
    "取消置顶": "Unpin",
    "置顶到基本区": "Pin to the basic section",
    "置顶到列表顶部": "Pin to top of list",
    "浏览…": "Browse…",
    "基本 · 置顶": "Basic · Pinned",
    "GGUF 文件路径(必填)": "GGUF file path (required)",
    "自定义名称": "Custom Name",
    "留空 = 显示文件名": "empty = show file name",
    "将保存为 config/%@.llm": "Will be saved as config/%@.llm",
    "点参数行右侧的图钉,把常用参数置顶到这里": "Click the pin on a row to move frequently used parameters here",
    "%d 项 · %d 已设置": "%d items · %d set",
    "%d 项": "%d items",
    "保存": "Save",
    "已保存": "Saved",
    "端口需为 1-65535 的数字": "Port must be a number between 1 and 65535",
    "重置为默认": "Reset to Defaults",
    "将清空所有已填参数(回到 llama.cpp 官方默认),置顶不受影响。点「保存」后才会写入文件。": "Clears all filled parameters (back to llama.cpp official defaults); pinning is untouched. Nothing is written until you hit Save.",
    "重置": "Reset",
    "删除配置": "Delete Config",
    "llama.cpp 未就绪,模型暂不可用": "llama.cpp is not ready — models unavailable",
    "去环境页 →": "Go to Environment →",
    "选择模型…": "Select model…",
    " · 已加载": " · loaded",
    "全局参数": "Global Parameters",
    "添加新模型": "Add Model",
    "搜索参数…(如 temp / gpu / cache)": "Search parameters… (e.g. temp / gpu / cache)",
    "复制": "Copy",
    "config/ 里没有模型,点上方「添加新模型」": "No models in config/ — use Add Model above",
    "从上方「模型」下拉菜单选择要配置的模型": "Pick a model from the dropdown above to edit its config",
    "无法删除": "Cannot delete",
    "模型正在加载,请先卸载模型": "The model is loaded — unload it first",
    "删除模型 %@": "Delete model %@",
    "确认删除参数配置(不会删除模型本体)": "Deletes the parameter config only — the model file itself is kept",
    "确认": "Confirm",

    // ── environment page (upgrade / adopt / branches) ──
    "升级完成": "Upgrade complete",
    "升级失败,查看上方输出": "Upgrade failed — see output above",
    "已取消": "Cancelled",
    "官方版安装完成": "Official build installed",
    "官方版安装失败,查看上方输出": "Official install failed — see output above",
    "源码版安装完成": "Source build installed",
    "源码版安装失败,查看上方输出": "Source install failed — see output above",
    "检查更新中…": "Checking for updates…",
    "检查更新失败(网络?),下次打开页面再试": "Update check failed (network?) — retry next time the page opens",
    "当前分支无对应远程分支,跳过检查": "No remote branch for the current branch — check skipped",
    "当前分支无上游,跳过 pull 直接编译": "No upstream for the current branch — skipping pull, building as-is",
    "⚠️ 代码已更新,当前二进制还是旧版 —— 需要编译": "⚠️ Code is updated but the binary is stale — a build is needed",
    "✅ 代码已是最新(未在 app 内编译过,二进制新旧未知)": "✅ Code is up to date (never built in-app; binary age unknown)",
    "✅ 已是最新": "✅ Up to date",
    "⬆️ 官方有 %d 个新提交 · 最新: %@": "⬆️ %d new commit(s) upstream · latest: %@",
    "⬆️ GitHub 上有 %d 个新提交 · 最新: %@": "⬆️ %d new commit(s) on GitHub · latest: %@",
    "⬆️ 有新版本(当前 b%d → 新 b%d)": "⬆️ New version available (b%d → b%d)",
    "官方最新: %@": "Latest upstream: %@",
    "切换到 %@?": "Switch to %@",
    "将执行 git checkout %@,需要重新 cmake 编译后才生效。": "Runs git checkout %@; a cmake rebuild is required for it to take effect.",
    "确认切换": "Switch",
    "当前有未提交的改动(%d 项)": "Uncommitted changes (%d file(s))",
    "请先在终端 commit 或 stash 后再切换分支。": "Commit or stash in a terminal before switching branches.",
    "本地分支 %@ 有 %d 个未推送提交": "Local branch %@ has %d unpushed commit(s)",
    "切换到远程分支会把本地分支重置到远程状态,这些提交将被丢弃。请先在终端 push 或处理后再切换。": "Switching to the remote branch would reset the local branch to the remote state and discard these commits. Push or handle them in a terminal first.",
    "知道了": "OK",
    "router 已一并停止。请释放被占用的端口后,重新切换开关重试。": "The router was stopped as well. Free the occupied port, then toggle the switch again to retry.",
    "git checkout 失败:\n%@": "git checkout failed:\n%@",
    "已切换到 %@(与当前编译版本一致,无需重新编译)": "Switched to %@ (matches the built version — no rebuild needed)",
    "已切换到 %@ —— 需要重新编译,点「编译并生效」": "Switched to %@ — rebuild required, click Build & Apply",
    "编译完成,正在重启 router 生效…": "Build complete; restarting the router to apply…",
    "router 仍未就绪,请查看日志页": "router still not ready — check the Logs page",
    "✅ 升级完成,router 已生效": "✅ Upgrade complete — router is running the new build",
    "接入失败:\n%@": "Adopt failed:\n%@",
    "已接入 %@,router 已重启": "Adopted %@ — router restarted",
    "已切换到 %@,router 已重启": "Switched to %@ — router restarted",
    "正在接入其他编译版": "Adopting another build",
    "删除这条记录?": "Delete this entry?",
    "只删除这条记录,不会删除目录和二进制文件。": "This only removes the record — the directory and binaries are not deleted.",
    "删除": "Delete",
    "✅ 其他编译版": "✅ Other build",
    "官方版": "Official",
    "正在切换回官方版": "Switching back to the official build",
    "可用编译版(点击切换)": "Available builds (click to switch)",
    "升级 %@": "Upgrade %@",
    "使用中": "In use",
    "目录不存在": "Directory not found",
    "名字(留空 = 取目录名)": "Name (empty = use folder name)",
    "✅ 官方源码编译版": "✅ Official source build",
    "官方源码编译版": "Official source build",
    "分支: %@": "branch: %@",
    "升级": "Upgrade",
    "我已有其他编译版": "I Have Another Build",
    "分支管理": "Branches",
    "升级(重跑官方安装脚本)": "Upgrade (rerun official installer)",
    "源码编译(推荐)": "Build from Source (recommended)",
    "官方版·一键安装": "Official · One-Click Install",
    "目录": "Directory",
    "✅ 官方预编译版": "✅ Official prebuilt",
    "❌ 未检测到 llama.cpp": "❌ llama.cpp not detected",
    "选一种方式安装,全程无需打开终端(源码版需先备好编译工具,见下方提示)": "Pick an install method — no terminal needed (the source build requires build tools; see the note below)",
    "git pull 拉取最新代码并重新编译,完成后自动重启 router 生效。": "git pull + rebuild; the router restarts automatically when done.",
    "开始升级": "Start Upgrade",
    "接入一个你自己 clone + 编译过的 llama.cpp 目录(自动检测覆盖不了任意路径的存量安装)。接入后升级/分支管理都指向它。": "Adopt a llama.cpp directory you cloned and built yourself (auto-detection can't find installs in arbitrary paths). Upgrades and branch management will then target it.",
    "目录路径": "Directory path",
    "接入": "Adopt",
    "列出本仓库的分支(本地 + 已 fetch 的远程)。切换后需到「升级」页重新编译。": "Lists this repo's branches (local + fetched remote). After switching, rebuild on the Upgrade tab.",
    "查询分支": "Query Branches",
    "刷新": "Refresh",
    "搜索分支…": "Search branches…",
    "+/− 相对当前分支 %@": "+/− vs current branch %@",
    "当前": "current",
    "上游领先 %d 个提交,「升级」可更新": "upstream is %d commit(s) ahead — Upgrade can update",
    "与上游同步": "in sync with upstream",
    "当前分支 %@ 未编译,需要重新编译才生效": "Branch %@ has not been compiled — rebuild to take effect",
    "编译并生效": "Build & Apply",
    "当前分支": "current branch",
    "当前分支 %@": "current branch %@",
    "比%@多 %d 个提交": "ahead of %@ by %d commit(s)",
    "比%@少 %d 个提交": "behind %@ by %d commit(s)",
    "与%@同步": "in sync with %@",
    "缺少编译工具:%@": "Missing build tools: %@",
    "Xcode 命令行工具": "Xcode Command Line Tools",
    "• Xcode 命令行工具:终端执行 xcode-select --install 并按弹窗安装,或到 Mac App Store 搜索 Command Line Tools 安装": "• Xcode Command Line Tools: run xcode-select --install in a terminal, or search for Command Line Tools in the Mac App Store",
    "• CMake:官网 cmake.org/download 下载 macOS 安装包,或终端执行 brew install cmake": "• CMake: download the macOS package from cmake.org/download, or run brew install cmake in a terminal",
    "我已装好,继续": "Installed — Continue",

    // ── settings page ──
    "通用": "General",
    "界面语言": "Language",
    "连接": "Connection",
    "主机": "Host",
    "127.0.0.1(留空 = 默认)": "127.0.0.1 (empty = default)",
    "端口": "Port",
    "8080(留空 = 默认)": "8080 (empty = default)",
    "API 地址": "API Base URL",
    "更多端点(v1 %d · 非 v1 %d)": "More endpoints (v1 %d · non-v1 %d)",
    "v1 端点": "v1 endpoints",
    "非 v1 端点": "non-v1 endpoints",
    "置顶": "Pinned",
    "llama.cpp 路径": "llama.cpp Path",
    "未设置(到环境页检测/接入)": "not set (detect / adopt on the Environment page)",
    "主机/端口是 llama.cpp router 的监听地址,本应用自身不监听任何端口。点「确认」保存并立即重启 router 生效。": "Host/port is the llama.cpp router's listen address; this app itself listens on no port. Confirm saves and restarts the router immediately.",

    // ── sidebar / window ──
    "环境": "Environment",
    "日志": "Logs",
    "暂停滚动": "Pause scroll",
    "查找历史": "View history",
    "默认状态": "Reset to default",
    "实时日志 + 自动滚动": "Live log + auto-scroll",
    "设置": "Settings",
    "Corral 控制面板": "Corral Dashboard",

    // ── parameter catalog: group names + default hints (rendered via T) ──
    "上下文 & 缓存": "Context & Cache",
    "GPU & 设备": "GPU & Devices",
    "采样": "Sampling",
    "推理 & 模板": "Inference & Templates",
    "其他(多模态 / 服务器 / 投机解码 / 调试)": "Other (multimodal / server / spec decoding / debug)",
    "0 (从模型读取)": "0 (read from model)",
    "-1 (无限)": "-1 (unlimited)",
    "auto (slots 为 auto 时启用)": "auto (enabled when slots is auto)",
    "未设置": "unset",
    "linear (模型默认)": "linear (model default)",
    "模型默认": "model default",
    "auto (数字 / auto / all)": "auto / number / all",
    "默认": "llama.cpp",
    "同 threads": "same as threads",
    "同 cpu-mask": "same as cpu-mask",
    "同 cpu-range": "same as cpu-range",
    "同 cpu-strict": "same as cpu-strict",
    "同 poll": "same as poll",
    "格式 FNAME:SCALE": "format FNAME:SCALE",
    "默认 (\\n : \" *)": "\\n : \" *",
    "-1 (随机)": "-1 (random)",
    "默认顺序": "default order",
    "格式 TOKEN_ID(+/-)BIAS": "format TOKEN_ID(+/-)BIAS",
    "模型自带": "built into model",
    "JSON 对象字符串": "JSON object string",
    "-1 (不限)": "-1 (unlimited)",
    "无": "none",
    "读自模型": "read from model",
    "在 PATH 中查找": "looked up in PATH",
    "跟随 device (none = 不卸载)": "follows device (none = no offload)",
    "宿主环境 (docker:/podman:/ssh:)": "host environment (docker:/podman:/ssh:)",
    "无 (all = 全部)": "none (all = every tool)",
    "none (逗号分隔: draft-simple, ngram-simple, ...)": "none (comma-separated: draft-simple, ngram-simple, ...)",
    "同 spec-draft-threads": "same as spec-draft-threads",
    "同 spec-draft-cpu-mask": "same as spec-draft-cpu-mask",
    "同 spec-draft-cpu-strict": "same as spec-draft-cpu-strict",
    "同 spec-draft-poll": "same as spec-draft-poll",
    "实验性功能": "Experimental",
    "音频转码": "Audio Transcoding",
    "音频转码代理": "Audio transcoding proxy",
    "让本地语音转写支持 WebM 等格式": "Lets local speech-to-text accept WebM and similar formats",
    "这里的功能是测试性质的:可能不稳定、可能有 bug、默认全部关闭,且只做了有限测试,不保证在所有场景下都正常工作。如果你不使用相关功能,请保持关闭;如果开启后出现问题,直接关闭对应功能即可恢复原有行为,不会损坏模型或数据。": "These features are under test: they may be unstable or contain bugs, are off by default, and have only been lightly tested — we can't guarantee they work in every situation. If you don't use the related feature, keep it off. If one misbehaves, just turn it off to restore normal behavior; it won't damage your models or data.",
    "为什么有这个功能:llama.cpp 的本地语音转写只认 WAV / MP3 / FLAC 三种音频,而 OpenWhispr 等听写软件录的是 WebM/Opus,两者对不上、直接转写会报 400。本功能在中间实时把 WebM 等转成 ASR 能读的 16kHz 单声道 WAV。": "Why this exists: llama.cpp's local speech-to-text only reads WAV / MP3 / FLAC, while dictation apps like OpenWhispr record WebM/Opus — the two don't match, so transcribing directly fails with a 400 error. This feature converts WebM and similar audio into the 16 kHz mono WAV the ASR model expects, in real time.",
    "为什么是实验性:目前只在 OpenWhispr 上验证过;对其他听写软件大概率可用,但未逐一测试、不保证效果。不使用语音转写软件请保持关闭(默认关闭)。": "Why it's experimental: verified only with OpenWhispr. It will likely work with other dictation apps, but we haven't tested each one and can't guarantee results. If you don't use speech-to-text, keep it off (off by default).",
    "监听端口": "Listen port",
    "与设置页连接端口一致(当前 %d)": "Same as the connection port in Settings (currently %d)",
    "未找到 — 请安装: brew install ffmpeg": "Not found — install with: brew install ffmpeg",
    "音频转码代理启动失败": "Audio transcoding proxy failed to start",
    "启用": "enable",
    "停用": "disable",
    "将%@音频转码代理,需要重启 router,已加载的模型会先卸载。确认继续吗?": "This will %@ the audio transcoding proxy and restart the router; any loaded models will be unloaded first. Continue?",
]
