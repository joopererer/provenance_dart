// ISO 8601 date formatting for provenance metadata (SPEC §8).

/// Formats [dt] as an ISO 8601 string that always carries a timezone.
///
/// A UTC [DateTime] is written with the `Z` suffix; a local [DateTime] is
/// written with its local offset, for example `2026-10-20T15:30:00+02:00`.
///
/// Dart's [DateTime] cannot carry an arbitrary offset, so an offset that was
/// read from a file is preserved by keeping the original text instead of
/// reformatting the value (see `XmpProvenance`).
String formatDateTimeWithTimezone(DateTime dt) {
  if (dt.isUtc) return formatDateTimeUtc(dt);

  final offset = dt.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs();
  final minutes = offset.inMinutes.abs() % 60;

  return '${_datePart(dt)}T${_timePart(dt)}'
      '$sign${_two(hours)}:${_two(minutes)}';
}

/// Formats [dt] as an ISO 8601 UTC string with the `Z` suffix.
String formatDateTimeUtc(DateTime dt) {
  final utc = dt.toUtc();
  return '${_datePart(utc)}T${_timePart(utc)}Z';
}

String _datePart(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-${_two(dt.month)}-${_two(dt.day)}';

String _timePart(DateTime dt) =>
    '${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}';

String _two(int value) => value.toString().padLeft(2, '0');
