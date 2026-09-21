import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'local_media_screen.dart';
import 'models.dart';
import 'player_screen.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.playerBuilder,
  });
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  @visibleForTesting
  final Widget Function(DramaDetail, int, double)? playerBuilder;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  Timer? _timer;
  List<DownloadJob> _jobs = [];
  bool _loading = true;
  bool _refreshing = false;
  bool _opening = false;
  String? _error;
  String _filter = 'all';
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final jobs = await widget.repository.downloads();
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _refreshing = false;
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _control(String command, [DownloadJob? job]) async {
    final id = job?.id ?? '';
    if (_busy.contains(id) || _busy.contains('')) return;
    if (command == 'remove' && job!.completed) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除已下载视频？'),
          content: Text(
            '${job.drama.title} · 第 ${job.episode.number} 集\n删除后需要重新下载。',
          ),
          actions: [
            TextButton(
              autofocus: AppLayout.isTelevision(context),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _busy.add(id));
    try {
      await widget.repository.controlDownloads(command, id: id);
      await _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _play(DownloadJob job) async {
    if (_opening) return;
    _opening = true;
    final completed =
        _jobs
            .where((entry) => entry.completed && entry.drama.id == job.drama.id)
            .toList()
          ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    final index = completed.indexWhere((entry) => entry.id == job.id);
    if (index < 0) {
      _opening = false;
      return;
    }
    final detail = DramaDetail(
      job.drama,
      completed.map((entry) => entry.episode).toList(),
    );
    final watch = widget.store.watched(job.drama.id);
    final position = watch?.episode == job.episode.number && !watch!.finished
        ? watch.position
        : 0.0;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              widget.playerBuilder?.call(detail, index, position) ??
              PlayerScreen(
                detail: detail,
                initialIndex: index,
                initialPosition: position,
                repository: widget.repository,
                store: widget.store,
                localOnly: true,
              ),
        ),
      );
    } finally {
      _opening = false;
      if (mounted) await _refresh();
    }
  }

  Future<void> _actions(DownloadJob job) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${job.drama.title} · 第 ${job.episode.number} 集'),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (job.completed)
            TextButton.icon(
              autofocus: true,
              onPressed: () => Navigator.pop(context, 'play'),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('本地播放'),
            ),
          if (job.active)
            TextButton.icon(
              autofocus: true,
              onPressed: () => Navigator.pop(context, 'pause'),
              icon: const Icon(Icons.pause_rounded),
              label: const Text('暂停'),
            ),
          if (job.resumable)
            TextButton.icon(
              autofocus: true,
              onPressed: () => Navigator.pop(context, 'resume'),
              icon: const Icon(Icons.download_rounded),
              label: Text(job.state == 'failed' ? '重试下载' : '继续下载'),
            ),
          if (job.state != 'removing')
            TextButton.icon(
              onPressed: () => Navigator.pop(context, 'remove'),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(job.completed ? '删除视频' : '取消下载'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'play') {
      await _play(job);
    } else {
      await _control(action, job);
    }
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _card(DownloadJob job, {FocusNode? node, VoidCallback? onFocus}) {
    final television = AppLayout.isTelevision(context);
    final busy = _busy.contains(job.id) || _busy.contains('');
    final quality = job.actualQuality > 0 ? job.actualQuality : job.quality;
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${job.drama.title} · 第 ${job.episode.number} 集',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
          ),
          const SizedBox(height: 5),
          Text(
            '${SourceSite.byId(job.drama.source).name} · ${job.stateLabel}'
            '${quality > 0 ? ' · ${quality}P' : ''}${job.episode.vip ? ' · VIP 试看' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (!job.completed) ...[
            LinearProgressIndicator(
              value: job.progress > 0 || job.state != 'downloading'
                  ? job.progress
                  : null,
            ),
            const SizedBox(height: 7),
          ],
          Text(
            '${_size(job.bytes)}${job.total > 0 ? ' / ${_size(job.total)}' : ''}'
            '${!job.completed && job.progress > 0 ? ' · ${(job.progress * 100).floor()}%' : ''}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (job.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                job.error,
                maxLines: television ? 1 : 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!television)
            Row(
              children: [
                if (job.completed)
                  TextButton.icon(
                    key: ValueKey('local-play-${job.id}'),
                    onPressed: busy ? null : () => _play(job),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('本地播放'),
                  ),
                if (job.active)
                  TextButton.icon(
                    key: ValueKey('pause-${job.id}'),
                    onPressed: busy ? null : () => _control('pause', job),
                    icon: const Icon(Icons.pause_rounded),
                    label: const Text('暂停'),
                  ),
                if (job.resumable)
                  TextButton.icon(
                    key: ValueKey('resume-${job.id}'),
                    onPressed: busy ? null : () => _control('resume', job),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(job.state == 'failed' ? '重试下载' : '继续下载'),
                  ),
                const Spacer(),
                if (job.state != 'removing')
                  IconButton(
                    key: ValueKey('remove-${job.id}'),
                    tooltip: job.completed ? '删除视频' : '取消下载',
                    onPressed: busy ? null : () => _control('remove', job),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
              ],
            ),
        ],
      ),
    );
    if (television) {
      return RemoteTarget(
        key: ValueKey('download-task-${job.id}'),
        focusNode: node,
        onFocus: onFocus,
        label: '${job.drama.title}，第 ${job.episode.number} 集，${job.stateLabel}',
        onPressed: busy ? null : () => _actions(job),
        child: content,
      );
    }
    return Card(key: ValueKey('download-task-${job.id}'), child: content);
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final colors = Theme.of(context).colorScheme;
    final activeCount = _jobs.where((job) => job.active).length;
    final visible = _jobs
        .where(
          (job) =>
              _filter == 'all' ||
              (_filter == 'completed' ? job.completed : !job.completed),
        )
        .toList();
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '下载任务',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('download-queue-actions'),
                tooltip: '队列操作',
                icon: const Icon(Icons.more_horiz_rounded),
                enabled: _busy.isEmpty,
                onSelected: (command) => _control(command),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'pauseAll',
                    enabled: _jobs.any((job) => job.active),
                    child: const Text('全部暂停'),
                  ),
                  PopupMenuItem(
                    value: 'resumeAll',
                    enabled: _jobs.any((job) => job.resumable),
                    child: const Text('全部继续'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _loading
                      ? '正在读取任务'
                      : '共 ${_jobs.length} 项${activeCount > 0 ? ' · $activeCount 项进行中' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                key: const ValueKey('download-local-media'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => LocalMediaScreen(
                      repository: widget.repository,
                      store: widget.store,
                    ),
                  ),
                ),
                icon: const Icon(Icons.video_library_outlined),
                label: const Text('本地媒体'),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          key: const ValueKey('download-filters'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final filter in const {
                'all': '全部',
                'pending': '未完成',
                'completed': '已下载',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: television
                      ? RemoteButton(
                          key: ValueKey('download-filter-${filter.key}'),
                          label: filter.value,
                          selected: _filter == filter.key,
                          onPressed: () => setState(() => _filter = filter.key),
                        )
                      : ChoiceChip(
                          key: ValueKey('download-filter-${filter.key}'),
                          label: Text(filter.value),
                          selected: _filter == filter.key,
                          showCheckmark: false,
                          onSelected: (_) =>
                              setState(() => _filter = filter.key),
                        ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
          child: Text(
            Platform.isAndroid
                ? '支持后台下载，可在通知中查看进度和暂停。已下载视频可断网播放。'
                : '下载时请保持应用运行，重开后可继续。已下载视频可断网播放。',
            style: TextStyle(
              fontSize: television ? 14 : 12,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        if (_error != null && _jobs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(_error!),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _jobs.isEmpty
              ? StatusPanel(
                  title: '无法读取下载记录',
                  message: _error!,
                  onRetry: _refresh,
                )
              : visible.isEmpty
              ? StatusPanel(
                  title: _jobs.isEmpty ? '还没有下载任务' : '暂无符合条件的任务',
                  message: '在剧集详情点击“下载选集”即可加入队列。',
                  icon: Icons.download_outlined,
                )
              : television
              ? RemoteGrid(
                  itemKeys: visible.map((job) => job.id).toList(),
                  columns: 1,
                  itemExtent: 190,
                  spacing: 8,
                  itemBuilder: (_, index, node, onFocus) =>
                      _card(visible[index], node: node, onFocus: onFocus),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: visible.length,
                  itemBuilder: (_, index) => _card(visible[index]),
                ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('下载')),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}
