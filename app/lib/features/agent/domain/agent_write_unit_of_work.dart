/// 写原子单元：把业务提交、审计日志与权限变更装进同一个原子操作。
///
/// 领域层纯 Dart 接口，不含任何 Drift/数据库依赖；[AgentWriteTool] 通过它把
/// "commit -> logAgentWrite -> afterSuccessfulCommit" 放进一个事务，
/// 使其中任何一步失败时全部回滚。数据层实现见
/// `data/drift_agent_write_unit_of_work.dart`。
abstract interface class AgentWriteUnitOfWork {
  Future<T> run<T>(Future<T> Function() body);
}