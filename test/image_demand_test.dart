import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/image_demand.dart';

const _a = 'https://i.pximg.net/a.jpg';
const _b = 'https://i.pximg.net/b.jpg';

void main() {
  late DateTime now;
  late ImageDemand demand;
  late List<String> held;

  setUp(() {
    now = DateTime(2026, 10, 3);
    demand = ImageDemand(clock: () => now);
    held = [];
    demand.onHeld = held.add;
  });

  test('nothing is wanted by default', () {
    expect(demand.wants(_a), isFalse);
  });

  test('holds are counted', () {
    demand
      ..hold(_a)
      ..hold(_a)
      ..release(_a);
    now = now.add(const Duration(seconds: 5));
    expect(demand.wants(_a), isTrue);
    demand.release(_a);
    now = now.add(const Duration(seconds: 5));
    expect(demand.wants(_a), isFalse);
  });

  test('a released URL stays wanted for the grace period', () {
    demand
      ..hold(_a)
      ..release(_a);
    now = now.add(const Duration(milliseconds: 400));
    expect(demand.wants(_a), isTrue);
    now = now.add(const Duration(milliseconds: 200));
    expect(demand.wants(_a), isFalse);
  });

  test('a re-hold inside the grace period keeps it wanted for good', () {
    demand
      ..hold(_a)
      ..release(_a)
      ..hold(_a);
    now = now.add(const Duration(seconds: 5));
    expect(demand.wants(_a), isTrue);
  });

  test('a timed hold expires', () {
    demand.holdFor(_a, const Duration(seconds: 10));
    now = now.add(const Duration(seconds: 9));
    expect(demand.wants(_a), isTrue);
    now = now.add(const Duration(seconds: 2));
    expect(demand.wants(_a), isFalse);
  });

  test('a shorter timed hold never cuts a longer one', () {
    demand
      ..holdFor(_a, const Duration(seconds: 10))
      ..holdFor(_a, const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 5));
    expect(demand.wants(_a), isTrue);
  });

  test('prefetch windows are replaced per owner and cleared', () {
    final grid = Object();
    final viewer = Object();
    demand
      ..setPrefetchWindow(grid, {_a})
      ..setPrefetchWindow(viewer, {_b});
    expect(demand.wants(_a), isTrue);
    expect(demand.wants(_b), isTrue);

    demand.setPrefetchWindow(grid, {_b});
    expect(demand.wants(_a), isFalse);
    demand.clearPrefetchWindow(viewer);
    expect(demand.wants(_b), isTrue, reason: 'still in the grid window');
    demand.clearPrefetchWindow(grid);
    expect(demand.wants(_b), isFalse);
  });

  test('onHeld fires on the first hold and on every timed hold', () {
    demand
      ..hold(_a)
      ..hold(_a);
    expect(held, [_a]);
    demand
      ..release(_a)
      ..release(_a)
      ..hold(_a);
    expect(held, [_a, _a]);
    demand.holdFor(_b, const Duration(seconds: 1));
    expect(held, [_a, _a, _b]);
  });

  test('expired bookkeeping is pruned once it grows', () {
    for (var i = 0; i < 300; i++) {
      demand
        ..hold('$i')
        ..release('$i');
      now = now.add(const Duration(seconds: 1));
    }
    for (var i = 0; i < 299; i++) {
      expect(demand.wants('$i'), isFalse);
    }
    expect(demand.debugBookkeepingSize, lessThan(300));
  });
}
