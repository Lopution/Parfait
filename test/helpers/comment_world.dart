import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/user/user_entity.dart';

import 'api_responses.dart';
import 'fake_account.dart';

/// The comments' signed-in account: user 10 owns the sample comments.
StubAccountStore commentsAccountStore() => StubAccountStore(
  accounts: const [Account(id: 'account', userId: 10, name: 'tester')],
);

CommentEntity sampleComment(
  int id, {
  int workId = 1,
  CommentWorkKind kind = CommentWorkKind.illust,
  int userId = 10,
  String? userName,
  int? parentCommentId,
  int? rootCommentId,
  int replyCount = 0,
  String? content,
}) => CommentEntity(
  id: id,
  workId: workId,
  kind: kind,
  parentCommentId: parentCommentId,
  rootCommentId: rootCommentId ?? id,
  user: UserEntity(
    id: userId,
    name: userName ?? 'user $userId',
    account: 'user_$userId',
  ),
  content: content ?? 'comment $id',
  createdAt: DateTime.utc(2026, 8, 27),
  hasReplies: replyCount > 0,
  replyCount: replyCount,
);

/// [comment] as the App API's comment object.
Map<String, dynamic> commentJson(CommentEntity comment) => {
  'id': comment.id,
  'comment': comment.content,
  'date': comment.createdAt.toIso8601String(),
  'user': userJson(comment.user),
  'has_replies': comment.hasReplies,
  'reply_count': comment.replyCount,
  'parent_comment_id': ?comment.parentCommentId,
};

/// The App API's comment endpoints. Root pages answer [rootComments] (by
/// default root comment 11 with one reply) and reply pages [replies] (by
/// default reply 12 to the root asked for), each as one page; the root
/// page carries the author's switch, [commentsClosed]. Adds answer
/// [added] once [addGate] opens, or [addFailure]; [deletes] logs the ids
/// deleted.
class CommentApi {
  List<CommentEntity>? rootComments;
  List<CommentEntity>? replies;
  bool? commentsClosed;
  Completer<void>? addGate;
  CommentEntity added = sampleComment(20);
  ApiRoute? addFailure;
  final deletes = <int>[];

  Map<String, ApiRoute> get routes => {
    for (final kind in CommentWorkKind.values) ...{
      '/v3/${kind.name}/comments': (request) {
        final query = request.url.queryParameters;
        final workId = int.parse(query['${kind.name}_id']!);
        final comments =
            rootComments ?? [sampleComment(11, workId: workId, replyCount: 1)];
        return jsonResponse({
          'comments': [for (final comment in comments) commentJson(comment)],
          'next_url': null,
          'comment_access_control': ?switch (commentsClosed) {
            true => 1,
            false => 0,
            null => null,
          },
        });
      },
      '/v2/${kind.name}/comment/replies': (request) {
        final root = int.parse(request.url.queryParameters['comment_id']!);
        final comments =
            replies ??
            [sampleComment(12, parentCommentId: root, rootCommentId: root)];
        return jsonResponse(
          pageJson('comments', [
            for (final comment in comments) commentJson(comment),
          ]),
        );
      },
      '/v1/${kind.name}/comment/add': (request) async {
        await addGate?.future;
        if (addFailure case final fail?) return fail(request);
        return jsonResponse({'comment': commentJson(added)});
      },
      '/v1/${kind.name}/comment/delete': (request) {
        deletes.add(int.parse(requestFields(request)['comment_id']!));
        return jsonResponse(const <String, Object?>{});
      },
    },
  };
}

/// Signed in as user 10, who owns the sample comments, over [PixivApi]
/// with [comments]' routes and [routes].
Future<ProviderContainer> commentWorld(
  CommentApi comments, {
  Map<String, ApiRoute> routes = const {},
}) => signedInApiContainer(
  PixivApi({...backgroundRoutes, ...comments.routes, ...routes}).client,
  account: const Account(id: 'account', userId: 10, name: 'tester'),
);
