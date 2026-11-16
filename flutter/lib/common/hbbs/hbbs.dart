import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';

import 'package:flutter_hbb/models/peer_model.dart';

import '../../models/platform_model.dart';

class HttpType {
  static const kAuthReqTypeAccount = "account";
  static const kAuthReqTypeMobile = "mobile";
  static const kAuthReqTypeSMSCode = "sms_code";
  static const kAuthReqTypeEmailCode = "email_code";
  static const kAuthReqTypeTfaCode = "tfa_code";

  static const kAuthResTypeToken = "access_token";
  static const kAuthResTypeEmailCheck = "email_check";
  static const kAuthResTypeTfaCheck = "tfa_check";
}

enum UserStatus { kDisabled, kNormal, kUnverified }

// to-do: The UserPayload does not contain all the fields of the user.
// Is all the fields of the user needed?
class UserPayload {
  String name = '';
  String displayName = '';
  String avatar = '';
  String email = '';
  String note = '';
  String? verifier;
  UserStatus status;
  bool isAdmin = false;

  UserPayload.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '',
        displayName = json['display_name'] ?? '',
        avatar = json['avatar'] ?? '',
        email = json['email'] ?? '',
        note = json['note'] ?? '',
        verifier = json['verifier'],
        status = json['status'] == 0
            ? UserStatus.kDisabled
            : json['status'] == -1
                ? UserStatus.kUnverified
                : UserStatus.kNormal,
        isAdmin = json['is_admin'] == true;

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> map = {
      'name': name,
      'display_name': displayName,
      'avatar': avatar,
      'status': status == UserStatus.kDisabled
          ? 0
          : status == UserStatus.kUnverified
              ? -1
              : 1,
    };
    return map;
  }

  Map<String, dynamic> toGroupCacheJson() {
    final Map<String, dynamic> map = {
      'name': name,
      'display_name': displayName,
    };
    return map;
  }

  String get displayNameOrName {
    return displayName.trim().isEmpty ? name : displayName;
  }
}

class PeerPayload {
  String id = '';
  Map<String, dynamic> info = {};
  int? status;
  String user = '';
  String user_name = '';
  String? device_group_name;
  String note = '';
  // Sense Remote: all project tags of the peer from the panel's `sense`
  // extension; null when the server does not send it (stock behaviour).
  List<SenseProjectRef>? senseProjects;

  PeerPayload.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? '',
        info = (json['info'] is Map<String, dynamic>) ? json['info'] : {},
        status = json['status'],
        user = json['user'] ?? '',
        user_name = json['user_name'] ?? '',
        device_group_name = json['device_group_name'] ?? '',
        note = json['note'] ?? '',
        senseProjects = SenseProjectRef.listFromSense(json['sense']);

  static Peer toPeer(PeerPayload p) {
    return Peer.fromJson({
      "id": p.id,
      'loginName': p.user_name,
      "username": p.info['username'] ?? '',
      "platform": _platform(p.info['os']),
      "hostname": p.info['device_name'],
      "device_group_name": p.device_group_name,
      "note": p.note,
    });
  }

  static String? _platform(dynamic field) {
    if (field == null) {
      return null;
    }
    final fieldStr = field.toString();
    List<String> list = fieldStr.split(' / ');
    if (list.isEmpty) return null;
    final os = list[0];
    switch (os.toLowerCase()) {
      case 'windows':
        return kPeerPlatformWindows;
      case 'linux':
        return kPeerPlatformLinux;
      case 'macos':
        return kPeerPlatformMacOS;
      case 'android':
        return kPeerPlatformAndroid;
      default:
        if (fieldStr.toLowerCase().contains('linux')) {
          return kPeerPlatformLinux;
        }
        return null;
    }
  }
}

class LoginRequest {
  String? username;
  String? password;
  String? id;
  String? uuid;
  bool? autoLogin;
  String? type;
  String? verificationCode;
  String? tfaCode;
  String? secret;

  LoginRequest(
      {this.username,
      this.password,
      this.id,
      this.uuid,
      this.autoLogin,
      this.type,
      this.verificationCode,
      this.tfaCode,
      this.secret});

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    if (username != null) data['username'] = username;
    if (password != null) data['password'] = password;
    if (id != null) data['id'] = id;
    if (uuid != null) data['uuid'] = uuid;
    if (autoLogin != null) data['autoLogin'] = autoLogin;
    if (type != null) data['type'] = type;
    if (verificationCode != null) {
      data['verificationCode'] = verificationCode;
    }
    if (tfaCode != null) data['tfaCode'] = tfaCode;
    if (secret != null) data['secret'] = secret;

    Map<String, dynamic> deviceInfo = {};
    try {
      deviceInfo = jsonDecode(bind.mainGetLoginDeviceInfo());
    } catch (e) {
      debugPrint('Failed to decode get device info: $e');
    }
    data['deviceInfo'] = deviceInfo;
    return data;
  }
}

class LoginResponse {
  String? access_token;
  String? type;
  String? tfa_type;
  String? secret;
  UserPayload? user;

  LoginResponse(
      {this.access_token, this.type, this.tfa_type, this.secret, this.user});

  LoginResponse.fromJson(Map<String, dynamic> json) {
    access_token = json['access_token'];
    type = json['type'];
    tfa_type = json['tfa_type'];
    secret = json['secret'];
    user = json['user'] != null ? UserPayload.fromJson(json['user']) : null;
  }
}

class RequestException implements Exception {
  int statusCode;
  String cause;
  RequestException(this.statusCode, this.cause);

  @override
  String toString() {
    return "RequestException, statusCode: $statusCode, error: $cause";
  }
}

enum ShareRule {
  read(1),
  readWrite(2),
  fullControl(3);

  const ShareRule(this.value);
  final int value;

  static String desc(int v) {
    if (v == ShareRule.read.value) {
      return translate('Read-only');
    }
    if (v == ShareRule.readWrite.value) {
      return translate('Read/Write');
    }
    if (v == ShareRule.fullControl.value) {
      return translate('Full Control');
    }
    return v.toString();
  }

  static String shortDesc(int v) {
    if (v == ShareRule.read.value) {
      return 'R';
    }
    if (v == ShareRule.readWrite.value) {
      return 'RW';
    }
    if (v == ShareRule.fullControl.value) {
      return 'F';
    }
    return v.toString();
  }

  static ShareRule? fromValue(int v) {
    if (v == ShareRule.read.value) {
      return ShareRule.read;
    }
    if (v == ShareRule.readWrite.value) {
      return ShareRule.readWrite;
    }
    if (v == ShareRule.fullControl.value) {
      return ShareRule.fullControl;
    }
    return null;
  }
}

class AbProfile {
  String guid;
  String name;
  String owner;
  String? note;
  dynamic info;
  int rule;

  AbProfile(this.guid, this.name, this.owner, this.note, this.rule, this.info);

  AbProfile.fromJson(Map<String, dynamic> json)
      : guid = json['guid'] ?? '',
        name = json['name'] ?? '',
        owner = json['owner'] ?? '',
        note = json['note'] ?? '',
        info = json['info'],
        rule = json['rule'] ?? 0;
}

class AbTag {
  String name;
  int color;

  AbTag(this.name, this.color);

  AbTag.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '',
        color = json['color'] ?? '';
}

class DeviceGroupPayload {
  String name;
  // Sense Remote: project id and panel sort key from the `sense` extension;
  // null on stock servers. Not written to the group cache.
  SenseProjectRef? sense;

  DeviceGroupPayload(this.name, {this.sense});

  DeviceGroupPayload.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '',
        sense = SenseProjectRef.fromJsonOrNull(json['sense']);

  Map<String, dynamic> toGroupCacheJson() {
    final Map<String, dynamic> map = {
      'name': name,
    };
    return map;
  }
}

// Sense Remote: the Sense panel adds a `sense` object to the device group and
// peer list items (panel contract `client-api/peers.ts`, plan §2.1.6). The
// classes below read it and give the Controller list the panel order and
// multi-project membership. Without `sense` nothing here is used.
class SenseProjectRef {
  final String projectId;
  final String sortKey;

  const SenseProjectRef(this.projectId, this.sortKey);

  static SenseProjectRef? fromJsonOrNull(dynamic json) {
    if (json is! Map) return null;
    final projectId = json['project_id'];
    final sortKey = json['sort_key'];
    if (projectId is! String || projectId.isEmpty) return null;
    return SenseProjectRef(projectId, sortKey is String ? sortKey : '');
  }

  /// Reads `sense.projects` of a peer; null when `sense` is missing.
  static List<SenseProjectRef>? listFromSense(dynamic sense) {
    if (sense is! Map) return null;
    final projects = sense['projects'];
    if (projects is! List) return <SenseProjectRef>[];
    return projects
        .map(fromJsonOrNull)
        .whereType<SenseProjectRef>()
        .toList();
  }
}

/// Sense Remote: panel order of the Controller list (pure, no global state).
class SensePanelOrder {
  // peer id -> position in the panel response (project order, then in-project order)
  final Map<String, int> _peerIndex;
  // peer id -> {project (group) name -> in-project sort key}
  final Map<String, Map<String, String>> _peerKeys;

  SensePanelOrder._(this._peerIndex, this._peerKeys);

  /// True when any device group came with the `sense` extension.
  static bool groupsHaveSense(List<DeviceGroupPayload> groups) =>
      groups.any((g) => g.sense != null);

  /// Null when the server sent no `sense` data (stock behaviour stays).
  /// [peers] must be in response order.
  static SensePanelOrder? build(
      List<DeviceGroupPayload> groups, List<PeerPayload> peers) {
    if (!groupsHaveSense(groups) &&
        !peers.any((p) => p.senseProjects != null)) {
      return null;
    }
    final groupNameById = <String, String>{};
    for (final g in groups) {
      final sense = g.sense;
      if (sense != null) groupNameById[sense.projectId] = g.name;
    }
    final peerIndex = <String, int>{};
    final peerKeys = <String, Map<String, String>>{};
    for (final p in peers) {
      peerIndex.putIfAbsent(p.id, () => peerIndex.length);
      final keys = <String, String>{};
      for (final ref in p.senseProjects ?? const <SenseProjectRef>[]) {
        final name = groupNameById[ref.projectId];
        if (name != null) keys.putIfAbsent(name, () => ref.sortKey);
      }
      // A peer without `sense` keeps its single legacy group.
      if (p.senseProjects == null &&
          (p.device_group_name ?? '').isNotEmpty) {
        keys[p.device_group_name!] = '';
      }
      peerKeys[p.id] = keys;
    }
    return SensePanelOrder._(peerIndex, peerKeys);
  }

  bool knowsPeer(String peerId) => _peerKeys.containsKey(peerId);

  /// Project (group) names the peer belongs to.
  Iterable<String> groupNamesOf(String peerId) =>
      _peerKeys[peerId]?.keys ?? const <String>[];

  /// Panel order. With [groupName] (selected project) the in-project sort key
  /// decides; otherwise the response position. Unknown peers go last, by id.
  int compare(String a, String b, {String? groupName}) {
    if (groupName != null && groupName.isNotEmpty) {
      final ka = _peerKeys[a]?[groupName];
      final kb = _peerKeys[b]?[groupName];
      if (ka != null && kb != null && ka != kb) return ka.compareTo(kb);
    }
    final ia = _peerIndex[a];
    final ib = _peerIndex[b];
    if (ia != null && ib != null) return ia.compareTo(ib);
    if (ia != null) return -1;
    if (ib != null) return 1;
    return a.compareTo(b);
  }
}
