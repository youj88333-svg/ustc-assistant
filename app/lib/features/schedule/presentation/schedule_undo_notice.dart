import 'package:flutter/material.dart';

/// A compact, schedule-page-local floating notice for whole-day course moves.
///
/// It replaces the old root/global [ScaffoldMessenger] snackbar so the undo
/// prompt never covers the chat surface and never lingers across pages. The
/// parent [SchedulePage] owns the six-second [Timer] and decides when the
/// notice is shown or hidden; this widget is purely presentational and must be
/// placed as a (Positioned) child of a [Stack] owned by the schedule page.
class ScheduleUndoNotice extends StatelessWidget {
  const ScheduleUndoNotice({
    super.key,
    required this.message,
    required this.onUndo,
  });

  final String message;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      key: const Key('schedule-undo-notice'),
      left: 16,
      right: 16,
      bottom: 8,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        color: scheme.inverseSurface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onInverseSurface),
                ),
              ),
              TextButton(
                onPressed: onUndo,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.inversePrimary,
                ),
                child: const Text('撤销'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}