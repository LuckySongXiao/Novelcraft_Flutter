import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/repositories/volume_repository.dart';
import 'project_content_archive_service.dart';

class ProjectArchiveAuditReport {
  const ProjectArchiveAuditReport({
    required this.projectId,
    required this.projectName,
    required this.archiveEntries,
    required this.volumeCount,
    required this.chapterCount,
    required this.contentCharacters,
    required this.nameMismatches,
    required this.orphanEntries,
  });

  final String projectId;
  final String projectName;
  final int archiveEntries;
  final int volumeCount;
  final int chapterCount;
  final int contentCharacters;
  final int nameMismatches;
  final int orphanEntries;

  bool get isConsistent => nameMismatches == 0 && orphanEntries == 0;
  int get mismatchCount => nameMismatches + orphanEntries;
}

/// Compares the live book project with the generated writing archive.
///
/// The archive intentionally lives in KV storage, so it cannot participate in
/// drift joins. Keeping this audit in one service makes the comparison and the
/// corrective write atomic from the UI's point of view.
class ProjectArchiveAuditService {
  ProjectArchiveAuditService({
    required ProjectRepository projects,
    required VolumeRepository volumes,
    required ChapterRepository chapters,
    required ProjectContentArchiveService archive,
  })  : _projects = projects,
        _volumes = volumes,
        _chapters = chapters,
        _archive = archive;

  final ProjectRepository _projects;
  final VolumeRepository _volumes;
  final ChapterRepository _chapters;
  final ProjectContentArchiveService _archive;

  Future<ProjectArchiveAuditReport?> audit(String projectId) async {
    final String pid = projectId.trim();
    if (pid.isEmpty) return null;
    final ProjectRow? project = await _projects.getById(pid);
    if (project == null) return null;
    final List<VolumeRow> volumes = await _volumes.getByProjectId(pid);
    final List<ChapterRow> chapters = await _chapters.getByProjectId(pid);
    final List<ProjectArchiveEntry> entries = await _archive.listEntries(
      pid,
      limit: ProjectContentArchiveService.maxEntriesPerProject,
    );
    int nameMismatches = 0;
    int orphanEntries = 0;
    for (final ProjectArchiveEntry entry in entries) {
      if (entry.projectId != pid) {
        orphanEntries++;
      } else if (entry.projectName != project.name) {
        nameMismatches++;
      }
      final String? chapterId = entry.metadata['chapterId'];
      if (chapterId != null &&
          chapterId.isNotEmpty &&
          !chapters.any((ChapterRow chapter) => chapter.id == chapterId)) {
        orphanEntries++;
      }
      final String? volumeId = entry.metadata['volumeId'];
      if (volumeId != null &&
          volumeId.isNotEmpty &&
          !volumes.any((VolumeRow volume) => volume.id == volumeId)) {
        orphanEntries++;
      }
    }
    return ProjectArchiveAuditReport(
      projectId: pid,
      projectName: project.name,
      archiveEntries: entries.length,
      volumeCount: volumes.length,
      chapterCount: chapters.length,
      contentCharacters: chapters.fold<int>(
        0,
        (int total, ChapterRow chapter) => total + (chapter.content?.length ?? 0),
      ),
      nameMismatches: nameMismatches,
      orphanEntries: orphanEntries,
    );
  }

  /// Rewrites stale project labels and removes archive records whose chapter or
  /// volume no longer exists. This is safe to run repeatedly.
  Future<int> calibrate(String projectId) async {
    final String pid = projectId.trim();
    if (pid.isEmpty) return 0;
    final ProjectRow? project = await _projects.getById(pid);
    if (project == null) return 0;
    final Set<String> volumeIds =
        (await _volumes.getByProjectId(pid)).map((VolumeRow e) => e.id).toSet();
    final Set<String> chapterIds =
        (await _chapters.getByProjectId(pid)).map((ChapterRow e) => e.id).toSet();
    return _archive.reconcileProject(
      pid,
      projectName: project.name,
      validVolumeIds: volumeIds,
      validChapterIds: chapterIds,
    );
  }
}
