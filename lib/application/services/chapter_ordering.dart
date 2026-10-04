import '../../data/database.dart';

/// The canonical book order: volume number first, then chapter number.
///
/// A chapter's `orderIndex` is only meaningful inside its volume. Sorting a
/// project-wide chapter list by that value alone interleaves chapters from
/// different volumes and was the source of the archive/export mismatch.
abstract final class ChapterOrdering {
  static List<ChapterRow> sort(
    Iterable<ChapterRow> chapters,
    Iterable<VolumeRow> volumes,
  ) {
    final Map<String, VolumeRow> byId = <String, VolumeRow>{
      for (final VolumeRow volume in volumes) volume.id: volume,
    };
    final List<ChapterRow> result = chapters.toList(growable: false);
    result.sort((ChapterRow a, ChapterRow b) {
      final VolumeRow? av = byId[a.volumeId];
      final VolumeRow? bv = byId[b.volumeId];
      final int volumeOrder = (av?.orderIndex ?? 0).compareTo(bv?.orderIndex ?? 0);
      if (volumeOrder != 0) return volumeOrder;
      final int chapterOrder = a.orderIndex.compareTo(b.orderIndex);
      if (chapterOrder != 0) return chapterOrder;
      return a.id.compareTo(b.id);
    });
    return result;
  }
}
