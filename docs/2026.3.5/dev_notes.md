# Lumi-Hub 开发笔记：Chat UI 交互进阶 (长按菜单与多选模式)

> 记录时间：2026-03-05  
> 内容：为 Flutter 客户端的聊天界面添加基础的消息交互能力，包括长按弹出操作菜单（复制纯文本、本地删除），以及支持批量操作的“多选模式”。同时解决并重构了遗留的弃用 API（如 `withOpacity`）以适应更高的 Lint 检查标准。

---

## 一、今天做了什么

| 任务 | 结果 |
|------|------|
| `ChatMessage` 模型扩展（增加 `isSelected` 属性） | ✅ |
| `WsService` 支持根据 ID 集合本地移除消息 | ✅ |
| 单条消息长按，自底部弹出 `BottomSheet` 菜单 | ✅ |
| 面板操作：复制消息内容至系统剪贴板 | ✅ |
| 面板操作：二次确认后本地删除单条消息 | ✅ |
| 面板操作：唤起多选模式 | ✅ |
| 多选模式界面态：点击改变气泡选择状态（屏蔽长按），对方气泡左侧/我方右侧显示 Checkbox | ✅ |
| 多选状态栏 (`_TopBar` 切换)：显示“已选择 N 项”，提供一键取消及批量删除入口 | ✅ |
| 修复全体过时的 `.withOpacity(x)` 警告为 `.withValues(alpha: x)` | ✅ 消除所有 Flutter Lints 警告 |
| Host 侧 WebSocket Echo 测试，验证 AstrBot LLM 链路畅通 | ✅ `test_echo.py` 跑通全量测试 |

---

## 二、消息模型与服务层扩展

### 1. `ChatMessage` 模型更新
为了支持多选状态，我们在原有的属性上补强了 `isSelected`。
```dart
class ChatMessage {
  // ... 其他属性
  final bool isSelected; // 是否被选中 (用于多选)

  ChatMessage({
    // ...
    this.isSelected = false,
  });

  ChatMessage copyWith({
    // ...
    bool? isSelected,
  }) {
    return ChatMessage(
      // ...
      isSelected: isSelected ?? this.isSelected,
    );
  }
}
```

### 2. `WsService` 本地消息管理
之前的逻辑仅支持新增消息，现在加了一个专门用于移除本地消息集合的方法：
```dart
void removeMessages(Set<String> messageIds) {
  if (messageIds.isEmpty) return;
  _messages.removeWhere((m) => messageIds.contains(m.id));
  notifyListeners();
}
```

---

## 三、长按菜单 (Context Menu) 交互设计

直接利用 Flutter Material 原生的 `showModalBottomSheet`，从底部弹出一个符合侧栏暗色/亮色主题的菜单。

### 弹窗菜单选项
1. **复制**：直接调取 `Clipboard.setData(ClipboardData(text: msg.content))`。考虑到目前 AstrBot 给过来的大部分是 Markdown 文本，复制底层原文能够满足绝大多数对代码块、命令行的提取需求。并贴心地配有 `SnackBar` 短暂提示。
2. **多选**：唤起顶层页面的 `isSelectionMode = true` 状态，同时自动将当前触发操作的消息设置为被选中状态。
3. **删除**：点击后并非立刻删除，而是呼出一个居中的次级 `AlertDialog` 进行**二次确认**（防止误触手滑），确认无误后才调用 `onDeleteMessage` 毁尸灭迹。

---

## 四、多选批量操作模式

多选模式算是聊天系统的标准复杂交互了。我们通过在顶级父组件 `_ChatScreenState` 维护状态来下发调度。

### 1. 状态提升
在 `_ChatScreenState` 中新增两个核心变量：
```dart
bool _isSelectionMode = false;
final Set<String> _selectedMessageIds = {};
```
这两个状态通过构造函数传给 `_TopBar`（用于渲染 AppBar）和 `_MessageList`（用于渲染气泡与 Checkbox）。

### 2. 气泡交互分流
当 `isSelectionMode == true` 时：
- `_BubbleItem` 屏蔽了 `onLongPress`。
- `onTap` 行为不再是空，而是与 `_toggleMessageSelection` 绑定，点击气泡任意位置即可切换勾选状态。
- 为气泡动态注入 `Checkbox` UI 组件。如果是我的消息（靠右），Checkbox 在气泡左下角；是对方的消息（靠左），Checkbox 在气泡右下角。这样布局既自然，也不破坏整体的圆角流线。

### 3. 多选状态栏 (`_TopBar` 变身)
当普通聊天态时，顶栏显示“对方头像、名字、在线小绿点”。
一旦切入 `isSelectionMode`，整个顶栏立刻变身：
- 左侧变成 `X` (取消按钮)，点击后清空 `_selectedMessageIds` 并退出多选。
- 中间变成粗体的 **“已选择 N 项”**。
- 右侧出现一个红色的 `IconButton(Icons.delete_outline)`，点击后同样有二次确认弹窗告诉你要删掉 N 条消息，确认后执行批量销毁。

---

## 五、技术债清理与踩坑记录

### `withOpacity` 弃用问题 (Lint 警告)
随着 Flutter 版本迭代，`Color.withOpacity(double)` 在较新的 SDK 被标记为 `@Deprecated`，原因是该方法会在颜色转换中导致潜在的精度丢失等问题。

**解决方式：**
全局扫描，将主题 `app_theme.dart` 与业务 `chat_screen.dart` 中所有的 `.withOpacity(x)` 替换为更加安全和结构化的 `.withValues(alpha: x)`。

```dart
// Before
color: colors.accent.withOpacity(0.15)
// After
color: colors.accent.withValues(alpha: 0.15)
```
清理后，`flutter analyze` 以 `No issues found!` 完美收官。

### JSON/WebSocket 通讯疑云
你在开发交互中间一度怀疑是 AstrBot 没收发对消息。我们特意运行了一遍此前遗留的 `test_echo.py` 测试脚本，结果：
- CONNECT 握手正常
- LLM 回复极其健康
- PERSONA_LIST 读取到了多个人格列表
排查得出是偶尔 WebSocket 长连接心跳不及时或是 UI 没有在首帧回滚到底部造成的错觉，底层链路完美畅通。

---

## 六、下一步规划 (Phase 4 / 5 前瞻)

Flutter 客户端基础的 UI/UX 其实已经比较成型（主题、全双工通讯、多行输入、操作菜单、批量管理），接下来我们可以正式向“智能体操作 (Agent Action)”的核心战场进发了！

1. **审批体系 UI (HitL)**：这也是 README 中提到的 “Human-in-the-loop”。当 Host 下发需要文件读取/修改、Git Commit 等行为时，推一个特殊的带有 “同意/拒绝” 和命令 Diff 预览的 Message 卡片过来供用户审批。
2. **OpenClaw (Agent) 执行引擎接入**：构建 Python 端的工具执行器逻辑，连接上 MCP，实现 `Action -> 询问权限 -> 执行 -> 反馈` 的核心操作环。
