import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../buildcontext_extension.dart';
import '../../providers/article.dart';
import '../../providers/query.dart';
import '../../services/wallabag_storage.dart';
import '../../widgets/async/list.dart';
import 'article_list_item.dart';

const listingHeight = 130.0;

class ArticleListView extends ConsumerStatefulWidget {
  const ArticleListView({
    super.key,
    this.controller,
    required this.doRefresh,
    required this.onItemSelect,
    required this.sideBySideMode,
    this.headerOffset = 0,
    this.indexOffset = 1,
  });

  final ScrollController? controller;
  final Future<void> Function() doRefresh;
  final void Function(int articleId)? onItemSelect;
  final bool sideBySideMode;
  final double headerOffset;
  final int indexOffset;

  @override
  ConsumerState<ArticleListView> createState() => _ArticleListState();
}

class _ArticleListState extends ConsumerState<ArticleListView> {
  late final ScrollController _scroller;

  double _computePixelsToScroll(int scrollToIndex) {
    final targetIndex = scrollToIndex - widget.indexOffset;
    final itemPixels = targetIndex * listingHeight;
    final separatorsPixels = targetIndex.abs() * 16.0; // default Divider height
    final targetPixels = (itemPixels + separatorsPixels - widget.headerOffset);
    return targetPixels.clamp(
      -1, // NestedScrollView wants a negative to work as expected
      _scroller.position.maxScrollExtent,
    );
  }

  @override
  void initState() {
    super.initState();

    _scroller = widget.controller ?? ScrollController();

    if (widget.sideBySideMode) {
      () async {
        final article = await ref.read(currentArticleProvider.future);
        if (article?.id != null) {
          final query = ref.read(queryProvider);
          final scrollToIndex = await ref
              .read(wStorageProvider.notifier)
              .indexOf(article!.id, query);
          if (scrollToIndex != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scroller.jumpTo(_computePixelsToScroll(scrollToIndex));
            });
          }
        }
      }();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingOpenArticleId = ref.watch(openArticleProvider);
    if (pendingOpenArticleId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(openArticleProvider.notifier).reset();
        _openArticle(pendingOpenArticleId);
      });
    }

    final storage = ref.watch(wStorageProvider.notifier);
    final query = ref.watch(queryProvider);

    final count = storage.count(query);

    return AListView.separated(
      controller: _scroller,
      itemCount: count,
      itemBuilder: (context, index) async {
        if (index == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            storage.index(index, query).then((article) => ref
                .read(currentArticleProvider.notifier)
                .maybeInit(article!.id));
          });
        }
        return ArticleListItem(
          article: (await storage.index(index, query))!,
          onTap: (article) => _openArticle(article.id),
          showSelection: widget.sideBySideMode,
        );
      },
      itemHeight: listingHeight,
      separatorBuilder: (context, index) => const Divider(),
      create: (context, child) => Center(
          child: RefreshIndicator.adaptive(
        onRefresh: widget.doRefresh,
        child: child,
      )),
      emptyBuilder: (context) => Center(
        child: Text(
          context.L.listing_noArticles,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
      restorationId: 'listing.listview',
    );
  }

  void _openArticle(int articleId) {
    ref.read(currentArticleProvider.notifier).change(articleId);
    widget.onItemSelect?.call(articleId);
  }
}