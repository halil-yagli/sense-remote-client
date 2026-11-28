// Sense Remote (Sürüm 12, ST 4): terminal tab keys of the stock terminal window.

/// "peer_3" → ("peer", 3); peer ids may contain "_" (last one splits).
(String, int)? senseTerminalTabKey(String key) {
  final cut = key.lastIndexOf('_');
  if (cut <= 0) return null;
  final n = int.tryParse(key.substring(cut + 1));
  if (n == null) return null;
  return (key.substring(0, cut), n);
}
