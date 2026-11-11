import 'package:flutter_test/flutter_test.dart';
import 'package:mdsu_rep_hub/src/shared/format.dart';

void main() {
  group('payAmount (Handbook §11: 65 SEK per started half hour, members only)', () {
    test('exact hours', () => expect(payAmount(120, member: true), 260));
    test('started half hour rounds up', () => expect(payAmount(130, member: true), 325));
    test('5 h 10 min = 11 half hours = 715 SEK', () => expect(payAmount(310, member: true), 715));
    test('one minute = one started half hour', () => expect(payAmount(1, member: true), 65));
    test('non-member gets nothing', () => expect(payAmount(600, member: false), 0));
    test('zero minutes', () => expect(payAmount(0, member: true), 0));
    test('custom rate', () => expect(payAmount(60, member: true, halfHourRate: 70), 140));
  });

  group('formatting', () {
    test('fmtMinutes', () {
      expect(fmtMinutes(45), '45m');
      expect(fmtMinutes(60), '1h');
      expect(fmtMinutes(150), '2h 30m');
    });
    test('fmtHours', () {
      expect(fmtHours(120), '2');
      expect(fmtHours(90), '1.5');
    });
  });
}
