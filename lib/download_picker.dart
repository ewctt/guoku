import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'models.dart';
import 'remote_widgets.dart';

class DownloadSelection {
  const DownloadSelection(this.episodes, this.quality);
  final List<Episode> episodes;
  final int quality;
}

class DownloadPicker extends StatefulWidget {
  const DownloadPicker({super.key, required this.detail});
  final DramaDetail detail;

  @override
  State<DownloadPicker> createState() => _DownloadPickerState();
}

class _DownloadPickerState extends State<DownloadPicker> {
  late final _selected = widget.detail.episodes
      .where((episode) => !episode.vip)
      .take(500)
      .map((episode) => episode.number)
      .toSet();
  int _quality = 0;

  void _select(Iterable<Episode> episodes) {
    setState(() {
      _selected.clear();
      _selected.addAll(episodes.take(500).map((episode) => episode.number));
    });
  }

  void _toggle(Episode episode) {
    if (!_selected.contains(episode.number) && _selected.length >= 500) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多加入 500 集，请分批下载')));
      return;
    }
    setState(() {
      if (!_selected.remove(episode.number)) _selected.add(episode.number);
    });
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.detail.episodes;
    final television = AppLayout.isTelevision(context);
    final hasVip = episodes.any(
      (episode) => episode.vip && _selected.contains(episode.number),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('下载选集')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                  child: Text(
                    widget.detail.drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => _select(episodes),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () => _select(const []),
                        child: const Text('清空'),
                      ),
                      TextButton(
                        onPressed: () =>
                            _select(episodes.where((episode) => !episode.vip)),
                        child: const Text('仅非 VIP'),
                      ),
                      DropdownButton<int>(
                        key: const ValueKey('download-quality'),
                        value: _quality,
                        onChanged: (value) =>
                            setState(() => _quality = value ?? 0),
                        items: [
                          const DropdownMenuItem(
                            value: 0,
                            child: Text('自动 · 优先高清'),
                          ),
                          for (final quality in [1080, 720, 480])
                            DropdownMenuItem(
                              value: quality,
                              child: Text('${quality}P'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    '保存源站原始视频；指定画质不可用时使用可用版本。下载时请保持应用运行。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (hasVip)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                    child: Text(
                      '已选 VIP 集可能只能下载试看内容。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => RemoteGrid(
                      itemKeys: episodes
                          .map((episode) => 'pick-${episode.number}')
                          .toList(),
                      columns:
                          ((constraints.maxWidth - 36) /
                                  (television ? 100 : 76))
                              .floor()
                              .clamp(1, 10),
                      itemExtent: television ? 66 : 58,
                      spacing: 8,
                      itemBuilder: (_, index, node, onFocus) {
                        final episode = episodes[index];
                        final selected = _selected.contains(episode.number);
                        return Semantics(
                          selected: selected,
                          child: RemoteEpisodeButton(
                            key: ValueKey('download-episode-${episode.number}'),
                            number: episode.number,
                            vip: episode.vip,
                            current: selected,
                            focusNode: node,
                            onFocus: onFocus,
                            onPressed: () => _toggle(episode),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: FilledButton.icon(
                    key: const ValueKey('enqueue-downloads'),
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            DownloadSelection(
                              episodes
                                  .where(
                                    (episode) =>
                                        _selected.contains(episode.number),
                                  )
                                  .toList(),
                              _quality,
                            ),
                          ),
                    icon: const Icon(Icons.download_rounded),
                    label: Text('加入下载 · ${_selected.length} 集'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
