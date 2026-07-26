abstract interface class ReminderReconciler {
  Future<void> reconcile({
    required String accountId,
    required String source,
  });
}

class NoopReminderReconciler implements ReminderReconciler {
  const NoopReminderReconciler();

  @override
  Future<void> reconcile({
    required String accountId,
    required String source,
  }) async {}
}
