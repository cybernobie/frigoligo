import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:frigoligo/wallabag/wallabag.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/article.dart';
import '../models/article_scroll_position.dart';
import '../models/db.dart';

final _log = Logger('wallabag.service');

enum RefreshState {
  idle,
  inProgress,
  success,
  error,
}

class ArticlesProvider with ChangeNotifier {
  ArticlesProvider({this.onError}) {
    _watcher = db.articles.watchLazy().listen((_) => notifyListeners());

    // ensure a relative freshness of the articles
    _log.info('provider initialization > incremental refresh');
    incrementalRefresh(threshold: autoSyncThrottleSeconds);
  }

  final DBInstance db = DB.get();
  final WallabagClient wallabag = WallabagInstance.get();
  StreamSubscription? _watcher;
  void Function(Exception)? onError;

  float? _refreshProgressValue;
  float? get refreshProgressValue => _refreshProgressValue;
  set refreshProgressValue(float? value) {
    _refreshProgressValue = value;
    notifyListeners();
  }

  bool get refreshInProgress => _refreshProgressValue != null;

  @override
  void dispose() {
    _watcher?.cancel();
    super.dispose();
  }

  Query<R> _buildQuery<R>({
    StateFilter state = StateFilter.unread,
    StarredFilter starred = StarredFilter.all,
    String? sort,
    String? property,
  }) {
    List<FilterCondition> conditions = [];
    if (state != StateFilter.all) {
      conditions.add(state == StateFilter.archived
          ? const FilterCondition.isNotNull(property: 'archivedAt')
          : const FilterCondition.isNull(property: 'archivedAt'));
    }
    if (starred == StarredFilter.starred) {
      conditions.add(const FilterCondition.isNotNull(property: 'starredAt'));
    }

    FilterOperation? filter;
    if (conditions.length == 1) {
      filter = conditions[0];
    } else {
      filter = FilterGroup.and(conditions);
    }

    List<SortProperty> sortBy = [];
    if (sort != null) {
      final String property;
      final Sort direction;
      if (sort.startsWith('-')) {
        property = sort.substring(1);
        direction = Sort.desc;
      } else {
        property = sort;
        direction = Sort.asc;
      }
      sortBy.add(SortProperty(property: property, sort: direction));
    }

    return db.articles.buildQuery(
      filter: filter,
      sortBy: sortBy,
      property: property,
    );
  }

  List<Article> all(StateFilter state, StarredFilter starred) =>
      _buildQuery<Article>(
        state: state,
        starred: starred,
        sort: '-createdAt',
      ).findAllSync();
  Article? index(int n, StateFilter state, StarredFilter starred) {
    if (n < 0 || n >= count(state, starred)) return null;
    var ids = _buildQuery(
      state: state,
      starred: starred,
      sort: '-createdAt',
      property: 'id',
    ).findAllSync();
    return db.articles.getSync(ids[n])!;
  }

  int count(StateFilter state, StarredFilter starred) =>
      _buildQuery(state: state, starred: starred).countSync();

  Future<int> syncRemoteDeletes() async {
    _log.info('checking for server-side deletions');
    final remoteCount = await wallabag.fetchTotalEntriesCount();
    var localIds = (await db.articles.where().idProperty().findAll()).toSet();
    final delta = localIds.length - remoteCount;
    if (delta <= 0) return 0;
    _log.info('server-side deletion detected: delta=$delta');

    // seems overkill but the only way to enumerate all entry ids efficiently
    final entriesStream = wallabag.fetchAllEntries(
      perPage: 100,
      detail: DetailValue.metadata,
    );
    await for (final (entries, _) in entriesStream) {
      localIds = localIds.difference(entries.map((e) => e.id).toSet());
    }

    final deletedCount = await db.writeTxn(() async {
      final res = await db.articles.deleteAll(localIds.toList());
      await db.articleScrollPositions.deleteAll(localIds.toList());
      return res;
    });
    _log.info('removed $deletedCount entries from database');

    return deletedCount;
  }

  Future<int> fullRefresh({int? since}) async {
    if (refreshInProgress) return 0;

    var count = 0;
    final sinceRepr = since != null
        ? DateTime.fromMillisecondsSinceEpoch(since * 1000).toIso8601String()
        : null;
    _log.info('starting refresh with since=$sinceRepr');

    if (since == null) {
      await db.writeTxn(() async {
        await db.articles.clear();
        _log.info('cleared the whole articles collection');
      });
    }

    void onProgress(float progress) => refreshProgressValue = progress;

    try {
      final stopwatch = Stopwatch()..start();
      var entriesStream =
          wallabag.fetchAllEntries(since: since, onProgress: onProgress);
      await for (final (entries, _) in entriesStream) {
        final articles = {
          for (var e in entries) e.id: Article.fromWallabagEntry(e)
        };
        final positions =
            await db.articleScrollPositions.getAll(articles.keys.toList());
        final invalidPositions = positions
            .whereType<ArticleScrollPosition>()
            .where((e) => e.readingTime != articles[e.id]?.readingTime)
            .map((e) => e.id!)
            .toList();

        final putCount = await db.writeTxn(() async {
          final res = await db.articles.putAll(articles.values.toList());
          await db.articleScrollPositions.deleteAll(invalidPositions);
          return res.length;
        });
        _log.info('saved $putCount entries to the database');

        count += entries.length;
      }
      _log.info(
          'completed refresh of $count entries in ${stopwatch.elapsed.inSeconds} s');

      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      await SharedPreferences.getInstance()
          .then((prefs) => prefs.setInt(spLastRefreshTimestamp, now.toInt()));

      onProgress(0);
      syncRemoteDeletes();
    } on Exception catch (e, st) {
      _log.severe('refresh failed', e, st);
      onError?.call(e);
    } finally {
      refreshProgressValue = null;
    }

    return count;
  }

  Future<int> incrementalRefresh({int? threshold}) async {
    final since = await SharedPreferences.getInstance()
        .then((prefs) => prefs.getInt(spLastRefreshTimestamp));

    if (threshold != null && since != null) {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      final elapsed = now - since;
      if (elapsed < threshold) {
        _log.info(
            'incremental refresh throttled (last: ${elapsed.toStringAsFixed(0)} s)');
        return 0;
      }
    }
    return fullRefresh(since: since);
  }
}
