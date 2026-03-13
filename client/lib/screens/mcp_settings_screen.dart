import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';
import '../theme/app_theme.dart';

// ── Data model ──────────────────────────────────────────────────────────────

enum McpServerType { stdio, http }

class McpServerDraft {
  String name;
  McpServerType type;

  // Stdio fields
  String command;
  String args; // comma-separated raw string
  List<MapEntry<String, String>> env;

  // HTTP fields
  String url;
  List<MapEntry<String, String>> headers;

  McpServerDraft({
    this.name = '',
    this.type = McpServerType.stdio,
    this.command = '',
    this.args = '',
    List<MapEntry<String, String>>? env,
    this.url = '',
    List<MapEntry<String, String>>? headers,
  })  : env = env ?? [],
        headers = headers ?? [];

  /// Build the JSON config map for this server.
  Map<String, dynamic> toConfig() {
    if (type == McpServerType.http) {
      return {
        'type': 'http',
        'url': url.trim(),
        if (headers.isNotEmpty)
          'headers': {for (final e in headers) e.key: e.value},
      };
    } else {
      final argList = args
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return {
        'type': 'stdio',
        'command': command.trim(),
        if (argList.isNotEmpty) 'args': argList,
        if (env.isNotEmpty) 'env': {for (final e in env) e.key: e.value},
      };
    }
  }

  /// Build from existing config map.
  factory McpServerDraft.fromConfig(String name, Map<String, dynamic> cfg) {
    final rawType = cfg['type'] as String? ?? '';
    final isHttp = rawType == 'http' || rawType == 'sse' ||
        (cfg.containsKey('url') && !cfg.containsKey('command'));

    if (isHttp) {
      final rawHeaders = cfg['headers'] as Map<String, dynamic>? ?? {};
      return McpServerDraft(
        name: name,
        type: McpServerType.http,
        url: cfg['url'] as String? ?? '',
        headers: rawHeaders.entries
            .map((e) => MapEntry(e.key, e.value.toString()))
            .toList(),
      );
    } else {
      final rawArgs = cfg['args'] as List<dynamic>? ?? [];
      final rawEnv = cfg['env'] as Map<String, dynamic>? ?? {};
      return McpServerDraft(
        name: name,
        type: McpServerType.stdio,
        command: cfg['command'] as String? ?? '',
        args: rawArgs.join(', '),
        env: rawEnv.entries
            .map((e) => MapEntry(e.key, e.value.toString()))
            .toList(),
      );
    }
  }
}

// ── Main Screen ─────────────────────────────────────────────────────────────

class McpSettingsScreen extends StatefulWidget {
  const McpSettingsScreen({super.key});

  @override
  State<McpSettingsScreen> createState() => _McpSettingsScreenState();
}

class _McpSettingsScreenState extends State<McpSettingsScreen> {
  bool _isLoading = true;
  Map<String, dynamic> _rawServers = {};
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    final ws = context.read<WsService>();
    _sub = ws.mcpConfigResponses.listen(_handleResponse);
    if (ws.status == WsStatus.connected) {
      ws.getMcpConfig();
    } else {
      setState(() => _isLoading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showSnack('WebSocket 未连接，请稍后再试', isError: true);
      });
    }
  }

  void _handleResponse(Map<String, dynamic> response) {
    if (!mounted) return;
    final type = response['type'];
    final payload = response['payload'] ?? {};
    final status = payload['status'];

    if (type == 'MCP_CONFIG_RESPONSE') {
      setState(() {
        _isLoading = false;
        if (status == 'success') {
          final config = payload['config'] as Map<String, dynamic>? ?? {};
          _rawServers = Map<String, dynamic>.from(
              config['mcpServers'] as Map<String, dynamic>? ?? {});
        }
      });
      if (status != 'success') {
        _showSnack('获取配置失败: ${payload['message'] ?? '未知错误'}', isError: true);
      }
    } else if (type == 'MCP_CONFIG_UPDATE_RESPONSE') {
      setState(() => _isLoading = false);
      if (status == 'success') {
        _showSnack('MCP 配置已更新并热重载成功！');
      } else {
        _showSnack('更新失败: ${payload['message']}', isError: true);
      }
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : null,
    ));
  }

  void _saveAll() {
    setState(() => _isLoading = true);
    final fullConfig = {'mcpServers': _rawServers};
    context.read<WsService>().updateMcpConfig(fullConfig);
  }

  void _deleteServer(String name) {
    setState(() {
      _rawServers.remove(name);
    });
    _saveAll();
  }

  Future<void> _openEditor({String? existingName}) async {
    McpServerDraft initial;
    if (existingName != null && _rawServers.containsKey(existingName)) {
      initial = McpServerDraft.fromConfig(
          existingName, _rawServers[existingName] as Map<String, dynamic>);
    } else {
      initial = McpServerDraft();
    }

    final result = await showDialog<McpServerDraft>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _McpServerEditorDialog(
        draft: initial,
        existingNames:
            _rawServers.keys.where((k) => k != existingName).toSet(),
      ),
    );

    if (result == null) return;

    setState(() {
      if (existingName != null && existingName != result.name) {
        _rawServers.remove(existingName);
      }
      _rawServers[result.name] = result.toConfig();
    });
    _saveAll();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colors.sidebar,
        elevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        title: Text(
          '扩展生态 (MCP)',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _isLoading ? null : () => _openEditor(),
              icon: Icon(Icons.add_rounded, color: colors.accent),
              label: Text('添加 Server',
                  style: TextStyle(color: colors.accent, fontSize: 13)),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(colors, colorScheme),
    );
  }

  Widget _buildBody(LumiColors colors, ColorScheme colorScheme) {
    if (_rawServers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_off_rounded,
                size: 64, color: colors.subtext.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('尚未配置任何 MCP Server',
                style: TextStyle(color: colors.subtext, fontSize: 15)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加第一个 Server'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ..._rawServers.entries.map((entry) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ServerCard(
                name: entry.key,
                config: entry.value as Map<String, dynamic>,
                colors: colors,
                colorScheme: colorScheme,
                onEdit: () => _openEditor(existingName: entry.key),
                onDelete: () => _confirmDelete(entry.key),
              ),
            )),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _openEditor(),
          icon: Icon(Icons.add_rounded, color: colors.accent),
          label: Text('添加 Server', style: TextStyle(color: colors.accent)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: colors.accent.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Server'),
        content: Text('确认删除 "$name"？此操作会立即热重载。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) _deleteServer(name);
  }
}

// ── Server Card ──────────────────────────────────────────────────────────────

class _ServerCard extends StatelessWidget {
  final String name;
  final Map<String, dynamic> config;
  final LumiColors colors;
  final ColorScheme colorScheme;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerCard({
    required this.name,
    required this.config,
    required this.colors,
    required this.colorScheme,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final rawType = config['type'] as String? ?? '';
    final isHttp = rawType == 'http' ||
        rawType == 'sse' ||
        (config.containsKey('url') && !config.containsKey('command'));
    final typeLabel = isHttp ? 'HTTP / SSE' : 'Stdio';
    final typeColor = isHttp ? Colors.teal : Colors.deepPurple;

    final subtitle = isHttp
        ? (config['url'] as String? ?? '—')
        : '${config['command'] ?? ''} ${(config['args'] as List?)?.join(' ') ?? ''}'
            .trim();

    return Container(
      decoration: BoxDecoration(
        color: colors.inputBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isHttp ? Icons.cloud_rounded : Icons.terminal_rounded,
              color: colors.accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name,
                        style: TextStyle(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 15)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: typeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(typeLabel,
                          style:
                              TextStyle(color: typeColor, fontSize: 11)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.edit_rounded, color: colors.subtext, size: 20),
            tooltip: '编辑',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_rounded,
                color: Colors.redAccent, size: 20),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

// ── Editor Dialog ────────────────────────────────────────────────────────────

class _McpServerEditorDialog extends StatefulWidget {
  final McpServerDraft draft;
  final Set<String> existingNames;

  const _McpServerEditorDialog({
    required this.draft,
    required this.existingNames,
  });

  @override
  State<_McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

class _McpServerEditorDialogState extends State<_McpServerEditorDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late McpServerType _type;

  // Stdio
  late TextEditingController _commandCtrl;
  late TextEditingController _argsCtrl;
  late List<MapEntry<String, String>> _env;

  // HTTP
  late TextEditingController _urlCtrl;
  late List<MapEntry<String, String>> _headers;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _nameCtrl = TextEditingController(text: d.name);
    _type = d.type;
    _commandCtrl = TextEditingController(text: d.command);
    _argsCtrl = TextEditingController(text: d.args);
    _env = List<MapEntry<String, String>>.from(d.env);
    _urlCtrl = TextEditingController(text: d.url);
    _headers = List<MapEntry<String, String>>.from(d.headers);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _commandCtrl.dispose();
    _argsCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _addKvPair(List<MapEntry<String, String>> list) {
    setState(() => list.add(const MapEntry('', '')));
  }

  void _removeKvPair(List<MapEntry<String, String>> list, int idx) {
    setState(() => list.removeAt(idx));
  }

  void _updateKvKey(
      List<MapEntry<String, String>> list, int idx, String key) {
    setState(() => list[idx] = MapEntry(key, list[idx].value));
  }

  void _updateKvValue(
      List<MapEntry<String, String>> list, int idx, String val) {
    setState(() => list[idx] = MapEntry(list[idx].key, val));
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final result = McpServerDraft(
      name: _nameCtrl.text.trim(),
      type: _type,
      command: _commandCtrl.text,
      args: _argsCtrl.text,
      env: List.from(_env),
      url: _urlCtrl.text,
      headers: List.from(_headers),
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final isEdit = widget.draft.name.isNotEmpty;

    return Dialog(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                isEdit ? '编辑 Server' : '添加 MCP Server',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),

              // Form
              Expanded(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name
                        _buildField(
                          colors: colors,
                          colorScheme: colorScheme,
                          label: 'Server 名称',
                          controller: _nameCtrl,
                          hint: '例如：filesystem、notion',
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return '名称不能为空';
                            }
                            if (widget.existingNames
                                .contains(v.trim())) {
                              return '名称已存在';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Type selector
                        Text('接入方式',
                            style: TextStyle(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                                fontSize: 13)),
                        const SizedBox(height: 8),
                        _buildTypeSelector(colors, colorScheme),
                        const SizedBox(height: 20),

                        // Type-specific fields
                        if (_type == McpServerType.stdio) ...[
                          _buildField(
                            colors: colors,
                            colorScheme: colorScheme,
                            label: '启动命令 (command)',
                            controller: _commandCtrl,
                            hint: '例如：npx 或 uvx',
                            validator: (v) =>
                                (v == null || v.trim().isEmpty)
                                    ? '命令不能为空'
                                    : null,
                          ),
                          const SizedBox(height: 16),
                          _buildField(
                            colors: colors,
                            colorScheme: colorScheme,
                            label: '参数 args（逗号分隔）',
                            controller: _argsCtrl,
                            hint:
                                '例如：-y, @modelcontextprotocol/server-filesystem, /path',
                          ),
                          const SizedBox(height: 16),
                          _buildKvSection(
                            colors: colors,
                            colorScheme: colorScheme,
                            title: '环境变量 (env)',
                            list: _env,
                            keyHint: 'VARIABLE_NAME',
                            valueHint: 'value',
                            obscureValue: true,
                          ),
                        ] else ...[
                          _buildField(
                            colors: colors,
                            colorScheme: colorScheme,
                            label: '服务器地址 (url)',
                            controller: _urlCtrl,
                            hint: '例如：https://mcp.example.com/sse',
                            validator: (v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'URL 不能为空'
                                    : null,
                          ),
                          const SizedBox(height: 16),
                          _buildKvSection(
                            colors: colors,
                            colorScheme: colorScheme,
                            title: '请求头 Headers（可选）',
                            list: _headers,
                            keyHint: 'Authorization',
                            valueHint: 'Bearer token...',
                            obscureValue: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),
              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('取消',
                        style: TextStyle(color: colors.subtext)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(isEdit ? '保存并热重载' : '添加并热重载'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeSelector(LumiColors colors, ColorScheme colorScheme) {
    return Row(
      children: [
        _TypeOption(
          label: 'Stdio（本地命令）',
          subtitle: 'npx / uvx / python',
          icon: Icons.terminal_rounded,
          selected: _type == McpServerType.stdio,
          colors: colors,
          colorScheme: colorScheme,
          onTap: () => setState(() => _type = McpServerType.stdio),
        ),
        const SizedBox(width: 10),
        _TypeOption(
          label: 'HTTP / SSE（远程）',
          subtitle: 'HTTPS endpoint',
          icon: Icons.cloud_rounded,
          selected: _type == McpServerType.http,
          colors: colors,
          colorScheme: colorScheme,
          onTap: () => setState(() => _type = McpServerType.http),
        ),
      ],
    );
  }

  Widget _buildField({
    required LumiColors colors,
    required ColorScheme colorScheme,
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscureText = false,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          validator: validator,
          style: TextStyle(color: colorScheme.onSurface, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: colors.subtext, fontSize: 12),
            filled: true,
            fillColor: colors.inputBg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.divider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.divider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.accent)),
            errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: Colors.redAccent)),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }

  Widget _buildKvSection({
    required LumiColors colors,
    required ColorScheme colorScheme,
    required String title,
    required List<MapEntry<String, String>> list,
    required String keyHint,
    required String valueHint,
    bool obscureValue = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title,
                style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _addKvPair(list),
              icon: Icon(Icons.add_rounded, size: 16, color: colors.accent),
              label: Text('添加',
                  style: TextStyle(color: colors.accent, fontSize: 12)),
              style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (list.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.inputBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.divider),
            ),
            child: Text('（无）',
                style: TextStyle(color: colors.subtext, fontSize: 12),
                textAlign: TextAlign.center),
          )
        else
          ...list.asMap().entries.map((entry) {
            final idx = entry.key;
            final kv = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _KvField(
                      initial: kv.key,
                      hint: keyHint,
                      colors: colors,
                      colorScheme: colorScheme,
                      onChanged: (v) => _updateKvKey(list, idx, v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: _KvField(
                      initial: kv.value,
                      hint: valueHint,
                      obscureText: obscureValue,
                      colors: colors,
                      colorScheme: colorScheme,
                      onChanged: (v) => _updateKvValue(list, idx, v),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded,
                        color: Colors.redAccent, size: 18),
                    onPressed: () => _removeKvPair(list, idx),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

// ── Helper Widgets ───────────────────────────────────────────────────────────

class _TypeOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final LumiColors colors;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _TypeOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.colors,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.accent.withValues(alpha: 0.12)
                : colors.inputBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? colors.accent : colors.divider,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 18,
                  color: selected ? colors.accent : colors.subtext),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            color: selected
                                ? colors.accent
                                : colorScheme.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    Text(subtitle,
                        style:
                            TextStyle(color: colors.subtext, fontSize: 10)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A simple text field that reports changes via [onChanged].
/// Uses an internal controller so it can be pre-filled.
class _KvField extends StatefulWidget {
  final String initial;
  final String hint;
  final bool obscureText;
  final LumiColors colors;
  final ColorScheme colorScheme;
  final ValueChanged<String> onChanged;

  const _KvField({
    required this.initial,
    required this.hint,
    required this.colors,
    required this.colorScheme,
    required this.onChanged,
    this.obscureText = false,
  });

  @override
  State<_KvField> createState() => _KvFieldState();
}

class _KvFieldState extends State<_KvField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final colorScheme = widget.colorScheme;
    return TextField(
      controller: _ctrl,
      obscureText: widget.obscureText,
      onChanged: widget.onChanged,
      style: TextStyle(color: colorScheme.onSurface, fontSize: 12),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: TextStyle(color: colors.subtext, fontSize: 11),
        filled: true,
        fillColor: colors.inputBg,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: colors.divider)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: colors.divider)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: colors.accent)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        isDense: true,
      ),
    );
  }
}
