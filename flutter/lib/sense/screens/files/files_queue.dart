// Sense Remote (#155): transfers list of the remote files window (prototype `.fmq`):
// "AKTARIMLAR · N sürüyor · M tamamlandı", one row per job — direction, name and
// route, progress bar (green; orange when stopped), state text, actions. Data is the
// stock JobController (no Rust change).
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../models/file_model.dart';
import '../../sense.dart';
import '../../strings/files.dart';
import 'files_format.dart';

const double _kQueueMaxHeight = 150;

/// What a row says and offers; pure, so it is tested without widgets.
class SenseJobView {
  const SenseJobView({required this.state, required this.percent, required this.status, required this.actions});

  final JobState state;
  final int percent;

  /// Bold part + rest, e.g. ("%42", "11,8 MB/sn · 6 sn kaldı").
  final (String, String) status;

  /// Which buttons the row shows.
  final List<SenseJobAction> actions;

  bool get running => state == JobState.inProgress || state == JobState.none;
  bool get done => state == JobState.done;
  bool get failed => state == JobState.error;
}

enum SenseJobAction { resume, cancel, remove }

SenseJobView senseJobView(JobProgress j) {
  final p = (j.percent * 100).clamp(0, 100).round();
  final pct = SenseFilesStrings.percent(p);
  if (j.type == JobType.deleteFile || j.type == JobType.deleteDir) {
    final done = j.state == JobState.done;
    return SenseJobView(
      state: j.state,
      percent: done ? 100 : p,
      status: j.state == JobState.error
          ? (SenseFilesStrings.stopped, '')
          : (done ? SenseFilesStrings.deleted : SenseFilesStrings.deleting, ''),
      actions: done ? const [] : const [SenseJobAction.remove],
    );
  }
  switch (j.state) {
    case JobState.done:
      final (String, String) st = j.err == 'cancel'
          ? (SenseFilesStrings.cancelled, '')
          : j.err == 'skipped'
              ? (SenseFilesStrings.skipped, '')
              : (SenseFilesStrings.done, j.totalSize > 0 ? senseFileSize(j.totalSize) : '');
      return SenseJobView(state: j.state, percent: 100, status: st, actions: const []);
    case JobState.error:
      return SenseJobView(
        state: j.state,
        percent: p,
        status: (SenseFilesStrings.stopped, pct),
        actions: const [SenseJobAction.remove],
      );
    case JobState.paused:
      return SenseJobView(
        state: j.state,
        percent: p,
        status: (SenseFilesStrings.paused, pct),
        actions: const [SenseJobAction.resume, SenseJobAction.cancel],
      );
    case JobState.none:
      return SenseJobView(
        state: j.state,
        percent: p,
        status: (SenseFilesStrings.waiting, ''),
        actions: const [SenseJobAction.cancel],
      );
    case JobState.inProgress:
      final left = j.speed > 0 && j.totalSize > j.finishedSize
          ? ((j.totalSize - j.finishedSize) / j.speed).ceil().clamp(1, 359999)
          : 0;
      final rest = j.speed > 0
          ? (left > 0
              ? SenseFilesStrings.speedLeft(senseFileSize(j.speed), left)
              : SenseFilesStrings.speed(senseFileSize(j.speed)))
          : '';
      return SenseJobView(
        state: j.state,
        percent: p,
        status: (pct, rest),
        actions: const [SenseJobAction.cancel],
      );
  }
}

class SenseFilesQueue extends StatelessWidget {
  const SenseFilesQueue({super.key, required this.jobs, required this.computer});

  final JobController jobs;

  /// The remote computer's name ("Bu bilgisayar → <ad>").
  final String computer;

  void _act(JobProgress j, SenseJobAction a) {
    switch (a) {
      case SenseJobAction.resume:
        jobs.resumeJob(j.id);
      case SenseJobAction.cancel:
      case SenseJobAction.remove:
        // Stock "Delete": drop the row and cancel the job.
        jobs.jobTable.remove(j);
        jobs.cancelJob(j.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final list = jobs.jobTable.toList();
      final views = [for (final j in list) senseJobView(j)];
      final running = views.where((v) => v.running).length;
      final done = views.where((v) => v.done).length;
      final caps = SenseTextStyles.caps;
      return Container(
        key: const Key('sense-files-queue'),
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.popup),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: SenseColors.line))),
            child: Row(children: [
              Text(senseUpperTr(SenseFilesStrings.transfers), style: caps),
              const SizedBox(width: 8),
              if (list.isNotEmpty)
                Text(SenseFilesStrings.transfersSummary(running, done), style: SenseTextStyles.hint),
              const Spacer(),
              if (done > 0)
                SenseButton(
                  key: const Key('sense-files-clear-done'),
                  label: SenseFilesStrings.clearDone,
                  size: SenseButtonSize.small,
                  onPressed: () => jobs.jobTable.removeWhere((j) => j.state == JobState.done),
                ),
            ]),
          ),
          if (list.isEmpty)
            Padding(
              key: const Key('sense-files-queue-empty'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: SenseFilesStrings.transfersEmptyLead),
                  TextSpan(text: SenseFilesStrings.send, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium)),
                  const TextSpan(text: SenseFilesStrings.transfersEmptyOr),
                  TextSpan(text: SenseFilesStrings.receive, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium)),
                  const TextSpan(text: SenseFilesStrings.transfersEmptyTail),
                ]),
                style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _kQueueMaxHeight),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1, thickness: 1, color: SenseColors.line),
                itemBuilder: (_, i) => _JobRow(job: list[i], view: views[i], computer: computer, onAction: _act),
              ),
            ),
        ]),
      );
    });
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.view, required this.computer, required this.onAction});

  final JobProgress job;
  final SenseJobView view;
  final String computer;
  final void Function(JobProgress, SenseJobAction) onAction;

  @override
  Widget build(BuildContext context) {
    final j = job;
    final down = j.isRemoteToLocal;
    final isDelete = j.type == JobType.deleteFile || j.type == JobType.deleteDir;
    final name = j.fileName.isNotEmpty ? j.fileName : senseBaseName(j.jobName);
    final from = down ? computer : SenseFilesStrings.thisComputer;
    final to = down ? SenseFilesStrings.thisComputer : computer;
    final target = j.to.isNotEmpty ? j.to : j.jobName;
    final statusColor = view.failed
        ? SenseColors.warn
        : view.done
            ? SenseColors.ok
            : SenseColors.text;
    final barColor = view.failed ? SenseColors.warn : SenseColors.ok;
    return Container(
      key: Key('sense-files-job-${j.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(children: [
        SizedBox(
          width: 18,
          child: Tooltip(
            message: isDelete ? SenseFilesStrings.deleting : (down ? SenseFilesStrings.receiving : SenseFilesStrings.sending),
            child: Icon(
              isDelete ? Icons.delete_outline_rounded : (down ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded),
              size: 14,
              color: SenseColors.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 14,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: SenseTextStyles.bodySmall),
            Text.rich(
              TextSpan(children: [
                if (isDelete)
                  TextSpan(text: target)
                else ...[
                  TextSpan(text: '$from '),
                  SenseGlyph.span(SenseGlyphKind.right, size: SenseFontSize.hintSmall, color: SenseColors.textMuted),
                  TextSpan(text: ' ${SenseFilesStrings.routeTail(to, target)}'),
                ],
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 10,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(children: [
                const Positioned.fill(child: ColoredBox(color: SenseColors.raised)),
                FractionallySizedBox(
                  widthFactor: view.percent / 100,
                  heightFactor: 1,
                  child: ColoredBox(color: barColor),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 200,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: view.status.$1,
                  style: SenseTextStyles.of(size: SenseFontSize.hint, weight: SenseFontWeight.medium, color: statusColor)),
              if (view.status.$2.isNotEmpty)
                TextSpan(text: ' · ${view.status.$2}', style: SenseTextStyles.hint),
            ]),
            key: Key('sense-files-job-status-${j.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 168,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            for (final a in view.actions) ...[
              const SizedBox(width: 6),
              SenseButton(
                key: Key('sense-files-job-${a.name}-${j.id}'),
                label: switch (a) {
                  SenseJobAction.resume => SenseFilesStrings.resume,
                  SenseJobAction.cancel => SenseFilesStrings.cancel,
                  SenseJobAction.remove => SenseFilesStrings.remove,
                },
                size: SenseButtonSize.small,
                onPressed: () => onAction(j, a),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
