import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

Matcher failure(FailureCode code) =>
    isA<AppFailure>().having((value) => value.code, 'stable code', code);

void main() {
  group('Windows directory ownership', () {
    final executable = p.join(
      Directory.current.path,
      'build',
      'ownership_probe_bundle',
      'bundle',
      'bin',
      'ownership_probe.exe',
    );
    late Directory root;
    final owners = <DemoDirectory>[];
    final processes = <Process>[];
    final executors = <QueryExecutor>[];

    setUpAll(() async {
      final compilerTemp = await Directory(
        p.join(Directory.current.path, 'build', 'compiler_temp'),
      ).create(recursive: true);
      final config =
          jsonDecode(
                await File('.dart_tool/package_config.json').readAsString(),
              )
              as Map<String, dynamic>;
      final flutter = Directory.fromUri(
        Uri.parse(config['flutterRoot'] as String),
      );
      final dart = p.join(
        flutter.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dart.exe',
      );
      final result = await Process.run(
        dart,
        [
          'build',
          'cli',
          '-t',
          'tool/ownership_probe.dart',
          '-o',
          'build/ownership_probe_bundle',
        ],
        workingDirectory: Directory.current.path,
        environment: {'TEMP': compilerTemp.path, 'TMP': compilerTemp.path},
      ).timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: 'ownership probe compilation');
      expect(File(executable).existsSync(), isTrue);
    });

    setUp(() async {
      root = await Directory.systemTemp.createTemp('ustc_m0_owner_test_');
    });

    tearDown(() async {
      for (final process in processes) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      processes.clear();
      for (final executor in executors) {
        await executor.close();
      }
      executors.clear();
      for (final owner in owners) {
        await owner.release();
      }
      owners.clear();
      // Resolve and check the full target before recursive deletion. This test
      // never acquires or cleans the persistent default demo directory.
      final resolved = p.windows.normalize(await root.resolveSymbolicLinks());
      final temp = p.windows.normalize(
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(p.windows.isAbsolute(resolved), isTrue);
      expect(p.windows.isWithin(temp, resolved), isTrue);
      expect(p.windows.basename(resolved), startsWith('ustc_m0_owner_test_'));
      await Directory(resolved).delete(recursive: true);
    });

    Future<DemoDirectory> own(String path) async {
      final owner = await DemoDirectory.acquire(path);
      owners.add(owner);
      return owner;
    }

    Future<Process> probe(String mode, String path) async {
      final process = await Process.start(executable, [
        mode,
        path,
      ], workingDirectory: Directory.current.path);
      processes.add(process);
      return process;
    }

    Future<void> junction(String path, String target) async {
      String literal(String value) => "'${value.replaceAll("'", "''")}'";
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'New-Item -ItemType Junction -Path ${literal(path)} '
            '-Target ${literal(target)} | Out-Null',
      ]);
      // Do not surface the shell's paths or native exception text on failure.
      expect(result.exitCode, 0, reason: 'native junction creation');
    }

    test(
      'same process, case and dot aliases cannot obtain a second owner',
      () async {
        final path = p.join(root.path, 'Demo');
        final owner = await own(path);
        expect(owner.isHeld, isTrue);
        expect(p.windows.isAbsolute(owner.path), isTrue);
        for (final alias in [
          path,
          path.toUpperCase(),
          p.join(path, '.', '..', 'Demo'),
        ]) {
          await expectLater(
            DemoDirectory.acquire(alias),
            throwsA(failure(FailureCode.ownerConflict)),
          );
        }
        expect(File(p.join(path, 'm0_demo.sqlite')).existsSync(), isFalse);
        await owner.release();
        await owner.release();
        expect(owner.isHeld, isFalse);
        expect(owner.ensureHeld, throwsA(failure(FailureCode.ownershipLost)));
        await own(path.toUpperCase());
      },
    );

    test(
      'child directory creation is idempotent and rejects files and junctions',
      () async {
        final owner = await own(p.join(root.path, 'demo'));
        final child = owner.createPlainChildDirectory('child');
        for (var i = 0; i < 20; i++) {
          expect(owner.createPlainChildDirectory('child'), child);
        }
        await File(p.join(owner.path, 'file')).writeAsString('synthetic');
        expect(
          () => owner.createPlainChildDirectory('file'),
          throwsA(failure(FailureCode.unsafeDirectory)),
        );
        final outside = await Directory(p.join(root.path, 'outside')).create();
        await junction(p.join(owner.path, 'link'), outside.path);
        expect(
          () => owner.createPlainChildDirectory('link'),
          throwsA(failure(FailureCode.unsafeDirectory)),
        );
        expect(outside.existsSync(), isTrue);
      },
    );

    test('real second process is refused before database creation', () async {
      final path = p.join(root.path, 'demo');
      await own(path);
      final process = await probe('try', path);
      final output = await process.stdout.transform(utf8.decoder).join();
      final errors = await process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 1);
      expect(output.trim(), 'conflict');
      expect(errors, isEmpty);
      expect(File(p.join(path, 'm0_demo.sqlite')).existsSync(), isFalse);
    });

    test('forced process exit releases the real kernel owner', () async {
      final path = p.join(root.path, 'demo');
      final process = await probe('hold', path);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 30)),
        isTrue,
      );
      expect(lines.current, 'ready');
      await expectLater(
        DemoDirectory.acquire(path),
        throwsA(failure(FailureCode.ownerConflict)),
      );
      expect(process.kill(ProcessSignal.sigkill), isTrue);
      await process.exitCode.timeout(const Duration(seconds: 10));
      await lines.cancel();
      expect(await process.stderr.transform(utf8.decoder).join(), isEmpty);
      final owner = await own(path);
      expect(owner.isHeld, isTrue);
    });

    test(
      'native junction in any directory level is rejected before opening',
      () async {
        final target = await Directory(p.join(root.path, 'target')).create();
        final link = p.join(root.path, 'linked');
        await junction(link, target.path);
        try {
          await expectLater(
            DemoDirectory.acquire(link),
            throwsA(failure(FailureCode.unsafeDirectory)),
          );
          await expectLater(
            DemoDirectory.acquire(p.join(link, 'child')),
            throwsA(failure(FailureCode.unsafeDirectory)),
          );
          expect(
            File(p.join(target.path, 'm0_demo.sqlite')).existsSync(),
            isFalse,
          );
          expect(Directory(p.join(target.path, 'child')).existsSync(), isFalse);
        } finally {
          await Link(link).delete();
        }
      },
    );

    test('owner pins block directory and ancestor replacement', () async {
      final ancestor = await Directory(p.join(root.path, 'ancestor')).create();
      final owner = await own(p.join(ancestor.path, 'demo'));
      await expectLater(
        Directory(owner.path).rename(p.join(ancestor.path, 'moved')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        ancestor.rename(p.join(root.path, 'ancestor_moved')),
        throwsA(isA<FileSystemException>()),
      );
      expect(owner.isHeld, isTrue);
    });

    test(
      'all existing database slots reject reparse or non-file assets',
      () async {
        final owner = await own(p.join(root.path, 'demo'));
        final target = await Directory(p.join(root.path, 'target')).create();
        for (final suffix in ['', '-wal', '-shm']) {
          final slot = p.join(owner.path, 'm0_demo.sqlite$suffix');
          await junction(slot, target.path);
          try {
            expect(
              () => openDemoDatabase(owner),
              throwsA(failure(FailureCode.unsafeDirectory)),
            );
          } finally {
            await Link(slot).delete();
          }
          await Directory(slot).create();
          expect(
            () => openDemoDatabase(owner),
            throwsA(failure(FailureCode.unsafeDirectory)),
          );
          await Directory(slot).delete();
        }
      },
    );

    test(
      'released ownership refuses exports and deferred database opening',
      () async {
        final owner = await own(p.join(root.path, 'demo'));
        final executor = openDemoDatabase(owner);
        executors.add(executor);
        await owner.release();
        expect(
          () => openDemoDatabase(owner),
          throwsA(failure(FailureCode.ownershipLost)),
        );
        expect(
          () => executor.ensureOpen(const _DatabaseUser()),
          throwsA(failure(FailureCode.ownershipLost)),
        );
        expect(
          File(p.join(owner.path, 'm0_demo.sqlite')).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'SQLite configuration and ordinary demo files survive reopen',
      () async {
        final path = p.join(root.path, 'demo');
        final owner = await own(path);
        final executor = openDemoDatabase(owner);
        executors.add(executor);
        await executor.ensureOpen(const _DatabaseUser());
        for (final entry in {
          'foreign_keys': 1,
          'journal_mode': 'wal',
          'synchronous': 2,
          'busy_timeout': 3000,
        }.entries) {
          final result = await executor.runSelect('PRAGMA ${entry.key}', []);
          expect(result.single.values.single, entry.value);
        }
        await executor.runCustom(
          'CREATE TABLE synthetic (value INTEGER NOT NULL)',
        );
        await executor.runInsert('INSERT INTO synthetic VALUES (?)', [7]);
        await executor.close();
        executors.remove(executor);
        await owner.release();
        final reopened = await own(path);
        final second = openDemoDatabase(reopened);
        executors.add(second);
        await second.ensureOpen(const _DatabaseUser());
        expect(
          (await second.runSelect(
            'SELECT value FROM synthetic',
            [],
          )).single['value'],
          7,
        );
      },
    );
    test(
      'an existing connection rejects reads and transactions after ownership loss',
      () async {
        final owner = await own(p.join(root.path, 'demo'));
        final executor = openDemoDatabase(owner);
        executors.add(executor);
        await executor.ensureOpen(const _DatabaseUser());
        // Deliberately violate composition order to verify the executor's guard.
        await owner.release();
        expect(
          () => executor.runSelect('SELECT 1', []),
          throwsA(failure(FailureCode.ownershipLost)),
        );
        expect(
          executor.beginTransaction,
          throwsA(failure(FailureCode.ownershipLost)),
        );
        // Cleanup itself must remain available to drain an invalidated owner.
        await executor.close();
        executors.remove(executor);
      },
    );
  }, skip: !Platform.isWindows);
}

final class _DatabaseUser implements QueryExecutorUser {
  const _DatabaseUser();
  @override
  int get schemaVersion => 1;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
