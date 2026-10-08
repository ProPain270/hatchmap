import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hatch_map/main.dart';

Map<String, dynamic> fixture() => {
      'meta': {
        'schema': 2,
        'node': 'media-server',
        'tailnet': 'private network',
        'updated': DateTime.now().toUtc().toIso8601String()
      },
      'sitrep': [
        {'l': 'Services', 'v': '1 / 1', 's': 'running', 'state': 'ok'}
      ],
      'groups': [
        {
          'tier': 'Services',
          'nodes': [
            {
              't': 'docker',
              'name': 'Jellyseerr',
              'plain': 'Request movies',
              'state': 'up',
              'traffic': {'up': 8, 'down': 16, 'interval_s': 120}
            },
            false,
            {
              'name': 'Unknown traffic',
              'traffic': {'down': 4, 'interval_s': 120}
            }
          ]
        }
      ],
      'devices': [
        {
          'name': "Alex's Phone",
          'kind': 'phone',
          'what': 'Samsung phone',
          'state': 'offline',
          'via': 'tailscale',
          'bluetooth': null
        },
        17,
        {'name': null}
      ],
    };
Map<String, dynamic> historyFixture() => {
      'meta': {
        'updated': DateTime.now().toUtc().toIso8601String(),
        'coverage_start': '2026-09-27T17:47:32Z'
      },
      'nodes': {
        'Jellyseerr': [
          {
            't': DateTime.now().millisecondsSinceEpoch / 1000 - 300,
            'up': 8,
            'down': 16
          },
          'bad',
          {'t': 3, 'down': 0}
        ]
      }
    };
void main() {
  test('Malformed entries are isolated and missing counters stay unknown', () {
    final t = Topology.fromJson(fixture());
    expect(t.devices.length, 1);
    expect(t.groups.single.nodes.length, 2);
    expect(t.groups.single.nodes.last.traffic, isNull);
    expect(t.groups.single.nodes.first.traffic!.up, 8);
    expect(
        TrafficHistory.fromJson(historyFixture()).nodes['Jellyseerr']!.length,
        1);
    expect(() => TrafficMeasure.fromJson({'down': 0, 'interval_s': 120}),
        throwsFormatException);
    expect(
        TrafficMeasure.fromJson({'up': 0, 'down': 0, 'interval_s': 120}).up, 0);
  });
  testWidgets(
      'Devices caches real history and survives failed refresh and relaunch',
      (tester) async {
    SharedPreferences.setMockInitialValues({'hatch_view_mode': 'devices'});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var offline = false;
    await http.runWithClient(() async {
      await tester.pumpWidget(const HatchMapApp());
      await tester.pumpAndSettle();
      expect(find.text("Alex's Phone"), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.textContaining('Bluetooth capability: —'), findsWidgets);
      expect(find.textContaining('Recorded: sent'), findsOneWidget);

      offline = true;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Offline — showing saved data'), findsOneWidget);
      expect(find.text("Alex's Phone"), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(const HatchMapApp());
      await tester.pumpAndSettle();
      expect(find.text("Alex's Phone"), findsOneWidget);
      expect(find.textContaining('Recorded: sent'), findsOneWidget);
      expect(
          find.textContaining('Offline — showing saved data'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((req) async {
              if (offline) throw http.ClientException('Offline test');
              return http.Response(
                  jsonEncode(req.url.path.endsWith('traffic-history.json')
                      ? historyFixture()
                      : fixture()),
                  200);
            }));
  });
  testWidgets('First launch offline has no invented topology', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await http.runWithClient(() async {
      await tester.pumpWidget(const HatchMapApp());
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Offline — no saved data yet'), findsOneWidget);
      expect(find.text('35 / 35'), findsNothing);
      expect(find.textContaining('Auto-restarted'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient(
            (_) async => throw http.ClientException('Offline test')));
  });
}
