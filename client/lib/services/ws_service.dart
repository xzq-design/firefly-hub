import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;
  bool isRestoringAuth = false;
  String? _token;
  Map<String, dynamic>? _user;
  Map<String, dynamic>? get user => _user;

  // 审批请求流
  final _authRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get authRequests =>
      _authRequestController.stream;

  String get serverUrl => _defaultUrl;

  WsService() {
    _initAuth().then((_) {
      connect();
    });
  }

  Future<void> _initAuth() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
    if (_token != null) {
      isRestoringAuth = true;
    }
    // 注意：这里不再乐观地直接设置 _isAuthenticated = true
    // 而是等待 connect() 之后通过 AUTH_RESTORE 从服务端拿回结果，才进入 ChatScreen
    notifyListeners();
  }

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
      if (_token != null) {
        restoreAuth();
      }
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
        case 'AUTH_RESPONSE':
          _handleAuthResponse(data);
        case 'AUTH_REQUIRED':
          _handleAuthRequired(data);
        case 'HISTORY_RESPONSE':
          _handleHistoryResponse(data);
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

  Future<void> _handleAuthResponse(Map<String, dynamic> data) async {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final status = payload['status'] as String?;

    isRestoringAuth = false;

    if (status == 'success') {
      _isAuthenticated = true;
      _token = payload['token'] as String?;
      _user = payload['user'] as Map<String, dynamic>?;

      if (_token != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', _token!);
        debugPrint('[WS] Auth 成功，已保存 Token: $_token');

        // 登录成功后拉取历史
        requestHistory();
      }
      notifyListeners();
    } else {
      debugPrint('[WS] Auth 失败: ${payload['message']}');
      await logout();
    }
  }

  void _handleAuthRequired(Map<String, dynamic> data) {
    debugPrint('[WS] 收到审批请求: ${data['message_id']}');
    _authRequestController.add(data);
  }

  void _handleHistoryResponse(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final messagesJson = payload['messages'] as List<dynamic>? ?? [];

    _messages.clear();
    for (var m in messagesJson) {
      final msg = m as Map<String, dynamic>;
      final isMe = msg['role'] == 'user';
      _messages.add(
        ChatMessage(
          id: msg['id']?.toString() ?? msg['client_msg_id'] ?? _genId(),
          content: msg['content'] as String? ?? '',
          sender: isMe ? MessageSender.me : MessageSender.ai,
          time: DateTime.fromMillisecondsSinceEpoch(
            (msg['timestamp'] as num).toInt(),
          ),
        ),
      );
    }
    notifyListeners();
  }

  // ── 认证方法 ─────────────────────────────────────────────────────────

  void login(String username, String password) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'AUTH_LOGIN',
      'source': 'client',
      'target': 'host',
      'payload': {'username': username, 'password': password},
    });
  }

  void register(String username, String password) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'AUTH_REGISTER',
      'source': 'client',
      'target': 'host',
      'payload': {'username': username, 'password': password},
    });
  }

  void restoreAuth() {
    if (_status != WsStatus.connected || _token == null) return;
    _send({
      'message_id': _genId(),
      'type': 'AUTH_RESTORE',
      'source': 'client',
      'target': 'host',
      'payload': {'token': _token},
    });
  }

  void sendAuthResponse(String taskId, String decision) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': taskId, // 必须回传相同的 message_id/task_id
      'type': 'AUTH_RESPONSE',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'task_id': taskId, 'decision': decision, 'reason': ''},
    });
  }

  void requestHistory({int limit = 50, int offset = 0}) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'HISTORY_REQUEST',
      'source': 'client',
      'target': 'host',
      'payload': {'limit': limit, 'offset': offset},
    });
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    _isAuthenticated = false;
    isRestoringAuth = false;
    _token = null;
    _user = null;
    _messages.clear();
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
    _authRequestController.close();
    disconnect();
    super.dispose();
  }
}
