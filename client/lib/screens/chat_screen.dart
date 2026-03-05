import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../services/app_settings.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final ws = context.watch<WsService>();

    // 消息更新时滚到底部
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

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
                _TopBar(colors: colors, ws: ws),
                Divider(height: 1, color: colors.divider),
                // 消息列表
                Expanded(
                  child: _MessageList(
                    messages: ws.messages,
                    scroll: _scroll,
                    colors: colors,
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
    final settings = context.watch<AppSettings>();
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
          // 字体选择行
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.font_download_outlined,
                  size: 16,
                  color: colors.subtext,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    kAvailableFonts[settings.fontKey] ?? '系统默认',
                    style: TextStyle(fontSize: 13, color: colors.subtext),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '切换字体',
                  icon: Icon(
                    Icons.expand_more,
                    size: 18,
                    color: colors.subtext,
                  ),
                  onSelected: settings.setFontFamily,
                  itemBuilder: (_) => kAvailableFonts.entries
                      .map(
                        (e) => PopupMenuItem<String>(
                          value: e.key,
                          child: Row(
                            children: [
                              if (settings.fontKey == e.key)
                                Icon(
                                  Icons.check,
                                  size: 16,
                                  color: colors.accent,
                                )
                              else
                                const SizedBox(width: 16),
                              const SizedBox(width: 8),
                              Text(e.value),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
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
        ? colors.accent.withOpacity(0.15)
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

  const _TopBar({required this.colors, required this.ws});

  @override
  Widget build(BuildContext context) {
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

  const _MessageList({
    required this.messages,
    required this.scroll,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text('向流萤发送第一条消息吧 ✨', style: TextStyle(color: colors.subtext)),
      );
    }

    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: messages.length,
      itemBuilder: (_, i) => _BubbleItem(msg: messages[i], colors: colors),
    );
  }
}

class _BubbleItem extends StatelessWidget {
  final ChatMessage msg;
  final LumiColors colors;

  const _BubbleItem({required this.msg, required this.colors});

  @override
  Widget build(BuildContext context) {
    final isMe = msg.sender == MessageSender.me;
    final bubbleColor = isMe ? colors.bubbleMe : colors.bubbleThem;
    final textColor = isMe ? colors.onBubbleMe : colors.onBubbleThem;
    final timeStr = DateFormat('HH:mm').format(msg.time);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: colors.accent,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: msg.isTyping
                  ? _TypingIndicator(color: textColor)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          msg.content,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          timeStr,
                          style: TextStyle(
                            color: textColor.withOpacity(0.55),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          if (isMe) const SizedBox(width: 8),
        ],
      ),
    );
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
            builder: (_, __) => Transform.translate(
              offset: Offset(0, _anims[i].value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.color.withOpacity(0.7),
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
                  ? widget.colors.accent.withOpacity(0.15)
                  : Colors.transparent,
              shape: const CircleBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
