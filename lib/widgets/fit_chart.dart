import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/fit_result.dart';

/// fl_chart 拟合图：散点 + 拟合直线。
class FitChart extends StatelessWidget {
  const FitChart({super.key, required this.fit});

  final FitResult fit;

  @override
  Widget build(BuildContext context) {
    final List<FitPoint> points = fit.points;
    if (points.isEmpty) {
      return const SizedBox(height: 240, child: Center(child: Text('暂无拟合数据')));
    }

    double minX = points.map((p) => p.x).reduce(math.min);
    double maxX = points.map((p) => p.x).reduce(math.max);
    double minY = points.map((p) => p.y).reduce(math.min);
    double maxY = points.map((p) => p.y).reduce(math.max);

    final double lineYMin = fit.slope * minX + fit.intercept;
    final double lineYMax = fit.slope * maxX + fit.intercept;
    minY = math.min(minY, math.min(lineYMin, lineYMax));
    maxY = math.max(maxY, math.max(lineYMin, lineYMax));

    if ((maxX - minX).abs() < 1e-9) maxX = minX + 1;
    if ((maxY - minY).abs() < 1e-9) maxY = minY + 1;

    final double xPad = (maxX - minX) * 0.15;
    final double yPad = (maxY - minY) * 0.15;
    final double chartMinX = minX - xPad;
    final double chartMaxX = maxX + xPad;
    final double chartMinY = minY - yPad;
    final double chartMaxY = maxY + yPad;

    final List<FlSpot> lineSpots = <FlSpot>[
      FlSpot(chartMinX, fit.slope * chartMinX + fit.intercept),
      FlSpot(chartMaxX, fit.slope * chartMaxX + fit.intercept),
    ];
    final List<FlSpot> pointSpots = <FlSpot>[
      for (final FitPoint p in points) FlSpot(p.x, p.y),
    ];

    return SizedBox(
      height: 260,
      child: LineChart(
        LineChartData(
          minX: chartMinX,
          maxX: chartMaxX,
          minY: chartMinY,
          maxY: chartMaxY,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (double value, TitleMeta meta) => Text(
                  value.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 10, color: kNeutralGrey),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                getTitlesWidget: (double value, TitleMeta meta) => Text(
                  value.toStringAsFixed(0),
                  style: const TextStyle(fontSize: 10, color: kNeutralGrey),
                ),
              ),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          lineBarsData: <LineChartBarData>[
            LineChartBarData(
              spots: lineSpots,
              color: kPrimaryColor,
              barWidth: 2,
              isCurved: false,
              dotData: const FlDotData(show: false),
            ),
            LineChartBarData(
              spots: pointSpots,
              color: Colors.transparent,
              barWidth: 0,
              isCurved: false,
              dotData: FlDotData(
                show: true,
                getDotPainter:
                    (
                      FlSpot spot,
                      double percent,
                      LineChartBarData bar,
                      int index,
                    ) => FlDotCirclePainter(
                      color: kPrimaryColor,
                      radius: 4,
                      strokeColor: Colors.white,
                      strokeWidth: 1.5,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
