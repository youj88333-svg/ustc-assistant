import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_grounding_policy.dart';

void main() {
  const policy = AgentGroundingPolicy();

  group('AgentGroundingPolicy.classify — exact manual phrases', () {
    test('pending event reviews is a grounded read intent', () {
      final req = policy.classify('有哪些需要我确认的课程出勤或听讲？');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_pending_event_reviews'});
      expect(req.terminalTools, isEmpty);
      expect(req.mutationIntent, isFalse);
    });

    test('plan a task execution window is a grounded write intent', () {
      final req = policy.classify('给完成操作系统大作业安排明天下午两点');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_tasks'});
      expect(req.terminalTools, {'plan_task'});
      // A write intent must require a terminal write tool, not just a lookup.
      final required = req.requiredTools;
      expect(required.contains('plan_task'), isTrue);
      expect(req.mutationIntent, isTrue);
    });

    test('capability question is not an operation', () {
      expect(policy.classify('你能不能修改日程？'), isNull);
    });

    test('conflict QUESTION is a get_conflicts READ intent, never a write', () {
      final req = policy.classify('这周有冲突吗');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_conflicts'});
      expect(req.terminalTools, isEmpty);
      expect(req.mutationIntent, isFalse);
    });

    test('which conflicts are arranged this week is a READ intent', () {
      final req = policy.classify('我这周有哪些时间冲突的安排？');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_conflicts'});
      expect(req.terminalTools, isEmpty);
      expect(req.mutationIntent, isFalse);
    });

    test('recording a relation is a create_schedule_relation WRITE intent', () {
      final req = policy.classify('记录这两节课的冲突');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'create_schedule_relation'});
      expect(req.mutationIntent, isTrue);
    });

    test('explicit relation decision stays a write intent', () {
      final req = policy.classify('把2026年3月的那两节计算机网络课记录为冲突，二选一。');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'create_schedule_relation'});
      expect(req.mutationIntent, isTrue);
    });

    test('recording a no-conflict decision is a relation write, not a query', () {
      final req = policy.classify('把重叠甲和重叠乙记录为不冲突，两个时段都去。');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'create_schedule_relation'});
      expect(req.mutationIntent, isTrue);
    });

    test('single-course move is NOT a whole-day JW course move', () {
      final req = policy.classify('把周五的英语课移到下午');
      expect(req, isNotNull);
      expect(req!.terminalTools, isNot(contains('move_jw_course_day')));
      expect(req.terminalTools, {'update_event'});
    });

    test('whole-day JW course move stays a move_jw_course_day write', () {
      final req = policy.classify('把 8 月 3 日的教务课程移到 8 月 9 日');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'move_jw_course_day'});
      expect(req.mutationIntent, isTrue);
    });

    test('explicit no-query instruction is free chat', () {
      expect(policy.classify('不要查询，只讨论复习方法'), isNull);
    });

    test('greeting is free chat', () {
      expect(policy.classify('你好，介绍一下自己'), isNull);
    });
  });

  group('AgentGroundingPolicy.classify — conservative free chat', () {
    test('hypothetical and general-advice text is never an operation', () {
      expect(policy.classify('你能做什么？'), isNull);
      expect(policy.classify('怎么规划复习比较好？'), isNull);
      expect(policy.classify('为什么课程会发生冲突？'), isNull);
      expect(policy.classify('假设我周三没课，该怎么安排？'), isNull);
      expect(policy.classify('解释一下 PlanBlock。'), isNull);
      expect(policy.classify('帮我看看'), isNull);
    });
  });

  group('AgentGroundingPolicy.classify — polite request intent matrix', () {
    // A single politeness word (能不能 / 帮我看看 / 解释) must not force an
    // operation into free chat, nor must a bare politeness word be a glue
    // that mis-classifies a real operation.
    test('能不能帮我看看明天有什么课？ is a get_schedule read', () {
      final req = policy.classify('能不能帮我看看明天有什么课？');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_schedule'});
      expect(req.terminalTools, isEmpty);
      expect(req.mutationIntent, isFalse);
    });

    test('帮我看看这周有哪些任务 is a get_tasks read', () {
      final req = policy.classify('帮我看看这周有哪些任务');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_tasks'});
      expect(req.mutationIntent, isFalse);
    });

    test('查一下并解释我这周为什么有冲突 is a get_conflicts read', () {
      final req = policy.classify('查一下并解释我这周为什么有冲突');
      expect(req, isNotNull);
      expect(req!.lookupTools, {'get_conflicts'});
      expect(req.mutationIntent, isFalse);
    });

    test('你能不能修改日程？ is capability/free chat, not a write', () {
      expect(policy.classify('你能不能修改日程？'), isNull);
    });

    test('为什么课程会发生冲突？ is advice/free chat, not a conflict read', () {
      expect(policy.classify('为什么课程会发生冲突？'), isNull);
    });

    test('不要查询，只讨论复习方法 is free chat (hard override)', () {
      expect(policy.classify('不要查询，只讨论复习方法'), isNull);
    });

    test('把数据结构课程移到周五下午 is a single-course update_event', () {
      final req = policy.classify('把数据结构课程移到周五下午');
      expect(req, isNotNull);
      expect(req!.terminalTools, isNot(contains('move_jw_course_day')));
      expect(req.terminalTools, {'update_event'});
    });

    test('whole-day all-JW-courses move is move_jw_course_day', () {
      final req = policy.classify('把 8 月 3 日当天所有教务课程移到 8 月 9 日');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'move_jw_course_day'});
    });

    test('把周五课程移到周一 is NOT a whole-day move (allow clarification)', () {
      final req = policy.classify('把周五课程移到周一');
      expect(req, isNotNull);
      expect(req!.terminalTools, isNot(contains('move_jw_course_day')));
    });

    test('给我安排周五晚上打游戏 is create_event, not plan_task', () {
      final req = policy.classify('给我安排周五晚上打游戏');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'create_event'});
      expect(req.terminalTools, isNot(contains('plan_task')));
    });

    test('给操作系统作业安排明天下午两点 is plan_task', () {
      final req = policy.classify('给操作系统作业安排明天下午两点');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'plan_task'});
    });
  });

  group('AgentGroundingRequirement — create_schedule_relation lookup alternatives',
      () {
    // A relation needs "two valid refs". Event-event relations must NOT force
    // get_plan_blocks; PlanBlock relations must NOT force get_schedule. The
    // requirement must express these as an EITHER/OR over lookup groups.
    test('a relation requirement expresses alternative lookup groups', () {
      final req = policy.classify('记录这两节课的冲突');
      expect(req, isNotNull);
      expect(req!.terminalTools, {'create_schedule_relation'});
      expect(req.lookupTools, containsAll({'get_schedule', 'get_plan_blocks'}));
      // Expression of the alternative: any one group is a complete lookup set.
      final groups = req.anyOfLookupToolGroups;
      expect(groups, isNotEmpty);
      expect(groups.any((g) => g.contains('get_schedule')), isTrue);
      expect(groups.any((g) => g.contains('get_plan_blocks')), isTrue);
      expect(
        groups.any(
          (g) => !g.contains('get_schedule') || !g.contains('get_plan_blocks'),
        ),
        isTrue,
        reason: 'at least one group must NOT contain BOTH tools',
      );
    });

    test('event-event relation is satisfied by get_schedule alone', () {
      final req = policy.classify('把2026年3月的那两节计算机网络课记录为冲突');
      expect(req, isNotNull);
      // Event-event: getting schedule refs alone is a complete lookup.
      expect(req!.isLookupsSatisfied({'get_schedule'}), isTrue);
      // It never *requires* plan blocks.
      expect(
        req.anyOfLookupToolGroups.any((g) => g.contains('get_plan_blocks')),
        isTrue,
      );
    });

    test('PlanBlock-PlanBlock relation is satisfied by get_plan_blocks alone', () {
      final req = policy.classify('记录这两个执行块互相冲突');
      expect(req, isNotNull);
      expect(req!.isLookupsSatisfied({'get_plan_blocks'}), isTrue);
    });

    test('no ref-less fake success: relation still requires the terminal write',
        () {
      final req = policy.classify('记录这两节课的冲突');
      expect(req, isNotNull);
      expect(req!.mutationIntent, isTrue);
      expect(req.terminalTools, {'create_schedule_relation'});
      // Lookup success alone never grounds a mutation.
      expect(req.isLookupsSatisfied({'get_schedule', 'get_plan_blocks'}), isTrue);
      expect(req.requiredTools, contains('create_schedule_relation'));
    });
  });
}