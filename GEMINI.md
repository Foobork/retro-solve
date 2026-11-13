# Global Rules & Guidelines

## Verification & Build
- **Run `flutter analyze` and `flutter test` before creating any local git commit only when Dart code (`lib/`, `test/`) or Flutter configuration has been modified.**
- **Run `flutter build windows --debug` (or target platform build) only when:**
  - `pubspec.yaml` or `pubspec.lock` has been modified.
  - Native platform files (e.g. `windows/`) have been modified.
  - Or before pushing to remote (`git push`).
- For pure Dart changes tested interactively, Hot Reload (`r`) and Hot Restart (`R`) along with passing `flutter analyze` and `flutter test` are sufficient for local commits.

## Git & Deployment
- **Git commits and pushes (`git commit`, `git push`) are permitted when changes are verified with passing tests and ready.**
- **Git commit messages must be concise (single-line summary, avoid verbose multi-line descriptions).**
