// Sense Remote: name and place of this computer (YH H1, #33, #51, S3; plan §2.6).
// The Host is the one source of its name; the place is chosen from the places of
// its project (no free text). Bridge `main_sense_identity` /
// `main_sense_identity_set` (D3c): the service signs the change to the panel
// and stores it only when the panel took it.
import 'dart:convert';

import '../../../../models/platform_model.dart';

class SensePlace {
  const SensePlace(this.id, this.name);
  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is SensePlace && other.id == id && other.name == name;
  @override
  int get hashCode => Object.hash(id, name);
}

class SenseIdentity {
  const SenseIdentity({
    this.name = '',
    this.placeId = '',
    this.placeName = '',
    this.places = const [],
    this.panelOk,
  });

  static const empty = SenseIdentity();

  final String name;
  final String placeId;
  final String placeName;
  final List<SensePlace> places;

  /// Panel reachable; null = the bridge does not say (the screen falls back to
  /// the connection server state).
  final bool? panelOk;

  SenseIdentity copyWith({String? name, String? placeId, String? placeName}) => SenseIdentity(
        name: name ?? this.name,
        placeId: placeId ?? this.placeId,
        placeName: placeName ?? this.placeName,
        places: places,
        panelOk: panelOk,
      );

  /// `{name, location_id, location_name, locations:[{id,name}], panel:"ok"|"unreachable"}`.
  factory SenseIdentity.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return empty;
      String str(Object? o) => o is String ? o.trim() : '';
      final places = <SensePlace>[];
      final list = v['locations'];
      if (list is List) {
        for (final p in list) {
          if (p is Map && str(p['name']).isNotEmpty) places.add(SensePlace(str(p['id']), str(p['name'])));
        }
      }
      final panel = v['panel'];
      return SenseIdentity(
        name: str(v['name']),
        placeId: str(v['location_id']),
        placeName: str(v['location_name']),
        places: places,
        panelOk: panel == 'ok' ? true : (panel == 'unreachable' ? false : null),
      );
    } catch (_) {
      return empty;
    }
  }
}

/// Error code of `main_sense_identity_set`; null = saved.
String? senseIdentitySetError(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is Map && v['ok'] == true) return null;
    final e = v is Map ? v['error'] : null;
    return e is String && e.isNotEmpty ? e : 'other';
  } catch (_) {
    return 'other';
  }
}

abstract class SenseIdentityBackend {
  Future<String> identity();
  Future<String> setIdentity(String name, String placeId);
}

class SenseIdentityBridge implements SenseIdentityBackend {
  const SenseIdentityBridge();

  // D3c: `--server` answers (stored name / place, the panel's place list, panel state).
  @override
  Future<String> identity() => bind.mainSenseIdentity();

  // D3c: `--server` signs the change to the panel with the device key, then stores it.
  @override
  Future<String> setIdentity(String name, String placeId) =>
      bind.mainSenseIdentitySet(name: name, locationId: placeId);
}
