# Firefly-Hub 开发笔记：Phase 3 启动 - Flutter Windows 客户端

> 记录时间：2026-03-04  
> 内容：从零搭建 Flutter Windows 聊天客户端，实现 WebSocket 通信、Telegram 风格 UI、深浅主题跟随系统、可扩展字体切换、Enter 发送 / Shift+Enter 换行

---

## 一、今天做了什么

| 任务 | 结果 |
|------|------|
| 初始化 Flutter Windows 项目 | ✅ |
| Telegram 风格暗色/亮色双主题 | ✅ 跟随系统自动切换 |
| WebSocket 服务层（连接/心跳/重连） | ✅ |
| 聊天界面（左侧栏 + 气泡 + 输入框） | ✅ |
| 三点跳动"正在输入"动画 | ✅ |
| MiSans 可变字体接入 | ✅ |
| 字体 PopupMenu 选择器（可扩展） | ✅ |
| Enter 发送 / Shift+Enter 换行 | ✅ |

---

## 二、Flutter 项目初始化

### 创建 Windows 桌面项目

```bash
flutter create client --platforms=windows --org=dev.firefly --project-name=firefly_client
cd client
flutter pub get
```

关键参数：
- `--platforms=windows`：只生成 Windows 平台相关文件，不生成 Android/iOS（减少干扰）
- `--org=dev.firefly`：包名前缀（反向域名）
- `--project-name=firefly_client`：Dart 包名

### 依赖清单（pubspec.yaml）

```yaml
dependencies:
  flutter:
    sdk: flutter
  web_socket_channel: ^3.0.1  # WebSocket 通信
  provider: ^6.1.2             # 状态管理
  intl: ^0.19.0                # 时间格式化（HH:mm）
```

为什么选这几个：
- **web_socket_channel**：Flutter 官方出品，底层自动适配不同平台（dart:io on desktop, dart:html on web）
- **provider**：Google 推荐的轻量状态管理，比 GetX/Bloc 简单，比 setState 强大
- **intl**：消息气泡里显示时间（"18:05"这种格式）

---

## 三、主题系统：深浅自动跟随系统

### 核心机制

Flutter 的 `MaterialApp` 有三个主题参数：

```dart
MaterialApp(
  themeMode: ThemeMode.system,  // 跟随系统！
  theme: AppTheme.light(),      // 亮色主题
  darkTheme: AppTheme.dark(),   // 暗色主题
  ...
)
```

当 Windows 系统设置里切换深色/浅色模式，Flutter 会自动切换 `theme` 和 `darkTheme`，App 不需要做任何额外处理。

### Telegram 配色方案

```
暗色模式（Telegram 深色）:
  背景:      #17212B  （深蓝灰）
  侧栏:      #0E1621  （更深）
  他方气泡:  #182533
  我方气泡:  #2B5278  （蓝）
  强调色:    #5BACF0  （亮蓝）
  次要文字:  #6C8EAD

亮色模式（Telegram 浅色）:
  背景:      #F0F2F5
  侧栏:      #FFFFFF
  他方气泡:  #FFFFFF
  我方气泡:  #EFFFBF  （淡绿，Telegram 经典）
  强调色:    #2481CC
  次要文字:  #707579
```

### ThemeExtension：自定义颜色令牌

Flutter 的 `ThemeData` 只提供 `primary`、`surface` 等 Material 标准颜色，我们需要 `sidebar`、`bubbleMe`、`inputBg` 这些自定义颜色，所以用了 `ThemeExtension`：

```dart
class FireflyColors extends ThemeExtension<FireflyColors> {
  final Color sidebar;
  final Color bubbleThem;
  final Color bubbleMe;
  // ...
}

// 在 widget 中访问：
final colors = Theme.of(context).extension<FireflyColors>()!;
```

这样所有颜色都走主题系统，深浅切换时自动更新，不需要手动判断 `isDarkMode`。

---

## 四、WebSocket 服务层（ws_service.dart）

### 连接生命周期

```
connect() → WebSocketChannel.connect() → await .ready
  → 订阅 stream.listen()
  → 发送 CONNECT 握手
  → 启动 PING 定时器（每 20 秒）
  
断线（onDone / onError）
  → 清除 typing 占位
  → 设置状态为 disconnected
  → 3 秒后自动 reconnect()
```

### 状态枚举

```dart
enum WsStatus { disconnected, connecting, connected }
```

UI 里通过 `context.watch<WsService>()` 监听状态变化，自动刷新顶栏状态小圆点：
- 🟢 绿 = connected
- 🟡 黄 = connecting
- ⚫ 灰 = disconnected

### "正在输入"占位符模式

发消息时的用户体验设计：

```dart
void sendMessage(String text) {
  // 1. 立即显示用户自己发的消息（乐观更新）
  _messages.add(ChatMessage(sender: me, content: text));
  
  // 2. 立即显示 AI 正在输入的占位
  _messages.add(ChatMessage(sender: ai, isTyping: true));
  notifyListeners();  // UI 立刻更新，用户感觉快
  
  // 3. 发给服务器
  _send({'type': 'CHAT_REQUEST', 'payload': {'content': text}});
}

void _handleChatResponse(...) {
  // 4. 收到真实回复后，移除占位，插入真实内容
  _messages.removeWhere((m) => m.isTyping);
  _messages.add(ChatMessage(sender: ai, content: realContent));
}
```

这种"乐观更新"模式让界面看起来比实际更快。

---

## 五、聊天界面结构

### 布局方案（Telegram 双栏布局）

```
Scaffold
└── Row
    ├── _Sidebar (width: 260) ─── 左侧栏
    │   ├── 顶部标题 "Firefly Hub"
    │   ├── _ContactTile (流萤，带状态圆点)
    │   ├── Spacer (把字体选择推到底部)
    │   └── 字体 PopupMenu 行
    │
    ├── VerticalDivider (分割线)
    │
    └── Expanded ─── 聊天主区域
        ├── _TopBar (头像 + 名字 + 状态)
        ├── _MessageList (ListView.builder)
        │   └── _BubbleItem × N (气泡)
        └── _InputBar (输入框 + 发送按钮)
```

### 消息气泡细节

```dart
// 圆角规则：模拟真实聊天 App 的气泡形状
BorderRadius.only(
  topLeft: Radius.circular(16),
  topRight: Radius.circular(16),
  bottomLeft: Radius.circular(isMe ? 16 : 4),  // 对方：左下尖角
  bottomRight: Radius.circular(isMe ? 4 : 16), // 我方：右下尖角
)
```

气泡最大宽度限制在屏幕的 55%，防止长消息撑满整个屏幕。

### 三点跳动动画（_TypingIndicator）

```dart
class _TypingIndicatorState extends State<...> with TickerProviderStateMixin {
  // 3 个 AnimationController，各自做上下跳动
  // 通过 Future.delayed(i * 150ms) 错开相位，形成波浪效果
  
  final controllers = List.generate(3, (i) =>
    AnimationController(duration: 600ms)..repeat(reverse: true)
  );
}
```

关键点：`TickerProviderStateMixin` 让每个 controller 有自己的 vsync 源；`repeat(reverse: true)` 让动画自动来回播放。

---

## 六、字体系统

### 可变字体 vs 普通字体

| 类型 | 数量 | 大小 | 字重支持 |
|------|------|------|----------|
| 普通字体 (11个) | 11 个 .ttf | ~33MB | 只有预设字重 |
| 可变字体 (VF) | 1 个 .ttf | ~5MB | 100~900 任意值 |

**结论：一个 MiSansVF.ttf 搞定所有字重，体积还更小。**

### 注册到 Flutter

```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/fonts/  # 注意：路径必须和实际目录对应，多一个字母都不行

  fonts:
    - family: MiSans
      fonts:
        - asset: assets/fonts/MiSansVF.ttf
```

注意：`assets` 目录名必须和 `asset:` 路径完全一致（我们踩过认错路径的坑：`assests` vs `assets`）。

### 动态字体切换架构

```
AppSettings (ChangeNotifier)
  fontKey: '' | 'MiSans' | 未来更多...
  fontFamily: null | 'MiSans' | ...

MaterialApp
  theme: AppTheme.light(fontFamily: settings.fontFamily)
  darkTheme: AppTheme.dark(fontFamily: settings.fontFamily)

ThemeData(fontFamily: ...) 
  → 传入 null 时用系统默认
  → 传入 'MiSans' 时用注册的字体
```

任何地方调用 `settings.setFontFamily(key)` → `notifyListeners()` → `MaterialApp` 重建 → 全局字体立即切换。

### 可扩展字体列表

```dart
// app_settings.dart
const Map<String, String> kAvailableFonts = {
  '': '系统默认',
  'MiSans': 'MiSans',
  // 以后加新字体：只需在这里加一行 + 注册 pubspec.yaml
};
```

UI 里的 PopupMenuButton 自动遍历这个 Map，不需要改任何 widget 代码。

---

## 七、键盘快捷键：Enter 发送 / Shift+Enter 换行

### 为什么要手动处理

Flutter 的 `TextField` 的 `onSubmitted` 只在**单行模式**下有效；我们的输入框是 `maxLines: null`（多行），所以 `onSubmitted` 不触发，需要自己拦截键盘事件。

### 实现方式

```dart
// 把 TextField 包在 Focus 里，Focus 拦截键盘事件
Focus(
  focusNode: widget.focusNode,
  onKeyEvent: _handleKey,
  child: TextField(...),
)

KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
  // 只处理按下和长按（忽略松开事件，避免重复触发）
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  
  final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!isEnter) return KeyEventResult.ignored;

  if (HardwareKeyboard.instance.isShiftPressed) {
    // Shift+Enter → 手动插入 \n 到光标位置
    final sel = controller.selection;
    final newText = controller.text.replaceRange(sel.start, sel.end, '\n');
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
    return KeyEventResult.handled;
  } else {
    // 纯 Enter → 发送
    if (enabled) onSend();
    return KeyEventResult.handled;
  }
}
```

关键 API：
- `LogicalKeyboardKey`：逻辑键（不受键盘物理布局影响）
- `HardwareKeyboard.instance.isShiftPressed`：检查 Shift 是否被同时按住
- `KeyEventResult.handled`：告诉 Flutter 这个事件已被处理，不要继续向上传递

---

## 八、踩坑记录

### 坑 1：字体路径拼写错误

**现象**：pubspec.yaml 写的是 `assests/fonts/`（多了个 s），IDE 报 warning。  
**原因**：用户把字体文件放进去叫 `assests`，我写 pubspec 时沿用了这个拼写，之后用户改了目录名但 pubspec 没更新。  
**教训**：字体资源路径是字符串，拼写错误不会编译报错，只会在运行时找不到字体，要仔细检查。

### 坑 2：`fontFamily: 'Segoe UI'` 导致字体渲染异常

**现象**：设置了 `fontFamily: 'Segoe UI'` 后字体显示"小怪"。  
**原因**：Flutter 在 Windows 上的字体系统并不直接使用 `Segoe UI` 这个名字，会 fallback 到别的字体，导致渲染结果和预期不符。  
**解决**：去掉 `fontFamily` 设置，Flutter 会自动使用系统最佳字体（Windows 11 上是 Segoe UI Variable，渲染质量更好）。

### 坑 3：终端命令没响应

**现象**：用 AI 工具运行 `flutter create` 命令，只看到终端打开但没有任何输出。  
**原因**：工具的终端执行机制在某些情况下会挂起。  
**解决**：手动在自己的终端运行命令，更可靠。

### 坑 4：`_InputBar` 的 `onSubmitted` 不触发

**现象**：给 TextField 设置了 `onSubmitted: (_) => send()`，但多行模式下按 Enter 没反应。  
**原因**：`onSubmitted` 只有在 `maxLines: 1` 时才会在 Enter 按下时触发；多行模式下 Enter 是换行，不触发 submit。  
**解决**：用 `Focus` + `onKeyEvent` 手动拦截键盘事件。

---

## 九、当前文件结构

```
firefly-hub/
├── host/                           # AstrBot 平台适配器
│   ├── main.py                     # Star 壳 + Platform 适配器
│   ├── ws_server.py                # WebSocket Server
│   ├── firefly_event.py            # 重写 send() 转发 LLM 回复
│   ├── metadata.yaml               # 插件元数据 v0.2.0
│   └── __init__.py
│
├── client/                         # Flutter Windows 客户端
│   ├── lib/
│   │   ├── main.dart               # 入口，ThemeMode.system
│   │   ├── theme/
│   │   │   └── app_theme.dart      # 双主题 + FireflyColors 扩展
│   │   ├── models/
│   │   │   └── message.dart        # ChatMessage 数据模型
│   │   ├── services/
│   │   │   ├── ws_service.dart     # WebSocket 服务（连接/心跳/重连）
│   │   │   └── app_settings.dart   # 全局设置（字体选择）
│   │   └── screens/
│   │       └── chat_screen.dart    # 聊天主界面
│   ├── assets/
│   │   └── fonts/
│   │       └── MiSansVF.ttf        # MiSans 可变字体
│   └── pubspec.yaml
│
├── docs/
│   ├── 2026.3.3/
│   │   └── dev_notes.md            # Phase 2 笔记（Host 重构）
│   └── 2026.3.4/
│       └── dev_notes.md            # ← 本文件（Flutter 客户端）
│
└── test_echo.py                    # Host 侧测试脚本
```

---

## 十、Phase 进度更新

| Phase | 目标 | 状态 |
|-------|------|------|
| **1** | WebSocket 通信基建 + Echo | ✅ 完成 |
| **2** | Host 对接 AstrBot LLM + 人格列表 | ✅ 完成 |
| **3** | Flutter Client 核心 UI + 通信 | ✅ **今天完成** |
| **4** | OpenClaw + MCP 工具接入 | 🚧 下一步 |
| **5** | Human-in-the-loop 审批 + 安全机制 | 📋 计划 |
| **6** | 体验打磨（人格切换 UI、动画等） | 📋 计划 |

---

## 十一、下一步

- **前端**：人格切换 UI（侧栏下拉选择 + 切换后全局生效）
- **后端**：PERSONA_UPDATE（前端直接修改 prompt 写回 AstrBot）
- **功能**：接入 OpenClaw 执行引擎（MCP 工具 list_dir / view_file）
- **体验**：消息气泡入场动画（从底部滑入 + 淡入）
