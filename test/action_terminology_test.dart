// §5.7 ActionTerminology regression — the frozen verb table, one verb per
// consequence class. These pins fail on any copy edit that silently
// re-tiers an action (e.g. a list removal renamed 删除, or a navigation
// back relabeled 重试). The audit method: compare every candidate arb key
// against the table in the parent design; wording here is zh because the
// table was frozen on zh strings — other locales keep structural parity.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

void main() {
  final zh = lookupAppLocalizations(const Locale('zh'));

  group('delete tier — 删除 is irreversible only', () {
    test('irreversible destruction verbs', () {
      expect(zh.commentDelete, contains('删除'));
      expect(zh.commentDeleteConfirm, contains('删除'));
      expect(zh.historyDelete, contains('删除'));
      expect(zh.historyDeleteAll, contains('删除'));
      // The tier contract: the destructive label itself warns it cannot
      // be undone.
      expect(zh.historyDeleteHint, contains('不可恢复'));
      expect(zh.localNovelsDelete, '删除');
      expect(
        zh.localNovelsDeleteConfirm('t'),
        allOf(contains('删除'), contains('一并删除')),
      );
    });

    test('list-entry removal verbs — 移除, never 删除', () {
      for (final wording in [
        zh.removeAccount,
        zh.removeAccountConfirm,
        zh.downloadRemoveRecord,
        zh.downloadBatchRemoveConfirm(2),
        zh.cardActionRemoveWatchLater,
        zh.watchLaterRemoved,
      ]) {
        expect(wording, contains('移除'));
        expect(wording, isNot(contains('删除')));
      }
    });

    test('mute-tier verbs — 解除屏蔽 only', () {
      for (final wording in [
        zh.unmuteWork,
        zh.unmuteAuthor,
        zh.unmuteTag,
        zh.tagActionUnmute,
      ]) {
        expect(wording, contains('解除屏蔽'));
      }
    });
  });

  group('cancel tier — 取消 terminates the operation, never navigates', () {
    test('operation-cancel wordings', () {
      expect(zh.cancel, '取消');
      expect(zh.searchReverseCancel, '取消');
      expect(zh.commentCancelReply, contains('取消'));
      expect(zh.cancelDownload, '取消');
    });

    test('compound undo verbs stay idiomatic (取消关注/取消收藏/取消追更)', () {
      // List-level undo idioms — the "cancel" is bound to its object, so
      // they read as removal-tier actions, not navigation.
      expect(zh.unfollow, '取消关注');
      expect(zh.cardActionUnbookmark, '取消收藏');
      expect(zh.watchlistRemove, '取消追更');
    });

    test('no-change back is never labeled 取消', () {
      // The dirty-form confirm uses 放弃, not 取消 — §5.7 "无改动返回不叫取消".
      expect(zh.profileEditLeaveTitle, contains('放弃'));
      expect(zh.profileEditLeaveConfirm, contains('放弃'));
      expect(zh.profileEditLeaveTitle, isNot(contains('取消')));
    });

    test('documented deviation — searchCancel labels a plain back', () {
      // search_page leading arrow pops the route but carries this tooltip;
      // recorded in W2 codebase-search.md:22 and leaf-accepted. Pin the
      // current wording so the deviation stays visible until a leaf owns it.
      expect(zh.searchCancel, '取消');
    });
  });

  group('retry tier — 重试 same op / 重新打开·重新登录 rebuild / 返回 navigates', () {
    test('retry verbs all retry the same operation', () {
      for (final wording in [
        zh.retry,
        zh.retryDownload,
        zh.searchRetry,
        zh.newRetry,
        zh.profileRetry,
        zh.novelRetry,
      ]) {
        expect(wording, '重试');
      }
      expect(zh.searchReverseRetrySameEngine, contains('重试'));
    });

    test('flow-rebuild verbs', () {
      expect(zh.loginRestart, '重新登录');
      expect(zh.reauthRequired, contains('重新登录'));
      expect(zh.loginPageClosed, contains('重新打开'));
      expect(zh.loginWebView2Missing, contains('重新打开'));
    });

    test('navigation verbs use 返回 only', () {
      expect(zh.seriesBackToEpisode(3), contains('返回'));
      expect(zh.seriesBackToLast, contains('返回'));
    });
  });

  group('post-download view verb — 查看, never mixed with 打开', () {
    test('download-complete affordances use 查看', () {
      expect(zh.downloadViewResult, '查看');
      expect(zh.aboutUpdateOpen, '查看');
    });
  });

  group('apply/save tier — 应用 one-shot, 保存 persists a draft', () {
    test('one-shot explicit executions use 应用', () {
      expect(zh.searchApply, '应用');
      expect(zh.imageSourceApplyAndTest, contains('应用'));
    });

    test('draft persistence uses 保存', () {
      expect(zh.save, '保存');
      expect(zh.profileEditSave, contains('保存'));
      expect(zh.translateCredentialsSave, contains('保存'));
      expect(zh.saved, '已保存');
    });
  });
}
