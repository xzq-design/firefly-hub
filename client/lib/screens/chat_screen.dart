import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/message.dart';
import '../services/app_settings.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import 'components/approval_dialog.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focusNode = FocusNode();

  bool _isSelectionMode = false;
  final Set<String> _selectedMessageIds = {};
  StreamSubscription? _authSubscription;

  @override
  void initState() {
    super.initState();
    // 监听审批请求
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ws = context.read<WsService>();
      _authSubscription = ws.authRequests.listen(_handleAuthRequest);
    });
  }

  void _handleAuthRequest(Map<String, dynamic> request) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ApprovalDialog(
        authRequest: request,
        onDecision: (decision) {
          final ws = context.read<WsService>();
          ws.sendAuthResponse(request['message_id'], decision);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send(WsService ws) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    ws.sendMessage(text);
    _input.clear();
    _focusNode.requestFocus();
    // 滚到底部
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedMessageIds.clear();
      }
    });
  }

  void _toggleMessageSelection(String messageId) {
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
        if (_selectedMessageIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  void _deleteSelectedMessages(WsService ws) {
    if (_selectedMessageIds.isEmpty) return;
    ws.removeMessages(_selectedMessageIds);
    setState(() {
      _isSelectionMode = false;
      _selectedMessageIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final ws = context.watch<WsService>();

    // 消息更新时滚到底部
    if (!_isSelectionMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    return Scaffold(
      body: Row(
        children: [
          // ── 左侧栏 ───────────────────────────────
          _Sidebar(colors: colors, ws: ws),
          // ── 分割线 ───────────────────────────────
          VerticalDivider(width: 1, color: colors.divider),
          // ── 聊天主区域 ───────────────────────────
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  colors: colors,
                  ws: ws,
                  isSelectionMode: _isSelectionMode,
                  selectedCount: _selectedMessageIds.length,
                  onCancelSelection: _toggleSelectionMode,
                  onDeleteSelected: () => _deleteSelectedMessages(ws),
                ),
                Divider(height: 1, color: colors.divider),
                // 消息列表
                Expanded(
                  child: _MessageList(
                    messages: ws.messages,
                    scroll: _scroll,
                    colors: colors,
                    isSelectionMode: _isSelectionMode,
                    selectedMessageIds: _selectedMessageIds,
                    onToggleSelection: _toggleMessageSelection,
                    onEnterSelectionMode: () {
                      if (!_isSelectionMode) _toggleSelectionMode();
                    },
                    onDeleteMessage: (msgId) {
                      ws.removeMessages({msgId});
                    },
                  ),
                ),
                Divider(height: 1, color: colors.divider),
                // 输入区
                _InputBar(
                  controller: _input,
                  focusNode: _focusNode,
                  colors: colors,
                  onSend: () => _send(ws),
                  enabled: ws.status == WsStatus.connected,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 左侧栏 ─────────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final LumiColors colors;
  final WsService ws;

  const _Sidebar({required this.colors, required this.ws});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      color: colors.sidebar,
      child: Column(
        children: [
          // 顶部标题栏
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: Text(
              'Lumi Hub',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          Divider(height: 1, color: colors.divider),
          // 联系人列表
          _ContactTile(
            name: '流萤',
            subtitle: '点击开始聊天',
            isSelected: true,
            colors: colors,
            status: ws.status,
          ),
          const Spacer(),
          Divider(height: 1, color: colors.divider),
          const Spacer(),
          Divider(height: 1, color: colors.divider),
          // 设置入口
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              hoverColor: colors.accent.withValues(alpha: 0.1),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                Icons.settings_outlined,
                color: colors.subtext,
                size: 20,
              ),
              title: Text(
                '设置',
                style: TextStyle(color: colors.subtext, fontSize: 13),
              ),
              onTap: () {
                showDialog(
                  context: context,
                  builder: (_) => _SettingsDialog(ws: ws, colors: colors),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsDialog extends StatelessWidget {
  final WsService ws;
  final LumiColors colors;

  const _SettingsDialog({required this.ws, required this.colors});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final user = ws.user;

    return AlertDialog(
      backgroundColor: colors.sidebar,
      title: Text(
        '偏好设置',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 账号信息卡片
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.inputBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: colors.accent,
                    child: const Icon(Icons.person, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?['username'] ?? '未知用户',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'ID: ${user?['id'] ?? '-'}',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 字体设置
            Text(
              '界面',
              style: TextStyle(
                color: colors.subtext,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.font_download_outlined,
                  color: colors.subtext,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '字体',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: settings.fontKey,
                  dropdownColor: colors.inputBg,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  underline: const SizedBox(),
                  items: kAvailableFonts.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) settings.setFontFamily(val);
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 注销按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('注销登录'),
                onPressed: () async {
                  await ws.logout();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('关闭', style: TextStyle(color: colors.subtext)),
        ),
      ],
    );
  }
}

class _ContactTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final bool isSelected;
  final LumiColors colors;
  final WsStatus status;

  const _ContactTile({
    required this.name,
    required this.subtitle,
    required this.isSelected,
    required this.colors,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isSelected
        ? colors.accent.withValues(alpha: 0.15)
        : Colors.transparent;

    return Container(
      color: bg,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: colors.accent,
              child: const Text(
                '流',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            // 连接状态小圆点
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _statusColor(status),
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.sidebar, width: 2),
                ),
              ),
            ),
          ],
        ),
        title: Text(
          name,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colors.subtext),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Color _statusColor(WsStatus s) => switch (s) {
    WsStatus.connected => const Color(0xFF4CAF50),
    WsStatus.connecting => const Color(0xFFFFC107),
    WsStatus.disconnected => const Color(0xFF9E9E9E),
  };
}

// ─── 顶部栏 ─────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final LumiColors colors;
  final WsService ws;
  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback onCancelSelection;
  final VoidCallback onDeleteSelected;

  const _TopBar({
    required this.colors,
    required this.ws,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    required this.onCancelSelection,
    required this.onDeleteSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (isSelectionMode) {
      return Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: colors.sidebar,
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.close, color: colors.subtext),
              onPressed: onCancelSelection,
              tooltip: '取消多选',
            ),
            const SizedBox(width: 8),
            Text(
              '已选择 $selectedCount 项',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const Spacer(),
            if (selectedCount > 0)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除消息'),
                      content: Text('确定要删除选中的 $selectedCount 条消息吗？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            onDeleteSelected();
                          },
                          child: const Text(
                            '删除',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                tooltip: '删除选中项',
              ),
          ],
        ),
      );
    }

    final statusText = switch (ws.status) {
      WsStatus.connected => '在线',
      WsStatus.connecting => '连接中...',
      WsStatus.disconnected => '未连接',
    };
    final statusColor = switch (ws.status) {
      WsStatus.connected => const Color(0xFF4CAF50),
      WsStatus.connecting => const Color(0xFFFFC107),
      WsStatus.disconnected => const Color(0xFF9E9E9E),
    };

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: colors.accent,
            child: const Text('流', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '流萤',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Text(
                    statusText,
                    style: TextStyle(fontSize: 12, color: colors.subtext),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── 消息列表 ────────────────────────────────────────────────────────────────

class _MessageList extends StatelessWidget {
  final List<ChatMessage> messages;
  final ScrollController scroll;
  final LumiColors colors;
  final bool isSelectionMode;
  final Set<String> selectedMessageIds;
  final Function(String) onToggleSelection;
  final VoidCallback onEnterSelectionMode;
  final Function(String) onDeleteMessage;

  const _MessageList({
    required this.messages,
    required this.scroll,
    required this.colors,
    required this.isSelectionMode,
    required this.selectedMessageIds,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
    required this.onDeleteMessage,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text('向流萤发送第一条消息吧 ✨', style: TextStyle(color: colors.subtext)),
      );
    }

    return SelectionArea(
      child: ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: messages.length,
        itemBuilder: (_, i) {
          final msg = messages[i];
          return _BubbleItem(
            msg: msg,
            colors: colors,
            isSelected: selectedMessageIds.contains(msg.id),
            isSelectionMode: isSelectionMode,
            onToggleSelection: () => onToggleSelection(msg.id),
            onEnterSelectionMode: onEnterSelectionMode,
            onDeleteMessage: () => onDeleteMessage(msg.id),
          );
        },
      ),
    );
  }
}

class _BubbleItem extends StatefulWidget {
  final ChatMessage msg;
  final LumiColors colors;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelectionMode;
  final VoidCallback onDeleteMessage;

  const _BubbleItem({
    required this.msg,
    required this.colors,
    this.isSelected = false,
    this.isSelectionMode = false,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
    required this.onDeleteMessage,
  });

  @override
  State<_BubbleItem> createState() => _BubbleItemState();
}

class _BubbleItemState extends State<_BubbleItem> {
  bool _isHovered = false;

  void _showContextMenu(BuildContext context) {
    if (widget.msg.isTyping) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: widget.colors.sidebar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  Icons.copy,
                  color: Theme.of(context).iconTheme.color,
                ),
                title: const Text('复制'),
                onTap: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.msg.content),
                  );
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制到剪贴板'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.checklist,
                  color: Theme.of(context).iconTheme.color,
                ),
                title: const Text('多选'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onEnterSelectionMode();
                  widget.onToggleSelection(); // Also select the current item
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  '删除',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(context);
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除消息'),
                      content: const Text('确定要在本地删除这条消息吗？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            widget.onDeleteMessage();
                          },
                          child: const Text(
                            '删除',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.msg.sender == MessageSender.me;
    final bubbleColor = isMe
        ? widget.colors.bubbleMe
        : widget.colors.bubbleThem;
    final textColor = isMe
        ? widget.colors.onBubbleMe
        : widget.colors.onBubbleThem;
    final now = DateTime.now();
    final timeStr = widget.msg.time.year == now.year
        ? DateFormat('MM-dd HH:mm:ss').format(widget.msg.time)
        : DateFormat('yyyy-MM-dd HH:mm:ss').format(widget.msg.time);

    Widget bubbleWidget = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            AnimatedOpacity(
              opacity: _isHovered ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Padding(
                padding: EdgeInsets.only(
                  left: isMe ? 0 : 54.0,
                  right: isMe ? 12.0 : 0,
                  bottom: 4,
                ),
                child: Text(
                  timeStr,
                  style: TextStyle(
                    color: widget.colors.subtext.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            GestureDetector(
              onLongPress: widget.isSelectionMode
                  ? null
                  : () => _showContextMenu(context),
              onTap: widget.isSelectionMode ? widget.onToggleSelection : null,
              child: Container(
                color: widget.isSelected
                    ? widget.colors.accent.withValues(alpha: 0.15)
                    : Colors.transparent,
                child: Row(
                  mainAxisAlignment: isMe
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (widget.isSelectionMode && !isMe)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 8),
                        child: AbsorbPointer(
                          child: Checkbox(
                            value: widget.isSelected,
                            onChanged: (_) {},
                            activeColor: widget.colors.accent,
                          ),
                        ),
                      ),
                    if (!isMe) ...[
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: widget.colors.accent,
                        child: const Text(
                          '流',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.55,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMe ? 16 : 4),
                            bottomRight: Radius.circular(isMe ? 4 : 16),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: widget.msg.isTyping
                            ? _TypingIndicator(color: textColor)
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  MarkdownBody(
                                    data: widget.msg.content,
                                    selectable:
                                        false, // Let parent SelectionArea handle selection
                                    styleSheet: MarkdownStyleSheet(
                                      p: TextStyle(
                                        color: textColor,
                                        fontSize: 14,
                                        height: 1.4,
                                      ),
                                      listBullet: TextStyle(
                                        color: textColor,
                                        fontSize: 14,
                                      ),
                                      code: TextStyle(
                                        backgroundColor: Colors.black26,
                                        color: textColor,
                                        fontFamily: 'monospace',
                                        fontSize: 13,
                                      ),
                                      codeblockDecoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        color: const Color(0xFF282C34),
                                      ),
                                      blockquoteDecoration: BoxDecoration(
                                        color: widget.colors.sidebar.withValues(
                                          alpha: 0.5,
                                        ),
                                        border: Border(
                                          left: BorderSide(
                                            color: widget.colors.accent,
                                            width: 4,
                                          ),
                                        ),
                                      ),
                                    ),
                                    builders: {'code': CodeElementBuilder()},
                                  ),
                                ],
                              ),
                      ),
                    ),
                    if (isMe) const SizedBox(width: 8),
                    if (widget.isSelectionMode && isMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, bottom: 8),
                        child: AbsorbPointer(
                          child: Checkbox(
                            value: widget.isSelected,
                            onChanged: (_) {},
                            activeColor: widget.colors.accent,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return bubbleWidget;
  }
}

/// 三点跳动的"正在输入"动画
class _TypingIndicator extends StatefulWidget {
  final Color color;
  const _TypingIndicator({required this.color});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      3,
      (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..repeat(reverse: true),
    );
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 150), () {
        if (mounted) _controllers[i].repeat(reverse: true);
      });
    }
    _anims = _controllers
        .map(
          (c) => Tween<double>(
            begin: 0,
            end: -6,
          ).animate(CurvedAnimation(parent: c, curve: Curves.easeInOut)),
        )
        .toList();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _anims[i],
            builder: (context, child) => Transform.translate(
              offset: Offset(0, _anims[i].value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.7),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── 输入栏 ────────────────────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final LumiColors colors;
  final VoidCallback onSend;
  final bool enabled;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.colors,
    required this.onSend,
    required this.enabled,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  /// Enter 发送，Shift+Enter 换行
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final isShift = HardwareKeyboard.instance.isShiftPressed;
    if (isShift) {
      // Shift+Enter → 插入换行符
      final sel = widget.controller.selection;
      final text = widget.controller.text;
      final newText = text.replaceRange(sel.start, sel.end, '\n');
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + 1),
      );
      return KeyEventResult.handled;
    } else {
      // Enter → 发送
      if (widget.enabled) widget.onSend();
      return KeyEventResult.handled;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: widget.colors.inputBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: widget.colors.divider),
              ),
              child: Focus(
                focusNode: widget.focusNode,
                onKeyEvent: _handleKey,
                child: TextField(
                  controller: widget.controller,
                  enabled: widget.enabled,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: widget.enabled
                        ? '发送消息... (Enter 发送，Shift+Enter 换行)'
                        : '等待连接中...',
                    hintStyle: TextStyle(
                      color: widget.colors.subtext,
                      fontSize: 13,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: widget.enabled ? widget.onSend : null,
            icon: Icon(
              Icons.send_rounded,
              color: widget.enabled
                  ? widget.colors.accent
                  : widget.colors.subtext,
            ),
            style: IconButton.styleFrom(
              backgroundColor: widget.enabled
                  ? widget.colors.accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              shape: const CircleBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    if (!element.textContent.endsWith('\n')) {
      return null;
    }

    // 如果存在 language-xxx 类，仍可以用来扩展不同块的风格
    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      if (lg.startsWith('language-')) {
        // language = lg.substring(9);
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: double.infinity,
        child: Container(
          color: const Color(0xFF282C34),
          padding: const EdgeInsets.all(12),
          child: Text(
            element.textContent.substring(0, element.textContent.length - 1),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.5,
              color: Color(0xFFABB2BF), // 简单的原子灰回退以防止 Highlighter 兼容性报错
            ),
          ),
        ),
      ),
    );
  }
}
