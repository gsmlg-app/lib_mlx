import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lib_mlx/lib_mlx.dart';

void main() {
  runApp(const LibMlxExampleApp());
}

class LibMlxExampleApp extends StatelessWidget {
  const LibMlxExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'lib_mlx',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6FEB)),
        useMaterial3: true,
      ),
      home: const RuntimePage(),
    );
  }
}

class RuntimePage extends StatefulWidget {
  const RuntimePage({super.key});

  @override
  State<RuntimePage> createState() => _RuntimePageState();
}

class _RuntimePageState extends State<RuntimePage> {
  final LibMlxRuntime _runtime = const LibMlxRuntime();
  final TextEditingController _modelPathController = TextEditingController();
  final TextEditingController _portController = TextEditingController(
    text: '0',
  );

  MlxModelHandle? _handle;
  MlxServerInfo? _server;
  String _status = Platform.isIOS ? 'idle' : 'unsupported platform';
  String _output = '';
  bool _busy = false;

  @override
  void dispose() {
    _modelPathController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    return Scaffold(
      appBar: AppBar(title: const Text('lib_mlx runtime')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _modelPathController,
              decoration: const InputDecoration(
                labelText: 'Model path',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy && _handle == null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                    enabled: !_busy && _server == null,
                  ),
                ),
                const SizedBox(width: 12),
                _ActionButton(
                  icon: Icons.download_for_offline,
                  label: 'Load',
                  enabled: Platform.isIOS && !_busy && _handle == null,
                  onPressed: _loadModel,
                ),
                const SizedBox(width: 8),
                _ActionButton(
                  icon: Icons.play_arrow,
                  label: 'Start',
                  enabled:
                      Platform.isIOS &&
                      !_busy &&
                      _handle != null &&
                      _server == null,
                  onPressed: _startServer,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionButton(
                  icon: Icons.health_and_safety,
                  label: 'Status',
                  enabled: Platform.isIOS && !_busy && _handle != null,
                  onPressed: _refreshStatus,
                ),
                _ActionButton(
                  icon: Icons.chat_bubble_outline,
                  label: 'Chat',
                  enabled: !_busy && server != null,
                  onPressed: _sendChat,
                ),
                _ActionButton(
                  icon: Icons.stop,
                  label: 'Stop',
                  enabled:
                      Platform.isIOS &&
                      !_busy &&
                      _handle != null &&
                      _server != null,
                  onPressed: _stopServer,
                ),
                _ActionButton(
                  icon: Icons.delete_outline,
                  label: 'Unload',
                  enabled: Platform.isIOS && !_busy && _handle != null,
                  onPressed: _unloadModel,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _StatusPanel(
              status: _status,
              serverUrl: server?.baseUrl ?? '-',
              output: _output,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _run(String status, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _status = status;
    });
    try {
      await action();
    } on Object catch (error) {
      setState(() {
        _status = 'failed';
        _output = error.toString();
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _loadModel() async {
    await _run('loading model', () async {
      final handle = await _runtime.loadModel(
        MlxModelConfig(modelPath: _modelPathController.text.trim()),
      );
      setState(() {
        _handle = handle;
        _status = 'model ready';
        _output = handle.toString();
      });
    });
  }

  Future<void> _startServer() async {
    final handle = _handle;
    if (handle == null) return;

    await _run('starting server', () async {
      final server = await _runtime.startServer(
        handle,
        config: MlxServerConfig(port: int.tryParse(_portController.text) ?? 0),
      );
      setState(() {
        _server = server;
        _status = 'server running';
        _output = server.baseUrl;
      });
    });
  }

  Future<void> _refreshStatus() async {
    final handle = _handle;
    if (handle == null) return;

    await _run('reading status', () async {
      final status = await _runtime.serverStatus(handle);
      setState(() {
        _status = '${status.modelStatus} / ${status.serverStatus}';
        _output = '${status.modelId}\n${status.modelPath}';
      });
    });
  }

  Future<void> _sendChat() async {
    final server = _server;
    if (server == null) return;

    await _run('sending chat request', () async {
      final client = LibMlxOpenAiClient(baseUri: server.uri);
      try {
        final response = await client.chatCompletions(<String, Object?>{
          'model': server.modelId,
          'messages': [
            {'role': 'user', 'content': 'Capital of France? One word.'},
          ],
          'temperature': 0,
          'max_tokens': 32,
        });
        setState(() {
          _status = 'chat complete';
          _output = response.toString();
        });
      } finally {
        client.close(force: true);
      }
    });
  }

  Future<void> _stopServer() async {
    final handle = _handle;
    if (handle == null) return;

    await _run('stopping server', () async {
      await _runtime.stopServer(handle);
      setState(() {
        _server = null;
        _status = 'server stopped';
        _output = '';
      });
    });
  }

  Future<void> _unloadModel() async {
    final handle = _handle;
    if (handle == null) return;

    await _run('unloading model', () async {
      await _runtime.unloadModel(handle);
      setState(() {
        _handle = null;
        _server = null;
        _status = 'unloaded';
        _output = '';
      });
    });
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.status,
    required this.serverUrl,
    required this.output,
  });

  final String status;
  final String serverUrl;
  final String output;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RowText(label: 'Status', value: status),
            const SizedBox(height: 8),
            _RowText(label: 'Server', value: serverUrl),
            if (output.isNotEmpty) ...[
              const Divider(height: 24),
              SelectableText(output),
            ],
          ],
        ),
      ),
    );
  }
}

class _RowText extends StatelessWidget {
  const _RowText({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(child: SelectableText(value)),
      ],
    );
  }
}
