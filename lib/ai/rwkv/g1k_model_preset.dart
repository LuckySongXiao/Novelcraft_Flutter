/// Family prefixes are stable across model releases; resolve full IDs from
/// each endpoint's /models response before sending a chat request.
const String kG1kMainModelFamily = 'rwkv7-g1k-7.2b';
const String kG1kWriterModelFamily = 'rwkv7-g1k-2.9b';
const String kG1kWriterBaseUrl = 'https://api-3b.rwkvos.com/v1';

class G1kBookPreset {
  const G1kBookPreset({
    this.mainModel = '',
    this.writerModel = '',
    this.writerEndpointId = 'official-3b',
  });

  final String mainModel;
  final String writerModel;
  final String writerEndpointId;

  bool get enabled => mainModel.isNotEmpty && writerModel.isNotEmpty;

  Map<String, String> toJson() => {
        'mainModel': mainModel,
        'writerModel': writerModel,
        'writerEndpointId': writerEndpointId,
      };

  factory G1kBookPreset.fromJson(Map<String, dynamic> json) => G1kBookPreset(
        mainModel: json['mainModel'] is String ? json['mainModel'] as String : '',
        writerModel:
            json['writerModel'] is String ? json['writerModel'] as String : '',
        writerEndpointId: json['writerEndpointId'] is String &&
                (json['writerEndpointId'] as String).trim().isNotEmpty
            ? json['writerEndpointId'] as String
            : 'official-3b',
      );
}

String? resolveG1kModel(String selected, Iterable<String> available) {
  final String query = selected.trim().toLowerCase();
  if (query.isEmpty) return null;
  final List<String> exact = available
      .where((id) => id.toLowerCase() == query)
      .toList(growable: false);
  if (exact.isNotEmpty) return exact.first;
  if (query != kG1kMainModelFamily && query != kG1kWriterModelFamily) {
    return null;
  }
  final List<String> matches = available
      .where((id) => id.toLowerCase().startsWith('$query-'))
      .toList(growable: false);
  // Never silently choose between two releases with different behavior.
  return matches.length == 1 ? matches.single : null;
}
