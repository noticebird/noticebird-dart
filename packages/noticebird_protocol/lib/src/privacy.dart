/// The kinds of data a client redacts from technical text, in any privacy
/// profile: the categories [PrivacyPatterns] sorts its patterns and `extra`
/// keys into ([PrivacyPatterns.extraKeyViolation]).
enum PrivacyViolation {
  /// A credential — a bearer token, a JWT, or an assigned token, secret,
  /// password, API key or authorization — or an `extra` key that names one.
  secret,

  /// A health value (`glucose: 5.4`), or an `extra` key that names a health
  /// measure.
  medicalData,

  /// An e-mail address, a phone number, a UUID or an IPv4 address, or an
  /// `extra` key that names an identity.
  identifier,
}

/// The patterns of what a client redacts from technical text, as
/// regular-expression sources it builds its redaction from, as the
/// `noticebird` client does for an event's free text and a feedback
/// report's message. Identity the host sends on purpose is not technical
/// text: an e-mail address in `CrashUser.email` or a feedback report's
/// contact goes as it is. Nor is a value the client sends as the host gave
/// it, such as a feedback report's `userContext`, so a host keeps such data
/// out of it.
///
/// Each is matched case-insensitively and is open-ended: none needs a word
/// boundary after its match, so a redaction built from them still removes a
/// value that cutting a text leaves at its end.
abstract final class PrivacyPatterns {
  /// An e-mail address.
  static const email = r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}';

  /// A phone-number-like run of at least ten digits.
  static const phone = r'(?<!\d)\+?\d[\d ()-]{8,}\d(?!\d)';

  /// A UUID of version 1 to 8.
  static const uuid =
      r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}';

  /// An IPv4 address.
  static const ipv4 =
      r'\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}';

  /// A JWT: a JSON header and payload (`eyJ…`) and a signature.
  static const jwt = r'eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+';

  /// A bearer token: `bearer` and the token after it.
  static const bearerToken = r'bearer\s+\S+';

  /// A word a credential is assigned to (`token: …`, `api_key=…`), as a
  /// group.
  static final credentialKey = _group(_credentials, '[_-]');

  /// A word a credential follows, as a group: `bearer` or a [credentialKey].
  static final credentialWord = _group([_bearer, ..._credentials], '[_-]');

  /// A credential: a [credentialKey] assigned a value.
  static final credentialAssignment = '$credentialKey\\s*[:=]\\s*\\S+';

  /// A health measure (`glucose`, `heart rate`), as a group.
  static final healthMeasure = _group(_healthMeasures, '[_ ]');

  /// A health value: a [healthMeasure] assigned a value.
  static final healthValue = '\\b$healthMeasure\\b\\s*[:=]\\s*\\S+';

  /// Every pattern above that a text may not hold.
  static final all = <String>[
    email,
    phone,
    uuid,
    ipv4,
    jwt,
    bearerToken,
    credentialAssignment,
    healthValue,
  ];

  /// The violation an `extra` key is on its own, whatever its value, or null.
  ///
  /// The key is compared lowercased and without anything outside `a-z0-9`,
  /// so `User_ID`, `user-id` and `userId` read alike. A key that contains a
  /// credential word is a [PrivacyViolation.secret], one that contains a
  /// health measure (or `medical`) a [PrivacyViolation.medicalData], and one
  /// that is `name` or `mobile`, contains an identity (`email`, `userid`,
  /// `phone`, `passport`, `nationalid`, …) or has a short personal number as a word of its own
  /// (`bsn`, `ssn`, `iban`: `customerBsn`, `ssn_last4`, `IBAN`, but not
  /// `className`) a [PrivacyViolation.identifier]. Words are split at
  /// anything outside `A-Za-z0-9` and where a capital starts a word.
  static PrivacyViolation? extraKeyViolation(String key) {
    for (final violation in PrivacyViolation.values) {
      if (_isKeyOf(violation, key)) return violation;
    }
    return null;
  }

  static const _bearer = 'bearer';

  // A space is where a term may hold a separator, or none.
  static const _credentials = [
    'token',
    'secret',
    'password',
    'api key',
    'authorization',
  ];
  static const _healthMeasures = [
    'ecg',
    'electrocardiogram',
    'heart rate',
    'glucose',
    'diagnosis',
    'observation',
    'blood pressure',
    'spo2',
  ];

  static final _secretKeys = [_bearer, ..._credentials].map(_key).toList();
  static final _medicalKeys = [..._healthMeasures.map(_key), 'medical'];
  static const _identifierKeys = [
    'email',
    'ipaddress',
    'patientid',
    'userid',
    'username',
    'nationalid',
    'passport',
    'socialsecurity',
    'phone',
    'mobilenumber',
  ];

  // Identities only as the whole key: `mobile` names a phone number, but
  // `isMobile` a layout.
  static const _identifierNames = {'name', 'mobile'};

  // Too short to look for inside a key (`className` holds `ssn`): a word of
  // the key's own.
  static const _identifierWords = {'bsn', 'ssn', 'iban'};

  static String _group(List<String> terms, String separator) =>
      '(?:${terms.map((term) => term.replaceAll(' ', '$separator?')).join('|')})';

  static String _key(String term) => term.replaceAll(' ', '');
}

/// Whether the `extra` key [key] is [violation] on its own.
bool _isKeyOf(PrivacyViolation violation, String key) {
  final normalized = key.toLowerCase().replaceAll(_outsideKey, '');
  return switch (violation) {
    PrivacyViolation.secret => PrivacyPatterns._secretKeys.any(
      normalized.contains,
    ),
    PrivacyViolation.medicalData => PrivacyPatterns._medicalKeys.any(
      normalized.contains,
    ),
    PrivacyViolation.identifier =>
      PrivacyPatterns._identifierNames.contains(normalized) ||
          PrivacyPatterns._identifierKeys.any(normalized.contains) ||
          _keyWords
              .allMatches(key)
              .any(
                (word) => PrivacyPatterns._identifierWords.contains(
                  word[0]!.toLowerCase(),
                ),
              ),
  };
}

final _outsideKey = RegExp('[^a-z0-9]');

/// A word of a key: a run of capitals not followed by a lowercase letter
/// (`IBAN`, the `BSN` of `BSNNumber`), a lowercase word that may start with
/// a capital (`Bsn`, `Number`), or a run of digits.
final _keyWords = RegExp('[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+');
