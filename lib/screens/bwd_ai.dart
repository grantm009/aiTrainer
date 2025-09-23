import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:ui' show FontFeature;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http_parser/http_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
class IngestKeys {
  static const sessionId = 'sessionId';
  static const deviceMac = 'deviceMac';
  static const tag = 'tag';
  static const startedAt = 'startedAt';
  static const endedAt = 'endedAt';
  static const events = 'events';
  static const timestamp = 'timestamp';
  static const rssi = 'rssi';
  static const handBrakeStatus = 'handBrakeStatus';
  static const doorStatus = 'doorStatus';
  static const ignitionStatus = 'ignitionStatus';
  static const appVersion = 'appVersion';
  static const firmwareVersion = 'firmwareVersion';
}
String _apiTagFor(String tag) {
  switch (tag) {
    case "baseline":
      return "inside";
    default:
      return tag;
  }
}
Future<bool> _uploadEiJson({
  required Map<String, dynamic> eiJson,
  required String apiKey,
  String? fileName,
  String? label,
  bool toTesting = false,
}) async {
  final url = Uri.parse('https://ingestion.edgeimpulse.com/api/${toTesting ? "testing" : "training"}/data');
  final res = await http.post(
    url,
    headers: {
      'x-api-key': apiKey,
      if (fileName?.isNotEmpty == true) 'x-file-name': fileName!,
      if (label?.isNotEmpty == true) 'x-label': label!,
      HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
    },
    body: jsonEncode(eiJson),
  ).timeout(const Duration(seconds: 45));
  final ok = res.statusCode >= 200 && res.statusCode < 300;
  if (!ok) {
    debugPrint('EI JSON upload failed: ${res.statusCode} - ${res.body}');
  }
  return ok;
}
Future<bool> _uploadCsvToEdgeImpulse({
  required String csvPath,
  required String apiKey,
  String? label,
  bool toTesting = false,
}) async {
  final url = Uri.parse(
      'https://ingestion.edgeimpulse.com/api/${toTesting ? "testing" : "training"}/files');
  final req = http.MultipartRequest('POST', url)
    ..headers['x-api-key'] = apiKey
    ..headers['x-add-date-id'] = '1';
  if (label != null && label.isNotEmpty) {
    req.headers['x-label'] = label;
  }
  req.files.add(
    await http.MultipartFile.fromPath(
      'data',
      csvPath,
      contentType: MediaType('text', 'csv'),
    ),
  );
  final res = await req.send().timeout(const Duration(seconds: 45));
  final body = await res.stream.bytesToString();
  final ok = res.statusCode >= 200 && res.statusCode < 300;
  if (!ok) {
    debugPrint('EI CSV upload failed: ${res.statusCode} - $body');
  }
  return ok;
}

bool _validateIngestionPayload(Map<String, dynamic> p, {void Function(String)? onError}) {
  bool err(String m) {
    onError?.call(m);
    return false;
  }

  for (final k in [
    IngestKeys.sessionId, IngestKeys.deviceMac, IngestKeys.tag,
    IngestKeys.startedAt, IngestKeys.endedAt, IngestKeys.events
  ]) {
    if (!p.containsKey(k)) return err('Missing key: $k');
  }

  final ev = p[IngestKeys.events];
  if (ev is! List || ev.isEmpty) return err('Events missing or empty');

  for (final e in ev) {
    if (e is! Map) return err('Event not a map');
    if (e[IngestKeys.timestamp] is! double) return err('Event.timestamp must be double');
    if (e[IngestKeys.rssi] is! double) return err('Event.rssi must be double');
    if (e[IngestKeys.handBrakeStatus] is! int) return err('Event.handBrakeStatus must be int');
    if (e[IngestKeys.doorStatus] is! int) return err('Event.doorStatus must be int');
    if (e[IngestKeys.ignitionStatus] is! int) return err('Event.ignitionStatus must be int');
  }
  return true;
}
T _num<T extends num>(Object? v, T fallback) {
  if (v is num) return (T == int ? v.toInt() : v.toDouble()) as T;
  if (v is String) {
    final p = num.tryParse(v);
    if (p != null) return (T == int ? p.toInt() : p.toDouble()) as T;
  }
  return fallback;
}
double _clampTs(double ts) {
  if (ts.isNaN || ts.isInfinite || ts < 0) return 0.0;
  return ts;
}
int _clampRssi(int r) {
  if (r < -127) return -127;
  if (r > 20) return 20;
  return r;
}
double _clampRssiDouble(double r) {
  if (r < -127.0) return -127.0;
  if (r > 20.0) return 20.0;
  return r;
}
int _clampi01(num v) {
  final clamped = v.clamp(0, 1);
  return clamped.toInt();
}
String _csvEscape(Object? v) {
  final s = '$v';
  return (s.contains(',') || s.contains('\n') || s.contains('"'))
      ? '"${s.replaceAll('"', '""')}"'
      : s;
}
class Event {
  final double ts;
  final double rssi;
  final int handBrakeStatus;
  final int doorStatus;
  final int ignitionStatus;
  final String note;
  Event({
    required this.ts,
    required this.rssi,
    required this.handBrakeStatus,
    required this.doorStatus,
    required this.ignitionStatus,
    required this.note,
  });
  Map<String, dynamic> toJson() => {
    IngestKeys.timestamp: double.parse(ts.toStringAsFixed(1)),
    IngestKeys.rssi: double.parse(rssi.toStringAsFixed(1)),
    IngestKeys.handBrakeStatus: handBrakeStatus,
    IngestKeys.doorStatus: doorStatus,
    IngestKeys.ignitionStatus: ignitionStatus,
  };
  Map<String, dynamic> toCsvRow(String label) => {
    "timestamp": (ts * 1000).round(),
    "rssi": rssi.toStringAsFixed(1),
    "handbrake": handBrakeStatus,
    "ignition": ignitionStatus,
    "door": doorStatus,
    "label": label,
  };
}
class TrainingSession {
  final String id;
  final String tag;
  final String device;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<Event> events;
  TrainingSession({
    required this.id,
    required this.tag,
    required this.device,
    required this.startedAt,
    required this.endedAt,
    required this.events,
  });
  int get count => events.length;
  double get durationSec => events.isEmpty ? 0 : events.last.ts;
  double get avgRssi =>
      events.isEmpty ? 0 : events.map((e) => e.rssi).reduce((a, b) => a + b) / events.length;
  double get minRssi => events.isEmpty ? 0 : events.map((e) => e.rssi).reduce(math.min);
  double get maxRssi => events.isEmpty ? 0 : events.map((e) => e.rssi).reduce(math.max);
  Map<String, dynamic> toPreviewJson() => {
    "start": {"command": "startTraining", "tag": tag, "device": device},
    "stream": events.take(math.min(40, events.length)).map((e) => e.toJson()).toList(),
    "end": {"command": "endTrain", "flag": true, "device": device},
    "meta": {
      "count": count,
      "durationSec": double.parse(durationSec.toStringAsFixed(1)),
      "avgRssi": double.parse(avgRssi.toStringAsFixed(1)),
      "minRssi": double.parse(minRssi.toStringAsFixed(1)),
      "maxRssi": double.parse(maxRssi.toStringAsFixed(1)),
    }
  };
  Map<String, dynamic> toIngestionJson({
    required String deviceMac,
    String? appVersion,
    String? firmwareVersion,
    bool includeMeta = false, // <— new
  }) =>
      {
        IngestKeys.sessionId: id,
        IngestKeys.deviceMac: deviceMac,
        IngestKeys.tag: tag,
        IngestKeys.startedAt: startedAt.toUtc().toIso8601String(),
        IngestKeys.endedAt: endedAt.toUtc().toIso8601String(),
        if (appVersion != null) IngestKeys.appVersion: appVersion,
        if (firmwareVersion != null) IngestKeys.firmwareVersion: firmwareVersion,
        IngestKeys.events: events.map((e) => e.toJson()).toList(),
        if (includeMeta)
          "meta": {
            "device": device,
            "count": count,
            "durationSec": double.parse(durationSec.toStringAsFixed(1)),
            "avgRssi": double.parse(avgRssi.toStringAsFixed(1)),
            "minRssi": double.parse(minRssi.toStringAsFixed(1)),
            "maxRssi": double.parse(maxRssi.toStringAsFixed(1)),
          }
      };
  Map<String, dynamic> toEdgeImpulseIngestionJson() {
    final values = <List<double>>[];
    int lastMs = -999;
    // Iterate through the sorted events and sample at 2 Hz
    final sortedEvents = sortedByTimestamp().events;
    for (final e in sortedEvents) {
      final ms = (e.ts * 1000).round();
      if (ms - lastMs >= 500) {
        values.add([
          e.rssi,
          e.handBrakeStatus.toDouble(),
          e.ignitionStatus.toDouble(),
          e.doorStatus.toDouble()
        ]);
        lastMs = ms;
      }
    }
    return {
      "protected": {
        "ver": "v1",
        "alg": "none"
      },
      "signature": "UNSIGNED",
      "payload": {
        "device_type": "EDGE_IMPULSE_UPLOADER",
        "interval_ms": 500,
        "sensors": [
          {"name": "rssi", "units": "N/A"},
          {"name": "handbrake", "units": "N/A"},
          {"name": "ignition", "units": "N/A"},
          {"name": "door", "units": "N/A"}
        ],
        "values": values,
      }
    };
  }

  String get eiLabel {
    switch (tag) {
      case "approach":
        return "Driver_Approaching_Vehicle";
      case "enter":
        return "Driver_Entering_Vehicle";
      case "baseline":
        return "Driver_Inside_Vehicle";
      case "leave":
        return "Driver_Leaving_Vehicle";
      case "depart":
        return "Driver_Walking_Away";
      case "unauthorized_entry":
        return "Unauthorized_Entry";
      case "unauthorized_use_attempted":
        return "Unauthorized_Use_Attempted";
      default:
        return tag;
    }
  }

  List<Map<String, dynamic>> toCsvData() {
    final correctedTag = eiLabel;
    final List<Event> sampledEvents = [];
    int lastMs = -999;
    for (final e in sortedByTimestamp().events) {
      final ms = (e.ts * 1000).round();
      if (ms - lastMs >= 500) {
        // enforce 2 Hz
        sampledEvents.add(e);
        lastMs = ms;
      }
    }
    return sampledEvents.map((e) => e.toCsvRow(correctedTag)).toList();
  }
}
extension TrainingSessionSorting on TrainingSession {
  TrainingSession sortedByTimestamp() {
    final sorted = List<Event>.from(events)..sort((a, b) => a.ts.compareTo(b.ts));
    final newEnded = startedAt.add(Duration(
        milliseconds:
        sorted.isEmpty ? 0 : (sorted.last.ts * 1000).round()));
    return TrainingSession(
      id: id,
      tag: tag,
      device: device,
      startedAt: startedAt,
      endedAt: newEnded,
      events: sorted,
    );
  }
}

class _UiState {
  String? connectedDevice;
  String? connectedMac;
  int? currentRssi;
  bool isTraining = false;
  String? selectedTag;
  DateTime? trainingStartReal;
  final List<Event> buffer = [];
  final List<TrainingSession> history = [];
  final List<String> _snack = [];
  final int _bufferCap = 50000;
  String _notifyBuf = "";
  bool pendingEndTrain = false;
  bool eiUploadToTesting = false;

  void enqueueSnack(String m) => _snack.add(m);
  String? takeSnack() => _snack.isEmpty ? null : _snack.removeAt(0);
  void discardTraining() {
    isTraining = false;
    buffer.clear();
  }
}
const bool kDemoMode = bool.fromEnvironment('DEMO', defaultValue: true);
const String kServerUrl = kDemoMode
    ? "https://httpbin.org/post"
    : "https://your.api.endpoint/train";
const _tags = [
  "approach",
  "enter",
  "leave",
  "depart",
  "baseline",
  "unauthorized_entry",
  "unauthorized_use_attempted",
];
const kCardRadius = 12.0;
const kCardElevation = 4.0;
const Duration kStreamTimeout = Duration(seconds: 7);
const String kBwdServiceUuid = "fecdcb88-8e90-11ee-b9d1-0242ac120002";
const String kBwdRssiCharUuid = "fecdce67-8e90-11ee-b9d1-0242ac120002";
const String kBwdCtrlCharUuid = "fecdce99-8e90-11ee-b9d1-02123c1a000a";
const String kBwdStateCharUuid = "fecdce68-8e90-11ee-b9d1-0242ac120002";
String _fakeMac(math.Random r) {
  String two() => r.nextInt(256).toRadixString(16).padLeft(2, '0').toUpperCase();
  return "D1:9A:${two()}:${two()}:${two()}:${two()}";
}
class _TagSelector extends StatelessWidget {
  final String? selected;
  final bool enabled;
  final ValueChanged<String> onSelected;
  const _TagSelector({
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _tags.length,
        itemBuilder: (_, i) {
          final t = _tags[i];
          final isSel = t == selected;
          return ChoiceChip(
            label: Text(t),
            selected: isSel,
            onSelected: enabled ? (_) => onSelected(t) : null,
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
      ),
    );
  }
}
class BwdAi extends StatefulWidget {
  const BwdAi({super.key});
  @override
  State<BwdAi> createState() => _BwdAiState();
}

class _BwdAiState extends State<BwdAi> {
  int _tab = 0;
  late final _UiState state;
  final List<ScanResult> _devices = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  BluetoothCharacteristic? _ctrlChar;
  BluetoothCharacteristic? _rssiChar;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _streamWatchdog;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  BluetoothCharacteristic? _stateChar;
  String? _cachedFwVersion;
  Timer? _reconnectTimer;
  int _retries = 0;
  BluetoothDevice? _lastDevice;
  final _rng = math.Random();
  Timer? _listRebuildThrottle;
  Timer? _demoTimer;
  double _demoTime = 0.0;

  @override
  void initState() {
    super.initState();
    state = _UiState();
    _initBluetooth();
  }

  @override
  void dispose() {
    _teardownConnection();
    _demoTimer?.cancel();
    _scanSub?.cancel();
    _scanSub = null;
    _adapterStateSub?.cancel();
    _adapterStateSub = null;
    _listRebuildThrottle?.cancel();
    _listRebuildThrottle = null;
    FlutterBluePlus.stopScan().catchError((_) {});
    super.dispose();
  }

  // === BLE Core functions ===
  Future<void> _initBluetooth() async {
    if (kDemoMode) {
      state.connectedDevice = "BWD-DEMO";
      state.connectedMac = "D1:9A:AA:BB:CC:DD";
      if (mounted) setState(() {});
      return;
    }
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
      if (statuses.values.any((s) => !s.isGranted)) {
        state.enqueueSnack("Permissions denied.");
        return;
      }
    }
    _adapterStateSub = FlutterBluePlus.adapterState.listen((s) async {
      if (s == BluetoothAdapterState.on) {
        if (state.connectedDevice == null) {
          _startScan();
        }
      } else {
        _stopReconnect();
        if (state.isTraining) {
          await _sendEndTraining(false);
          state.discardTraining();
        }
        state.enqueueSnack("Bluetooth is off. Please enable it.");
        if (mounted) {
          setState(() {
            state.connectedDevice = null;
            state.connectedMac = null;
            state.currentRssi = null;
          });
        }
      }
    });
  }

  void _startScan() async {
    _devices.clear();
    state.enqueueSnack("Scanning for BWD devices...");
    _scanSub?.cancel();
    // FIX: Add fallback for nameless devices by checking for the BWD service UUID
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        final hasBwdSvc = r.advertisementData.serviceUuids
            .map((u) => u.toString().toLowerCase())
            .contains(kBwdServiceUuid.toLowerCase());
        if ((name.isNotEmpty && name.startsWith('BWD')) || hasBwdSvc) {
          final idx = _devices.indexWhere((e) => e.device.remoteId == r.device.remoteId);
          if (idx == -1) {
            _devices.add(r);
          } else {
            _devices[idx] = r; // update RSSI
          }
        }
      }
    });
    setState(() {});
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
  }

  Future<void> _teardownConnection() async {
    _notifySub?.cancel();
    _notifySub = null;
    _streamWatchdog?.cancel();
    _streamWatchdog = null;
    await _connSub?.cancel();
    _connSub = null;
    _ctrlChar = null;
    _rssiChar = null;
    _reconnectTimer?.cancel();
    _retries = 0;
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
      _connectedDevice = null;
    }
  }

  void _stopReconnect() {
    _reconnectTimer?.cancel();
    _retries = 0;
  }

  void _beginAutoReconnect() {
    _reconnectTimer?.cancel();
    final jitter = _rng.nextInt(200).toDouble() / 1000.0;
    final delay = Duration(
        milliseconds:
        (1000 * (1 << _retries)).clamp(1000, 30000) + (jitter * 1000).toInt());
    state.enqueueSnack(
        "Attempting reconnect in ${delay.inSeconds}s (Retry ${_retries + 1})...");
    _reconnectTimer = Timer(delay, () async {
      if (_lastDevice == null) return;
      _retries++;
      try {
        await _lastDevice!
            .connect(timeout: const Duration(seconds: 10), autoConnect: false);
        _retries = 0;
        _connectedDevice = _lastDevice;
        state.connectedDevice =
            _lastDevice?.platformName ?? _lastDevice?.remoteId.toString();
        state.connectedMac = _lastDevice?.remoteId.toString();
        state.enqueueSnack("Reconnected to ${state.connectedDevice ?? ''}.");
        await _discoverServices();
        if (mounted) setState(() {});
      } catch (_) {
        _beginAutoReconnect();
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice d) async {
    _teardownConnection();
    _lastDevice = d;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;
    final displayName =
    d.platformName?.isNotEmpty == true ? d.platformName : d.remoteId.toString();
    state.enqueueSnack("Connecting to $displayName...");
    try {
      await d.connect(timeout: const Duration(seconds: 10), autoConnect: false);
      if (Platform.isAndroid) {
        try {
          await d.requestMtu(247);
        } catch (_) {}
      }
      _connectedDevice = d;
      state.connectedDevice = displayName;
      state.connectedMac = d.remoteId.toString();
      _connSub = d.connectionState.listen((s) async {
        if (s == BluetoothConnectionState.disconnected) {
          if (state.isTraining) {
            state.pendingEndTrain = true; // queue endTrain(false) for next reconnect
            state.discardTraining();
            state.enqueueSnack("Disconnected: training ended.");
            if (mounted) setState(() {});
          } else {
            state.enqueueSnack("Disconnected.");
          }
          await _teardownConnection();
          _beginAutoReconnect();
        }
      });
      await _discoverServices();
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      state.enqueueSnack("Failed to connect: $e");
      await _teardownConnection();
      _beginAutoReconnect();
    }
  }
  Future<void> _discoverServices() async {
    if (_connectedDevice == null) return;
    try {
      final services = await _connectedDevice!.discoverServices();
      final bwdSvc = services.firstWhere(
            (svc) => svc.uuid.toString().toLowerCase() == kBwdServiceUuid.toLowerCase(),
        orElse: () => throw 'BWD service not found',
      );
      for (final c in bwdSvc.characteristics) {
        final id = c.uuid.toString().toLowerCase();
        if (id == kBwdCtrlCharUuid.toLowerCase()) _ctrlChar = c;
        if (id == kBwdRssiCharUuid.toLowerCase()) _rssiChar = c;
        if (id == kBwdStateCharUuid.toLowerCase()) _stateChar = c;
      }
      state.enqueueSnack("Services discovered.");
      try {
        final raw = await _stateChar?.read();
        if (raw != null && raw.isNotEmpty) {
          _cachedFwVersion = utf8.decode(raw).trim();
          state.enqueueSnack("Firmware Version: $_cachedFwVersion");
        }
      } catch (_) {
      }
      if (state.pendingEndTrain && _ctrlChar != null) {
        try {
          await _sendEndTraining(false);
        } catch (_) {}
        state.pendingEndTrain = false;
      }
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      state.enqueueSnack("Service discovery failed: $e");
    }
  }

  Future<void> _safeWrite(BluetoothCharacteristic ch, List<int> data) async {
    try {
      await ch.write(data, withoutResponse: true);
    } catch (_) {
      await ch.write(data, withoutResponse: false);
    }
  }

  void _kickStreamWatchdog() {
    _streamWatchdog?.cancel();
    _streamWatchdog = Timer(kStreamTimeout, () async {
      if (mounted) {
        if (state.isTraining) {
          await _sendEndTraining(false);
          state.discardTraining();
        }
        state.enqueueSnack("Stream timed out. Disconnecting.");
        await _teardownConnection();
        _beginAutoReconnect();
      }
    });
  }

  Future<void> _sendStartTraining(String tag) async {
    if (kDemoMode) {
      state.isTraining = true;
      state.buffer.clear();
      _demoTime = 0.0;
      final rnd = math.Random();
      _demoTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted || !state.isTraining) {
          timer.cancel();
          return;
        }
        final e = Event(
          ts: _demoTime,
          rssi: (-65 + rnd.nextInt(5)).toDouble(),
          handBrakeStatus: _clampi01(1),
          doorStatus: _clampi01((_demoTime > 4 && _demoTime < 6) ? 1 : 0),
          ignitionStatus: _clampi01((_demoTime >= 2) ? 1 : 0),
          note: "demo#${state.buffer.length + 1}",
        );
        state.buffer.add(e);
        state.currentRssi = e.rssi.round();
        setState(() {});
        _demoTime += 0.5;
        if (_demoTime >= 20.0) {
          _sendEndTraining(true);
        }
      });
      state.enqueueSnack('Demo stream started.');
      return;
    }
    if (_ctrlChar == null) {
      state.enqueueSnack("Control characteristic not found.");
      return;
    }
    final payload = jsonEncode({"command": "startTraining", "tag": tag});
    await _safeWrite(_ctrlChar!, utf8.encode(payload));
    _subscribeTraining();
  }
  Future<void> _sendEndTraining(bool save) async {
    if (kDemoMode) {
      _demoTimer?.cancel();
      state.isTraining = false;
      if (mounted) setState(() {});
      state.enqueueSnack('Demo stream ended.');
      return;
    }
    if (_ctrlChar == null) {
      state.enqueueSnack("Control characteristic not found.");
      return;
    }
    final payload = jsonEncode({"command": "endTrain", "flag": save});
    await _safeWrite(_ctrlChar!, utf8.encode(payload));
    await Future.delayed(const Duration(milliseconds: 200)); // allow tail packets
    try {
      await _rssiChar?.setNotifyValue(false);
    } catch (_) {}
    await _notifySub?.cancel();
    _notifySub = null;
    _streamWatchdog?.cancel();
    _streamWatchdog = null;
    state.isTraining = false;
    state._notifyBuf = "";
    if (mounted) setState(() {});
  }
  Future<void> _subscribeTraining() async {
    if (_rssiChar == null) {
      state.enqueueSnack('Training stream characteristic not found.');
      return;
    }
    state._notifyBuf = "";
    bool ok = false;
    try {
      await _rssiChar!.setNotifyValue(true);
      ok = true;
    } catch (e) {
      state.enqueueSnack("Failed to enable notifications: $e");
    }
    if (!ok) return;
    _notifySub?.cancel();
    _notifySub = _rssiChar!.value.listen(_handleTrainingNotify);
    state.isTraining = true;
    state.buffer.clear();
    _kickStreamWatchdog();
    setState(() {});
  }
  void _handleTrainingNotify(List<int> bytes) {
    _kickStreamWatchdog();
    state._notifyBuf += utf8.decode(bytes);
    int nl;
    while ((nl = state._notifyBuf.indexOf('\n')) != -1) {
      final line = state._notifyBuf.substring(0, nl).trim();
      state._notifyBuf = state._notifyBuf.substring(nl + 1);
      if (line.isNotEmpty) _parseEventLine(line);
    }
    int depth = 0, start = -1;
    for (int i = 0; i < state._notifyBuf.length; i++) {
      final ch = state._notifyBuf[i];
      if (ch == '{') {
        if (depth++ == 0) start = i;
      }
      if (ch == '}') {
        if (--depth == 0 && start != -1) {
          final jsonStr = state._notifyBuf.substring(start, i + 1);
          _parseEventLine(jsonStr);
          state._notifyBuf = state._notifyBuf.substring(i + 1);
          i = -1; // restart scan
          start = -1;
        }
      }
    }
  }
  void _parseEventLine(String line) {
    try {
      final Map<String, dynamic> p = json.decode(line);
      final rssiSrc = p.containsKey('rssi')
          ? p['rssi']
          : (p.containsKey('RSSI') ? p['RSSI'] : -127);
      final event = Event(
        ts: _clampTs(_num<double>(p['timestamp'], 0.0)),
        rssi: _clampRssiDouble(_num<double>(rssiSrc, -127.0)),
        handBrakeStatus: _clampi01(_num<int>(
            p.containsKey('handBrakeStatus') ? p['handBrakeStatus'] : p['handbrake'], 0)),
        doorStatus: _clampi01(_num<int>(
            p.containsKey('doorStatus') ? p['doorStatus'] : p['door'], 0)),
        ignitionStatus: _clampi01(_num<int>(p.containsKey('ignitionStatus')
            ? p['ignitionStatus']
            : p['ignition'], 0)),
        note: "pkt#${state.buffer.length + 1}",
      );
      final last = state.buffer.isNotEmpty ? state.buffer.last.ts : null;
      if (last != null && event.ts < last) {
        state.enqueueSnack("Warning: Out-of-order packet received (kept).");
      }
      state.buffer.add(event);
      state.currentRssi = event.rssi.round();
      _requestLiveListRebuild();
    } catch (e) {
      state.enqueueSnack("Failed to parse training data: $e");
    }
  }

  void _requestLiveListRebuild() {
    if (!mounted) return;
    if (_listRebuildThrottle != null) return;
    _listRebuildThrottle = Timer(const Duration(milliseconds: 100), () {
      if (mounted) setState(() {});
      _listRebuildThrottle = null;
    });
  }
  Future<http.Response> _postWithRetry(Uri uri, {required Map<String,String> headers, required String body}) async {
    int attempt = 0;
    while (true) {
      try {
        final res = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 15));
        if (res.statusCode < 500 || res.statusCode >= 600 || attempt >= 2) return res;
      } catch (_) {
        if (attempt >= 2) rethrow;
      }
      await Future.delayed(Duration(milliseconds: 400 * (1 << attempt)));
      attempt++;
    }
  }
  Future<bool> _submitSession(TrainingSession session) async {
    if (kDemoMode) {
      await Future.delayed(const Duration(milliseconds: 300));
      state.enqueueSnack("Demo: submit simulated ✅ (not sent to server)");
      return true;
    }
    if ((state.connectedMac ?? "").isEmpty) {
      state.enqueueSnack("Device MAC missing. Please reconnect and try again.");
      return false;
    }
    if (session.tag.isEmpty || session.count == 0 || session.durationSec <= 0) {
      state.enqueueSnack("Nothing to submit (tag/events/duration invalid).");
      return false;
    }
    if (session.count > 10000) {
      state.enqueueSnack(
          "Large session (${session.count} events). Consider splitting.");
    }
    if (kServerUrl.isEmpty ||
        kServerUrl.contains('your.api.endpoint') ||
        kServerUrl.contains('<your-backend>')) {
      state.enqueueSnack("Server URL not configured. Submissions blocked.");
      return false;
    }
    final sorted = session.sortedByTimestamp();
    final payload = sorted.toIngestionJson(
      deviceMac: state.connectedMac ?? "UNKNOWN",
      appVersion: "1.0.0",
      firmwareVersion: _cachedFwVersion,
      includeMeta: false,
    );
    payload[IngestKeys.tag] = _apiTagFor(sorted.tag);
    assert(
    const DeepCollectionEquality().equals(
      (payload[IngestKeys.events] as List).first.keys.toSet(),
      {
        IngestKeys.timestamp,
        IngestKeys.rssi,
        IngestKeys.handBrakeStatus,
        IngestKeys.doorStatus,
        IngestKeys.ignitionStatus,
      }.toSet(),
    ),
    'CSV columns mismatch. Check Event.toJson()',
    );

    if (!_validateIngestionPayload(payload, onError: state.enqueueSnack)) {
      state.enqueueSnack("Payload validation failed!");
      return false;
    }
    try {
      final uri = Uri.parse(kServerUrl);
      final res = await _postWithRetry(
        uri,
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          HttpHeaders.acceptHeader: 'application/json',
          if (const String.fromEnvironment('BWD_API_KEY').isNotEmpty)
            'x-api-key': const String.fromEnvironment('BWD_API_KEY'),
        },
        body: jsonEncode(payload),
      );
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      state.enqueueSnack(ok
          ? "Session submitted successfully!"
          : "Submission failed: HTTP ${res.statusCode}");
      if (res.statusCode == 413) {
        state.enqueueSnack(
            "Submission failed: Session too large for the server. Consider splitting.");
      }
      return ok;
    } on SocketException {
      state.enqueueSnack("No internet connection.");
      return false;
    } on TimeoutException {
      state.enqueueSnack("Submission timed out. Please try again.");
      return false;
    } catch (e) {
      state.enqueueSnack("Submission failed: $e");
      return false;
    }
  }
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final m = state.takeSnack();
      if (m != null && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.showSnackBar(SnackBar(content: Text(m)));
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('BWD AI Training'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'reset') {
                setState(() {
                  state.discardTraining();
                  state.selectedTag = null;
                  state.connectedDevice = null;
                  state.connectedMac = null;
                  state.currentRssi = null;
                  _teardownConnection();
                });
                state.enqueueSnack("Training state reset.");
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'reset', child: Text('Reset Training State')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _ConnectTab(
            state: state,
            onChanged: () => setState(() {}),
            devices: _devices,
            startScan: _startScan,
            connectToDevice: _connectToDevice,
            disconnect: () async {
              _lastDevice = null;
              await _teardownConnection();
              state.discardTraining();
              setState(() {
                state.connectedDevice = null;
                state.connectedMac = null;
                state.currentRssi = null;
              });
              state.enqueueSnack("Disconnected.");
            },
            isConnected: state.connectedDevice != null,
          ),
          _TrainingTab(
            state: state,
            notify: () => setState(() {}),
            startTraining: _sendStartTraining,
            endTraining: _sendEndTraining,
            submitSession: _submitSession, // Pass the new function
          ),
          _HistoryTab(state: state, notify: () => setState(() {})),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.bluetooth_searching), label: 'Connect'),
          NavigationDestination(icon: Icon(Icons.timeline), label: 'Training'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}
class _ConnectTab extends StatefulWidget {
  final _UiState state;
  final VoidCallback onChanged;
  final List<ScanResult> devices;
  final VoidCallback startScan;
  final Function(BluetoothDevice d) connectToDevice;
  final VoidCallback disconnect;
  final bool isConnected;
  const _ConnectTab({
    required this.state,
    required this.onChanged,
    required this.devices,
    required this.startScan,
    required this.connectToDevice,
    required this.disconnect,
    required this.isConnected,
  });
  @override
  State<_ConnectTab> createState() => _ConnectTabState();
}

class _ConnectTabState extends State<_ConnectTab> {
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: kCardElevation,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kCardRadius)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device Status',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  if (widget.isConnected)
                    Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Chip(
                              avatar: const Icon(Icons.bluetooth_connected,
                                  color: Colors.blue),
                              label: const Text("Connected"),
                              backgroundColor: Colors.blue.withOpacity(0.1),
                              side: BorderSide.none,
                            ),
                            _rssiChip(s.currentRssi),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.connectedDevice ?? "",
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                GestureDetector(
                                  onLongPress: () {
                                    if (s.connectedMac != null) {
                                      Clipboard.setData(ClipboardData(text: s.connectedMac!));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('MAC address copied')),
                                      );
                                    }
                                  },
                                  child: Text(
                                    s.connectedMac ?? "",
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.grey[600]),
                                  ),
                                ),
                              ],
                            ),
                            OutlinedButton.icon(
                              onPressed: widget.disconnect,
                              icon: const Icon(Icons.bluetooth_disabled),
                              label: const Text("Disconnect"),
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                    BorderRadius.circular(kCardRadius)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: widget.startScan,
                            icon: const Icon(Icons.radar),
                            label: const Text("Scan for Devices"),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                  BorderRadius.circular(kCardRadius)),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Available Devices',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Expanded(
            child: widget.devices.isEmpty
                ? const Center(
              child: Text(
                "Tap 'Scan' to discover BWD devices.",
                textAlign: TextAlign.center,
              ),
            )
                : ListView.builder(
              itemCount: widget.devices.length,
              itemBuilder: (_, i) {
                final sr = widget.devices[i];
                final d = sr.device;
                final name = sr.advertisementData.advName.isNotEmpty
                    ? sr.advertisementData.advName
                    : (d.platformName?.isNotEmpty == true
                    ? d.platformName
                    : d.remoteId.toString());
                final isSelected = s.connectedMac == d.remoteId.toString();
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  elevation: isSelected ? kCardElevation : 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(kCardRadius),
                    side: isSelected
                        ? const BorderSide(color: Colors.blue, width: 2)
                        : BorderSide.none,
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    leading: const CircleAvatar(
                      backgroundColor: Colors.blueAccent,
                      child: Icon(Icons.bluetooth, color: Colors.white),
                    ),
                    title: Text(name,
                        style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal)),
                    subtitle: Text(d.remoteId.toString()),
                    trailing: Chip(
                      label: Text("${sr.rssi} dBm"),
                      // NITS: Use >= for accurate bucket edges
                      backgroundColor: _getRssiColor(sr.rssi).withOpacity(0.1),
                      side: BorderSide.none,
                    ),
                    onTap: isSelected ? null : () => widget.connectToDevice(d),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
class _TrainingTab extends StatefulWidget {
  final _UiState state;
  final VoidCallback notify;
  final Function(String tag) startTraining;
  final Function(bool save) endTraining;
  final Future<bool> Function(TrainingSession) submitSession;
  const _TrainingTab({
    required this.state,
    required this.notify,
    required this.startTraining,
    required this.endTraining,
    required this.submitSession,
  });
  @override
  State<_TrainingTab> createState() => _TrainingTabState();
}
class _TrainingTabState extends State<_TrainingTab>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation =
        CurvedAnimation(parent: _pulseController, curve: Curves.easeIn);
  }
  @override
  void didUpdateWidget(covariant _TrainingTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.isTraining != oldWidget.state.isTraining) {
      if (widget.state.isTraining) {
        _pulseController.repeat(reverse: true);
      } else {
        _pulseController.stop();
      }
    }
  }
  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }
  Future<void> _confirmEnd(BuildContext context) async {
    final s = widget.state;
    final snap = TrainingSession(
      id: "SESS-${DateTime.now().millisecondsSinceEpoch}",
      tag: s.selectedTag ?? "baseline",
      device: (s.connectedDevice ?? "Unknown") +
          (s.connectedMac != null ? " (${s.connectedMac})" : ""),
      startedAt: s.trainingStartReal ?? DateTime.now(),
      endedAt: s.trainingStartReal?.add(Duration(
          milliseconds:
          s.buffer.isEmpty ? 0 : (s.buffer.last.ts * 1000).round())) ??
          DateTime.now(),
      events: List<Event>.from(s.buffer),
    );
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("End Training?"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv("Tag", snap.tag),
            _kv("Duration", "${snap.durationSec.toStringAsFixed(1)} s"),
            _kv("Events", "${snap.count}"),
            _kv("Avg RSSI", "${snap.avgRssi.toStringAsFixed(1)} dBm"),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, "discard"),
            child: const Text("Discard"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, "save"),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (res == "save") {
      widget.endTraining(true);
      await _openReviewSheet(context, snap);
    } else if (res == "discard") {
      widget.endTraining(false);
      s.discardTraining();
      s.enqueueSnack('{"command":"endTrain","flag": false} sent · Training discarded');
      widget.notify();
    }
  }
  Future<String?> _saveCsvToDisk(TrainingSession session) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final csvData = session.toCsvData();
      if (csvData.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text("No data to export.")));
        return null;
      }
      final headers = const ['timestamp', 'rssi', 'handbrake', 'ignition', 'door', 'label'];
      final buf = StringBuffer()..writeln(headers.join(','));
      for (final row in csvData) {
        buf.writeln(headers.map((h) => _csvEscape(row[h])).join(','));
      }
      final csvString = buf.toString();
      final ts = DateTime.now().toIso8601String();
      final safeTs = ts.replaceAll(RegExp(r'[<>:"/\\|?*\s]+'), '-');
      final fname = 'bwd_${session.tag}_$safeTs.csv';

      Directory base;
      if (Platform.isAndroid) {
        base = (await getExternalStorageDirectory())!;
        final appDir = Directory('${base.path}/BWD');
        if (!(await appDir.exists())) await appDir.create(recursive: true);
        base = appDir;
      } else {
        base = await getApplicationDocumentsDirectory();
      }

      final file = File('${base.path}/$fname');
      await file.writeAsString(csvString);

      messenger.showSnackBar(SnackBar(content: Text("CSV saved to ${file.path}")));

      return file.path;

    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("CSV export failed: $e")));
      return null;
    }
  }
  Future<void> _openReviewSheet(BuildContext context, TrainingSession session) async {
    final s = widget.state;
    bool submitEnabled = true;
    bool isSubmitting = false;
    bool toTesting = s.eiUploadToTesting;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final preview = session.toPreviewJson();
        final pretty = const JsonEncoder.withIndent(' ').convert(preview);
        final messenger = ScaffoldMessenger.of(context);
        final h = MediaQuery.of(ctx).size.height;
        final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
        final ScrollController scrollController = ScrollController();
        return Padding(
          padding: EdgeInsets.only(left: 16, right: 16, bottom: math.max(16.0, viewInsets)),
          child: StatefulBuilder(
            builder: (ctx2, setState) {
              Future<void> _submitAndClose() async {
                setState(() => isSubmitting = true);
                final success = await widget.submitSession(session);
                if (!mounted) return;

                if (success) {
                  s.history.insert(0, session);
                  s.discardTraining();

                  const eiApiKey = String.fromEnvironment('EI_PROJECT_API_KEY');
                  if (eiApiKey.isNotEmpty) {
                    final eiJson = session.toEdgeImpulseIngestionJson();
                    final ok = await _uploadEiJson(
                      eiJson: eiJson,
                      apiKey: eiApiKey,
                      fileName: 'bwd_${session.tag}_${DateTime.now().millisecondsSinceEpoch}.json',
                      label: session.eiLabel,
                      toTesting: toTesting,
                    );
                    s.enqueueSnack(ok
                        ? 'Auto-uploaded to Edge Impulse ✅'
                        : 'Auto-upload to EI failed ❌');
                  } else {
                    s.enqueueSnack('EI_PROJECT_API_KEY not set. Skipping auto-upload.');
                  }

                  s.enqueueSnack('Session submitted.');
                  Navigator.pop(ctx);
                } else {
                  setState(() => isSubmitting = false);
                  messenger.showSnackBar(
                    SnackBar(
                      content: const Text("Submission failed. Retry?"),
                      action: SnackBarAction(label: "RETRY", onPressed: _submitAndClose),
                    ),
                  );
                }
                widget.notify();
              }
              return FractionallySizedBox(
                heightFactor: 0.92,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 8),
                      child: Text("Review & Submit", style: Theme.of(ctx2).textTheme.titleLarge, overflow:
                      TextOverflow.ellipsis),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.zero,
                        children: [
                          Text("Session Summary", style: Theme.of(ctx2).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          _kv("Device", session.device),
                          // Show both UI tag and API tag to prevent confusion
                          _kv("Tag (UI)", session.tag),
                          _kv("Tag (API)", _apiTagFor(session.tag)),
                          _kv("Events", "${session.count}"),
                          _kv("Duration", "${session.durationSec.toStringAsFixed(1)} s"),
                          _kv("RSSI", "avg ${session.avgRssi.toStringAsFixed(1)} dBm (min ${session.minRssi.toStringAsFixed(1)} / max ${session.maxRssi.toStringAsFixed(1)})"),
                          const SizedBox(height: 12),
                          Text("JSON Preview", style: Theme.of(ctx2).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Container(
                            constraints: BoxConstraints(
                              maxHeight: h * 0.40,
                            ),
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Theme.of(ctx2).dividerColor),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SingleChildScrollView(
                              child: Text(
                                // MODIFIED: If Demo Mode, show the correct EI JSON format.
                                kDemoMode
                                    ? const JsonEncoder.withIndent(' ').convert(session.toEdgeImpulseIngestionJson())
                                    : pretty,
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SwitchListTile(
                            title: const Text('Upload to Testing set'),
                            value: toTesting,
                            onChanged: isSubmitting ? null : (v) => setState(() {
                              toTesting = v;
                              s.eiUploadToTesting = v;
                            }),
                            secondary: const Icon(Icons.psychology_outlined),
                          ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        child: LayoutBuilder(
                          builder: (ctx3, c) {
                            final narrow = c.maxWidth < 380; // small phones
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.spaceBetween,
                                  children: [
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.copy_all),
                                      label: const Text("Copy JSON"),
                                      onPressed: isSubmitting ? null : () async {
                                        final content = kDemoMode
                                            ? const JsonEncoder.withIndent(' ').convert(session.toEdgeImpulseIngestionJson())
                                            : pretty;
                                        await Clipboard.setData(ClipboardData(text: content));
                                        messenger.clearSnackBars();
                                        messenger.showSnackBar(const SnackBar(content: Text("JSON copied")));
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.file_download),
                                      label: const Text("Export EI JSON"),
                                      onPressed: isSubmitting ? null : () async {
                                        final messenger = ScaffoldMessenger.of(context);
                                        try {
                                          final eiJson = session.toEdgeImpulseIngestionJson();
                                          final jsonString = const JsonEncoder.withIndent(' ').convert(eiJson);

                                          final ts = DateTime.now().toIso8601String();
                                          final safeTs = ts.replaceAll(RegExp(r'[<>:"/\\|?*\s]+'), '-');
                                          final fname = 'bwd_${session.tag}_$safeTs.json';

                                          Directory base;
                                          if (Platform.isAndroid) {
                                            base = (await getExternalStorageDirectory())!;
                                            final appDir = Directory('${base.path}/BWD');
                                            if (!(await appDir.exists())) await appDir.create(recursive: true);
                                            base = appDir;
                                          } else {
                                            base = await getApplicationDocumentsDirectory();
                                          }
                                          final file = File('${base.path}/$fname');
                                          await file.writeAsString(jsonString);

                                          messenger.showSnackBar(SnackBar(content: Text("JSON saved to ${file.path}")));
                                          await Share.shareXFiles([XFile(file.path)], text: 'Edge Impulse JSON export');

                                        } catch (e) {
                                          messenger.showSnackBar(SnackBar(content: Text("JSON export failed: $e")));
                                        }
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.ios_share),
                                      label: const Text("Share CSV"),
                                      onPressed: () async {
                                        final path = await _saveCsvToDisk(session);
                                        if (path != null) {
                                          await Share.shareXFiles([XFile(path)], text: 'BWD session CSV');
                                        }
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.cloud_upload),
                                      label: const Text("Upload EI JSON"),
                                      onPressed: isSubmitting ? null : () async {
                                        final messenger = ScaffoldMessenger.of(context);
                                        const eiApiKey = String.fromEnvironment('EI_PROJECT_API_KEY');
                                        if (eiApiKey.isEmpty) {
                                          messenger.showSnackBar(const SnackBar(content: Text("Missing EI API key")));
                                          return;
                                        }
                                        final eiJson = session.toEdgeImpulseIngestionJson();
                                        final ok = await _uploadEiJson(
                                          eiJson: eiJson,
                                          apiKey: eiApiKey,
                                          fileName: 'bwd_${session.tag}_${DateTime.now().millisecondsSinceEpoch}.json',
                                          label: session.eiLabel,
                                          toTesting: toTesting,
                                        );
                                        messenger.clearSnackBars();
                                        messenger.showSnackBar(SnackBar(
                                          content: Text(ok ? "Uploaded to Edge Impulse ✅" : "Upload failed ❌"),
                                        ));
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.file_upload),
                                      label: const Text("Upload EI CSV"),
                                      onPressed: isSubmitting ? null : () async {
                                        final messenger = ScaffoldMessenger.of(context);
                                        const eiApiKey = String.fromEnvironment('EI_PROJECT_API_KEY');
                                        if (eiApiKey.isEmpty) {
                                          messenger.showSnackBar(const SnackBar(content: Text("Missing EI API key")));
                                          return;
                                        }

                                        final path = await _saveCsvToDisk(session);
                                        if (path == null) {
                                          return;
                                        }
                                        final ok = await _uploadCsvToEdgeImpulse(
                                          csvPath: path,
                                          apiKey: eiApiKey,
                                          label: session.eiLabel,
                                          toTesting: toTesting,
                                        );
                                        messenger.clearSnackBars();
                                        messenger.showSnackBar(
                                          SnackBar(content: Text(ok ? "Uploaded to Edge Impulse ✅" : "Upload failed ❌")),
                                        );
                                      },
                                    ),
                                    SizedBox(
                                      width: narrow ? double.infinity : null,
                                      child: FilledButton.icon(
                                        icon: const Icon(Icons.send),
                                        label: isSubmitting ? const Text("Submitting...") : const Text("Submit"),
                                        onPressed: (submitEnabled && !isSubmitting) ? _submitAndClose : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final isConnected = s.connectedDevice != null;
    final scheme = Theme.of(context).colorScheme;
    final canStart = isConnected && s.selectedTag != null && !s.isTraining;
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: kCardElevation,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kCardRadius)),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Training Session',
                          style: Theme.of(context).textTheme.titleLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (s.isTraining) ...[
                        FadeTransition(
                          opacity: _pulseAnimation,
                          child: const Icon(Icons.circle,
                              size: 8, color: Colors.red),
                        ),
                        const SizedBox(width: 6),
                        Text("Recording",
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.brightness == Brightness.dark
                          ? scheme.surfaceVariant.withOpacity(0.22)
                          : scheme.surfaceVariant.withOpacity(0.32),
                      borderRadius: BorderRadius.circular(kCardRadius),
                    ),
                    padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.bluetooth_connected,
                            color: Colors.blue, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isConnected ? s.connectedDevice! : "No device selected",
                                  style: Theme.of(context).textTheme.bodyMedium,
                                  overflow: TextOverflow.ellipsis),
                              if (isConnected && s.connectedMac != null)
                                Text(s.connectedMac!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures()
                                      ],
                                    ),
                                    overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        if (isConnected) _rssiChip(s.currentRssi),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 0, thickness: 0.6),
                  const SizedBox(height: 8),
                  Text('Training Tags',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (!isConnected)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Connect a BWD device in the Connect tab to start training.',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ),
                  if (s.selectedTag == null && !s.isTraining)
                    Text('Choose a tag to enable Start',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(fontStyle: FontStyle.italic)),
                  _TagSelector(
                    selected: s.selectedTag,
                    enabled: !s.isTraining,
                    onSelected: (t) => setState(() => s.selectedTag = t),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: Tooltip(
                      message: s.isTraining
                          ? "End the current training session"
                          : "Start the training session",
                      child: FilledButton.icon(
                        style: ButtonStyle(
                          backgroundColor:
                          MaterialStateProperty.resolveWith((states) {
                            if (states.contains(MaterialState.disabled)) {
                              return null;
                            }
                            return s.isTraining
                                ? Colors.red.shade700
                                : Colors.green.shade700;
                          }),
                          shape: MaterialStateProperty.all(
                            RoundedRectangleBorder(
                                borderRadius:
                                BorderRadius.circular(kCardRadius)),
                          ),
                          padding: MaterialStateProperty.all(
                              const EdgeInsets.symmetric(vertical: 8)),
                          minimumSize: MaterialStateProperty.all(
                              const Size.fromHeight(44)),
                        ),
                        icon: Icon(
                            s.isTraining
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_filled,
                            size: 20),
                        label: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          transitionBuilder: (c, a) =>
                              FadeTransition(opacity: a, child: c),
                          child: Text(
                            s.isTraining ? "End Training" : "Start Training",
                            key: ValueKey(s.isTraining),
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                        onPressed: (s.isTraining || canStart)
                            ? () {
                          HapticFeedback.selectionClick();
                          if (!s.isTraining) {
                            s.trainingStartReal = DateTime.now();
                            widget.startTraining(s.selectedTag!);
                            s.enqueueSnack(
                                '{"command":"startTraining","tag":"${s.selectedTag}"} sent');
                          } else {
                            _confirmEnd(context);
                          }
                          widget.notify();
                        }
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('Live Event Stream',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Expanded(
            child: s.isTraining
                ? _LiveEventList(state: s)
                : s.buffer.isEmpty
                ? const Center(
                child: Text(
                    "Live events will appear here once training starts."))
                : _LiveEventList(state: s),
          ),
        ],
      ),
    );
  }
}
const int RSSI_GOOD = -50;
const int RSSI_OK = -70;
Color _getRssiColor(int rssi) {
  if (rssi >= RSSI_GOOD) return Colors.green;
  if (rssi >= RSSI_OK) return Colors.orange;
  return Colors.red;
}
Widget _rssiChip(int? rssi) {
  final has = rssi != null;
  final color = has ? _getRssiColor(rssi!) : Colors.grey;
  final announce =
  has ? 'Signal strength ${rssi} dBm' : 'Signal strength unavailable';
  final labelStyle = const TextStyle(
      fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);
  return Semantics(
    label: announce,
    child: Chip(
      visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      avatar: Icon(Icons.network_wifi, color: color, size: 16),
      label: Text(
        has ? "$rssi dBm" : "—",
        overflow: TextOverflow.fade,
        softWrap: false,
        maxLines: 1,
        style: labelStyle,
      ),
      backgroundColor: color.withOpacity(0.12),
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
  );
}
Widget _kv(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 80, maxWidth: 130),
        child: Text(k,
            style: const TextStyle(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis),
      ),
      const SizedBox(width: 6),
      Expanded(child: Text(v, overflow: TextOverflow.ellipsis, maxLines: 2)),
    ],
  ),
);

class _LiveEventList extends StatefulWidget {
  final _UiState state;
  const _LiveEventList({required this.state});
  @override
  _LiveEventListState createState() => _LiveEventListState();
}

class _LiveEventListState extends State<_LiveEventList> {
  final _scrollController = ScrollController();
  bool get _atLiveEdge => !_scrollController.hasClients ? true : _scrollController.offset <= 24.0;

  @override
  void didUpdateWidget(covariant _LiveEventList oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_atLiveEdge && _scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
    });
  }
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (s.buffer.isEmpty) {
      return const Center(
        child: Text(
          "Initializing stream...",
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    }
    final total = s.buffer.length;
    final start = math.max(0, total - 200); // Show last 200 events
    final view = s.buffer.sublist(start);

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      physics: const BouncingScrollPhysics(),
      itemCount: view.length,
      itemBuilder: (_, idx) {
        final e = view[idx];
        final rssiStatus = e.rssi >= RSSI_GOOD ? 'good' : (e.rssi >= RSSI_OK ? 'fair' : 'poor');

        return Semantics(
          label: 'ts ${e.ts}s, RSSI ${e.rssi} dBm $rssiStatus, handbrake ${e.handBrakeStatus == 1 ? 'engaged' : 'disengaged'}',
          child: Column(
            key: ValueKey(e.note),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "ts: ${e.ts.toStringAsFixed(2)}s",
                        style: const TextStyle(
                          fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    Text(
                      "RSSI: ${e.rssi.toStringAsFixed(1)} dBm",
                      style: TextStyle(
                        fontSize: 13,
                        color: _getRssiColor(e.rssi.round()),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Text(
                  "Handbrake: ${e.handBrakeStatus == 1 ? 'Engaged' : 'Disengaged'} · "
                      "Door: ${e.doorStatus == 1 ? 'Open' : 'Closed'} · "
                      "Ignition: ${e.ignitionStatus == 1 ? 'On' : 'Off'}",
                  style: const TextStyle(fontSize: 12.5, height: 1.2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 0, thickness: 0.6),
            ],
          ),
        );
      },
    );
  }
}
class _HistoryTab extends StatefulWidget {
  final _UiState state;
  final VoidCallback notify;
  const _HistoryTab({required this.state, required this.notify});
  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}
class _HistoryTabState extends State<_HistoryTab> {
  int _page = 1;
  static const _per = 5;
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final total = s.history.length;
    final pages = (total / _per).ceil().clamp(1, 999);
    final start = (_page - 1) * _per;
    final end = math.min(start + _per, total);
    final view = s.history.sublist(start, end);
    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    final messenger = ScaffoldMessenger.of(context);
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Session History', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (total == 0)
            const Expanded(
                child: Center(
                    child: Text("No sessions yet. Save one from Training.")))
          else
            Expanded(
              child: ListView.builder(
                itemCount: view.length,
                itemBuilder: (_, i) {
                  final sess = view[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    elevation: kCardElevation,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(kCardRadius)),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(sess.tag,
                                  style: Theme.of(context).textTheme.titleMedium),
                              const Spacer(),
                              Text("Created: ${fmt.format(sess.endedAt)}",
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text("Device: ${sess.device}",
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(
                                label: Text("Events: ${sess.count}"),
                                side: BorderSide.none,
                              ),
                              Chip(
                                label: Text(
                                    "Duration: ${sess.durationSec.toStringAsFixed(1)}s"),
                                side: BorderSide.none,
                              ),
                              Chip(
                                label: Text(
                                    "Avg RSSI: ${sess.avgRssi.toStringAsFixed(1)} dBm"),
                                side: BorderSide.none,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              OutlinedButton.icon(
                                icon: const Icon(Icons.visibility),
                                label: const Text("Preview JSON"),
                                onPressed: () {
                                  final pretty = const JsonEncoder.withIndent(' ')
                                      .convert(sess.toPreviewJson());
                                  showModalBottomSheet(
                                    context: context,
                                    isScrollControlled: true,
                                    useSafeArea: true,
                                    showDragHandle: true,
                                    builder: (ctx) {
                                      final ScrollController scrollController =
                                      ScrollController();
                                      return Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: FractionallySizedBox(
                                          heightFactor: 0.9,
                                          child: Column(
                                            crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                            children: [
                                              Text("JSON Preview",
                                                  style: Theme.of(ctx)
                                                      .textTheme
                                                      .titleLarge),
                                              const SizedBox(height: 12),
                                              Expanded(
                                                child: Container(
                                                  width: double.infinity,
                                                  padding:
                                                  const EdgeInsets.all(12),
                                                  decoration: BoxDecoration(
                                                    border: Border.all(
                                                        color: Theme.of(ctx)
                                                            .dividerColor),
                                                    borderRadius:
                                                    BorderRadius.circular(8),
                                                  ),
                                                  child: SingleChildScrollView(
                                                    controller: scrollController,
                                                    child: Text(pretty,
                                                        style: const TextStyle(
                                                            fontFamily:
                                                            'monospace')),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              SafeArea(
                                                top: false,
                                                child: Row(
                                                  children: [
                                                    OutlinedButton.icon(
                                                      icon:
                                                      const Icon(Icons.copy_all),
                                                      label: const Text("Copy JSON"),
                                                      onPressed: () async {
                                                        await Clipboard.setData(
                                                            ClipboardData(
                                                                text: pretty));
                                                        messenger.clearSnackBars();
                                                        messenger.showSnackBar(
                                                            const SnackBar(
                                                                content: Text(
                                                                    "JSON copied")));
                                                      },
                                                    ),
                                                    const Spacer(),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(ctx),
                                                      child: const Text("Close"),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                icon: const Icon(Icons.delete),
                                label: const Text("Delete"),
                                onPressed: () {
                                  final removed = s.history.removeAt(start + i);
                                  final oldPage = _page;
                                  setState(() {
                                    final newPages = (s.history.length / _per)
                                        .ceil()
                                        .clamp(1, 999);
                                    if (_page > newPages) _page = newPages;
                                  });
                                  widget.notify();
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: const Text('Session deleted'),
                                      action: SnackBarAction(
                                        label: 'UNDO',
                                        onPressed: () {
                                          setState(() {
                                            s.history.insert(start + i, removed);
                                            _page = oldPage;
                                          });
                                          widget.notify();
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          if (total > _per) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _page == 1 ? null : () => setState(() => _page--),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Previous page',
                ),
                Text("Page $_page of $pages"),
                IconButton(
                  onPressed: _page == pages ? null : () => setState(() => _page++),
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: 'Next page',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}