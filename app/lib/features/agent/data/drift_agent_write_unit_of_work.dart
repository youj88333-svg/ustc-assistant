import '../../../core/database/app_database.dart';
import '../domain/agent_write_unit_of_work.dart';

/// Drift 事务实现：用 `AppDatabase.transaction` 包裹原子操作。
///
/// Drift 事务支持嵌套——内部 service 自开的 `database.transaction(...)` 会
/// 加入外层事务，任何未捕获异常导致外层回滚时，内部写入（业务表、审计日志、
/// 权限变更）一并回滚。
final class DriftAgentWriteUnitOfWork implements AgentWriteUnitOfWork {
  DriftAgentWriteUnitOfWork(this.database);
  final AppDatabase database;

  @override
  Future<T> run<T>(Future<T> Function() body) => database.transaction(body);
}