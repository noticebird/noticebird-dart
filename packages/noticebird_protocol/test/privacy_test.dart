// PrivacyPatterns: the patterns a client builds its redaction from, and the
// category an `extra` key is on its own.

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

bool _matches(String source, String text) =>
    RegExp(source, caseSensitive: false).hasMatch(text);

void main() {
  const uuid = '7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d';

  test('each pattern matches what it names', () {
    for (final (source, sample) in [
      (PrivacyPatterns.email, 'person@example.com'),
      (PrivacyPatterns.phone, '+31 6 1234 5678'),
      (PrivacyPatterns.uuid, uuid),
      (PrivacyPatterns.ipv4, '10.20.30.40'),
      (PrivacyPatterns.jwt, 'eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl'),
      (PrivacyPatterns.bearerToken, 'Bearer abc'),
      (PrivacyPatterns.credentialAssignment, 'api_key=abc'),
      (PrivacyPatterns.credentialAssignment, 'refresh-token: abc'),
      (PrivacyPatterns.healthValue, 'blood pressure: 120'),
      (PrivacyPatterns.healthValue, 'heart_rate=180'),
    ]) {
      expect(_matches(source, 'at $sample'), isTrue, reason: sample);
      expect(
        PrivacyPatterns.all.any((pattern) => _matches(pattern, sample)),
        isTrue,
        reason: sample,
      );
    }
  });

  test('technical names match none', () {
    for (final text in [
      '#0 PatientRepository.load (package:app/patient_repository.dart:42:7)',
      'route.push',
      'retry_count',
      'v1.2.3',
    ]) {
      expect(
        PrivacyPatterns.all.where((pattern) => _matches(pattern, text)),
        isEmpty,
        reason: text,
      );
    }
  });

  test('the patterns are open-ended', () {
    expect(_matches(PrivacyPatterns.uuid, '${uuid}z'), isTrue);
    expect(_matches(PrivacyPatterns.ipv4, '1.2.3.4z'), isTrue);
  });

  test('the word groups take their separators', () {
    for (final word in ['api_key', 'api-key', 'apikey', 'bearer']) {
      expect(
        _matches('^${PrivacyPatterns.credentialWord}\$', word),
        isTrue,
        reason: word,
      );
    }
    expect(_matches('^${PrivacyPatterns.credentialKey}\$', 'bearer'), isFalse);
    for (final measure in ['heart rate', 'heart_rate', 'heartrate', 'spo2']) {
      expect(
        _matches('^${PrivacyPatterns.healthMeasure}\$', measure),
        isTrue,
        reason: measure,
      );
    }
  });

  test('extraKeyViolation reads a key normalized', () {
    expect(
      PrivacyPatterns.extraKeyViolation('api-key'),
      PrivacyViolation.secret,
    );
    expect(
      PrivacyPatterns.extraKeyViolation('Bearer'),
      PrivacyViolation.secret,
    );
    expect(
      PrivacyPatterns.extraKeyViolation('bloodPressure'),
      PrivacyViolation.medicalData,
    );
    expect(
      PrivacyPatterns.extraKeyViolation('medicalNote'),
      PrivacyViolation.medicalData,
    );
    expect(
      PrivacyPatterns.extraKeyViolation('User_ID'),
      PrivacyViolation.identifier,
    );
    expect(
      PrivacyPatterns.extraKeyViolation('Name'),
      PrivacyViolation.identifier,
    );
    expect(PrivacyPatterns.extraKeyViolation('surname'), isNull);
    expect(PrivacyPatterns.extraKeyViolation('retry_count'), isNull);
  });

  test('a key of two categories is the first, in the order of the enum', () {
    expect(
      PrivacyPatterns.extraKeyViolation('emailPassword'),
      PrivacyViolation.secret,
    );
    expect(
      PrivacyPatterns.extraKeyViolation('glucoseUserId'),
      PrivacyViolation.medicalData,
    );
  });
}
