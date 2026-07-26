import 'package:flutter/material.dart';

import '../domain/ustc_periods.dart';

class TimeAxis extends StatelessWidget {
  const TimeAxis({required this.pixelsPerMinute, super.key});

  final double pixelsPerMinute;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: Stack(
        children: [
          for (final period in UstcPeriods.values)
            Positioned(
              top:
                  (period.startMinutes - UstcPeriods.dayStartMinutes) *
                  pixelsPerMinute,
              left: 0,
              right: 0,
              child: Text(
                '${period.number}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
        ],
      ),
    );
  }
}
