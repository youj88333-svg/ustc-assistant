import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/platform/bundled_knowledge_loader.dart';

void main() {
  group('BundledKnowledgeLoader', () {
    test(
      'loads only the identity-bound catalog and matching body asset',
      () async {
        final fixture = _Fixture.single();

        final edition = await _loader(fixture).load();

        expect(edition.key, fixture.identity.key);
        expect(edition.catalogDigest, fixture.identity.catalogDigest);
        expect(edition.materials, hasLength(1));
        expect(edition.materials.single.key, 'teach-synthetic');
        expect(edition.materials.single.markdown, fixture.markdown);
        expect(fixture.reads, [
          'assets/knowledge/catalog.json',
          'assets/knowledge/teach-synthetic.md',
        ]);
      },
    );

    test(
      'rejects a catalog whose bytes do not match its bundled digest',
      () async {
        final fixture = _Fixture.single();
        final changedCatalog = Uint8List.fromList([
          ...fixture.catalogBytes,
          0x20,
        ]);

        await expectLater(
          _loader(fixture, catalogBytes: changedCatalog).load(),
          throwsA(_failure(PublicFailureCode.sourceSchema)),
        );
        expect(fixture.reads, ['assets/knowledge/catalog.json']);
      },
    );

    test(
      'rejects a body whose bytes do not match the catalog digest',
      () async {
        final fixture = _Fixture.single();

        await expectLater(
          _loader(
            fixture,
            replacements: {
              'assets/knowledge/teach-synthetic.md': Uint8List.fromList(
                utf8.encode('# Changed synthetic body'),
              ),
            },
          ).load(),
          throwsA(_failure(PublicFailureCode.sourceSchema)),
        );
      },
    );

    test(
      'rejects catalog entries that add a material outside the identity',
      () async {
        final fixture = _Fixture(
          identityKeys: const ['teach-synthetic'],
          entries: [
            _entry('teach-synthetic', '# Synthetic body'),
            _entry('finance-extra', '# Extra synthetic body'),
          ],
          bodies: {
            'teach-synthetic': '# Synthetic body',
            'finance-extra': '# Extra synthetic body',
          },
        );

        await expectLater(
          _loader(fixture).load(),
          throwsA(_failure(PublicFailureCode.sourceSchema)),
        );
        expect(fixture.reads, ['assets/knowledge/catalog.json']);
      },
    );

    test(
      'rejects an arbitrary bodyAsset even when the key and digest are valid',
      () async {
        final fixture = _Fixture.single(
          bodyAsset: 'assets/knowledge/outside.md',
        );

        await expectLater(
          _loader(fixture).load(),
          throwsA(_failure(PublicFailureCode.sourceSchema)),
        );
        expect(fixture.reads, ['assets/knowledge/catalog.json']);
      },
    );

    test('rejects a body that exceeds the per-asset byte limit', () async {
      final oversized = 'x' * (256 * 1024 + 1);
      final fixture = _Fixture.single(markdown: oversized);

      await expectLater(
        _loader(fixture).load(),
        throwsA(_failure(PublicFailureCode.resourceLimit)),
      );
    });

    test('reports an oversized catalog as a resource limit', () async {
      final fixture = _Fixture.single();
      final oversizedCatalog = Uint8List.fromList([
        ...fixture.catalogBytes,
        ...List<int>.filled(256 * 1024, 0x20),
      ]);
      final identity = KnowledgeEditionIdentity(
        key: fixture.identity.key,
        catalogDigest: _digest(oversizedCatalog),
        materialKeys: fixture.identity.materialKeys,
      );

      await expectLater(
        _loader(
          fixture,
          catalogBytes: oversizedCatalog,
          identity: identity,
        ).load(),
        throwsA(_failure(PublicFailureCode.resourceLimit)),
      );
      expect(fixture.reads, ['assets/knowledge/catalog.json']);
    });
  });
}

final class _Fixture {
  _Fixture({
    required List<String> identityKeys,
    required List<Map<String, Object?>> entries,
    required Map<String, String> bodies,
  }) : markdown = bodies.values.first,
       catalogBytes = Uint8List.fromList(
         utf8.encode(
           jsonEncode({
             'version': knowledgeEditionVersion,
             'key': 'synthetic-campus-edition-v1',
             'materials': entries,
           }),
         ),
       ),
       assets = {
         for (final entry in bodies.entries)
           'assets/knowledge/${entry.key}.md': Uint8List.fromList(
             utf8.encode(entry.value),
           ),
       } {
    identity = KnowledgeEditionIdentity(
      key: 'synthetic-campus-edition-v1',
      catalogDigest: _digest(catalogBytes),
      materialKeys: List.unmodifiable(identityKeys),
    );
    assets['assets/knowledge/catalog.json'] = catalogBytes;
  }

  factory _Fixture.single({
    String markdown = '# Synthetic guide\n\nSynthetic reviewed content.',
    String bodyAsset = 'assets/knowledge/teach-synthetic.md',
  }) => _Fixture(
    identityKeys: const ['teach-synthetic'],
    entries: [_entry('teach-synthetic', markdown, bodyAsset: bodyAsset)],
    bodies: {'teach-synthetic': markdown},
  );

  late final KnowledgeEditionIdentity identity;
  final String markdown;
  final Uint8List catalogBytes;
  final Map<String, Uint8List> assets;
  final List<String> reads = [];
}

Map<String, Object?> _entry(String key, String markdown, {String? bodyAsset}) =>
    {
      'key': key,
      'bodyAsset': bodyAsset ?? 'assets/knowledge/$key.md',
      'title': 'Synthetic guide $key',
      'provider': 'teach',
      'topic': 'synthetic-topic',
      'audience': 'synthetic-audience',
      'sourceVersion': 'synthetic-v1',
      'articleUrl': 'https://www.teach.ustc.edu.cn/synthetic/article',
      'materialUrl': null,
      'sourceDigest': List<String>.filled(64, 'a').join(),
      'coveredScope': 'Synthetic scope only.',
      'markdownDigest': _digest(utf8.encode(markdown)),
      'reviewVersion': 'synthetic-review-v1',
      'publishedOn': null,
      'updatedOn': null,
      'applicability': 'unknown',
      'quality': 'reviewedContent',
      'sourceDigestKind': 'decoded-html-utf8',
    };

BundledKnowledgeLoader _loader(
  _Fixture fixture, {
  Uint8List? catalogBytes,
  Map<String, Uint8List> replacements = const {},
  KnowledgeEditionIdentity? identity,
}) => BundledKnowledgeLoader(
  identity: identity ?? fixture.identity,
  reader: (key) async {
    fixture.reads.add(key);
    final bytes = key == 'assets/knowledge/catalog.json'
        ? catalogBytes ?? fixture.assets[key]
        : replacements[key] ?? fixture.assets[key];
    if (bytes == null) throw StateError('Unexpected synthetic asset key.');
    return Uint8List.fromList(bytes);
  },
);

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

Matcher _failure(PublicFailureCode code) => isA<PublicFailure>().having(
  (failure) => failure.code,
  'failure code',
  code,
);
