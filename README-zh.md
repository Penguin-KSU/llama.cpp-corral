# Corral

English | 中文

macOS 菜单栏应用:管理你**已有的** [llama.cpp](https://github.com/ggml-org/llama.cpp)
router(`llama-server serve`,官方预编译版或自编译版均可),
多模型一键加载/卸载,不用每次都敲命令行。

## 功能

- 菜单栏常驻,自动启动 llama.cpp router,意外退出自动重启,残留进程/端口冲突自动检测清理
- 多模型管理:每个模型一个 `*.llm` 参数文件,菜单栏一键加载/卸载
- 原生 SwiftUI 控制面板:模型参数可视化编辑(~210 个 llama-server 参数,常用参数可置顶)、
  实时日志、设置(端口、API 端点列表)
- llama.cpp 编译版管理:自动检测已有安装,接入并切换多个本地编译版
  (官方预编译版/自编译版/fork),一键升级(源码版 pull + 重编 + 自动重启),
  分支管理
- 中/英双语界面(设置页切换,默认跟随系统语言)
- 开机启动(可选)

## 对 llama.cpp 零侵入

Corral **从不修改 llama.cpp 的任何文件** —— 不写进源码目录、不动 build 产物、
不改任何配置。它只做三件事:启动并管理 `llama-server` 进程、把你的 `*.llm`
参数文件合并成 preset、通过 HTTP API 加载/卸载模型。所有自有数据都在自己的
数据目录里(见下)。

app 本身也很轻:单一二进制、零第三方依赖、无后台服务、不监听任何端口
(端口是 llama.cpp router 的)。

**卸载**:退出 app → 删除 `Corral.app` → 删除
`~/Library/Application Support/Corral/`(想保留配置就不删这一步)。
你的 llama.cpp 源码/二进制和模型文件原样不动。

## 安装(从源码构建)

```sh
git clone https://github.com/Penguin-KSU/llama.cpp-corral
cd llama.cpp-corral
./build.sh        # 产物 Corral.app,无需 Xcode,swiftc 零依赖
```

## 前置要求

- macOS 13+
- 已安装llama.cpp(官方预编译版或自行编译均可)。控制面板「环境」页会自动检测,
  未安装时可引导安装(官方一键安装 / 源码编译),已安装时可升级/切换分支;
  已有其他位置的编译版可在该页「接入」。首次使用请在「设置」页确认
  `bin` 目录(如 `/path/to/llama.cpp/build/bin`)和端口。

## 使用

1. 运行 app,状态栏出现 llama 图标
2. 打开「控制面板」(状态栏菜单,或 app 运行时点 Dock 图标)→「模型」→
   「添加新模型」,填模型路径(GGUF)和常用参数
3. 点击状态栏 → 模型 → 加载/卸载

## 模型参数文件(`*.llm`)

每个文件对应一个模型,`key = value` 格式,键名即 llama.cpp 命令行参数名。
**模型 id = 文件名去掉 `.llm` 后缀**(恒为 GGUF 真名);可加一行 `# display-name: 别名` 注释设置仅用于界面显示的别名。留空的参数不写,由 llama.cpp 使用官方默认值。

```ini
model              = /path/to/your-model.gguf
n-gpu-layers       = 99
ctx-size           = 128000
cache-type-k       = q8_0
cache-type-v       = q8_0
jinja              = 1
temp               = 0.7
top-p              = 0.95
```

应用启动时把所有 `.llm` 合并成 `.router-preset.ini`,通过 `--models-preset`
交给 llama.cpp,请勿手改该生成文件。

## 数据目录

所有用户数据在 macOS 标准位置(首次启动自动创建):

```
~/Library/Application Support/Corral/
├── config/           模型参数文件(.llm)
├── settings/         应用设置(bin 路径、端口、端点置顶、语言、全局参数模板)
└── logs/             router 日志
```

## 仓库结构

```
main.swift          AppKit 主体(设置/进程管理/router API)
dashboard.swift     控制面板(SwiftUI)
l10n.swift          中/英文案(中文当 key + 英文字典)
icon.swift          状态栏图标
build.sh            构建脚本(swiftc 一行编译)
icons/              预渲染的 AppIcon.icns + 状态栏 PNG
LICENSE             Apache License 2.0
```

## 许可证

Apache License 2.0,见 [LICENSE](LICENSE)。

