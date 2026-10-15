/// Presentation of backend values. Formatting only: nothing here derives or interprets a
/// reading; percentages are shown to at most one decimal. (English only until U-13 is decided.)
library;

const List<String> _weekdays = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
const List<String> _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// "68%" for 68.0, "68.4%" for 68.4.
String formatPercent(double value) => value == value.roundToDouble() ? '${value.toInt()}%' : '${value.toStringAsFixed(1)}%';

/// "31 °C" for 31.0, "31.5 °C" for 31.5 - the value as reported, to at most one decimal.
String formatTemperature(double celsius) => celsius == celsius.roundToDouble() ? '${celsius.toInt()} °C' : '${celsius.toStringAsFixed(1)} °C';

/// "3 minutes" for 180 s, "1 minute" for 60 s, "90 seconds" for 90 s - a duration the backend
/// gave, put into words.
String formatDurationWords(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds >= 60 && seconds % 60 == 0) {
    final minutes = seconds ~/ 60;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }
  return seconds == 1 ? '1 second' : '$seconds seconds';
}

/// "1.5 s" for 1500 ms, "2 s" for 2000 ms - a duration the backend gave in milliseconds.
String formatSeconds(num milliseconds) {
  final seconds = milliseconds / 1000;
  return seconds == seconds.roundToDouble() ? '${seconds.toInt()} s' : '${seconds.toStringAsFixed(1)} s';
}

/// "1,250".
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// "THURSDAY, OCTOBER 1, 2026" - the dashboard's date line, from the phone's clock.
String formatDateHeader(DateTime local) => '${_weekdays[local.weekday - 1]}, ${_months[local.month - 1].toUpperCase()} ${local.day}, ${local.year}';

/// "1 Oct 2026, 21:05" in the phone's time zone.
String formatDateTime(DateTime instant) {
  final local = instant.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.day} ${_months[local.month - 1].substring(0, 3)} ${local.year}, ${two(local.hour)}:${two(local.minute)}';
}

/// A detection label as reported by the device ("leaf_curl_virus") made readable
/// ("Leaf curl virus"). No translation and no renaming.
String formatDetectionLabel(String label) {
  final text = label.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  return text.isEmpty ? label : '${text[0].toUpperCase()}${text.substring(1)}';
}

/// Confidence 0..1 as reported by the device -> "87%".
String formatConfidence(double confidence) => '${(confidence * 100).round()}%';
