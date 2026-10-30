import 'package:noticebird/noticebird.dart';
import 'package:flutter_test/flutter_test.dart';

/// A crash report must not be lost because one breadcrumb label was too long.
/// The protocol stays strict — it is the wire contract — so the client clamps
/// on the way in.
void main() {
  test('an over-long tag value is shortened instead of losing the event', () {
    final long = 'x' * 250;
    final crumb = TypedBreadcrumb(
      occurredAt: DateTime.utc(2026, 9, 18),
      category: BreadcrumbCategory.bloc,
      action: 'bloc.change',
      data: {AllowedTag.operation: long},
    ).clamped();

    final value = crumb.data[AllowedTag.operation]! as String;
    expect(value.length, maxTagValueLength);
    expect(value.endsWith('…'), isTrue);

    // The clamped crumb survives the validator that rejected the original.
    expect(crumb.check, returnsNormally);
  });

  test('a value that already fits is left exactly as it was', () {
    const short = 'ProfileEvent · itemId: item-42';
    final crumb = TypedBreadcrumb(
      occurredAt: DateTime.utc(2026, 9, 18),
      category: BreadcrumbCategory.bloc,
      action: 'bloc.change',
      data: const {AllowedTag.operation: short},
    ).clamped();

    expect(crumb.data[AllowedTag.operation], short);
  });
}
