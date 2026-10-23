// Access to the read-only spec submodule's test vectors.
//
// The vectors are read in place from `spec/test-vectors/`; they are never
// copied into this package, so the submodule stays the single source of truth.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Absolute path of `spec/test-vectors`.
final String testVectorsPath = p.normalize(
  p.join(Directory.current.path, 'spec', 'test-vectors'),
);

/// The file of the test vector [name].
File vectorFile(String name) => File(p.join(testVectorsPath, name));

/// Reads the bytes of the test vector [name].
Future<Uint8List> readVector(String name) async =>
    Uint8List.fromList(await vectorFile(name).readAsBytes());

/// Reads `name.expected.json` as the JSON representation of SPEC §7.
Map<String, dynamic> loadExpected(String name) =>
    jsonDecode(vectorFile('$name.expected.json').readAsStringSync())
        as Map<String, dynamic>;

/// Asserts that [actual] contains every field of [expected] with equal value.
///
/// Only the fields present in [expected] are checked, because SPEC §7 allows
/// omitting absent fields. `_none` and `sha256` are spec-only annotations and
/// are skipped.
void expectJsonMatches(
  Map<String, dynamic> actual,
  Map<String, dynamic> expected,
  String label,
) {
  expected.forEach((key, expectedValue) {
    if (key == '_none' || key == 'sha256') return;

    expect(actual.containsKey(key), isTrue, reason: '$label: missing $key');
    final actualValue = actual[key];

    if (expectedValue is Map) {
      expect(actualValue, isA<Map>(), reason: '$label.$key should be a map');
      expectJsonMatches(
        Map<String, dynamic>.from(actualValue as Map),
        Map<String, dynamic>.from(expectedValue),
        '$label.$key',
      );
    } else if (expectedValue is List) {
      expect(actualValue, equals(expectedValue), reason: '$label.$key');
    } else if (key.endsWith('At') || key.endsWith('Date')) {
      expect(
        DateTime.parse(actualValue.toString()),
        equals(DateTime.parse(expectedValue.toString())),
        reason: '$label.$key',
      );
    } else {
      expect(actualValue, equals(expectedValue), reason: '$label.$key');
    }
  });
}
