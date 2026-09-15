# Thread Pocket · macOS 客户端

SwiftUI 实现的桌面端，只依赖一个可配置的后端地址，不内嵌业务数据。

## 构建与运行

```bash
./Scripts/build-app.sh            # debug
./Scripts/build-app.sh release    # 产出 dist/ThreadPocket.app（会做临时签名）
open dist/ThreadPocket.app
```

也可以直接用 SwiftPM 调试：

```bash
swift build && swift run ThreadPocket
```

要求 macOS 14+，Xcode 16 以上的工具链。

## 目录

```
Sources/ThreadPocket/
├── App/
│   ├── ThreadPocketApp.swift    入口、窗口样式、菜单栏命令
│   ├── AppSettings.swift        服务器地址 / 令牌 / 自动刷新（UserDefaults）
│   └── WorkspaceStore.swift     状态中枢：快照、草稿、变更、视图、搜索
├── Model/Models.swift           与后端一一对应的数据结构与日期工具
├── Net/APIClient.swift          REST 客户端（snake_case 自动转换、错误归类）
├── Design/
│   ├── PocketTheme.swift        颜色、圆角、玻璃质感
│   ├── OverlayCenter.swift      提示、浮层、确认框、面板
│   └── Components/              自绘控件：完成框、分段、日期、右键菜单
└── Features/                    RootView / SidebarPane / ThreadDetailView /
                                 OverviewView / ItemViews / ItemEditorPanel /
                                 SettingsPanel / Overlays
```

## 自绘控件的实现要点

**右键菜单**（`Design/Components/ContextMenu.swift`）

- `RightClickCatcher` 是一个 `NSViewRepresentable`：它的 `hitTest` 只在右键
  （或 `⌘ + 左键`）时返回自身，左键一律返回 `nil`，所以它不会挡住下方的 SwiftUI 内容。
- 命中后把 `locationInWindow` 换算成窗口左上角坐标，交给 `OverlayCenter` 渲染
  `ContextMenuLayer`；菜单在一个覆盖全窗口的浮层里绘制，因此不会被滚动区域裁切，
  并会自动向内收拢、空间不足时向上翻转。
- 文本编辑区使用同一套机制，菜单内容是剪切 / 复制 / 粘贴 / 全选 / 插入时间戳，
  通过 `NSApp.sendAction(_:to:from:)` 作用于当前第一响应者，因此系统不会弹出原生菜单。

**完成框**（`PocketCheck`）

- 用一个圆环 + 可描边的对勾 `Shape` 组成，`isOn` 变化时走 spring 动画，
  hover 时轻微放大，因此完全没有使用系统的 checkbox / toggle。

**其他自绘件**：`PocketSegmented`（`matchedGeometryEffect` 滑动高亮）、
`PocketMenuButton`（左键弹出菜单，通过 `PreferenceKey` 记录锚点）、
`CalendarPanel` / `TimePanel`（替代系统日期选择器）、`ConfirmLayer`（替代系统 alert）、
`ToastStack`（操作反馈与失败重试）。

## 数据一致性

- 启动 / `⌘R`：`GET /api/v1/snapshot` 全量同步。
- 每次写操作：服务端在事务里更新数据并追加日志，返回受影响的 Thread 上下文，
  客户端整体替换该 Thread 的本地状态。
- 未保存的当前描述或笔记会被记录为草稿；切换线索时先确认，避免丢失。
- 连接失败时保留本地视图并给出重试入口；写操作失败会提示并可直接重连。
