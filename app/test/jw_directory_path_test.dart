import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/jw_directory_path.dart';

void main() {
  group('default JW data directory path', () {
    test('uses USERPROFILE regardless of LOCALAPPDATA', () {
      const expected = r'C:\Users\学生\.ustc-assistant\local_v1';

      expect(
        defaultJwDirectoryPath({
          'USERPROFILE': r'C:\Users\学生',
          'LOCALAPPDATA': r'D:\Other\AppData\Local',
        }),
        expected,
      );
      expect(defaultJwDirectoryPath({'USERPROFILE': r'C:\Users\学生'}), expected);
    });

    test('does not fall back when USERPROFILE is absent or invalid', () {
      final invalidEnvironments = <String, Map<String, String>>{
        'missing USERPROFILE': {
          'LOCALAPPDATA': r'C:\Users\学生\AppData\Local',
          'TEMP': r'C:\Temp',
          'TMP': r'C:\Temp',
        },
        'relative USERPROFILE': {
          'USERPROFILE': r'Users\学生',
          'TEMP': r'C:\Temp',
        },
        'UNC USERPROFILE': {'USERPROFILE': r'\\server\share\学生'},
        'drive-root USERPROFILE': {'USERPROFILE': r'C:\'},
        'USERPROFILE containing NUL': {
          'USERPROFILE': 'C:\\Users\\bad\u0000name',
        },
      };

      for (final entry in invalidEnvironments.entries) {
        expect(
          () => defaultJwDirectoryPath(entry.value),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.code,
              'failure code',
              FailureCode.unsafeDirectory,
            ),
          ),
          reason: entry.key,
        );
      }
    });
  });
}
