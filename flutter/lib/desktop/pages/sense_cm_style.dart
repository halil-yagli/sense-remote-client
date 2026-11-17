// Sense Remote: text, design tokens and helpers of the Host-side connection
// icon and card (prototype Calisma/prototip/uygulama.html, screen 5).

import 'package:flutter/material.dart';

import '../../models/server_model.dart';

/// Interface text (Turkish first; the app UI is Turkish for now).
const Map<String, String> kSenseCmText = {
  'brand_bold': 'Sense',
  'brand_light': ' Remote',
  'connected': 'bağlı',
  'waiting': 'bekliyor',
  'ended': 'bitti',
  'hide': 'Gizle',
  'icon_tooltip': 'Sense Remote — bağlı',
  'kind_remote': 'Ekranı görüyor ve yönetiyor',
  'kind_camera': 'Kamerayı görüyor',
  'kind_file': 'Dosya aktarımı',
  'kind_terminal': 'Terminal',
  'kind_port': 'Bağlantı noktası yönlendirme',
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
class SenseCmTokens {
  static const black = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);
  static const line = Color(0xFF1D1D25);
  static const border = Color(0xFF33333D);
  static const iconBorder = Color(0xFF3A3A45);
  static const field = Color(0xFF0A0A0E);
  static const muted = Color(0xFF8E8E98);
  static const soft = Color(0xFFC9C9D1);
  static const accent1 = Color(0xFF020162);
  static const accent2 = Color(0xFF640164);
  static const live = Color(0xFF00FFB6);
  static const idle = Color(0xFF55555F);
  // Sense Remote: white 12 px text on #FF3B4D was 3.5:1; #D81E30 is about
  // 5.1:1 (WCAG AA, design review T3-6).
  static const danger = Color(0xFFD81E30);
  static const radius = 10.0;
  static const radiusCard = 14.0;
  static const font = 'Poppins';
  static const fontFallback = ['Segoe UI', 'Helvetica Neue', 'Arial'];
  static const gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent1, accent2]);

  static TextStyle text(
          {double size = 12,
          FontWeight weight = FontWeight.w300,
          Color color = white}) =>
      TextStyle(
          fontFamily: font,
          fontFamilyFallback: fontFallback,
          fontSize: size,
          fontWeight: weight,
          color: color,
          decoration: TextDecoration.none);
}

/// Label of what the peer is doing on this computer.
String senseCmKindText(Client client) {
  if (client.portForward.isNotEmpty) return senseCmText('kind_port');
  switch (client.type_()) {
    case ClientType.file:
      return senseCmText('kind_file');
    case ClientType.camera:
      return senseCmText('kind_camera');
    case ClientType.terminal:
      return senseCmText('kind_terminal');
    default:
      return senseCmText('kind_remote');
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
  final letters = words.take(2).map((w) => w.characters.first.toUpperCase());
  final result = letters.join();
  return result.isEmpty ? '?' : result;
}

