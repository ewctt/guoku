import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'download_picker.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'player_screen.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'drama_actions.dart';
import 'follow_state.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.resumeOnOpen = false,
    this.downloadOnOpen = false,
  });
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool resumeOnOpen;
  final bool downloadOnOpen;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  DramaDetail? _detail;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  bool _initialActionHandled = false;
  late final int _profileEpoch;
  Widget? get _sourceDiagnostics => widget.repository.supportsSourceManagement
      ? SourceDiagnosticsButton(
          repository: widget.repository,
          store: widget.store,
          drama: widget.drama,
        )
      : null;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    widget.store.addListener(_onStoreChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant DetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _generation++;
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.repository.detail(widget.drama);
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final merged = widget.repository.catalogUpdates
          .current(widget.drama)
          .merge(detail.drama);
      setState(() {
        _detail = DramaDetail(merged, detail.episodes, warning: detail.warning);
        _loading = false;
      });
      widget.repository.catalogUpdates.publish(merged, retryCover: true);
      unawaited(_supplement(merged, generation));
      await saveUserChange(context, () => widget.store.refreshDrama(merged));
      if (mounted &&
          generation == _generation &&
          _profileEpoch == widget.store.profileEpoch &&
          !_initialActionHandled &&
          detail.episodes.isNotEmpty) {
        _initialActionHandled = true;
        if (widget.resumeOnOpen) {
          unawaited(
            _play(
              resumeEpisodeIndex(
                detail.episodes,
                widget.store.watched(merged.id),
              ),
              resume: true,
            ),
          );
        } else if (widget.downloadOnOpen && widget.store.canDownload) {
          unawaited(_download());
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
      widget.repository.catalogUpdates.publish(
        widget.repository.catalogUpdates.current(widget.drama),
        retryCover: true,
      );
    }
  }

  Future<void> _supplement(Drama drama, int generation) async {
    try {
      final fresh = await widget.repository.supplementMetadata(drama);
      if (!mounted ||
          generation != _generation ||
          fresh == null ||
          _detail == null) {
        return;
      }
      final updated = _detail!.drama.merge(fresh);
      setState(() {
        _detail = DramaDetail(
          updated,
          _detail!.episodes,
          warning: _detail!.warning,
        );
      });
      widget.repository.catalogUpdates.publish(updated);
      await saveUserChange(context, () => widget.store.refreshDrama(updated));
    } catch (_) {}
  }

  Future<void> _download() async {
    final detail = _detail;
    if (detail == null ||
        !widget.store.canDownload ||
        _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    final selection = await Navigator.of(context).push<DownloadSelection>(
      MaterialPageRoute(builder: (_) => DownloadPicker(detail: detail)),
    );
    if (selection == null ||
        !mounted ||
        !widget.store.canDownload ||
        _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    try {
      final added = await widget.repository.enqueueDownloads(
        detail,
        selection.episodes,
        quality: selection.quality,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DownloadsScreen(
                    repository: widget.repository,
                    store: widget.store,
                  ),
                ),
              );
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _play(int index, {bool resume = false}) async {
    final detail = _detail;
    if (detail == null ||
        index < 0 ||
        index >= detail.episodes.length ||
        _profileEpoch != widget.store.profileEpoch ||
        !widget.store.allowsSource(detail.drama.source)) {
      return;
    }
    if (detail.episodes[index].vip) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这是一集 VIP 内容'),
          content: const Text('站源可能只提供试看或限制播放。'),
          actions: [
            TextButton(
              autofocus: AppLayout.isTelevision(context),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('尝试播放'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) {
        return;
      }
    }
    final saved = widget.store.watched(detail.drama.id);
    final position =
        resume &&
            saved?.episode == detail.episodes[index].number &&
            !saved!.finished
        ? saved.position
        : 0.0;
    if (!mounted || _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          detail: detail,
          initialIndex: index,
          initialPosition: position,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final drama = _detail?.drama ?? widget.drama;
    final watched = widget.store.watched(drama.id);
    final episodes = _detail?.episodes ?? [];
    final resumeIndex = resumeEpisodeIndex(episodes, watched);
    final television = AppLayout.isTelevision(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: television ? 64 : null,
          title: Text(drama.title, overflow: TextOverflow.ellipsis),
          actions: [
            if (widget.repository.supportsDownloads && widget.store.canDownload)
              IconButton(
                tooltip: '下载选集',
                onPressed: _loading || episodes.isEmpty ? null : _download,
                icon: const Icon(Icons.download_rounded),
              ),
            RefreshAction(
              loading: _loading,
              tooltip: '更新剧集信息',
              onPressed: _load,
            ),
            IconButton(
              tooltip: widget.store.isFavorite(drama.id) ? '取消追剧' : '加入追剧',
              onPressed: () => saveUserChange(
                context,
                () => widget.store.toggleFavorite(drama),
              ),
              icon: Icon(
                widget.store.isFavorite(drama.id)
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: television
              ? _televisionBody(drama, episodes, resumeIndex, watched)
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                            child: _followingControls(drama),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 112,
                                  height: 168,
                                  child: DramaCover(
                                    drama: drama,
                                    repository: widget.repository,
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        drama.title,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        SourceSite.byId(drama.source).name +
                                            (drama.episodes > 0
                                                ? ' · 共 ${drama.episodes} 集'
                                                : ''),
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      if (drama.category.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          drama.category,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                      if (drama.onlineDate.isNotEmpty ||
                                          drama.heat.isNotEmpty ||
                                          drama.views.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          [
                                            if (drama.onlineDate.isNotEmpty)
                                              '${drama.onlineDate} 上线',
                                            if (drama.heat.isNotEmpty)
                                              '热度 ${drama.heat}',
                                            if (drama.views.isNotEmpty)
                                              '播放 ${drama.views}',
                                          ].join(' · '),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                      if (drama.releaseStatus.isNotEmpty &&
                                          drama.releaseStatus != 'unknown') ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          drama.releaseLabel,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                      if (drama.source == 'huangdou') ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          drama.vipStatus == null
                                              ? 'VIP 状态待补齐'
                                              : drama.vip
                                              ? 'VIP 内容'
                                              : '免费内容',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                      const SizedBox(height: 18),
                                      FilledButton.icon(
                                        key: const ValueKey('start-play'),
                                        onPressed: episodes.isEmpty
                                            ? null
                                            : () => _play(
                                                resumeIndex,
                                                resume: true,
                                              ),
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                        ),
                                        label: Text(
                                          watched != null && episodes.isNotEmpty
                                              ? '继续第 ${episodes[resumeIndex].number} 集'
                                              : '立即播放',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_detail?.warning.isNotEmpty == true)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                              child: Text(
                                _detail!.warning,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        if (drama.tags.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final tag in drama.tags)
                                    Chip(label: Text(tag)),
                                ],
                              ),
                            ),
                          ),
                        if (drama.description.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              child: Text(
                                drama.description,
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  height: 1.6,
                                ),
                              ),
                            ),
                          ),
                        if (_loading)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          )
                        else if (_error != null)
                          SliverToBoxAdapter(
                            child: StatusPanel(
                              title: '剧集信息暂时不可用',
                              message: _error!,
                              onRetry: _load,
                              secondaryAction: _sourceDiagnostics,
                            ),
                          )
                        else ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                              child: Row(
                                children: [
                                  Text(
                                    '选集',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '共 ${episodes.length} 集',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 96,
                                    mainAxisExtent: 52,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              delegate: SliverChildBuilderDelegate((_, index) {
                                final episode = episodes[index];
                                final current =
                                    watched?.episode == episode.number;
                                return OutlinedButton(
                                  key: ValueKey('episode-${episode.number}'),
                                  onPressed: () => _play(index),
                                  style: OutlinedButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    backgroundColor: current
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.primaryContainer
                                        : null,
                                    side: BorderSide(
                                      color: current
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.outlineVariant,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('${episode.number}'),
                                      if (episode.vip) ...[
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.workspace_premium_rounded,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.tertiary,
                                          size: 14,
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }, childCount: episodes.length),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _followingControls(Drama drama) {
    final state = widget.store.following(drama.id);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const ValueKey('follow-status'),
          onPressed: () =>
              showDramaActions(context, drama: drama, store: widget.store),
          icon: Icon(
            state?.status == FollowStatus.watched
                ? Icons.check_circle_outline
                : Icons.bookmark_outline,
          ),
          label: Text(state?.label ?? '追剧状态'),
        ),
        if (state != null && state.newEpisodes > 0)
          ActionChip(
            label: Text('${state.newEpisodes} 集更新 · 标为已读'),
            onPressed: () => saveUserChange(
              context,
              () => widget.store.markUpdatesRead(drama.id),
            ),
          ),
      ],
    );
  }

  Widget _televisionBody(
    Drama drama,
    List<Episode> episodes,
    int resumeIndex,
    WatchEntry? watched,
  ) => LayoutBuilder(
    builder: (context, constraints) => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: (constraints.maxWidth * .34).clamp(210.0, 340.0),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _followingControls(drama),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      height: 138,
                      child: DramaCover(
                        drama: drama,
                        repository: widget.repository,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            drama.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            SourceSite.byId(drama.source).name,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (episodes.isNotEmpty)
                            Text('共 ${episodes.length} 集'),
                        ],
                      ),
                    ),
                  ],
                ),
                if (drama.description.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    drama.description,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (episodes.isNotEmpty)
                  RemoteButton(
                    key: const ValueKey('start-play'),
                    autofocus: true,
                    label: watched != null
                        ? '继续第 ${episodes[resumeIndex].number} 集'
                        : '立即播放',
                    icon: Icons.play_arrow_rounded,
                    onPressed: () => _play(resumeIndex, resume: true),
                  ),
                RemoteButton(
                  label: widget.store.isFavorite(drama.id) ? '已追剧' : '加入追剧',
                  icon: widget.store.isFavorite(drama.id)
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  onPressed: () => saveUserChange(
                    context,
                    () => widget.store.toggleFavorite(drama),
                  ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? StatusPanel(
                  title: '剧集信息暂时不可用',
                  message: _error!,
                  onRetry: _load,
                  secondaryAction: _sourceDiagnostics,
                )
              : episodes.isEmpty
              ? StatusPanel(
                  title: '暂时没有可播放的集数',
                  message: '可以更新剧集信息后重试。',
                  onRetry: _load,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        '选集',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => RemoteGrid(
                          key: ValueKey('detail-episodes-${drama.id}'),
                          itemKeys: episodes
                              .map((episode) => '${episode.number}')
                              .toList(),
                          columns: ((constraints.maxWidth - 36) / 96)
                              .floor()
                              .clamp(1, 8),
                          itemExtent: 64,
                          itemBuilder: (_, index, node, onFocus) =>
                              RemoteEpisodeButton(
                                key: ValueKey(
                                  'episode-${episodes[index].number}',
                                ),
                                number: episodes[index].number,
                                vip: episodes[index].vip,
                                current:
                                    watched?.episode == episodes[index].number,
                                focusNode: node,
                                onFocus: onFocus,
                                onPressed: () => _play(index),
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    ),
  );
}
