// Sense Remote: text, design tokens and helpers of the Host-side connection
// icon and card (prototype Calisma/prototip/uygulama.html, screen 5).

import 'package:flutter/material.dart';

import '../../components/sense_select.dart' show senseUpperTr;
import '../../strings/host_live.dart';
import '../../tokens/sense_tokens.dart';

import '../../../models/server_model.dart';

/// Interface text (Turkish first; the app UI is Turkish for now).
const Map<String, String> kSenseCmText = {
  'brand_bold': 'Sense',
  'brand_light': ' Remote',
  'connected': 'bağlı',
  'waiting': 'bekliyor',
  'ended': 'bitti',
  'hide': 'Gizle',
  'icon_tooltip': 'Sense Remote — bağlı',
  'perm_keyboard': 'klavye · fare',
  'perm_clipboard': 'pano',
  'perm_audio': 'ses',
  'perm_file': 'dosya',
  'perm_restart': 'yeniden başlatma',
  'perm_recording': 'kayıt',
  'perm_block_input': 'giriş kilidi',
  'perm_privacy': 'hayalet mod',
  'request': 'Bu bilgisayara bağlanmak istiyor.',
  'accept': 'Kabul et',
  'reject': 'Reddet',
  'voice_request': 'Sesli görüşme isteği',
  'voice_on': 'Sesli görüşme sürüyor',
  'voice_end': 'Görüşmeyi bitir',
  'chat_empty': 'Sense ekibiyle buradan yazışabilirsiniz.',
  'chat_hint': 'Sense ekibine yaz…',
  'send': 'Gönder',
  'end': 'Bağlantıyı bitir',
  'close': 'Kapat',
  'disconnected': 'Bağlantı bitti.',
};

String senseCmText(String key) => kSenseCmText[key] ?? key;

/// Design tokens (BRAND_CORE §5: black and white, navy→purple light accent).
// Sense Remote (A1b, YH T1): bridge only. Every field is an alias of the one token set
// (tokens/sense_tokens.dart); screens move to SenseColors in their own PRs, then this goes.
class SenseCmTokens {
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const black = SenseColors.bg;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const white = SenseColors.text;
  // Was #1D1D25: the hover tone, not a border.
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const line = SenseColors.hover;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const border = SenseColors.line;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const iconBorder = SenseColors.lineStrong;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const field = SenseColors.surface;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const muted = SenseColors.textMuted;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const soft = SenseColors.textSecondary;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const accent1 = SenseColors.glowStart;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const accent2 = SenseColors.glowEnd;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const live = SenseColors.ok;
  // Off LED (decoration).
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const idle = SenseColors.textDim;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const danger = SenseColors.danger;
  @Deprecated('Sense Remote A1b: use SenseRadii / tokens/sense_tokens.dart')
  static const radius = SenseRadii.categoryLarge;
  @Deprecated('Sense Remote A1b: use SenseRadii / tokens/sense_tokens.dart')
  static const radiusCard = SenseRadii.popup;
  @Deprecated('Sense Remote A1b: use SenseFont / tokens/sense_tokens.dart')
  static const font = SenseFont.family;
  // No token: system fonts after the bundled Poppins.
  @Deprecated('Sense Remote A1b: use SenseFont / tokens/sense_tokens.dart')
  static const fontFallback = ['Segoe UI', 'Helvetica Neue', 'Arial'];
  @Deprecated('Sense Remote A1b: use SenseGradients / tokens/sense_tokens.dart')
  static const gradient = SenseGradients.glow;

  @Deprecated('Sense Remote A1b: use tokens/sense_tokens.dart')
  static TextStyle text(
          {double size = SenseFontSize.bodySmall,
          FontWeight weight = SenseFontWeight.thin,
          Color color = SenseColors.text}) =>
      TextStyle(
          fontFamily: SenseFont.family,
          fontFamilyFallback: fontFallback,
          fontSize: size,
          fontWeight: weight,
          color: color,
          decoration: TextDecoration.none);
}

/// What a connection is for (O6): "ekran", "terminal", "TCP tüneli"…
String senseCmKindText(Client client) {
  if (client.portForward.isNotEmpty) return SenseHostLiveStrings.kindTunnel;
  switch (client.type_()) {
    case ClientType.file:
      return SenseHostLiveStrings.kindFile;
    case ClientType.camera:
      return SenseHostLiveStrings.kindCamera;
    case ClientType.terminal:
      return SenseHostLiveStrings.kindTerminal;
    default:
      return SenseHostLiveStrings.kindScreen;
  }
}

/// Permission pills: only the ones that are on, in a fixed order.
List<String> senseCmPermissions(Client client) => [
      if (client.keyboard) senseCmText('perm_keyboard'),
      if (client.clipboard) senseCmText('perm_clipboard'),
      if (client.audio) senseCmText('perm_audio'),
      if (client.file) senseCmText('perm_file'),
      if (client.restart) senseCmText('perm_restart'),
      if (client.recording) senseCmText('perm_recording'),
      if (client.blockInput) senseCmText('perm_block_input'),
      if (client.privacyMode) senseCmText('perm_privacy'),
    ];

/// The card must open by itself: a peer waits for an answer.
bool senseCmNeedsAttention(Client client) =>
    !client.disconnected && (!client.authorized || client.incomingVoiceCall);

String senseCmInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  // TS-18: Turkish upper case ("ismail" → "İ", "ışık" → "I").
  final letters = words.take(2).map((w) => senseUpperTr(w.characters.first));
  final result = letters.join();
  return result.isEmpty ? '?' : result;
}

