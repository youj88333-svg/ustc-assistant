/// Fixed school-deployment policy, shared by every gateway request and its UI
/// projection. A name resembling a supported model is not a capability grant.
/// No thinking-mode switch, arbitrary JSON or numeric budget is inferred.
String? modelReasoningEffort(String? modelId) => switch (modelId) {
  'deepseek-flash' => 'high',
  _ => null,
};
