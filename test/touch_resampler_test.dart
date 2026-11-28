import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/touch_resampler.dart';

Duration _ms(num ms) => Duration(microseconds: (ms * 1000).round());

PointerDownEvent _down(num ms, Offset position, {int pointer = 1}) =>
    PointerDownEvent(timeStamp: _ms(ms), pointer: pointer, position: position);

PointerMoveEvent _move(
  num ms,
  Offset position, {
  int pointer = 1,
  PointerDeviceKind kind = PointerDeviceKind.touch,
  Offset delta = Offset.zero,
}) => PointerMoveEvent(
  timeStamp: _ms(ms),
  pointer: pointer,
  kind: kind,
  position: position,
  delta: delta,
);

PointerUpEvent _up(num ms, Offset position, {int pointer = 1}) =>
    PointerUpEvent(timeStamp: _ms(ms), pointer: pointer, position: position);

const _frame120 = 1000 / 120;

extension on TouchResampler {
  /// The frame of the vsync at [vsync] ms, stamped as the engine stamps it
  /// for `handleBeginFrame`: one [period] later, at the vsync target.
  void frameAt(num vsync, [num period = _frame120]) =>
      sample(_ms(vsync + period), _ms(period));
}

class _Subject {
  final events = <PointerEvent>[];
  var frameRequests = 0;
  late final resampler = TouchResampler(
    dispatch: events.add,
    requestFrame: () => frameRequests++,
  );

  List<PointerMoveEvent> get moves =>
      events.whereType<PointerMoveEvent>().toList();
}

void main() {
  for (final hz in [120, 60]) {
    test('a frame shows where the finger was 10 ms before its vsync, '
        '$hz Hz', () {
      final subject = _Subject();
      final resampler = subject.resampler;
      resampler.add(_down(0, Offset.zero));
      expect(subject.events, hasLength(1), reason: 'the down is not delayed');

      // 1 px/ms downwards, sampled every 4 ms.
      for (var t = 4; t <= 24; t += 4) {
        resampler.add(_move(t, Offset(0, t.toDouble())));
      }
      expect(subject.moves, isEmpty);
      expect(subject.frameRequests, greaterThan(0));

      resampler.frameAt(31, 1000 / hz);
      final moves = subject.moves;
      expect(moves.map((e) => e.timeStamp), [
        for (var t = 4; t <= 20; t += 4) _ms(t),
        _ms(21),
      ]);
      expect(moves.last.position, const Offset(0, 21));
      expect(moves.last.synthesized, isTrue);
      expect(moves.where((e) => e.synthesized), hasLength(1));
      expect(
        moves.fold(Offset.zero, (sum, e) => sum + e.delta),
        moves.last.position,
        reason: 'the deltas add up to the shown position',
      );
      expect(resampler.hasPending, isTrue, reason: 'the 24 ms sample waits');
    });
  }

  test('a frame between two samples moves on without a new one', () {
    final subject = _Subject();
    subject.resampler
      ..add(_down(0, Offset.zero))
      ..add(_move(8, const Offset(0, 8)))
      ..add(_move(24, const Offset(0, 24)))
      ..frameAt(25)
      ..frameAt(30);
    expect(subject.moves.map((e) => (e.timeStamp, e.position.dy)), [
      (_ms(8), 8),
      (_ms(15), 15),
      (_ms(20), 20),
    ]);
  });

  test('without a later sample a frame keeps the newest real one', () {
    final subject = _Subject();
    subject.resampler
      ..add(_down(0, Offset.zero))
      ..add(_move(10, const Offset(0, 10)))
      ..add(_move(20, const Offset(0, 20)))
      ..frameAt(60);
    expect(subject.moves.last.position, const Offset(0, 20));
    expect(subject.moves.any((e) => e.synthesized), isFalse);
  });

  test('an up goes out after the moves still queued, in order', () {
    final subject = _Subject();
    subject.resampler
      ..add(_down(0, Offset.zero))
      ..add(_move(4, const Offset(0, 4)))
      ..add(_move(8, const Offset(0, 8)))
      ..add(_up(9, const Offset(0, 8)));
    expect(subject.events.map((e) => (e.runtimeType, e.timeStamp)), [
      (PointerDownEvent, _ms(0)),
      (PointerMoveEvent, _ms(4)),
      (PointerMoveEvent, _ms(8)),
      (PointerUpEvent, _ms(9)),
    ]);
    expect(subject.events.any((e) => e.synthesized), isFalse);
    expect(subject.resampler.hasPending, isFalse);
  });

  test('two fingers resample at one time, each from its own samples', () {
    final subject = _Subject();
    final resampler = subject.resampler;
    resampler
      ..add(_down(0, Offset.zero))
      ..add(_down(1, const Offset(100, 0), pointer: 2));
    for (var t = 4; t <= 24; t += 4) {
      resampler
        ..add(_move(t, Offset(0, t.toDouble())))
        ..add(_move(t, Offset(100 + t * 2.0, 0), pointer: 2));
    }
    resampler.frameAt(31);
    final resampled = {
      for (final e in subject.moves.where((e) => e.synthesized)) e.pointer: e,
    };
    expect(resampled[1]!.position, const Offset(0, 21));
    expect(resampled[2]!.position, const Offset(142, 0));
    expect(resampled[1]!.timeStamp, resampled[2]!.timeStamp);
    expect(resampled[2]!.delta, const Offset(2, 0));
  });

  test('a mouse, a stylus and a hover go out at once, after queued touch', () {
    final subject = _Subject();
    final resampler = subject.resampler;
    resampler
      ..add(_down(0, Offset.zero))
      ..add(_move(4, const Offset(0, 4)));
    final others = [
      _move(5, const Offset(9, 9), pointer: 7, kind: PointerDeviceKind.mouse),
      _move(6, const Offset(9, 9), pointer: 8, kind: PointerDeviceKind.stylus),
      PointerHoverEvent(timeStamp: _ms(7), position: const Offset(1, 1)),
    ];
    for (final event in others) {
      resampler.add(event);
    }
    expect(subject.events.map((e) => e.timeStamp), [
      for (final t in [0, 4, 5, 6, 7]) _ms(t),
    ]);
    expect(subject.events.skip(2), others);
  });

  test('without frames a move goes out as it comes', () {
    final subject = _Subject();
    subject.resampler
      ..add(_down(0, Offset.zero))
      ..add(_move(4, const Offset(0, 4)))
      ..add(_move(8, const Offset(0, 8)), queue: false);
    expect(subject.moves.map((e) => e.position.dy), [4, 8]);
    expect(subject.resampler.hasPending, isFalse);
  });
}
