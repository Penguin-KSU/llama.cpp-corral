# icons/

Pre-rendered icon assets, packaged into the app by `build.sh`.

`build.sh` 打包进 app 的预渲染图标资源。

| File | Purpose |
|---|---|
| `AppIcon.icns` | Dock / Finder app icon (generated from `AppIcon-1024.png` via sips + iconutil) |
| `AppIcon-1024.png` | 1024px master, kept for regenerating the icns |
| `status_idle.png` | Menu bar icon, idle state — 44×44 px (22pt @2x), black on transparent |
| `status_loaded.png` | Menu bar icon, model loaded — filled variant of the above |

The menu bar icons are macOS *template images*: the system automatically
renders them white on a dark menu bar and black on a light one.

状态栏图标是 macOS template image:深色菜单栏自动显示为白色,浅色菜单栏显示为黑色。
