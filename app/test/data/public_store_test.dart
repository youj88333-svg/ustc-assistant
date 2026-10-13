import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('PublicStore curated knowledge', () {
    test(
      'issued empty knowledge result loses delivery authority after clear',
      () async {
        final store = await _openStore(_identity(['teach/unused']));
        final result = await store.publicStore.searchKnowledge('合成无匹配');
        await store.publicStore.ensurePublicResult(result);
        await expectLater(
          store.publicStore.ensurePublicResult(
            PublicQueryResult(
              coverage: result.coverage,
              candidates: result.candidates,
            ),
          ),
          throwsA(
            isA<PublicFailure>().having(
              (e) => e.code,
              'code',
              PublicFailureCode.staleReference,
            ),
          ),
        );
        await store.publicStore.clearKnowledge(confirmed: true);
        await expectLater(
          store.publicStore.ensurePublicResult(result),
          throwsA(
            isA<PublicFailure>().having(
              (e) => e.code,
              'code',
              PublicFailureCode.staleReference,
            ),
          ),
        );
      },
    );
    test(
      'searches Chinese terms and returns bounded reviewed evidence',
      () async {
        final identity = _identity([
          'teach/course-selection',
          'finance/tuition',
        ]);
        final store = await _openStore(identity);
        final selection = _material(
          key: 'teach/course-selection',
          title: '本科选课流程',
          provider: PublicProvider.teach,
          topic: '选课流程',
          audience: '本科生',
          sourceVersion: '2026-秋季',
          coveredScope: '本科生常规选课、退课和审核流程',
          markdown: '''# 本科选课流程

学生查询课程后申请选课，系统检查成绩和时间冲突。

## 退课审核

学生提交退课申请，任课教师审核后由教务部门更新结果。''',
          reviewVersion: 'review-2026-09',
          publishedOn: '2026-08-20',
          updatedOn: '2026-09-02',
        );
        final tuition = _material(
          key: 'finance/tuition',
          title: '学费缴纳说明',
          provider: PublicProvider.finance,
          topic: '学费缴纳',
          audience: '全体学生',
          sourceVersion: '2026-秋季',
          coveredScope: '常规学费缴纳渠道和时间',
          markdown: '''# 学费缴纳说明

学生通过财务平台查询缴费状态。''',
          reviewVersion: 'review-2026-09',
        );
        await _loadDone(store, identity, [selection, tuition]);

        final twoCharacter = await store.publicStore.searchKnowledge('成绩');
        expect(twoCharacter.candidates, hasLength(1));
        expect(twoCharacter.candidates.single.title, selection.title);
        expect(twoCharacter.candidates.single.snippet, contains('成绩'));

        final multipleTerms = await store.publicStore.searchKnowledge('退课 审核');
        expect(multipleTerms.candidates, hasLength(1));
        expect(multipleTerms.candidates.single.title, selection.title);

        final filtered = await store.publicStore.searchKnowledge(
          '学生',
          provider: PublicProvider.teach,
          topic: '选课流程',
          audience: '本科生',
          version: '2026-秋季',
        );
        expect(filtered.candidates, hasLength(1));
        final evidence = filtered.candidates.single.evidence;
        expect(evidence.origin, EvidenceOrigin.localKnowledge);
        expect(evidence.provider, PublicProvider.teach);
        expect(evidence.sourceVersion, '2026-秋季');
        expect(evidence.audience, '本科生');
        expect(evidence.coveredScope, '本科生常规选课、退课和审核流程');
        expect(evidence.quality, EvidenceQuality.reviewedContent);
        expect(evidence.revision, isNotEmpty);
        expect(evidence.locator, '本科选课流程');
        expect(evidence.publishedOn, '2026-08-20');
        expect(evidence.updatedOn, '2026-09-02');

        final otherProvider = await store.publicStore.searchKnowledge(
          '学生',
          provider: PublicProvider.finance,
        );
        expect(otherProvider.candidates, hasLength(1));
        expect(otherProvider.candidates.single.title, tuition.title);
      },
    );

    test(
      'binds every target revision before a ticket can finish the edition',
      () async {
        final identity = _identity(['teach/first', 'teach/second']);
        final store = await _openStore(identity);
        final first = _material(
          key: 'teach/first',
          title: '第一份材料',
          markdown: '# 第一份材料\n\n原始校核正文。',
        );
        final second = _material(
          key: 'teach/second',
          title: '第二份材料',
          markdown: '# 第二份材料\n\n另一个已校核正文。',
        );
        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [first, second]),
        );

        expect(
          await store.publicStore.acceptKnowledgeMaterial(ticket, first),
          isTrue,
        );
        for (var replay = 0; replay < 4; replay++) {
          expect(
            await store.publicStore.acceptKnowledgeMaterial(ticket, first),
            isTrue,
          );
        }
        expect(ticket.accepted, 1);
        expect(ticket.unchanged, 0);
        expect((await store.publicStore.inspectKnowledge()).loading, isTrue);
        expect((await store.publicStore.inspectKnowledge()).edition, isNull);
        await expectLater(
          store.publicStore.finishKnowledgeLoad(
            ticket,
            KnowledgeLoadState.done,
          ),
          throwsA(_publicFailure(PublicFailureCode.sourceSchema)),
        );

        final wrongRevision = _material(
          key: first.key,
          title: first.title,
          markdown: '# 第一份材料\n\n同一键的另一版正文。',
        );
        await expectLater(
          store.publicStore.acceptKnowledgeMaterial(ticket, wrongRevision),
          throwsA(_publicFailure(PublicFailureCode.sourceSchema)),
        );

        expect(
          await store.publicStore.acceptKnowledgeMaterial(ticket, second),
          isTrue,
        );
        final outcome = await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.done,
        );
        expect(outcome.accepted, 2);
        expect(outcome.unchanged, 0);
        expect(outcome.total, 2);
        expect(outcome.state, KnowledgeLoadState.done);
        final summary = await store.publicStore.inspectKnowledge();
        expect(summary.edition, identity.key);
        expect(summary.loadCount, 1);
        expect(summary.materialCount, 2);
      },
    );

    test(
      'a second identical edition is unchanged and keeps existing references',
      () async {
        final identity = _identity(['teach/one', 'finance/two']);
        final store = await _openStore(identity);
        final one = _material(
          key: 'teach/one',
          title: '校内办事指南',
          markdown: '# 校内办事指南\n\n学生查询办事指南和审核进度。',
        );
        final two = _material(
          key: 'finance/two',
          title: '财务办事指南',
          provider: PublicProvider.finance,
          markdown: '# 财务办事指南\n\n学生查询缴费和发票说明。',
        );
        await _loadDone(store, identity, [one, two]);
        final before = await store.publicStore.searchKnowledge('办事指南');
        expect(before.candidates, hasLength(2));

        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [one, two]),
        );
        for (final material in [one, one, two]) {
          expect(
            await store.publicStore.acceptKnowledgeMaterial(ticket, material),
            isFalse,
          );
        }
        expect(ticket.accepted, 0);
        expect(ticket.unchanged, 2);
        final outcome = await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.done,
        );
        expect(outcome.accepted, 0);
        expect(outcome.unchanged, 2);

        final after = await store.publicStore.searchKnowledge('办事指南');
        expect(after.candidates, hasLength(2));
        final loadedFacts = await _count(
          store,
          'knowledge_audit',
          "action='loaded'",
        );
        expect(loadedFacts, 2);
        final summary = await store.publicStore.inspectKnowledge();
        expect(summary.materialCount, 2);
        expect(summary.loadCount, 2);
      },
    );

    test(
      'updated reviewed text with the same source digest replaces the old revision',
      () async {
        final identity = _identity(['teach/reviewed']);
        final sourceDigest = fingerprintBytes('synthetic original page bytes');
        final store = await _openStore(identity);
        final original = _material(
          key: 'teach/reviewed',
          title: '经校核指南',
          sourceDigest: sourceDigest,
          markdown: '# 经校核指南\n\n原校核内容包含旧词条。',
          reviewVersion: 'review-1',
        );
        await _loadDone(store, identity, [original]);
        final oldMatch = await store.publicStore.searchKnowledge('旧词条');
        expect(oldMatch.candidates, hasLength(1));
        final oldReference = oldMatch.candidates.single.reference;
        final oldRevision = oldMatch.candidates.single.evidence.revision;

        final revised = _material(
          key: original.key,
          title: original.title,
          sourceDigest: sourceDigest,
          markdown: '# 经校核指南\n\n更新后的校核内容包含新词条。',
          reviewVersion: 'review-2',
        );
        expect(revised.sourceDigest, original.sourceDigest);
        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [revised]),
        );
        expect(
          await store.publicStore.acceptKnowledgeMaterial(ticket, revised),
          isTrue,
        );
        await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.done,
        );

        await expectLater(
          store.publicStore.readKnowledgeMaterial(oldReference),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        expect(
          (await store.publicStore.searchKnowledge('旧词条')).candidates,
          isEmpty,
        );
        final newMatch = await store.publicStore.searchKnowledge('新词条');
        expect(newMatch.candidates, hasLength(1));
        expect(
          newMatch.candidates.single.evidence.revision,
          isNot(oldRevision),
        );
      },
    );

    test(
      'checkpoint failure rolls back material, sections, receipt, audit and ticket counts',
      () async {
        final identity = _identity(['teach/rollback']);
        var failCheckpoint = false;
        final store = await _openStore(
          identity,
          onKnowledgeCheckpoint: () async {
            if (failCheckpoint) {
              throw StateError('synthetic checkpoint failure');
            }
          },
        );
        final original = _material(
          key: 'teach/rollback',
          title: '回滚指南',
          markdown: '# 回滚指南\n\n已提交的旧正文。',
        );
        await _loadDone(store, identity, [original]);
        final beforeSummary = await store.publicStore.inspectKnowledge();
        final beforeAudits = await _count(
          store,
          'knowledge_audit',
          "action='loaded'",
        );
        final revised = _material(
          key: original.key,
          title: original.title,
          markdown: '# 回滚指南\n\n不能提交的新正文。\n\n## 第二节\n\n新片段也必须回滚。',
          reviewVersion: 'review-2',
        );
        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [revised]),
        );
        failCheckpoint = true;
        await expectLater(
          store.publicStore.acceptKnowledgeMaterial(ticket, revised),
          throwsA(_publicFailure(PublicFailureCode.storageFailed)),
        );

        final afterSummary = await store.publicStore.inspectKnowledge();
        expect(afterSummary.materialCount, beforeSummary.materialCount);
        expect(afterSummary.sectionCount, beforeSummary.sectionCount);
        expect(afterSummary.loadCount, beforeSummary.loadCount);
        expect(ticket.accepted, 0);
        expect(ticket.unchanged, 0);
        expect(
          await _count(store, 'knowledge_audit', "action='loaded'"),
          beforeAudits,
        );
        final receipt = await store
            .customSelect(
              'SELECT result FROM knowledge_load_items WHERE operation_id=? AND material_key=?',
              variables: [
                Variable.withString(ticket.id),
                Variable.withString(revised.key),
              ],
            )
            .getSingle();
        expect(receipt.read<String?>('result'), isNull);
        final load = await store
            .customSelect(
              'SELECT accepted,unchanged FROM knowledge_loads WHERE operation_id=?',
              variables: [Variable.withString(ticket.id)],
            )
            .getSingle();
        expect(load.read<int>('accepted'), 0);
        expect(load.read<int>('unchanged'), 0);
        expect(
          (await store.publicStore.searchKnowledge('旧正文')).candidates,
          hasLength(1),
        );
        expect(
          (await store.publicStore.searchKnowledge('新正文')).candidates,
          isEmpty,
        );

        failCheckpoint = false;
        await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.failed,
          failure: PublicFailureCode.storageFailed,
        );
      },
    );

    test(
      'a failed transaction send rolls back accepted content and its receipt',
      () async {
        final identity = _identity(['teach/commit-failure']);
        final fault = _CommitFault();
        final store = await _openStore(
          identity,
          executor: _CommitFaultExecutor(NativeDatabase.memory(), fault),
        );
        final original = _material(
          key: 'teach/commit-failure',
          title: '提交故障指南',
          markdown: '# 提交故障指南\n\n此前已提交的正文。',
        );
        await _loadDone(store, identity, [original]);
        final beforeSummary = await store.publicStore.inspectKnowledge();
        final beforeAudits = await _count(
          store,
          'knowledge_audit',
          "action='loaded'",
        );
        final originalReference = (await store.publicStore.searchKnowledge(
          '此前已提交',
        )).candidates.single.reference;

        final revised = _material(
          key: original.key,
          title: original.title,
          markdown: '# 提交故障指南\n\n提交失败后必须回滚的新正文。\n\n## 新片段\n\n不得留下的段落。',
          reviewVersion: 'review-2',
        );
        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [revised]),
        );
        fault.failNextSend = true;
        await expectLater(
          store.publicStore.acceptKnowledgeMaterial(ticket, revised),
          throwsA(_publicFailure(PublicFailureCode.storageFailed)),
        );
        expect(fault.injectedFailures, 1);

        final afterSummary = await store.publicStore.inspectKnowledge();
        expect(afterSummary.materialCount, beforeSummary.materialCount);
        expect(afterSummary.sectionCount, beforeSummary.sectionCount);
        expect(afterSummary.loadCount, beforeSummary.loadCount);
        expect(ticket.accepted, 0);
        expect(ticket.unchanged, 0);
        expect(
          await _count(store, 'knowledge_audit', "action='loaded'"),
          beforeAudits,
        );
        final materialRow = await store
            .customSelect(
              'SELECT markdown FROM knowledge_materials WHERE material_key=?',
              variables: [Variable.withString(original.key)],
            )
            .getSingle();
        expect(materialRow.read<String>('markdown'), original.markdown);
        final sectionRow = await store
            .customSelect(
              'SELECT heading,markdown FROM knowledge_sections WHERE material_key=?',
              variables: [Variable.withString(original.key)],
            )
            .getSingle();
        expect(sectionRow.read<String>('heading'), '提交故障指南');
        expect(sectionRow.read<String>('markdown'), original.markdown);
        final item = await store
            .customSelect(
              'SELECT result FROM knowledge_load_items WHERE operation_id=? AND material_key=?',
              variables: [
                Variable.withString(ticket.id),
                Variable.withString(revised.key),
              ],
            )
            .getSingle();
        expect(item.read<String?>('result'), isNull);
        final load = await store
            .customSelect(
              'SELECT accepted,unchanged FROM knowledge_loads WHERE operation_id=?',
              variables: [Variable.withString(ticket.id)],
            )
            .getSingle();
        expect(load.read<int>('accepted'), 0);
        expect(load.read<int>('unchanged'), 0);
        final originalRead = await store.publicStore.readKnowledgeMaterial(
          originalReference,
        );
        expect(originalRead.document!.markdown, original.markdown);
        expect(
          (await store.publicStore.searchKnowledge('此前已提交')).candidates,
          hasLength(1),
        );
        expect(
          (await store.publicStore.searchKnowledge('必须回滚的新正文')).candidates,
          isEmpty,
        );

        final outcome = await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.failed,
          failure: PublicFailureCode.storageFailed,
        );
        expect(outcome.accepted, 0);
        expect(outcome.unchanged, 0);
        expect(outcome.hasCommittedChanges, isFalse);
        expect(outcome.state, KnowledgeLoadState.failed);
        expect((await store.publicStore.inspectKnowledge()).materialCount, 1);
      },
    );

    test(
      'a failed begin commit leaves no ghost load and the next begin can proceed',
      () async {
        final identity = _identity(['teach/begin-failure']);
        final fault = _CommitFault();
        final store = await _openStore(
          identity,
          executor: _CommitFaultExecutor(NativeDatabase.memory(), fault),
        );

        fault.failNextSend = true;
        await expectLater(
          store.publicStore.beginKnowledgeLoad(),
          throwsA(_publicFailure(PublicFailureCode.storageFailed)),
        );
        expect(fault.injectedFailures, 1);
        expect((await store.publicStore.inspectKnowledge()).loading, isFalse);
        expect(await _count(store, 'knowledge_loads'), 0);

        final ticket = await store.publicStore.beginKnowledgeLoad();
        expect((await store.publicStore.inspectKnowledge()).loading, isTrue);
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [
            _material(
              key: 'teach/begin-failure',
              title: '重新开始的加载',
              markdown: '# 重新开始的加载\n\n没有遗留忙碌状态。',
            ),
          ]),
        );
        expect(await _count(store, 'knowledge_loads'), 1);
        final outcome = await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.failed,
          failure: PublicFailureCode.cancelled,
        );
        expect(outcome.accepted, 0);
        expect(outcome.unchanged, 0);
        expect((await store.publicStore.inspectKnowledge()).loading, isFalse);
      },
    );

    test(
      'cancelling after a commit preserves committed content and reports a partial batch',
      () async {
        final identity = _identity(['teach/committed', 'teach/pending']);
        final store = await _openStore(identity);
        final committed = _material(
          key: 'teach/committed',
          title: '已提交资料',
          markdown: '# 已提交资料\n\n取消之前已事务提交。',
        );
        final pending = _material(
          key: 'teach/pending',
          title: '尚未提交资料',
          markdown: '# 尚未提交资料\n\n取消后不写入。',
        );
        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [committed, pending]),
        );
        expect(
          await store.publicStore.acceptKnowledgeMaterial(ticket, committed),
          isTrue,
        );
        await store.publicStore.cancelKnowledgeLoad();
        final outcome = await store.publicStore.finishKnowledgeLoad(
          ticket,
          KnowledgeLoadState.cancelled,
        );
        expect(outcome.state, KnowledgeLoadState.cancelled);
        expect(outcome.accepted, 1);
        expect(outcome.unchanged, 0);
        expect(outcome.total, 2);
        expect(outcome.hasCommittedChanges, isTrue);
        expect(
          (await store.publicStore.searchKnowledge('事务提交')).candidates,
          hasLength(1),
        );
        expect(
          (await store.publicStore.searchKnowledge('取消后不写入')).candidates,
          isEmpty,
        );
      },
    );

    test(
      'clear cancels in-flight writes while keeping independent JW and Young facts',
      () async {
        final identity = _identity(['teach/clear']);
        final store = await _openStore(identity);
        final original = _material(
          key: 'teach/clear',
          title: '待清理指南',
          markdown: '# 待清理指南\n\n清理前可查询。',
        );
        await _loadDone(store, identity, [original]);
        final oldReference = (await store.publicStore.searchKnowledge(
          '清理前',
        )).candidates.single.reference;
        final revised = _material(
          key: original.key,
          title: original.title,
          markdown: '# 待清理指南\n\n在途的新正文不能越过清库。',
          reviewVersion: 'review-2',
        );
        final ticket = await store.publicStore.beginKnowledgeLoad();
        await store.publicStore.bindKnowledgeEdition(
          ticket,
          _edition(identity, [revised]),
        );

        // These synthetic source facts stand in for data owned by the two school
        // stores. Clearing curated knowledge must leave their rows alone.
        await store.customStatement(
          'INSERT INTO jw_events '
          '(external_id,kind,semester_id,title,starts_at,ends_at,presence,version) '
          "VALUES ('synthetic-retained-jw','course',202610,'合成教务课程',1,2,'observed',1)",
        );
        await store.customStatement(
          'INSERT INTO young_events '
          '(external_id,item_id,title,place,starts_at,ends_at,presence,version) '
          "VALUES ('synthetic-retained-young','synthetic-item','合成个人日程','',1,2,'observed',1)",
        );

        await store.publicStore.clearKnowledge(confirmed: true);
        await expectLater(
          store.publicStore.acceptKnowledgeMaterial(ticket, revised),
          throwsA(_publicFailure(PublicFailureCode.cancelled)),
        );
        await expectLater(
          store.publicStore.readKnowledgeMaterial(oldReference),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        final summary = await store.publicStore.inspectKnowledge();
        expect(summary.materialCount, 0);
        expect(summary.sectionCount, 0);
        expect(summary.loading, isFalse);
        expect(summary.edition, isNull);
        expect(summary.loadCount, 0);
        expect(await _count(store, 'jw_events'), 1);
        expect(await _count(store, 'young_events'), 1);
        final jw = await store
            .customSelect('SELECT title FROM jw_events')
            .getSingle();
        final young = await store
            .customSelect('SELECT title FROM young_events')
            .getSingle();
        expect(jw.read<String>('title'), '合成教务课程');
        expect(young.read<String>('title'), '合成个人日程');
      },
    );

    test(
      'long material can be read through a stable cursor and invalidated by clear',
      () async {
        final identity = _identity(['teach/long-one', 'teach/long-two']);
        final store = await _openStore(identity);
        String longMarkdown(String title) =>
            '# $title\n\n${List<String>.filled(13000, '长').join()}尾部唯一标记。';
        final first = _material(
          key: 'teach/long-one',
          title: '长章节一',
          markdown: longMarkdown('长章节一'),
        );
        final second = _material(
          key: 'teach/long-two',
          title: '长章节二',
          markdown: longMarkdown('长章节二'),
        );
        await _loadDone(store, identity, [first, second]);
        final matches = await store.publicStore.searchKnowledge('长章节');
        expect(matches.candidates, hasLength(2));
        final reference = matches.candidates.first.reference;
        final otherReference = matches.candidates.last.reference;

        final page1 = await store.publicStore.readKnowledgeMaterial(
          reference,
          maxCharacters: 5000,
        );
        expect(page1.document!.markdown.runes.length, 5000);
        expect(page1.next, isNotNull);
        await expectLater(
          store.publicStore.readKnowledgeMaterial(
            reference,
            maxCharacters: 4000,
            cursor: page1.next,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        await expectLater(
          store.publicStore.readKnowledgeMaterial(
            otherReference,
            maxCharacters: 5000,
            cursor: page1.next,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        var cursor = page1.next;
        PublicQueryResult? lastPage;
        while (cursor != null) {
          lastPage = await store.publicStore.readKnowledgeMaterial(
            reference,
            maxCharacters: 5000,
            cursor: cursor,
          );
          cursor = lastPage.next;
        }
        expect(lastPage, isNotNull);
        final finalPage = lastPage!;
        expect(finalPage.document!.markdown, contains('尾部唯一标记'));
        expect(finalPage.coverage.truncated, isTrue);

        await store.publicStore.clearKnowledge(confirmed: true);
        await expectLater(
          store.publicStore.readKnowledgeMaterial(
            reference,
            maxCharacters: 5000,
            cursor: page1.next,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
      },
    );

    test(
      'iCourse consent and per-source public job authority remain isolated',
      () async {
        final identity = _identity(['teach/unused']);
        final store = await _openStore(identity);
        final icourseBefore = await store.publicStore.publicAuthority(
          PublicSource.icourse,
        );
        final campusBefore = await store.publicStore.publicAuthority(
          PublicSource.campus,
        );
        expect(await store.publicStore.hasIcourseConsent(), isFalse);
        await expectLater(
          store.publicStore.beginPublicJob(PublicSource.icourse),
          throwsA(_publicFailure(PublicFailureCode.consentRequired)),
        );

        final campusJob = await store.publicStore.beginPublicJob(
          PublicSource.campus,
        );
        await store.publicStore.ensurePublicJob(campusJob);
        await store.publicStore.setIcourseConsent(true);
        await store.publicStore.ensureAuthority(campusBefore);
        await expectLater(
          store.publicStore.ensureAuthority(icourseBefore),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        final icourseJob = await store.publicStore.beginPublicJob(
          PublicSource.icourse,
        );
        await store.publicStore.ensurePublicJob(icourseJob);
        await store.publicStore.setIcourseConsent(false);
        expect(await store.publicStore.hasIcourseConsent(), isFalse);
        await expectLater(
          store.publicStore.ensurePublicJob(icourseJob),
          throwsA(_publicFailure(PublicFailureCode.cancelled)),
        );
        await store.publicStore.ensurePublicJob(campusJob);
        await store.publicStore.cancelPublicJob(campusJob);
        await expectLater(
          store.publicStore.ensurePublicJob(campusJob),
          throwsA(_publicFailure(PublicFailureCode.cancelled)),
        );
        await expectLater(
          store.publicStore.ensureAuthority(campusJob.authority),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        store.publicStore.releasePublicJob(campusJob);
        store.publicStore.releasePublicJob(icourseJob);
      },
    );
  });
}

Future<JwStore> _openStore(
  KnowledgeEditionIdentity identity, {
  Future<void> Function()? onKnowledgeCheckpoint,
  QueryExecutor? executor,
}) async {
  final store = JwStore(
    executor ?? NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 10, 12)),
    knowledgeIdentity: identity,
    onKnowledgeCheckpoint: onKnowledgeCheckpoint,
  );
  await store.initialize();
  addTearDown(store.close);
  return store;
}

KnowledgeEditionIdentity _identity(List<String> keys) =>
    KnowledgeEditionIdentity(
      key: 'synthetic-knowledge-edition',
      catalogDigest: List<String>.filled(64, 'c').join(),
      materialKeys: List<String>.unmodifiable(keys),
    );

KnowledgeEdition _edition(
  KnowledgeEditionIdentity identity,
  List<KnowledgeMaterial> materials,
) => KnowledgeEdition(
  key: identity.key,
  catalogDigest: identity.catalogDigest,
  materials: materials,
);

Future<KnowledgeLoadOutcome> _loadDone(
  JwStore store,
  KnowledgeEditionIdentity identity,
  List<KnowledgeMaterial> materials,
) async {
  final ticket = await store.publicStore.beginKnowledgeLoad();
  await store.publicStore.bindKnowledgeEdition(
    ticket,
    _edition(identity, materials),
  );
  for (final material in materials) {
    await store.publicStore.acceptKnowledgeMaterial(ticket, material);
  }
  return store.publicStore.finishKnowledgeLoad(ticket, KnowledgeLoadState.done);
}

KnowledgeMaterial _material({
  required String key,
  required String title,
  String markdown = '# 合成知识\n\n学生可以查询合成知识。',
  PublicProvider provider = PublicProvider.teach,
  String topic = '校内办事',
  String audience = '本科生',
  String sourceVersion = '2026-秋季',
  String coveredScope = '合成材料所述办理范围',
  String reviewVersion = 'review-1',
  String? sourceDigest,
  String? publishedOn = '2026-09-01',
  String? updatedOn = '2026-09-10',
}) {
  final allowedUrl = provider == PublicProvider.finance
      ? Uri.parse('https://finance.ustc.edu.cn/main.htm')
      : Uri.parse(
          'https://www.teach.ustc.edu.cn/service/svc-student/12522.html',
        );
  return KnowledgeMaterial(
    key: key,
    title: title,
    provider: provider,
    topic: topic,
    audience: audience,
    sourceVersion: sourceVersion,
    articleUrl: allowedUrl,
    sourceDigest: sourceDigest ?? fingerprintBytes('source:$key'),
    coveredScope: coveredScope,
    markdown: markdown,
    markdownDigest: fingerprintBytes(markdown),
    reviewVersion: reviewVersion,
    publishedOn: publishedOn,
    updatedOn: updatedOn,
  );
}

Future<int> _count(JwStore store, String table, [String? where]) async {
  if (!RegExp(r'^[a-z_]+$').hasMatch(table)) throw ArgumentError.value(table);
  final row = await store
      .customSelect(
        'SELECT COUNT(*) AS count FROM $table${where == null ? '' : ' WHERE $where'}',
      )
      .getSingle();
  return row.read<int>('count');
}

Matcher _publicFailure(PublicFailureCode code) => isA<PublicFailure>().having(
  (failure) => failure.code,
  'failure code',
  code,
);

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}

final class _CommitFault {
  bool failNextSend = false;
  int injectedFailures = 0;

  bool takeFailure() {
    if (!failNextSend) return false;
    failNextSend = false;
    injectedFailures++;
    return true;
  }
}

/// Delegates every database operation to a real NativeDatabase executor and
/// only intercepts TransactionExecutor.send before SQLite receives COMMIT.
final class _CommitFaultExecutor implements QueryExecutor {
  _CommitFaultExecutor(this._delegate, this._fault);

  final QueryExecutor _delegate;
  final _CommitFault _fault;

  @override
  SqlDialect get dialect => _delegate.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _delegate.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _delegate.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _delegate.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _delegate.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _delegate.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _delegate.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _delegate.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() =>
      _CommitFaultTransaction(_delegate.beginTransaction(), _fault);

  @override
  QueryExecutor beginExclusive() =>
      _CommitFaultExecutor(_delegate.beginExclusive(), _fault);

  @override
  Future<void> close() => _delegate.close();
}

final class _CommitFaultTransaction extends _CommitFaultExecutor
    implements TransactionExecutor {
  _CommitFaultTransaction(super._delegate, super._fault);

  TransactionExecutor get _transaction => _delegate as TransactionExecutor;

  @override
  bool get supportsNestedTransactions =>
      _transaction.supportsNestedTransactions;

  @override
  Future<void> send() async {
    if (_fault.takeFailure()) {
      throw StateError('synthetic failure before delegated transaction commit');
    }
    await _transaction.send();
  }

  @override
  Future<void> rollback() => _transaction.rollback();
}
