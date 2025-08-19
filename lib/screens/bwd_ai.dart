import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class Event {
  final double ts;
  final int rssi;
  final int handBrakeStatus;
  final int doorStatus;
  final int ignitionStatus;

  Event({
    required this.ts,
    required this.rssi,
    required this.handBrakeStatus,
    required this.doorStatus,
    required this.ignitionStatus,
  });

  Map<String, dynamic> toJson() => {
    "ts": double.parse(ts.toStringAsFixed(1)),
    "rssi": rssi,
    "handBrakeStatus": handBrakeStatus,
    "doorStatus": doorStatus,
    "ignitionStatus": ignitionStatus,
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
  int get avgRssi =>
      events.isEmpty ? 0 : (events.map((e) => e.rssi).reduce((a, b) => a + b) / events.length).round();
  int get minRssi => events.isEmpty ? 0 : events.map((e) => e.rssi).reduce(min);
  int get maxRssi => events.isEmpty ? 0 : events.map((e) => e.rssi).reduce(max);

  Map<String, dynamic> toPreviewJson() => {
    "start": {"command": "startTraining", "tag": tag, "device": device},
    "stream": events.take(min(40, events.length)).map((e) => e.toJson()).toList(),
    "end": {"command": "endTrain", "flag": true, "device": device},
    "meta": {
      "count": count,
      "durationSec": double.parse(durationSec.toStringAsFixed(1)),
      "avgRssi": avgRssi,
      "minRssi": minRssi,
      "maxRssi": maxRssi,
      if (events.length > 40) "truncated": events.length - 40,
    }
  };
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

  void enqueueSnack(String m) => _snack.add(m);
  String? takeSnack() => _snack.isEmpty ? null : _snack.removeAt(0);

  void dispose() {
    // Clean up any active connections or streams here
  }

  void startTraining() {
    isTraining = true;
    buffer.clear();
    trainingStartReal = DateTime.now();
    // In a real implementation, this is where you would subscribe
    // to the BLE characteristic for live data streaming.
  }

  TrainingSession endTrainingAndBuildSession() {
    isTraining = false;
    final started = trainingStartReal ?? DateTime.now();
    final ended =
    started.add(Duration(milliseconds: buffer.isEmpty ? 0 : (buffer.last.ts * 1000).round()));
    return TrainingSession(
      id: "SESS-${DateTime.now().millisecondsSinceEpoch}",
      tag: selectedTag ?? "baseline",
      device: (connectedDevice ?? "Unknown") + (connectedMac != null ? " ($connectedMac)" : ""),
      startedAt: started,
      endedAt: ended,
      events: List<Event>.from(buffer),
    );
  }

  void discardTraining() {
    isTraining = false;
    buffer.clear();
  }
}

const _tags = ["approach", "enter", "leave", "depart", "baseline"];
const kCardRadius = 12.0;
const kCardElevation = 4.0;

const int _RSSI_GOOD = -50;
const int _RSSI_OK = -70;

Color _getRssiColor(int rssi) {
  if (rssi > _RSSI_GOOD) return Colors.green;
  if (rssi > _RSSI_OK) return Colors.orange;
  return Colors.red;
}

Widget _rssiChip(int? rssi) {
  final has = rssi != null;
  final color = has ? _getRssiColor(rssi!) : Colors.grey;
  final announce = has ? 'Signal strength ${rssi} dBm' : 'Signal strength unavailable';
  final labelStyle = const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);

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

class _TagSelector extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelected;
  final bool enabled;

  const _TagSelector({super.key, required this.selected, required this.onSelected, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: _tags.map((t) {
        final isSel = t == selected;
        return ChoiceChip(
          label: Text(t,
              overflow: TextOverflow.ellipsis, softWrap: false, style: const TextStyle(fontSize: 12)),
          selected: isSel,
          onSelected: enabled ? (_) => onSelected(t) : null,
          showCheckmark: false,
          side: BorderSide.none,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          selectedColor: scheme.primary.withOpacity(0.20),
          backgroundColor: scheme.surfaceVariant.withOpacity(0.35),
          elevation: isSel ? 0.5 : 0.0,
          shape: const StadiumBorder(),
        );
      }).toList(),
    );
  }
}

class _LiveEventList extends StatelessWidget {
  final _UiState state;
  final VoidCallback notify;

  const _LiveEventList({super.key, required this.state, required this.notify});

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s.buffer.isEmpty) {
      return const Center(
          child: Text("Waiting for data stream...", style: TextStyle(fontStyle: FontStyle.italic)));
    }
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.zero,
      physics: const BouncingScrollPhysics(),
      itemCount: s.buffer.length,
      itemBuilder: (_, idx) {
        final e = s.buffer[s.buffer.length - 1 - idx];
        final rssiStatus = e.rssi > _RSSI_GOOD ? 'good' : (e.rssi > _RSSI_OK ? 'fair' : 'poor');
        return Semantics(
          label:
          'ts ${e.ts}s, RSSI ${e.rssi} dBm $rssiStatus, handbrake ${e.handBrakeStatus == 1 ? 'engaged' : 'disengaged'}',
          child: Column(
            key: ValueKey(e.ts),
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
                      ),
                    ),
                    Text(
                      "RSSI: ${e.rssi} dBm",
                      style: TextStyle(
                        fontSize: 13,
                        color: _getRssiColor(e.rssi),
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

class BwdAi extends StatefulWidget {
  const BwdAi({super.key});
  @override
  State<BwdAi> createState() => _BwdAiState();
}

class _BwdAiState extends State<BwdAi> {
  int _tab = 0;
  late final _UiState state;

  @override
  void initState() {
    super.initState();
    state = _UiState();
  }

  @override
  void dispose() {
    state.dispose();
    super.dispose();
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
                  state.currentRssi = null;
                });
                state.enqueueSnack("Training state reset.");
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('Reset Training State')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _ConnectTab(state: state, onChanged: () => setState(() {})),
          _TrainingTab(state: state, notify: () => setState(() {})),
          _HistoryTab(state: state, notify: () => setState(() {})),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: 'Connect'),
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
  const _ConnectTab({super.key, required this.state, required this.onChanged});

  @override
  State<_ConnectTab> createState() => _ConnectTabState();
}

class _ConnectTabState extends State<_ConnectTab> {
  bool _scanning = false;
  List<({String name, String mac, int rssi})> _found = [];

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found.clear();
    });

    // Replace this with your actual BLE scanning logic.
    // For now, it just shows the scanning indicator for 1.5s.
    await Future.delayed(const Duration(milliseconds: 1500));

    // When devices are found, populate the _found list and call setState.
    // e.g., _found.add((name: "BWD-123", mac: "AB:CD:...", rssi: -50));

    setState(() => _scanning = false);
  }

  void _connect(({String name, String mac, int rssi}) d) {
    final s = widget.state;
    // Add your BLE connection logic here.
    // On success, update the state:
    s.connectedDevice = d.name;
    s.connectedMac = d.mac;
    s.currentRssi = d.rssi;
    s.enqueueSnack("Connected to ${d.name}");
    widget.onChanged();
  }

  void _disconnect() {
    final s = widget.state;
    // Add your BLE disconnection logic here.
    s.connectedDevice = null;
    s.connectedMac = null;
    s.currentRssi = null;
    s.enqueueSnack("Disconnected.");
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final isConnected = s.connectedDevice != null;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: kCardElevation,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCardRadius)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device Status', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  if (isConnected)
                    Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Chip(
                              avatar: const Icon(Icons.bluetooth_connected, color: Colors.blue),
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
                                Text(
                                  s.connectedMac ?? "",
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey[600]),
                                ),
                              ],
                            ),
                            OutlinedButton.icon(
                              onPressed: _disconnect,
                              icon: const Icon(Icons.bluetooth_disabled),
                              label: const Text("Disconnect"),
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(kCardRadius)),
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
                            onPressed: _scanning ? null : _scan,
                            icon: const Icon(Icons.radar),
                            label: Text(_scanning ? "Scanning..." : "Scan for Devices"),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(kCardRadius)),
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
          Text('Available Devices', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Expanded(
            child: _found.isEmpty
                ? Center(
              child: Text(
                _scanning
                    ? "Discovering nearby BWD devices..."
                    : "Tap 'Scan' to discover BWD devices.",
                textAlign: TextAlign.center,
              ),
            )
                : ListView.builder(
              itemCount: _found.length,
              itemBuilder: (_, i) {
                final d = _found[i];
                final isSelected = s.connectedMac == d.mac;
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: const CircleAvatar(
                      backgroundColor: Colors.blueAccent,
                      child: Icon(Icons.bluetooth, color: Colors.white),
                    ),
                    title: Text(d.name,
                        style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                    subtitle: Text(d.mac),
                    trailing: Chip(
                      label: Text("${d.rssi} dBm"),
                      backgroundColor: _getRssiColor(d.rssi).withOpacity(0.1),
                      side: BorderSide.none,
                    ),
                    onTap: isSelected ? null : () => _connect(d),
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
  const _TrainingTab({super.key, required this.state, required this.notify});

  @override
  State<_TrainingTab> createState() => _TrainingTabState();
}

class _TrainingTabState extends State<_TrainingTab> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = CurvedAnimation(parent: _pulseController, curve: Curves.easeIn);
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCardRadius)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
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
                          child: const Icon(Icons.circle, size: 8, color: Colors.red),
                        ),
                        const SizedBox(width: 6),
                        Text("Recording", style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.brightness == Brightness.dark
                          ? scheme.surfaceVariant.withOpacity(0.22)
                          : scheme.surfaceVariant.withOpacity(0.32),
                      borderRadius: BorderRadius.circular(kCardRadius),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.bluetooth_connected, color: Colors.blue, size: 16),
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
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                    overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        if (isConnected) _rssiChip(s.currentRssi),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 0, thickness: 0.6),
                  const SizedBox(height: 12),
                  Text('Training Tags', style: Theme.of(context).textTheme.titleMedium),
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
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: Tooltip(
                      message: s.isTraining
                          ? "End the current training session"
                          : "Start the training session",
                      child: FilledButton.icon(
                        style: ButtonStyle(
                          backgroundColor: MaterialStateProperty.resolveWith((states) {
                            if (states.contains(MaterialState.disabled)) return null;
                            return s.isTraining ? Colors.red.shade700 : Colors.green.shade700;
                          }),
                          shape: MaterialStateProperty.all(
                            RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCardRadius)),
                          ),
                          padding:
                          MaterialStateProperty.all(const EdgeInsets.symmetric(vertical: 8)),
                          minimumSize: MaterialStateProperty.all(const Size.fromHeight(44)),
                        ),
                        icon: Icon(
                            s.isTraining ? Icons.stop_circle_outlined : Icons.play_circle_filled,
                            size: 20),
                        label: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
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
                            s.startTraining();
                            s.enqueueSnack(
                                '{"command":"startTraining","tag":"${s.selectedTag}"} sent');
                          } else {
                            _confirmEnd(context);
                            return;
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
          const SizedBox(height: 16),
          Text('Live Event Stream', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Expanded(
            child: s.isTraining
                ? _LiveEventList(state: s, notify: widget.notify)
                : const Center(
              child: Text("Live events will appear here once training starts."),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEnd(BuildContext context) async {
    final s = widget.state;
    final snap = s.endTrainingAndBuildSession();

    if (snap.count == 0) {
      s.enqueueSnack("Session has no events. Discarded.");
      s.discardTraining();
      widget.notify();
      return;
    }

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
            _kv("Avg RSSI", "${snap.avgRssi} dBm"),
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
      await _openReviewSheet(context, snap);
    } else if (res == "discard") {
      s.discardTraining();
      s.enqueueSnack('{"command":"endTrain","flag": false} sent · Training discarded');
      widget.notify();
    }
  }

  Future<void> _openReviewSheet(BuildContext context, TrainingSession session) async {
    final s = widget.state;
    bool submitEnabled = false;
    bool isSubmitting = false;
    bool armed = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final preview = session.toPreviewJson();
        final pretty = const JsonEncoder.withIndent('  ').convert(preview);
        final messenger = ScaffoldMessenger.of(context);
        final h = MediaQuery.of(ctx).size.height;
        final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
        final ScrollController scrollController = ScrollController();

        return Padding(
          padding: EdgeInsets.only(left: 16, right: 16, bottom: max(16, viewInsets)),
          child: StatefulBuilder(
            builder: (ctx2, setState) {
              if (!armed) {
                armed = true;
                Timer(const Duration(milliseconds: 1200), () {
                  if (Navigator.of(ctx2).canPop() && !submitEnabled) {
                    setState(() => submitEnabled = true);
                  }
                });
              }

              return FractionallySizedBox(
                heightFactor: 0.92,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 8),
                      child: Text("Review & Submit",
                          style: Theme.of(ctx2).textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.zero,
                        children: [
                          Text("Session Summary", style: Theme.of(ctx2).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          _kv("Device", session.device),
                          _kv("Tag", session.tag),
                          _kv("Events", "${session.count}"),
                          _kv("Duration", "${session.durationSec.toStringAsFixed(1)} s"),
                          _kv("RSSI",
                              "avg ${session.avgRssi} dBm (min ${session.minRssi} / max ${session.maxRssi})"),
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
                                pretty,
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Row(
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.copy_all),
                            label: const Text("Copy JSON"),
                            onPressed: isSubmitting
                                ? null
                                : () async {
                              await Clipboard.setData(ClipboardData(text: pretty));
                              if (mounted) {
                                messenger.clearSnackBars();
                                messenger.showSnackBar(
                                  const SnackBar(content: Text("JSON copied")),
                                );
                              }
                            },
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            icon: const Icon(Icons.send),
                            label: isSubmitting ? const Text("Submitting...") : const Text("Submit"),
                            onPressed: (submitEnabled && !isSubmitting)
                                ? () async {
                              HapticFeedback.selectionClick();
                              setState(() => isSubmitting = true);
                              // TODO: Replace with a real network call to the /train endpoint.
                              // Handle success and error cases.
                              await Future.delayed(const Duration(milliseconds: 1600));
                              if (!mounted) return;
                              s.history.insert(0, session);
                              s.discardTraining();
                              s.enqueueSnack(
                                  '{"command":"endTrain","flag": true} sent · Session submitted');
                              Navigator.pop(ctx);
                              widget.notify();
                            }
                                : null,
                          ),
                        ],
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
}

class _HistoryTab extends StatefulWidget {
  final _UiState state;
  final VoidCallback notify;
  const _HistoryTab({super.key, required this.state, required this.notify});
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
    final end = min(start + _per, total);
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
                child: Center(child: Text("No sessions yet. Save one from the Training tab.")))
          else
            Expanded(
              child: ListView.builder(
                itemCount: view.length,
                itemBuilder: (_, i) {
                  final sess = view[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    elevation: kCardElevation,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCardRadius)),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(sess.tag, style: Theme.of(context).textTheme.titleMedium),
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
                                label: Text("Duration: ${sess.durationSec.toStringAsFixed(1)}s"),
                                side: BorderSide.none,
                              ),
                              Chip(
                                label: Text("Avg RSSI: ${sess.avgRssi} dBm"),
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
                                  final pretty = const JsonEncoder.withIndent('  ')
                                      .convert(sess.toPreviewJson());
                                  showModalBottomSheet(
                                    context: context,
                                    isScrollControlled: true,
                                    useSafeArea: true,
                                    showDragHandle: true,
                                    builder: (ctx) {
                                      final ScrollController scrollController = ScrollController();
                                      return Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: FractionallySizedBox(
                                          heightFactor: 0.9,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text("JSON Preview",
                                                  style: Theme.of(ctx).textTheme.titleLarge),
                                              const SizedBox(height: 12),
                                              Expanded(
                                                child: Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.all(12),
                                                  decoration: BoxDecoration(
                                                    border: Border.all(
                                                        color: Theme.of(ctx).dividerColor),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: SingleChildScrollView(
                                                    controller: scrollController,
                                                    child: Text(pretty,
                                                        style: const TextStyle(
                                                            fontFamily: 'monospace')),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              SafeArea(
                                                top: false,
                                                child: Row(
                                                  children: [
                                                    OutlinedButton.icon(
                                                      icon: const Icon(Icons.copy_all),
                                                      label: const Text("Copy JSON"),
                                                      onPressed: () async {
                                                        await Clipboard.setData(
                                                            ClipboardData(text: pretty));
                                                        messenger.clearSnackBars();
                                                        messenger.showSnackBar(const SnackBar(
                                                            content: Text("JSON copied")));
                                                      },
                                                    ),
                                                    const Spacer(),
                                                    FilledButton(
                                                      onPressed: () => Navigator.pop(ctx),
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
                                    final newPages =
                                    (s.history.length / _per).ceil().clamp(1, 999);
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