# Sense Remote — tasarım değerleri üreticisi

Tek kaynak `design/tokens.json` (yol haritası T1–T4, T6, T9; prototip CSS'iyle aynı değerler). Üretici bundan Dart ve CSS yazar: `python tools/sense-tokens/generate.py` (yalnız Python standart kitaplığı, 3.9+).

| Çıktı | Kim kullanır |
| --- | --- |
| `flutter/lib/sense/tokens/tokens.g.dart` | Uygulama; ekranlar `package:flutter_hbb/sense/tokens/sense_tokens.dart` içe aktarır |
| `design/tokens.css` | Panel (`packages/shared/design/tokens.css` kopyası; başlıktaki sürüm + sha256 ile denetlenir) |

- Çıktılar elle düzenlenmez. Değer değişecekse önce prototip, sonra `tokens.json`, sonra üretici; üçü aynı PR'da.
- `python tools/sense-tokens/generate.py --check` çıktılar güncel değilse 1 döner. `flutter test test/sense_tokens_test.dart` de üretilmiş Dart ve CSS'in JSON ile aynı olduğunu ve eşik sınırlarını denetler.
- Adlar lowerCamelCase; CSS'te `--sr-<grup>-<ad>` (ör. `--sr-color-line-strong`, `--sr-motion-popup-open`).
- Eşik yönü: `above` (büyük kötü; değer sınıra eşitse o düzeydedir, "%85 turuncu"), `below` (küçük kötü; "15 fps altı").
