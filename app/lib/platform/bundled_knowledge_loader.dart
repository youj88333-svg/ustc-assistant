import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../core/knowledge_contract.dart';
import '../core/public_query_contract.dart';
import '../data/bundled_knowledge_identity.dart';

typedef KnowledgeAssetReader = Future<Uint8List> Function(String key);

/// Fixed packaged text only; no network, filesystem path, shell or OCR API.
final class BundledKnowledgeLoader {
  BundledKnowledgeLoader({
    KnowledgeAssetReader? reader,
    this.identity = bundledKnowledgeIdentity,
  }) : _reader = reader ?? _readBundle;
  final KnowledgeAssetReader _reader;
  final KnowledgeEditionIdentity identity;

  static Future<Uint8List> _readBundle(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<KnowledgeEdition> load() async {
    try {
      final bytes = await _reader('assets/knowledge/catalog.json');
      if (bytes.length > 256 * 1024) {
        throw const PublicFailure(PublicFailureCode.resourceLimit);
      }
      if (sha256.convert(bytes).toString() != identity.catalogDigest) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      final catalog = jsonDecode(utf8.decode(bytes));
      if (catalog is! Map<String, dynamic> ||
          catalog['version'] != knowledgeEditionVersion ||
          catalog['key'] != identity.key ||
          catalog['materials'] is! List) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      final entries = catalog['materials'] as List;
      if (entries.length != identity.materialKeys.length ||
          entries.length > 256) {
        throw const PublicFailure(PublicFailureCode.sourceSchema);
      }
      final keys = <String>{};
      final materials = <KnowledgeMaterial>[];
      for (final value in entries) {
        if (value is! Map<String, dynamic>) {
          throw const PublicFailure(PublicFailureCode.sourceSchema);
        }
        String text(String name) {
          final entry = value[name];
          if (entry is! String || entry.trim().isEmpty || entry.length > 2000) {
            throw const PublicFailure(PublicFailureCode.sourceSchema);
          }
          return entry;
        }

        String? date(String name) {
          if (value[name] == null) return null;
          final result = text(name);
          if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(result)) {
            throw const PublicFailure(PublicFailureCode.sourceSchema);
          }
          return result;
        }

        final key = text('key');
        if (!keys.add(key) ||
            !identity.materialKeys.contains(key) ||
            value['bodyAsset'] != 'assets/knowledge/$key.md' ||
            !RegExp(r'^[a-z0-9-]{1,80}$').hasMatch(key) ||
            value['applicability'] != 'unknown' ||
            value['quality'] != 'reviewedContent' ||
            ![
              'image-bytes',
              'decoded-html-utf8',
            ].contains(value['sourceDigestKind'])) {
          throw const PublicFailure(PublicFailureCode.sourceSchema);
        }
        final body = await _reader('assets/knowledge/$key.md');
        if (body.length > 256 * 1024) {
          throw const PublicFailure(PublicFailureCode.resourceLimit);
        }
        final bodyDigest = text('markdownDigest');
        if (sha256.convert(body).toString() != bodyDigest) {
          throw const PublicFailure(PublicFailureCode.sourceSchema);
        }
        final provider = PublicProvider.values.byName(text('provider'));
        if (provider == PublicProvider.icourse) {
          throw const PublicFailure(PublicFailureCode.sourceSchema);
        }
        materials.add(
          KnowledgeMaterial(
            key: key,
            title: text('title'),
            provider: provider,
            topic: text('topic'),
            audience: text('audience'),
            sourceVersion: text('sourceVersion'),
            articleUrl: Uri.parse(text('articleUrl')),
            materialUrl: value['materialUrl'] == null
                ? null
                : Uri.parse(text('materialUrl')),
            sourceDigest: text('sourceDigest'),
            coveredScope: text('coveredScope'),
            markdown: utf8.decode(body),
            markdownDigest: bodyDigest,
            reviewVersion: text('reviewVersion'),
            publishedOn: date('publishedOn'),
            updatedOn: date('updatedOn'),
          ),
        );
      }
      return KnowledgeEdition(
        key: identity.key,
        catalogDigest: identity.catalogDigest,
        materials: materials,
      );
    } on PublicFailure {
      rethrow;
    } on Object {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
  }
}
