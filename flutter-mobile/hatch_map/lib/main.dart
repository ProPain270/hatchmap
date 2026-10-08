// HatchMap — homelab topology map (Flutter mobile client)
// Reads the SAME topology.json the macOS app reads, so the two stay in sync.
// Endpoint is tailnet-only; reachable from your phone when Tailscale is on.
//
//   flutter pub get && flutter run
//
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// Shared source of truth (see SHARED-CONTRACT.md). Override with:
//   flutter run --dart-define=HATCH_API=http://media-server:8770/topology.json
// The default below is a placeholder that never resolves; this build has no in-app
// endpoint setting, so pass --dart-define (or edit kApiUrl) for your own node.
const String kApiUrl = String.fromEnvironment('HATCH_API',
    defaultValue:
        'https://your-node.your-tailnet.example:8443/topology.json');
const Duration kPoll = Duration(seconds: 30);
const String kCacheKey = 'hatch_topology_cache';

void main() => runApp(const HatchMapApp());

// ---------- enums ----------
enum ThemeProfile { obsidian, cyberpunk, midnight }

enum HapticProfile { off, subtle, standard, heavy }

enum HapticImpact { selection, light, medium, heavy }

enum ViewMode { grid, tree, devices }

// ---------- palette & theme system ----------
class AppThemeData {
  final String id;
  final String name;
  final String description;
  final Color bg;
  final Color bg2;
  final Color panel;
  final Color line;
  final Color ink;
  final Color sub;
  final Color dim;
  final Color ok;
  final Color warn;
  final Color crit;
  final Color funnel;
  final Color tail;
  final Color vpn;
  final Color guard;

  const AppThemeData({
    required this.id,
    required this.name,
    required this.description,
    required this.bg,
    required this.bg2,
    required this.panel,
    required this.line,
    required this.ink,
    required this.sub,
    required this.dim,
    required this.ok,
    required this.warn,
    required this.crit,
    required this.funnel,
    required this.tail,
    required this.vpn,
    required this.guard,
  });

  Color type(String t) =>
      {
        'host': const Color(0xFF3FB6C8),
        'lxc': ok,
        'vm': tail,
        'docker': const Color(0xFFC98B3A),
        'net': funnel,
        'guard': guard,
        'store': const Color(0xFFE0B341),
      }[t] ??
      sub;

  Color state(String s) => s == 'down' ? crit : (s == 'warn' ? warn : ok);
}

final Map<ThemeProfile, AppThemeData> kThemes = {
  ThemeProfile.obsidian: const AppThemeData(
    id: 'obsidian',
    name: 'Obsidian Dark',
    description: 'Deep homelab dark mode with funnel blue accents',
    bg: Color(0xFF0B0F17),
    bg2: Color(0xFF0E1420),
    panel: Color(0xFF121A28),
    line: Color(0xFF243247),
    ink: Color(0xFFE8EEF7),
    sub: Color(0xFF8FA3BD),
    dim: Color(0xFF61718C),
    ok: Color(0xFF4BD07A),
    warn: Color(0xFFE5B445),
    crit: Color(0xFFE5624A),
    funnel: Color(0xFF5AA8FF),
    tail: Color(0xFFB3A3F0),
    vpn: Color(0xFFF0857A),
    guard: Color(0xFF4FD1C5),
  ),
  ThemeProfile.cyberpunk: const AppThemeData(
    id: 'cyberpunk',
    name: 'Cyberpunk Neon',
    description: 'Vibrant neon cyan & electric purple dark theme',
    bg: Color(0xFF0A0915),
    bg2: Color(0xFF120E24),
    panel: Color(0xFF1B1438),
    line: Color(0xFF3B2A68),
    ink: Color(0xFFF5F0FF),
    sub: Color(0xFFB8A6E3),
    dim: Color(0xFF7A68A5),
    ok: Color(0xFF00FF9D),
    warn: Color(0xFFFFB800),
    crit: Color(0xFFFF0055),
    funnel: Color(0xFF00F0FF),
    tail: Color(0xFFD946EF),
    vpn: Color(0xFFFF3366),
    guard: Color(0xFF00F0FF),
  ),
  ThemeProfile.midnight: const AppThemeData(
    id: 'midnight',
    name: 'Midnight Navy',
    description: 'Sleek oceanic navy background with emerald guard accents',
    bg: Color(0xFF060D1A),
    bg2: Color(0xFF0B172C),
    panel: Color(0xFF11223F),
    line: Color(0xFF1F3A66),
    ink: Color(0xFFEAEEF5),
    sub: Color(0xFF8BA6C9),
    dim: Color(0xFF58769E),
    ok: Color(0xFF34D399),
    warn: Color(0xFFF59E0B),
    crit: Color(0xFFEF4444),
    funnel: Color(0xFF38BDF8),
    tail: Color(0xFFA78BFA),
    vpn: Color(0xFFF87171),
    guard: Color(0xFF2DD4BF),
  ),
};

class C {
  static ThemeProfile activeProfile = ThemeProfile.obsidian;
  static AppThemeData get current =>
      kThemes[activeProfile] ?? kThemes[ThemeProfile.obsidian]!;

  static Color get bg => current.bg;
  static Color get bg2 => current.bg2;
  static Color get panel => current.panel;
  static Color get line => current.line;
  static Color get ink => current.ink;
  static Color get sub => current.sub;
  static Color get dim => current.dim;
  static Color get ok => current.ok;
  static Color get warn => current.warn;
  static Color get crit => current.crit;
  static Color get funnel => current.funnel;
  static Color get tail => current.tail;
  static Color get vpn => current.vpn;
  static Color get guard => current.guard;

  static Color type(String t) => current.type(t);
  static Color state(String s) => current.state(s);
}

const Map<String, IconData> kIcons = {
  'movie': Icons.movie_outlined,
  'magnet': Icons.download_outlined,
  'lock': Icons.lock_outline,
  'chart': Icons.query_stats_outlined,
  'gear': Icons.settings_outlined,
  'disk': Icons.storage_outlined,
  'shield': Icons.shield_outlined,
};

// ---------- multi-site definition ----------
class SiteOption {
  final String id;
  final String name;
  final String url;
  final String wsUrl;
  final String location;
  final IconData icon;

  const SiteOption({
    required this.id,
    required this.name,
    required this.url,
    required this.wsUrl,
    required this.location,
    required this.icon,
  });
}

const List<SiteOption> kSites = [
  // One site per topology endpoint. Add more entries here for additional nodes.
  SiteOption(
    id: 'main',
    name: 'Main Homelab',
    url: kApiUrl,
    wsUrl: '', // the backend has no WebSocket contract; HTTPS polling is the data source
    location: 'Primary Rack',
    icon: Icons.dns_outlined,
  ),
];

// ---------- self-healing event definition ----------
class SelfHealingEvent {
  final String id;
  final String title;
  final String target;
  final String action;
  final DateTime timestamp;
  final String status;

  SelfHealingEvent({
    required this.id,
    required this.title,
    required this.target,
    required this.action,
    required this.timestamp,
    this.status = 'healed',
  });
}

// ---------- chaos engineering scenario definition ----------
class FailureScenario {
  final String id;
  final String name;
  final String targetNodeName;
  final String targetType;
  final String description;
  final IconData icon;
  final Color accentColor;
  final List<String> steps;

  const FailureScenario({
    required this.id,
    required this.name,
    required this.targetNodeName,
    required this.targetType,
    required this.description,
    required this.icon,
    required this.accentColor,
    required this.steps,
  });
}

const List<FailureScenario> kFailureScenarios = [
  FailureScenario(
    id: 'oom',
    name: 'RAM OOM Spike Injection',
    targetNodeName: 'Jellyfin Media Server',
    targetType: 'Docker Container',
    description:
        'Simulate synthetic memory leak exceeding 98% cgroup threshold',
    icon: Icons.memory_rounded,
    accentColor: Color(0xFFE5624A),
    steps: [
      'Injecting cgroup heap memory pressure (allocating 7.8GB/8GB)...',
      'Autonomous Guard Watchdog detected memory threshold breach (>95%)',
      'Executing graceful container restart & memory buffer purge via Tailscale API',
      'Container re-established • Health check returned HTTP 200 in 0.38s',
    ],
  ),
  FailureScenario(
    id: 'cpu',
    name: 'CPU Thrashing Cascade',
    targetNodeName: 'Download Worker / VPN',
    targetType: 'VPN Gateway Stack',
    description: 'Simulate high thread contention and 100% 4-Core CPU lockup',
    icon: Icons.speed_rounded,
    accentColor: Color(0xFFE5B445),
    steps: [
      'Simulating synthetic process thread thrashing across Cores 0-3...',
      'Watchdog flagged thread starvation & high load factor (12.4)',
      'Autonomous Guard throttled process cgroups & re-initialized VPN tunnel',
      'CPU load normalized to 18.2% • VPN tunnel ping restored (1.2ms)',
    ],
  ),
  FailureScenario(
    id: 'dns',
    name: 'Tailnet Packet Loss Drop',
    targetNodeName: 'AdGuard Home DNS',
    targetType: 'LXC Resolver',
    description:
        'Simulate 85% network latency and packet loss on local DNS resolver',
    icon: Icons.wifi_tethering_off_rounded,
    accentColor: Color(0xFF5AA8FF),
    steps: [
      'Injecting 85% synthetic packet loss on eth0 interface...',
      'Tailnet latency check failed • DNS lookup timeout triggered',
      'Autonomous Guard switched failover DNS route & restarted AdGuard LXC',
      'DNS cache flushed • Tailnet latency re-established at 0.9ms',
    ],
  ),
  FailureScenario(
    id: 'crash',
    name: 'Node Ingress Crash (SIGKILL)',
    targetNodeName: 'Nginx Proxy Manager',
    targetType: 'Reverse Proxy',
    description:
        'Simulate instant process termination and HTTP 503 gateway error',
    icon: Icons.power_settings_new_rounded,
    accentColor: Color(0xFFB3A3F0),
    steps: [
      'Sending SIGKILL signal to proxy worker processes...',
      'Ingress watchdog caught HTTP 503 Service Unavailable alert',
      'Auto-healing daemon re-spawned Nginx worker pool & re-linked SSL sockets',
      'Reverse proxy operational • 0 dropped connections recorded',
    ],
  ),
];

// ---------- models: each malformed entry is isolated ----------
String textField(dynamic value, [String fallback = '']) =>
    value is String ? value : fallback;
List<T> decodeItems<T>(dynamic values, T Function(Map<String, dynamic>) parse) {
  final result = <T>[];
  if (values is! List) return result;
  for (final value in values) {
    if (value is! Map<String, dynamic>) continue;
    try {
      result.add(parse(value));
    } catch (_) {/* one bad entry is skipped */}
  }
  return result;
}

T? optionalDecode<T>(dynamic value, T Function(Map<String, dynamic>) parse) {
  if (value is! Map<String, dynamic>) return null;
  try {
    return parse(value);
  } catch (_) {
    return null;
  }
}

int counterValue(dynamic value) {
  if (value is! int || value < 0) {
    throw const FormatException('Unknown counter');
  }
  return value;
}

class PersonalDevice {
  final String name, kind, what, state, via, lastSeen;
  final String? bluetooth, dest;
  PersonalDevice(
      {required this.name,
      required this.kind,
      required this.what,
      required this.state,
      required this.via,
      required this.lastSeen,
      this.bluetooth,
      this.dest});
  factory PersonalDevice.fromJson(Map<String, dynamic> j) {
    final name = textField(j['name']);
    if (name.isEmpty) throw const FormatException('Missing name');
    return PersonalDevice(
        name: name,
        kind: textField(j['kind'], 'other'),
        what: textField(j['what']),
        state: textField(j['state'], 'unknown'),
        via: textField(j['via'], 'manual'),
        lastSeen: textField(j['last_seen'], 'Unknown'),
        bluetooth: j['bluetooth'] is String ? j['bluetooth'] : null,
        dest: j['dest'] is String ? j['dest'] : null);
  }
}

class TrafficMeasure {
  final int up, down, intervalS;
  TrafficMeasure(this.up, this.down, this.intervalS);
  factory TrafficMeasure.fromJson(Map<String, dynamic> j) {
    final interval = counterValue(j['interval_s']);
    if (interval == 0) throw const FormatException('Unknown interval');
    return TrafficMeasure(
        counterValue(j['up']), counterValue(j['down']), interval);
  }
}

class TrafficBucket {
  final double t;
  final int up, down;
  TrafficBucket(this.t, this.up, this.down);
  factory TrafficBucket.fromJson(Map<String, dynamic> j) {
    final t = j['t'];
    if (t is! num || !t.isFinite || t <= 0) {
      throw const FormatException('Unknown time');
    }
    return TrafficBucket(
        t.toDouble(), counterValue(j['up']), counterValue(j['down']));
  }
}

class TrafficHistory {
  final String updated;
  final String? coverageStart;
  final Map<String, List<TrafficBucket>> nodes;
  TrafficHistory(this.updated, this.coverageStart, this.nodes);
  factory TrafficHistory.fromJson(Map<String, dynamic> j) {
    if (j['meta'] is! Map || j['nodes'] is! Map) {
      throw const FormatException('Invalid history');
    }
    final nodes = <String, List<TrafficBucket>>{};
    (j['nodes'] as Map).forEach((name, values) {
      if (name is String) {
        nodes[name] = decodeItems(values, TrafficBucket.fromJson);
      }
    });
    return TrafficHistory(
        textField(j['meta']['updated']),
        j['meta']['coverage_start'] is String
            ? j['meta']['coverage_start']
            : null,
        nodes);
  }
}

class Topology {
  final String node, tailnet, updated;
  final List<Sit> sitrep;
  final List<Group> groups;
  final List<PersonalDevice> devices;
  final int? schema;
  Topology(this.node, this.tailnet, this.updated, this.sitrep, this.groups,
      this.devices,
      [this.schema]);
  factory Topology.fromJson(Map<String, dynamic> j) {
    if (j['meta'] is! Map || j['groups'] is! List) {
      throw const FormatException('Invalid topology');
    }
    return Topology(
        textField(j['meta']['node']),
        textField(j['meta']['tailnet']),
        textField(j['meta']['updated']),
        decodeItems(j['sitrep'], Sit.fromJson),
        decodeItems(j['groups'], Group.fromJson),
        decodeItems(j['devices'], PersonalDevice.fromJson),
        j['meta']['schema'] is int ? j['meta']['schema'] : null);
  }
}

class Sit {
  final String l, v, s, state;
  Sit(this.l, this.v, this.s, this.state);
  factory Sit.fromJson(Map<String, dynamic> j) => Sit(
      textField(j['l']),
      textField(j['v']),
      textField(j['s']),
      textField(j['state'], textField(j['c'], 'unknown')));
}

class Group {
  final String tier, kind, icon;
  final List<HNode> nodes;
  Group(this.tier, this.kind, this.icon, this.nodes);
  factory Group.fromJson(Map<String, dynamic> j) => Group(
      textField(j['tier']),
      textField(j['kind'], 'group'),
      textField(j['icon']),
      decodeItems(j['nodes'], HNode.fromJson));
}

class HNode {
  final String t, name, meta, plain, tech, state;
  final String? expo, url, free, ram, ip, dest;
  String? speed;
  final int? pct;
  double? cpu;
  final TrafficMeasure? traffic;
  HNode(
      this.t,
      this.name,
      this.meta,
      this.plain,
      this.tech,
      this.state,
      this.expo,
      this.url,
      this.pct,
      this.free,
      this.cpu,
      this.ram,
      this.speed,
      this.ip,
      this.dest,
      this.traffic);
  factory HNode.fromJson(Map<String, dynamic> j) {
    if (textField(j['name']).isEmpty) {
      throw const FormatException('Missing name');
    }
    String? optional(String key) => j[key] is String ? j[key] : null;
    return HNode(
        textField(j['t']),
        textField(j['name']),
        textField(j['meta']),
        textField(j['plain']),
        textField(j['tech']),
        textField(j['state'], 'unknown'),
        optional('expo'),
        optional('url'),
        j['pct'] is num ? (j['pct'] as num).toInt() : null,
        optional('free'),
        j['cpu'] is num ? (j['cpu'] as num).toDouble() : null,
        optional('ram'),
        optional('speed'),
        optional('ip'),
        optional('dest'),
        optionalDecode(j['traffic'], TrafficMeasure.fromJson));
  }
}

// ---------- app ----------
class HatchMapApp extends StatelessWidget {
  const HatchMapApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hatch Map',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: C.bg,
          fontFamily: 'SF Pro Text',
          colorScheme: ColorScheme.dark(surface: C.bg2, primary: C.funnel),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Topology? _data;
  TrafficHistory? _history;
  String? _historyError;
  int _requestGeneration = 0;
  bool _fetching = false;
  String? _error;
  bool _veteran = false;
  bool _loading = true;
  Timer? _timer;

  // View Mode state (Grid vs Topology Tree)
  ViewMode _viewMode = ViewMode.grid;
  final Map<String, bool> _expandedTreeGroups = {};

  // Haptic feedback profile state
  HapticProfile _selectedHaptic = HapticProfile.standard;

  // Site selector state
  SiteOption _selectedSite = kSites.first;

  // WebSocket streaming state
  WebSocket? _webSocket;
  StreamSubscription? _wsSubscription;
  bool _wsConnected = false;
  Timer? _simulatedWsTimer;

  // Self-Healing & Chaos Engineering state

  // Chaos simulation live step state

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _initializeData();
    _timer = Timer.periodic(kPoll, (_) => _load(silent: true));
    _initWebSocket();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _simulatedWsTimer?.cancel();
    _wsSubscription?.cancel();
    _webSocket?.close();
    super.dispose();
  }

  // ---------- preferences & haptic helpers ----------
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final themeStr = prefs.getString('hatch_theme_profile');
      if (themeStr != null) {
        if (themeStr == 'cyberpunk') {
          C.activeProfile = ThemeProfile.cyberpunk;
        } else if (themeStr == 'midnight') {
          C.activeProfile = ThemeProfile.midnight;
        } else {
          C.activeProfile = ThemeProfile.obsidian;
        }
      }

      final hapticStr = prefs.getString('hatch_haptic_profile');
      if (hapticStr != null) {
        if (hapticStr == 'off') {
          _selectedHaptic = HapticProfile.off;
        } else if (hapticStr == 'subtle') {
          _selectedHaptic = HapticProfile.subtle;
        } else if (hapticStr == 'heavy') {
          _selectedHaptic = HapticProfile.heavy;
        } else {
          _selectedHaptic = HapticProfile.standard;
        }
      }

      final viewStr = prefs.getString('hatch_view_mode');
      if (viewStr != null) {
        if (viewStr == 'tree') {
          _viewMode = ViewMode.tree;
        } else if (viewStr == 'devices') {
          _viewMode = ViewMode.devices;
        } else {
          _viewMode = ViewMode.grid;
        }
      }

      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _savePreference(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  void _triggerHaptic([HapticImpact impact = HapticImpact.light]) {
    if (_selectedHaptic == HapticProfile.off) return;

    switch (_selectedHaptic) {
      case HapticProfile.subtle:
        HapticFeedback.selectionClick();
        break;
      case HapticProfile.standard:
        if (impact == HapticImpact.selection) {
          HapticFeedback.selectionClick();
        } else if (impact == HapticImpact.light) {
          HapticFeedback.lightImpact();
        } else if (impact == HapticImpact.medium) {
          HapticFeedback.mediumImpact();
        } else if (impact == HapticImpact.heavy) {
          HapticFeedback.heavyImpact();
        }
        break;
      case HapticProfile.heavy:
        if (impact == HapticImpact.selection) {
          HapticFeedback.lightImpact();
        } else if (impact == HapticImpact.light ||
            impact == HapticImpact.medium) {
          HapticFeedback.mediumImpact();
        } else if (impact == HapticImpact.heavy) {
          HapticFeedback.heavyImpact();
          Future.delayed(const Duration(milliseconds: 70), () {
            HapticFeedback.heavyImpact();
          });
        }
        break;
      case HapticProfile.off:
        break;
    }
  }

  // ---------- real polling and durable last-good caches ----------
  void _initWebSocket() {
    // This backend has no WebSocket contract. HTTPS polling is the real data source.
    _wsSubscription?.cancel();
    _webSocket?.close();
    _simulatedWsTimer?.cancel();
    _wsConnected = false;
  }

  Future<void> _initializeData() async {
    await _loadFromCache();
    await _load();
  }

  Future<void> _loadFromCache() async {
    final site = _selectedSite;
    try {
      final prefs = await SharedPreferences.getInstance();
      final topology = prefs.getString('${kCacheKey}_${site.id}');
      final history = prefs.getString('hatch_history_${site.id}');
      if (!mounted || site.id != _selectedSite.id) return;
      if (topology != null && _data == null) {
        try {
          _data = Topology.fromJson(jsonDecode(topology));
          _error = 'Saved data — checking connection';
          _loading = false;
        } catch (_) {}
      }
      if (history != null && _history == null) {
        try {
          _history = TrafficHistory.fromJson(jsonDecode(history));
          _historyError = 'Saved traffic history';
        } catch (_) {}
      }
      setState(() {});
    } catch (_) {}
  }

  Future<void> _load({bool silent = false}) async {
    if (_fetching) return;
    _fetching = true;
    final generation = ++_requestGeneration;
    final site = _selectedSite;
    bool current() =>
        mounted &&
        generation == _requestGeneration &&
        site.id == _selectedSite.id;
    if (!silent && _data == null) setState(() => _loading = true);
    Future<void> fetchTopology() async {
      try {
        final r = await http
            .get(Uri.parse(site.url))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) {
          throw http.ClientException('HTTP ${r.statusCode}');
        }
        final value = Topology.fromJson(jsonDecode(r.body));
        if (!current()) return;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('${kCacheKey}_${site.id}', r.body);
        if (!current()) return;
        setState(() {
          _data = value;
          _error = null;
          _loading = false;
        });
      } catch (_) {
        if (current()) {
          setState(() {
            _error = _data == null
                ? 'Offline — no saved data yet. Connect Tailscale and refresh.'
                : 'Offline — showing saved data from ${_data!.updated}';
            _loading = false;
          });
        }
      }
    }

    Future<void> fetchHistory() async {
      try {
        final url = Uri.parse(site.url).resolve('traffic-history.json');
        final r = await http.get(url).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) {
          throw http.ClientException('HTTP ${r.statusCode}');
        }
        final value = TrafficHistory.fromJson(jsonDecode(r.body));
        if (!current()) return;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('hatch_history_${site.id}', r.body);
        if (!current()) return;
        setState(() {
          _history = value;
          _historyError = null;
        });
      } catch (_) {
        if (current()) {
          setState(() => _historyError =
              'Traffic history offline — saved measurements only');
        }
      }
    }

    await Future.wait([fetchTopology(), fetchHistory()]);
    if (current()) _fetching = false;
  }

  void _switchSite(SiteOption site) {
    _requestGeneration++;
    setState(() {
      _selectedSite = site;
      _data = null;
      _history = null;
      _loading = true;
      _error = null;
      _historyError = null;
      _fetching = false;
    });
    _initializeData();
    _initWebSocket();
  }

  // ---------- chaos engineering step simulator ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _viewMode == ViewMode.devices ? 1 : 0,
        onDestinationSelected: (index) {
          setState(
              () => _viewMode = index == 1 ? ViewMode.devices : ViewMode.grid);
          _savePreference('hatch_view_mode', _viewMode.name);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.hub_outlined), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.devices), label: 'Devices')
        ],
      ),
      body: SafeArea(
        child: _loading
            ? Center(child: CircularProgressIndicator(color: C.funnel))
            : RefreshIndicator(
                color: C.funnel,
                backgroundColor: C.panel,
                onRefresh: () async {
                  _triggerHaptic(HapticImpact.light);
                  await _load();
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (_data != null)
                      SliverToBoxAdapter(child: _attentionSummary(_data!)),
                    SliverToBoxAdapter(child: _header()),
                    if (_error != null)
                      SliverToBoxAdapter(child: _banner(_error!)),
                    if (_data != null && (_data!.schema ?? 1) > 2)
                      SliverToBoxAdapter(
                          child:
                              _banner("Newer schema — showing known fields")),
                    if (_historyError != null && _viewMode == ViewMode.devices)
                      SliverToBoxAdapter(child: _banner(_historyError!)),
                    if (_data != null) ..._body(_data!),
                    const SliverToBoxAdapter(child: SizedBox(height: 40)),
                  ],
                ),
              ),
      ),
    );
  }

  // ---------- header & toolbars ----------
  Widget _header() {
    final d = _data;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Multi-Site Dropdown, WS Badge & Settings button
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: [
            _siteSelectorDropdown(),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _wsLiveBadge(),
                const SizedBox(width: 6),
                IconButton(
                  icon: Icon(Icons.tune_rounded, color: C.sub, size: 20),
                  onPressed: () {
                    _triggerHaptic(HapticImpact.selection);
                    _showSettingsSheet();
                  },
                  tooltip: 'Settings & Theme Customization',
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              RichText(
                text: TextSpan(children: [
                  TextSpan(
                      text: 'Hatch ',
                      style: TextStyle(
                          color: C.guard,
                          fontSize: 23,
                          fontWeight: FontWeight.w700)),
                  TextSpan(
                      text: _selectedSite.name,
                      style: TextStyle(
                          color: C.ink,
                          fontSize: 23,
                          fontWeight: FontWeight.w700)),
                ]),
              ),
              const SizedBox(height: 3),
              Text(
                  d == null
                      ? 'Network map & SITREP · ${_selectedSite.location}'
                      : 'Updated ${_ago(d.updated)} · ${d.tailnet}',
                  style: TextStyle(color: C.sub, fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),

        // Controls Toolbar: View Mode (Grid vs Tree), Veteran Mode & Chaos Lab
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          spacing: 8,
          children: [
            _viewModeToggle(),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _veteranToggle(),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (d != null) _sitrep(d.sitrep),
      ]),
    );
  }

  Widget _viewModeToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: C.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _viewModeOption(ViewMode.grid, Icons.grid_view_rounded, 'Grid'),
          const SizedBox(width: 2),
          _viewModeOption(ViewMode.tree, Icons.account_tree_rounded, 'Tree'),
          const SizedBox(width: 2),
          _viewModeOption(ViewMode.devices, Icons.devices_rounded, 'Devices'),
        ],
      ),
    );
  }

  Widget _viewModeOption(ViewMode mode, IconData icon, String label) {
    final isSelected = _viewMode == mode;
    return GestureDetector(
      onTap: () {
        if (_viewMode != mode) {
          _triggerHaptic(HapticImpact.selection);
          setState(() => _viewMode = mode);
          _savePreference('hatch_view_mode', mode.name);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color:
              isSelected ? C.guard.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: C.guard.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isSelected ? C.guard : C.sub),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? C.ink : C.sub,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _siteSelectorDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<SiteOption>(
          value: _selectedSite,
          dropdownColor: C.panel,
          isDense: true,
          icon:
              Icon(Icons.keyboard_arrow_down_rounded, color: C.guard, size: 18),
          style: TextStyle(
              color: C.ink, fontSize: 12.5, fontWeight: FontWeight.w600),
          items: kSites.map((site) {
            return DropdownMenuItem<SiteOption>(
              value: site,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(site.icon,
                      size: 15,
                      color: site.id == _selectedSite.id ? C.guard : C.sub),
                  const SizedBox(width: 7),
                  Text(site.name,
                      style: TextStyle(
                        color: site.id == _selectedSite.id ? C.ink : C.sub,
                        fontSize: 12.5,
                        fontWeight: site.id == _selectedSite.id
                            ? FontWeight.w700
                            : FontWeight.w500,
                      )),
                ],
              ),
            );
          }).toList(),
          onChanged: (SiteOption? newSite) {
            if (newSite != null && newSite.id != _selectedSite.id) {
              _triggerHaptic(HapticImpact.selection);
              _switchSite(newSite);
            }
          },
        ),
      ),
    );
  }

  Widget _wsLiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: _wsConnected
            ? C.ok.withValues(alpha: 0.14)
            : C.warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: _wsConnected
                ? C.ok.withValues(alpha: 0.4)
                : C.warn.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _wsConnected ? C.ok : C.warn,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            _wsConnected ? 'Live stream' : 'Refreshes every 30s',
            style: TextStyle(
              color: _wsConnected ? C.ok : C.warn,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _veteranToggle() => GestureDetector(
        onTap: () {
          _triggerHaptic(HapticImpact.light);
          setState(() => _veteran = !_veteran);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
              color: C.panel,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: C.line)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 30,
              height: 17,
              decoration: BoxDecoration(
                  color: _veteran
                      ? C.guard.withValues(alpha: .35)
                      : const Color(0xFF26344A),
                  borderRadius: BorderRadius.circular(12)),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 160),
                alignment:
                    _veteran ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.all(2),
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                      color: _veteran ? C.guard : C.sub,
                      shape: BoxShape.circle),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(_veteran ? 'Vet' : 'Plain',
                style: TextStyle(
                    color: _veteran ? C.ink : C.sub,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      );

  Widget _sitrep(List<Sit> s) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final crossAxisCount = maxWidth > 1100
            ? 4
            : (maxWidth > 750 ? 3 : (maxWidth > 500 ? 2 : 1));

        return GridView.count(
          crossAxisCount: crossAxisCount,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio:
              crossAxisCount == 1 ? 3.6 : (crossAxisCount == 4 ? 2.4 : 2.5),
          mainAxisSpacing: 9,
          crossAxisSpacing: 9,
          children: s
              .map((x) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                    decoration: BoxDecoration(
                        color: C.panel,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: C.line)),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(x.l.toUpperCase(),
                              style: TextStyle(
                                  color: C.dim,
                                  fontSize: 9.5,
                                  letterSpacing: .9)),
                          const SizedBox(height: 2),
                          Row(children: [
                            Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                    color: C.state(x.state),
                                    shape: BoxShape.circle)),
                            Flexible(
                              child: Text(x.v,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: C.ink,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ]),
                          Text(x.s,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: C.sub, fontSize: 10.5)),
                        ]),
                  ))
              .toList(),
        );
      },
    );
  }

  // ---------- body (grid vs topology tree vs devices) ----------
  List<Widget> _body(Topology t) {
    if (_viewMode == ViewMode.devices) {
      return [
        SliverToBoxAdapter(child: _devicesView(t)),
      ];
    }

    if (_viewMode == ViewMode.tree) {
      return [
        SliverToBoxAdapter(child: _topologyTreeView(t)),
      ];
    }

    final out = <Widget>[];
    for (final g in t.groups) {
      out.add(SliverToBoxAdapter(child: _tierLabel(g)));
      out.add(
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.crossAxisExtent;
            final crossAxisCount = maxWidth > 1100
                ? 4
                : (maxWidth > 750 ? 3 : (maxWidth > 500 ? 2 : 1));

            return SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisExtent: g.kind == 'storage' ? 78 : 70,
                  crossAxisSpacing: 9,
                  mainAxisSpacing: 9,
                ),
                delegate: SliverChildBuilderDelegate(
                  (c, i) => _nodeCard(g.nodes[i]),
                  childCount: g.nodes.length,
                ),
              ),
            );
          },
        ),
      );
    }
    return out;
  }

  // ---------- devices tab implementation ----------
  Widget _devicesView(Topology t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title: Personal Gadgets
          Row(
            children: [
              Icon(Icons.devices_other_rounded, color: C.guard, size: 18),
              const SizedBox(width: 8),
              Text(
                'PERSONAL DEVICES (${t.devices.length})',
                style: TextStyle(
                  color: C.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (t.devices.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: C.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: C.line),
              ),
              child: Text(
                'No personal devices recorded in topology payload.',
                style: TextStyle(color: C.sub, fontSize: 12),
              ),
            )
          else
            ...t.devices.map((device) => _personalDeviceCard(device)),

          const SizedBox(height: 22),

          // Section Title: Homelab Nodes Traffic
          Wrap(
            children: [
              Icon(Icons.dns_rounded, color: C.funnel, size: 18),
              const SizedBox(width: 8),
              Text(
                'HOMELAB NODES & TRAFFIC',
                style: TextStyle(
                  color: C.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          ...t.groups
              .expand((g) => g.nodes)
              .map((node) => _nodeTrafficCard(node)),
        ],
      ),
    );
  }

  Widget _personalDeviceCard(PersonalDevice d) {
    final isOnline = d.state.toLowerCase() == 'online';
    final isOffline = d.state.toLowerCase() == 'offline';
    final stateColor = isOnline ? C.ok : (isOffline ? C.sub : C.warn);

    IconData deviceIcon = Icons.devices_rounded;
    if (d.kind == 'laptop') deviceIcon = Icons.laptop_mac_rounded;
    if (d.kind == 'phone') deviceIcon = Icons.phone_android_rounded;
    if (d.kind == 'wearable') deviceIcon = Icons.watch_rounded;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: C.guard.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(deviceIcon, color: C.guard, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            d.name,
                            style: TextStyle(
                              color: C.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: stateColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: stateColor.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: stateColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                d.state.toUpperCase(),
                                style: TextStyle(
                                  color: stateColor,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      d.what,
                      style: TextStyle(color: C.sub, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(color: C.line, height: 1),
          const SizedBox(height: 8),

          // Presence & Connectivity Line
          Row(
            children: [
              Icon(Icons.wifi_tethering_rounded, color: C.dim, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  d.via == 'tailscale'
                      ? 'Tailscale · ${d.lastSeen}'
                      : 'Presence: ${d.lastSeen}',
                  style: TextStyle(color: C.sub, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Talks To Destination
          Row(
            children: [
              Icon(Icons.alt_route_rounded, color: C.funnel, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Talks to: ${d.dest ?? "—"}',
                  style: TextStyle(
                      color: C.ink.withValues(alpha: 0.9), fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Bluetooth Capability
          Row(
            children: [
              Icon(Icons.bluetooth_rounded, color: C.tail, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Bluetooth capability: ${d.bluetooth ?? "—"}',
                  style: TextStyle(color: C.sub, fontSize: 11),
                ),
              ),
            ],
          ),
          Text("Declared capability, not live radio status",
              style: TextStyle(color: C.sub, fontSize: 11)),
          _trafficChart(d.name),
        ],
      ),
    );
  }

  Widget _nodeTrafficCard(HNode n) {
    final measure = n.traffic;
    return Card(
        color: C.panel,
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n.name,
                  style: TextStyle(color: C.ink, fontWeight: FontWeight.bold)),
              Text(_veteran ? n.tech : n.plain, style: TextStyle(color: C.sub)),
              Text('Talks to: ${n.dest ?? "—"}',
                  style: TextStyle(color: C.sub)),
              Text('Bluetooth capability: —', style: TextStyle(color: C.sub)),
              Text(
                  'Sent ${measure == null ? "—" : _fmtBytes(measure.up)} · Received ${measure == null ? "—" : _fmtBytes(measure.down)}',
                  style: TextStyle(color: C.ink)),
              if (measure != null)
                Text(
                    _veteran
                        ? '${measure.up} TX bytes / ${measure.down} RX bytes in ${measure.intervalS}s'
                        : 'Measured over ${measure.intervalS} seconds.',
                    style: TextStyle(color: C.sub, fontSize: 12)),
              _trafficChart(n.name),
            ])));
  }

  Widget _attentionSummary(Topology t) {
    final problems = t.groups
        .expand((g) => g.nodes)
        .where((n) => n.state != 'up' || (n.pct ?? 0) >= 90)
        .toList();
    final updated = DateTime.tryParse(t.updated);
    final stale = updated == null ||
        DateTime.now().difference(updated) > const Duration(minutes: 5) ||
        _error != null;
    final message = stale
        ? 'Saved or stale data — current health is unknown'
        : problems.isEmpty
            ? 'All clear'
            : '${problems.length} need attention: ${problems.take(3).map((n) => n.name).join(", ")}';
    return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: stale || problems.isNotEmpty ? C.warn : C.ok)));
  }

  Widget _trafficChart(String name) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final buckets = (_history?.nodes[name] ?? <TrafficBucket>[])
        .where((b) => b.t >= now - 86400 && b.t <= now)
        .toList();
    if (buckets.isEmpty) {
      return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Traffic log · last 24h: — No measurements yet',
              style: TextStyle(color: C.sub, fontSize: 12)));
    }
    final sent = buckets.fold<int>(0, (sum, b) => sum + b.up);
    final received = buckets.fold<int>(0, (sum, b) => sum + b.down);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 10),
      Text('Traffic log · last 24h', style: TextStyle(color: C.ink)),
      Semantics(
          label:
              'Recorded traffic. Sent ${_fmtBytes(sent)}, received ${_fmtBytes(received)}. Gaps excluded.',
          child: SizedBox(
              height: 72,
              width: double.infinity,
              child: CustomPaint(
                  painter: TrafficBarsPainter(buckets, now, C.funnel)))),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('24h ago', style: TextStyle(color: C.sub, fontSize: 11)),
        Text('Now', style: TextStyle(color: C.sub, fontSize: 11))
      ]),
      Text(
          'Recorded: sent ${_fmtBytes(sent)} · received ${_fmtBytes(received)}',
          style: TextStyle(color: C.ink, fontSize: 12)),
      Text(
          'Measured intervals only; gaps excluded. History begins ${_history?.coverageStart ?? "—"}.',
          style: TextStyle(color: C.sub, fontSize: 11)),
    ]);
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = (math.log(bytes) / math.log(1024)).floor();
    i = math.min(i, suffixes.length - 1);
    var num = bytes / math.pow(1024, i);
    return '${num.toStringAsFixed(num < 10 && i > 0 ? 1 : 0)} ${suffixes[i]}';
  }

  // ---------- topology tree view implementation ----------
  Widget _topologyTreeView(Topology t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Root Cluster Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: C.panel,
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: C.guard.withValues(alpha: 0.5), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: C.guard.withValues(alpha: 0.08),
                  blurRadius: 12,
                  spreadRadius: 2,
                )
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: C.guard.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_selectedSite.icon, color: C.guard, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _selectedSite.name.toUpperCase(),
                            style: TextStyle(
                              color: C.guard,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: C.ok.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'CLUSTER ROOT',
                              style: TextStyle(
                                  color: C.ok,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${t.node} • ${t.tailnet}',
                        style: TextStyle(
                            color: C.ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${t.groups.length} Tiers • ${t.groups.fold<int>(0, (acc, g) => acc + g.nodes.length)} Nodes',
                        style: TextStyle(color: C.sub, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Group Branches
          ...t.groups.asMap().entries.map((entry) {
            final g = entry.value;
            final isExpanded = _expandedTreeGroups[g.tier] ?? true;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rail Connector from Root/Prev to Group Header
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Container(
                    width: 2,
                    height: 14,
                    color: C.line,
                  ),
                ),

                // Group Header Branch Card
                GestureDetector(
                  onTap: () {
                    _triggerHaptic(HapticImpact.selection);
                    setState(() {
                      _expandedTreeGroups[g.tier] = !isExpanded;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: C.bg2,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: C.line),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isExpanded
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_right_rounded,
                          color: C.guard,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        if (kIcons[g.icon] != null) ...[
                          Icon(kIcons[g.icon], color: C.funnel, size: 16),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            g.tier.toUpperCase(),
                            style: TextStyle(
                              color: C.ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: C.panel,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: C.line),
                          ),
                          child: Text(
                            '${g.nodes.length} nodes',
                            style: TextStyle(
                                color: C.sub,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Group Child Leaf Nodes
                if (isExpanded)
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: C.guard.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: g.nodes.map((n) {
                          return Padding(
                            padding: const EdgeInsets.only(
                                left: 12, top: 8, bottom: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 12,
                                  height: 2,
                                  color: C.guard.withValues(alpha: 0.4),
                                ),
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: C.state(n.state),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _treeNodeCard(n),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _treeNodeCard(HNode n) {
    return GestureDetector(
      onTap: () {
        _triggerHaptic(HapticImpact.light);
        _detail(n);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.line),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: C.type(n.t).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: C.type(n.t).withValues(alpha: 0.4)),
              ),
              child: Text(
                n.t.toUpperCase(),
                style: TextStyle(
                  color: C.type(n.t),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          n.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: C.ink,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (n.expo != null) ...[
                        const SizedBox(width: 6),
                        _expoBadge(n.expo!),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    n.ip ?? n.meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: C.sub,
                      fontSize: 10.5,
                      fontFamily: 'Fira Code',
                    ),
                  ),
                  if (n.cpu != null && n.ram != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text('CPU ${n.cpu!.toStringAsFixed(1)}%',
                            style: TextStyle(color: C.dim, fontSize: 9.5)),
                        const SizedBox(width: 10),
                        Text('RAM ${n.ram}',
                            style: TextStyle(color: C.dim, fontSize: 9.5)),
                      ],
                    ),
                  ] else if (n.speed != null) ...[
                    const SizedBox(height: 4),
                    Text(n.speed!,
                        style: TextStyle(color: C.guard, fontSize: 9.5)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: C.dim, size: 18),
          ],
        ),
      ),
    );
  }

  // ---------- grid mode tier and cards ----------
  Widget _tierLabel(Group g) {
    final iconData = kIcons[g.icon];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
      child: Row(children: [
        if (iconData != null) ...[
          Icon(iconData, size: 14, color: C.dim),
          const SizedBox(width: 6),
        ],
        Text(g.tier.toUpperCase(),
            style: TextStyle(color: C.dim, fontSize: 10.5, letterSpacing: 1.3)),
        const SizedBox(width: 10),
        Expanded(child: Divider(color: C.line, height: 1)),
      ]),
    );
  }

  Widget _nodeCard(HNode n) => GestureDetector(
        onTap: () {
          _triggerHaptic(HapticImpact.light);
          _detail(n);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: C.bg2,
            borderRadius: BorderRadius.circular(10),
            border: Border(left: BorderSide(color: C.type(n.t), width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(children: [
                if (n.t != 'store' && n.t != 'net')
                  Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                          color: C.state(n.state), shape: BoxShape.circle)),
                Expanded(
                  child: Text(n.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: C.ink,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ),
                if (n.expo != null) _expoBadge(n.expo!),
              ]),
              const SizedBox(height: 3),
              Text(n.meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: C.sub, fontSize: 10.5, fontFamily: 'Fira Code')),
              if (n.cpu != null && n.ram != null) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('CPU ${n.cpu!.toStringAsFixed(1)}%',
                        style: TextStyle(color: C.dim, fontSize: 9.5)),
                    Text('RAM ${n.ram}',
                        style: TextStyle(color: C.dim, fontSize: 9.5)),
                  ],
                ),
              ] else if (n.speed != null) ...[
                const SizedBox(height: 4),
                Text(n.speed!, style: TextStyle(color: C.guard, fontSize: 9.5)),
              ],
              if (n.pct != null) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: n.pct! / 100.0,
                    minHeight: 5,
                    backgroundColor: const Color(0xFF1B2637),
                    color:
                        n.pct! >= 90 ? C.crit : (n.pct! >= 80 ? C.warn : C.ok),
                  ),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _expoBadge(String e) {
    final map = {
      'funnel': ['FUNNEL', C.funnel],
      'tail': ['TAIL', C.tail],
      'vpn': ['VPN', C.vpn],
    };
    final m = map[e];
    if (m == null) return const SizedBox.shrink();
    final col = m[1] as Color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
          color: col.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: col.withValues(alpha: .4))),
      child: Text(m[0] as String,
          style:
              TextStyle(color: col, fontSize: 8, fontWeight: FontWeight.w700)),
    );
  }

  // ---------- node detail sheet ----------
  void _detail(HNode n) {
    const typeName = {
      'host': 'Proxmox Host',
      'lxc': 'LXC Container',
      'vm': 'Virtual Machine',
      'docker': 'Docker Service',
      'net': 'Network',
      'guard': 'Self-Healing Guard',
      'store': 'Storage Volume',
    };
    showModalBottomSheet(
      context: context,
      backgroundColor: C.bg2,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (bottomSheetContext) => Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: MediaQuery.of(bottomSheetContext).size.height * 0.88,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 34),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                          color: C.line,
                          borderRadius: BorderRadius.circular(2))),
                ),
                Text((typeName[n.t] ?? 'Node').toUpperCase(),
                    style: TextStyle(
                        color: C.type(n.t),
                        fontSize: 10.5,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(n.name,
                    style: TextStyle(
                        color: C.ink,
                        fontSize: 21,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(n.meta, style: TextStyle(color: C.sub, fontSize: 12.5)),
                const SizedBox(height: 18),
                _sect('Actions'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        icon: Icons.restart_alt_rounded,
                        label: 'Restart',
                        color: C.warn,
                        onTap: () {
                          _triggerHaptic(HapticImpact.medium);
                          Navigator.pop(bottomSheetContext);
                          _executeContainerRestart(n);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        icon: Icons.copy_rounded,
                        label: 'Copy IP',
                        color: C.funnel,
                        onTap: () {
                          _triggerHaptic(HapticImpact.selection);
                          final targetIp = n.ip;
                          if (targetIp == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('IP address is unknown')));
                            return;
                          }
                          Clipboard.setData(ClipboardData(text: targetIp));
                          Navigator.pop(bottomSheetContext);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: C.panel,
                              content: Row(
                                children: [
                                  Icon(Icons.check_circle_outline,
                                      color: C.ok, size: 18),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text('Copied $targetIp to clipboard',
                                        style: TextStyle(color: C.ink)),
                                  ),
                                ],
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        icon: Icons.dns_rounded,
                        label: 'Flush DNS',
                        color: C.guard,
                        onTap: () {
                          _triggerHaptic(HapticImpact.medium);
                          Navigator.pop(bottomSheetContext);
                          _executeDnsFlush(n);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sect('What it does'),
                Text(_veteran ? n.tech : n.plain,
                    style:
                        TextStyle(color: C.ink, fontSize: 14.5, height: 1.5)),
                const SizedBox(height: 14),
                _sect(_veteran ? 'Plain Description' : 'Technical Details'),
                Text(_veteran ? n.plain : n.tech,
                    style: TextStyle(color: C.sub, fontSize: 13, height: 1.5)),
                if (n.pct != null) ...[
                  const SizedBox(height: 14),
                  _sect('Usage'),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: n.pct! / 100.0,
                      minHeight: 9,
                      backgroundColor: const Color(0xFF1B2637),
                      color: n.pct! >= 90
                          ? C.crit
                          : (n.pct! >= 80 ? C.warn : C.ok),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                      '${n.pct}% used${n.free != null ? " · ${n.free} free" : ""}',
                      style: TextStyle(color: C.sub, fontSize: 12)),
                ],
                if (n.url != null) ...[
                  const SizedBox(height: 18),
                  GestureDetector(
                    onTap: () async {
                      _triggerHaptic(HapticImpact.light);
                      final uri = Uri.parse(n.url!);
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                          color: C.funnel.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color: C.funnel.withValues(alpha: .4))),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Open ${n.name}  ↗',
                              style: TextStyle(
                                  color: C.funnel,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  void _executeContainerRestart(HNode n) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Restart is unavailable until a scoped phone credential is configured. No command was sent.')));
  }

  void _executeDnsFlush(HNode n) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'DNS changes are not available from this app. No command was sent.')));
  }

  // ---------- chaos engineering control sheet ----------

  // ---------- settings & theme customization control sheet ----------
  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.bg2,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          return Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 680,
                maxHeight: MediaQuery.of(context).size.height * 0.88,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: C.line,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: C.guard.withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.tune_rounded,
                                color: C.guard, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'CUSTOMIZATION & PREFERENCES',
                                  style: TextStyle(
                                    color: C.guard,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.9,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Synchronize theme palettes and tactile haptic profiles',
                                  style: TextStyle(color: C.sub, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _sect('Theme Aesthetic Profile'),
                      const SizedBox(height: 8),
                      ...kThemes.entries.map((tEntry) {
                        final profile = tEntry.key;
                        final themeData = tEntry.value;
                        final isSelected = C.activeProfile == profile;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GestureDetector(
                            onTap: () {
                              _triggerHaptic(HapticImpact.selection);
                              C.activeProfile = profile;
                              _savePreference(
                                  'hatch_theme_profile', themeData.id);
                              setSheetState(() {});
                              setState(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isSelected ? themeData.panel : C.panel,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected ? themeData.guard : C.line,
                                  width: isSelected ? 1.5 : 1.0,
                                ),
                              ),
                              child: Row(
                                children: [
                                  // Swatch preview dots
                                  Row(
                                    children: [
                                      _colorDot(themeData.bg),
                                      _colorDot(themeData.panel),
                                      _colorDot(themeData.guard),
                                      _colorDot(themeData.funnel),
                                    ],
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          themeData.name,
                                          style: TextStyle(
                                            color: C.ink,
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                        Text(
                                          themeData.description,
                                          style: TextStyle(
                                              color: C.sub, fontSize: 10.5),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(Icons.check_circle_rounded,
                                        color: C.guard, size: 18),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 18),
                      _sect('Tactile Haptic Feedback Profile'),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: C.panel,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: C.line),
                        ),
                        child: Column(
                          children: HapticProfile.values.map((profile) {
                            final isSelected = _selectedHaptic == profile;
                            final labels = {
                              HapticProfile.off: 'Disabled (Silent)',
                              HapticProfile.subtle: 'Subtle (Light Click)',
                              HapticProfile.standard: 'Standard Tactile',
                              HapticProfile.heavy: 'Heavy Dynamic',
                            };

                            return GestureDetector(
                              onTap: () {
                                _selectedHaptic = profile;
                                _savePreference(
                                    'hatch_haptic_profile', profile.name);
                                _triggerHaptic(HapticImpact.heavy);
                                setSheetState(() {});
                                setState(() {});
                              },
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? C.guard.withValues(alpha: 0.18)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(9),
                                  border: isSelected
                                      ? Border.all(
                                          color: C.guard.withValues(alpha: 0.4))
                                      : null,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      labels[profile] ?? profile.name,
                                      style: TextStyle(
                                        color: isSelected ? C.ink : C.sub,
                                        fontSize: 12.5,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                    if (isSelected)
                                      Icon(Icons.vibration_rounded,
                                          color: C.guard, size: 16),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _colorDot(Color col) {
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(
        color: col,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24, width: 0.5),
      ),
    );
  }

  Widget _sect(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s.toUpperCase(),
            style: TextStyle(color: C.dim, fontSize: 10.5, letterSpacing: 1)),
      );

  Widget _banner(String msg) => Container(
        margin: const EdgeInsets.fromLTRB(18, 4, 18, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            color: C.warn.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.warn.withValues(alpha: .4))),
        child: Row(children: [
          Icon(Icons.warning_amber_rounded, color: C.warn, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  _data != null ? 'Showing cached topology · $msg' : msg,
                  style: TextStyle(color: C.warn, fontSize: 12.5))),
        ]),
      );

  String _ago(String iso) {
    try {
      final t = DateTime.parse(iso);
      final d = DateTime.now().toUtc().difference(t);
      if (d.inMinutes < 1) return 'just now';
      if (d.inMinutes < 60) return '${d.inMinutes}m ago';
      return '${d.inHours}h ago';
    } catch (_) {
      return iso;
    }
  }
}

class TrafficBarsPainter extends CustomPainter {
  final List<TrafficBucket> buckets;
  final double now;
  final Color color;
  TrafficBarsPainter(this.buckets, this.now, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final maxBytes = buckets.fold<double>(
        1, (m, b) => math.max(m, (b.up + b.down).toDouble()));
    final paint = Paint()..color = color;
    for (final b in buckets) {
      final x =
          ((b.t - now + 86400) / 86400 * size.width).clamp(0.0, size.width);
      final height = math.max(1.0, (b.up + b.down) / maxBytes * size.height);
      canvas.drawRect(
          Rect.fromLTWH(
              x, size.height - height, math.max(1.0, size.width / 288), height),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant TrafficBarsPainter old) =>
      old.buckets != buckets || old.now != now || old.color != color;
}
