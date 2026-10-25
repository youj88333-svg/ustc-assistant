import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/onboarding_contract.dart';

/// Product journeys predate the guide and deliberately start after setup.
/// Called only for independent synthetic fixtures, never by a product entry.
Future<RuntimeBootstrap> configuredSyntheticInstallation(
  Future<RuntimeBootstrap> opening,
) async {
  final bootstrap = await opening;
  if (bootstrap.runtime != null &&
      !bootstrap.settings.settingsView.maintenance.blocksProduct) {
    await finishSyntheticSetup(bootstrap);
  }
  return bootstrap;
}

Future<void> finishSyntheticSetup(RuntimeBootstrap bootstrap) async {
  final progress = await bootstrap.jwStore.onboarding.inspect();
  await bootstrap.jwStore.onboarding.save(
    progress.context,
    status: OnboardingStatus.done,
    step: OnboardingStep.permissions,
  );
}
