import 'dart:io';
import 'dart:math';

/// Anonymous installation credential; never a phone identity or account password.
/// Private app storage only, excluded from resume exports. Sessions stay in memory.
final class GuestCredentialStore {
  GuestCredentialStore({Future<Directory> Function()? rootDirectory})
    : _root = rootDirectory;
  final Future<Directory> Function()? _root;
  Future<String>? _pending;

  Future<File?> _file() async => _root == null
      ? null
      : File(
          '${(await _root()).path}${Platform.pathSeparator}guest_installation_v1.key',
        );

  Future<String> getOrCreate() {
    return _pending ??= _load().catchError((Object error, StackTrace stack) {
      _pending = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<String> _load() async {
    final file = await _file();
    if (file != null && await file.exists()) {
      if (await file.length() != 64) throw const FormatException('游客标识损坏');
      final value = await file.readAsString();
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
        throw const FormatException('游客标识损坏');
      }
      return value;
    }
    final random = Random.secure();
    final value = List.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    if (file != null) {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
    }
    return value;
  }

  Future<void> clear() async {
    try {
      await _pending;
    } on Object {
      /* A corrupt file is still removable. */
    }
    final file = await _file();
    if (file != null) {
      if (await file.exists()) await file.delete();
      final temporary = File('${file.path}.tmp');
      if (await temporary.exists()) await temporary.delete();
    }
    _pending = null;
  }
}
