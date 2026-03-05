enum MessageSender { me, ai }

class ChatMessage {
  final String id;
  final String content;
  final MessageSender sender;
  final DateTime time;
  final bool isTyping; // AI 正在输入中的占位
  final bool isSelected; // 是否被选中 (用于多选)

  ChatMessage({
    required this.id,
    required this.content,
    required this.sender,
    required this.time,
    this.isTyping = false,
    this.isSelected = false,
  });

  ChatMessage copyWith({String? content, bool? isTyping, bool? isSelected}) {
    return ChatMessage(
      id: id,
      content: content ?? this.content,
      sender: sender,
      time: time,
      isTyping: isTyping ?? this.isTyping,
      isSelected: isSelected ?? this.isSelected,
    );
  }
}
