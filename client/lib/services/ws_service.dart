import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/message.dart';

enum WsStatus { disconnected, connecting, connected }

class WsService extends ChangeNotifier {
  static const String _defaultUrl = 'ws://127.0.0.1:8765';
  static const Duration _pingInterval = Duration(seconds: 20);
  static const Duration _reconnectDelay = Duration(seconds: 3);

  WsStatus _status = WsStatus.disconnected;
  WsStatus get status => _status;

  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;

  String get serverUrl => _defaultUrl;

  // ── 连接 ──────────────────────────────────────────────────────────────

  Future<void> connect() async {
    if (_status == WsStatus.connected || _status == WsStatus.connecting) return;
    _setStatus(WsStatus.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_defaultUrl));
      await _channel!.ready;
      _sub = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
      );
      _setStatus(WsStatus.connected);
      _sendHandshake();
      _startPing();
    } catch (e) {
      debugPrint('[WS] 连接失败: $e');
      _setStatus(WsStatus.disconnected);
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setStatus(WsStatus.disconnected);
  }

  // ── 发送消息 ───────────────────────────────────────────────────────────

  void sendMessage(String text) {
    if (_status != WsStatus.connected || text.trim().isEmpty) return;

    // 先加入本地
    final msg = ChatMessage(
      id: _genId(),
      content: text,
      sender: MessageSender.me,
      time: DateTime.now(),
    );
    _messages.add(msg);

    // 加 AI 正在输入占位
    final placeholder = ChatMessage(
      id: '${msg.id}_typing',
      content: '',
      sender: MessageSender.ai,
      time: DateTime.now(),
      isTyping: true,
    );
    _messages.add(placeholder);
    notifyListeners();

    // 发送到 Host
    _send({
      'message_id': msg.id,
      'type': 'CHAT_REQUEST',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'content': text, 'context_id': 'default'},
    });
  }

  // ── 内部 ───────────────────────────────────────────────────────────────

  void _onData(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';

      switch (type) {
        case 'CHAT_RESPONSE':
          _handleChatResponse(data);
        case 'PONG':
          // 心跳回应，忽略
          break;
        case 'CONNECT':
          debugPrint('[WS] 握手确认: ${data['payload']}');
        default:
          debugPrint('[WS] 未处理消息类型: $type');
      }
    } catch (e) {
      debugPrint('[WS] 解析消息失败: $e');
    }
  }

  void _handleChatResponse(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final content = payload['content'] as String? ?? '';
    if (content.isEmpty) return;

    // 移除占位，插入真实回复
    _messages.removeWhere((m) => m.isTyping);
    _messages.add(
      ChatMessage(
        id: data['message_id'] as String? ?? _genId(),
        content: content,
        sender: MessageSender.ai,
        time: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  void removeMessages(Set<String> messageIds) {
    if (messageIds.isEmpty) return;
    _messages.removeWhere((m) => messageIds.contains(m.id));
    notifyListeners();
  }

  void _onError(Object error) {
    debugPrint('[WS] 错误: $error');
    _handleDisconnect();
  }

  void _onDone() {
    debugPrint('[WS] 连接关闭');
    _handleDisconnect();
  }

  void _handleDisconnect() {
    // 清除 typing 占位
    _messages.removeWhere((m) => m.isTyping);
    _pingTimer?.cancel();
    _setStatus(WsStatus.disconnected);
    _scheduleReconnect();
  }

  void _sendHandshake() {
    _send({
      'message_id': _genId(),
      'type': 'CONNECT',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'client_version': '0.1.0',
        'platform': 'windows',
        'device_name': 'Lumi Client',
      },
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      _send({
        'message_id': _genId(),
        'type': 'PING',
        'source': 'client',
        'target': 'host',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'payload': {},
      });
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, connect);
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[WS] 发送失败: $e');
    }
  }

  void _setStatus(WsStatus s) {
    _status = s;
    notifyListeners();
  }

  String _genId() =>
      Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    super.dispose();
  }
}
