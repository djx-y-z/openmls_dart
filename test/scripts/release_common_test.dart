import 'package:test/test.dart';

import '../../scripts/src/release_common.dart';

/// [isResumableRelease] with the state a stage-2 release leaves behind when it
/// dies between its commit and its tag — pubspec already at the requested
/// version, that commit at HEAD, clean tree — so each test overrides only the
/// one field it is about.
bool resumable({
  String requestedVersion = '6.1.0',
  String currentVersion = '6.1.0',
  String headSubject = 'chore: prepare release v6.1.0',
  String expectedSubject = 'chore: prepare release v6.1.0',
  bool treeClean = true,
}) => isResumableRelease(
  requestedVersion: requestedVersion,
  currentVersion: currentVersion,
  headSubject: headSubject,
  expectedSubject: expectedSubject,
  treeClean: treeClean,
);

void main() {
  group('onlyTheseFilesDirty', () {
    const files = ['pubspec.yaml', 'CHANGELOG.md'];

    test('accepts a status listing only the release files', () {
      // What Ctrl-C between the bump and the commit leaves behind.
      expect(
        onlyTheseFilesDirty('M  pubspec.yaml\nM  CHANGELOG.md', files),
        isTrue,
      );
    });

    test('accepts unstaged as well as staged edits', () {
      expect(onlyTheseFilesDirty(' M pubspec.yaml', files), isTrue);
    });

    test('rejects a status naming anything else', () {
      // The suggested `git restore` would discard the other file's work too.
      expect(
        onlyTheseFilesDirty('M  pubspec.yaml\nM  lib/src/thing.dart', files),
        isFalse,
      );
    });

    test('rejects an untracked path', () {
      // `git restore` does not remove untracked files, so the hint would be
      // wrong even though the path is one of ours.
      expect(onlyTheseFilesDirty('?? CHANGELOG.md', files), isFalse);
    });

    test('rejects a rename, whose payload is "old -> new"', () {
      expect(
        onlyTheseFilesDirty('R  pubspec.yaml -> pubspec.old.yaml', files),
        isFalse,
      );
    });

    test('rejects an empty status', () {
      // Never reached in practice (the caller checks cleanliness first), but a
      // "clean" tree must not read as "only our files are dirty".
      expect(onlyTheseFilesDirty('', files), isFalse);
      expect(onlyTheseFilesDirty('\n', files), isFalse);
    });
  });

  group('isResumableRelease', () {
    test('resumes when the release commit is at HEAD on a clean tree', () {
      expect(resumable(), isTrue);
    });

    // Each condition below is on its own sufficient to make resuming wrong: a
    // false positive tags and pushes a commit that is not the release commit,
    // and a tag on origin cannot be taken back.

    test('refuses when the working tree is dirty', () {
      expect(resumable(treeClean: false), isFalse);
    });

    test('refuses when the version bump has not landed', () {
      // The ordinary fresh release: pubspec still on the previous version.
      expect(resumable(currentVersion: '6.0.0'), isFalse);
    });

    test('refuses when HEAD is a later commit than the release commit', () {
      // Someone committed on top of the interrupted release; resuming would
      // tag that commit instead.
      expect(resumable(headSubject: 'fix: typo in the changelog'), isFalse);
    });

    test('refuses when HEAD is the release commit of another version', () {
      expect(
        resumable(
          currentVersion: '6.0.0',
          headSubject: 'chore: prepare release v6.0.0',
        ),
        isFalse,
      );
    });

    test('matches the subject exactly, not by prefix', () {
      // `git log -1 --pretty=%s` yields the subject line alone, so an exact
      // comparison is the right one — a prefix match would accept a commit
      // whose subject merely starts with the release subject.
      expect(
        resumable(headSubject: 'chore: prepare release v6.1.0 (take two)'),
        isFalse,
      );
    });

    test('works for the scoped native-crate subject shape too', () {
      // The two release stages write different subjects; nothing here may
      // assume the package-release one.
      expect(
        resumable(
          requestedVersion: '2.1.0',
          currentVersion: '2.1.0',
          headSubject: 'chore(native_frb): release v2.1.0',
          expectedSubject: 'chore(native_frb): release v2.1.0',
        ),
        isTrue,
      );
    });
  });
}
