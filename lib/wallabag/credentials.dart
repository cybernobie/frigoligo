import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preference_app_group/shared_preference_app_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

part 'credentials.g.dart';

final log = Logger('wallabag.credentials');

@JsonSerializable()
class Credentials {
  Credentials(this.server, this.clientId, this.clientSecret, {this.token});

  final Uri server;
  final String clientId;
  final String clientSecret;
  OAuthToken? token;

  factory Credentials.fromJson(Map<String, dynamic> json) =>
      _$CredentialsFromJson(json);
  Map<String, dynamic> toJson() => _$CredentialsToJson(this);
}

@JsonSerializable()
class OAuthToken {
  OAuthToken(this.accessToken, this.expiresAt, this.refreshToken);

  final String accessToken;
  final int expiresAt;
  final String refreshToken;

  DateTime get expirationDateTime =>
      DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
  bool get isExpired => expirationDateTime.isBefore(DateTime.now());

  factory OAuthToken.fromJson(Map<String, dynamic> json) =>
      _$OAuthTokenFromJson(json);
  Map<String, dynamic> toJson() => _$OAuthTokenToJson(this);
}

const credentialsKey = '${kDebugMode ? 'debug.' : ''}wallabag.credentials';

class CredentialsManager {
  CredentialsManager({this.autoSync = true});

  Future<void> init({Credentials? initial}) async {
    if (Platform.isIOS) await SharedPreferenceAppGroup.setAppGroup(appGroupId);
    if (initial == null && autoSync) await load();
    if (initial != null) credentials = initial;
  }

  bool autoSync = true;

  Credentials? _value;
  Credentials? get credentials => _value;
  set credentials(Credentials? value) {
    _value = value;
    if (autoSync) commit();
  }

  OAuthToken? get token => credentials?.token;
  set token(OAuthToken? value) {
    assert(credentials != null);
    credentials!.token = value;
    if (autoSync) commit();
  }

  bool get canRefreshToken => token != null;
  bool get tokenIsExpired => token!.isExpired;

  Future<String?> _loadString(key) async {
    if (Platform.isIOS) {
      return await SharedPreferenceAppGroup.get(key);
    } else {
      return SharedPreferences.getInstance()
          .then((prefs) => prefs.getString(key));
    }
  }

  Future<void> _saveString(String key, String value) async {
    if (Platform.isIOS) {
      await SharedPreferenceAppGroup.setString(key, value);
    } else {
      await SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(key, value));
    }
  }

  Future<void> load() async {
    log.info('loading credentials...');
    final raw = await _loadString(credentialsKey);
    if (raw != null) {
      credentials = Credentials.fromJson(jsonDecode(raw));
    }
  }

  Future<void> commit() async {
    log.info('saving credentials...');
    if (credentials != null) {
      _saveString(credentialsKey, jsonEncode(credentials!.toJson()));
    }
  }

  Future<void> clear() async {
    log.info('clearing credentials...');
    credentials = null;
    if (Platform.isIOS) {
      await SharedPreferenceAppGroup.remove(credentialsKey);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(credentialsKey);
    }
  }
}
