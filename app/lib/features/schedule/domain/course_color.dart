const _coursePalette = <int>[
  0xFF2E6F9E,
  0xFF9B5D24,
  0xFF39765A,
  0xFF8A4F7D,
  0xFF6F6238,
  0xFF3D6D78,
  0xFF8A3F45,
  0xFF536B35,
  0xFF5C5792,
  0xFF8B6B2E,
  0xFF356F6A,
  0xFF77516B,
];

int courseColorValue(String stableSeriesIdentity) {
  var hash = 0x811C9DC5;
  for (final unit in stableSeriesIdentity.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return _coursePalette[hash % _coursePalette.length];
}
