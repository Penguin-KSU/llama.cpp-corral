# Corral

[中文](README-zh.md) | English

A macOS menu bar app that manages your [llama.cpp](https://github.com/ggml-org/llama.cpp)
router (`llama-server serve`) — load and unload multiple models with one click,
no more typing the same commands every time.

## Features

- Lives in the menu bar; starts the llama.cpp router automatically, restarts it
  on crash, and detects/cleans up stale processes and port conflicts
- Multi-model management: one `*.llm` parameter file per model, one-click
  load/unload from the menu bar
- Native SwiftUI dashboard: visual editing of model parameters (~210
  llama-server options, frequently used ones pinnable), live logs, settings
  (port, API endpoint list)
- llama.cpp build management: detects what you have, adopts and switches
  between multiple local builds (official prebuilt / self-built / fork),
  upgrades with one click (source builds: pull + rebuild + auto-restart),
  and manages branches
- Chinese / English UI (switch in Settings; follows the system language by default)
- Optional start-at-login

## Zero intrusion into llama.cpp

Corral **never modifies any of llama.cpp's files** — nothing is written into
the source tree, build artifacts are left alone, and no configuration is
touched. It does exactly three things: starts and manages the `llama-server`
process, merges your `*.llm` parameter files into a preset, and loads/unloads
models over the HTTP API. All of its own data lives in its own data directory
(see below).

The app itself is light: a single binary, zero third-party dependencies, no
background services, and it listens on no port of its own (the port belongs to
the llama.cpp router).

**Uninstall**: quit the app → delete `Corral.app` → delete
`~/Library/Application Support/Corral/` (skip this step to keep your configs).
Your llama.cpp source/binary and model files are left exactly as they were.

## Installation (build from source)

```sh
git clone https://github.com/Penguin-KSU/llama.cpp-corral
cd llama.cpp-corral
./build.sh        # produces Corral.app; no Xcode needed, plain swiftc
```

## Prerequisites

- macOS 13+
- llama.cpp installed (official prebuilt or self-built). The dashboard's
  Environment page detects it automatically and can guide installation
  (official one-click install / build from source), upgrade it, or switch
  branches; an existing build in another location can be adopted there.
  On first use, confirm the `bin` directory (e.g.
  `/path/to/llama.cpp/build/bin`) and port on the Settings page.

## Usage

1. Run the app — a llama icon appears in the menu bar
2. Open the Dashboard (menu bar, or click the Dock icon while the app is
   running) → Models → Add Model, and fill in the GGUF path and your usual
   parameters
3. Click the menu bar icon → model → load/unload

## Model parameter files (`*.llm`)

One file per model, `key = value` format; keys are llama.cpp command-line
option names. **Model id = file name without the `.llm` suffix.** Left-empty
parameters are not written, so llama.cpp uses its official defaults.

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

On launch the app merges all `.llm` files into `.router-preset.ini` and passes
it to llama.cpp via `--models-preset`. Don't edit that generated file by hand.

## Data directory

All user data lives in the standard macOS location (created on first launch):

```
~/Library/Application Support/Corral/
├── config/           model parameter files (.llm)
├── settings/         app settings (bin path, port, pinned endpoints, language, global param template)
└── logs/             router log
```

## Repository layout

```
main.swift          AppKit core (settings / process management / router API)
dashboard.swift     dashboard (SwiftUI)
l10n.swift          zh/en strings (Chinese keys + English dictionary)
icon.swift          status bar icon
build.sh            build script (one-line swiftc)
icons/              pre-rendered AppIcon.icns + status bar PNGs
LICENSE             Apache License 2.0
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).

