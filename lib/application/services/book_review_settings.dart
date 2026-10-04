import 'dart:convert';

import '../../data/storage/key_value_store.dart';

class GuestReaderProfile {
  const GuestReaderProfile({
    this.id = '',
    this.name = '客座读者',
    this.provider = '',
    this.model = '',
    this.taste = '普通读者：关注可读性、节奏和情绪是否自然',
    this.enabled = false,
  });

  final String id;
  final String name;
  final String provider;
  final String model;
  final String taste;
  final bool enabled;

  GuestReaderProfile copyWith({
    String? id,
    String? name,
    String? provider,
    String? model,
    String? taste,
    bool? enabled,
  }) => GuestReaderProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        provider: provider ?? this.provider,
        model: model ?? this.model,
        taste: taste ?? this.taste,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'provider': provider,
        'model': model,
        'taste': taste,
        'enabled': enabled,
      };

  factory GuestReaderProfile.fromJson(Map<String, dynamic> json) => GuestReaderProfile(
        id: json['id'] is String ? json['id'] as String : '',
        name: json['name'] is String ? json['name'] as String : '客座读者',
        provider: json['provider'] is String ? json['provider'] as String : '',
        model: json['model'] is String ? json['model'] as String : '',
        taste: json['taste'] is String
            ? json['taste'] as String
            : '普通读者：关注可读性、节奏和情绪是否自然',
        enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
      );
}

class BookReviewSettings {
  const BookReviewSettings({
    this.seniorProvider = 'RWKV Cloud::official-13b',
    this.seniorModel = '',
    this.guestReaders = const <GuestReaderProfile>[],
    this.enableSeniorReview = true,
  });

  final String seniorProvider;
  final String seniorModel;
  final List<GuestReaderProfile> guestReaders;
  final bool enableSeniorReview;

  BookReviewSettings copyWith({
    String? seniorProvider,
    String? seniorModel,
    List<GuestReaderProfile>? guestReaders,
    bool? enableSeniorReview,
  }) => BookReviewSettings(
        seniorProvider: seniorProvider ?? this.seniorProvider,
        seniorModel: seniorModel ?? this.seniorModel,
        guestReaders: guestReaders ?? this.guestReaders,
        enableSeniorReview: enableSeniorReview ?? this.enableSeniorReview,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'seniorProvider': seniorProvider,
        'seniorModel': seniorModel,
        'enableSeniorReview': enableSeniorReview,
        'guestReaders': <Object?>[for (final GuestReaderProfile p in guestReaders) p.toJson()],
      };

  factory BookReviewSettings.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['guestReaders'];
    return BookReviewSettings(
      seniorProvider: json['seniorProvider'] is String
          ? json['seniorProvider'] as String
          : 'RWKV Cloud::official-13b',
      seniorModel: json['seniorModel'] is String ? json['seniorModel'] as String : '',
      enableSeniorReview: json['enableSeniorReview'] is bool
          ? json['enableSeniorReview'] as bool
          : true,
      guestReaders: raw is List
          ? <GuestReaderProfile>[
              for (final Object? item in raw)
                if (item is Map)
                  GuestReaderProfile.fromJson(item.map(
                    (Object? key, Object? value) => MapEntry<String, dynamic>('$key', value),
                  )),
            ]
          : const <GuestReaderProfile>[],
    );
  }
}

class BookReviewSettingsStore {
  const BookReviewSettingsStore(this._store);
  static const String scope = 'ai_config';
  static const String key = 'book_review.settings';
  final Future<KeyValueStore> Function() _store;

  Future<BookReviewSettings> load() async {
    try {
      final String? raw = await (await _store()).readJson(scope, key);
      if (raw == null || raw.isEmpty) return const BookReviewSettings();
      final Object? decoded = jsonDecode(raw);
      return decoded is Map
          ? BookReviewSettings.fromJson(decoded.map(
              (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
            ))
          : const BookReviewSettings();
    } on Object {
      return const BookReviewSettings();
    }
  }

  Future<void> save(BookReviewSettings settings) async {
    await (await _store()).writeJson(scope, key, jsonEncode(settings.toJson()));
  }
}
