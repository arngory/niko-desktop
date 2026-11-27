import 'dart:convert';
import 'dart:io';

import '../daemon/daemon.dart';
import '../state/window_settings.dart';

const desktopBackupFormat = 'niko-desktop-backup';
const desktopBackupVersion = 1;

/// Summary of an exported desktop configuration backup.
class BackupExportSummary {
  const BackupExportSummary({
    required this.path,
    required this.groups,
    required this.profiles,
    required this.rules,
    required this.skippedNodes,
  });

  final String path;
  final int groups;
  final int profiles;
  final int rules;
  final int skippedNodes;
}

/// Dry-run preview of a desktop configuration backup before applying it (H6 / D-ADD-10).
class BackupPreview {
  const BackupPreview({
    required this.groups,
    required this.subscriptions,
    required this.profiles,
    required this.rules,
    required this.hasSettings,
    required this.containsSecrets,
  });

  final int groups;
  final int subscriptions;
  final int profiles;
  final int rules;
  final bool hasSettings;
  final bool containsSecrets;
}

/// Inspects a backup JSON string without modifying the daemon store.
BackupPreview inspectDesktopBackupJson(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('backup file must be a JSON object');
  }
  if (decoded['format'] != desktopBackupFormat) {
    throw const FormatException('unsupported backup format');
  }
  final version = decoded['version'];
  if (version is! int || version < 1 || version > desktopBackupVersion) {
    throw FormatException('unsupported backup version: $version');
  }
  final rawGroups = decoded['groups'] is List ? decoded['groups'] as List : const [];
  var groups = 0;
  var subs = 0;
  for (final g in rawGroups) {
    if (g is! Map) continue;
    if (g['subscription'] == true) {
      subs++;
    } else if (g['ungrouped'] != true) {
      groups++;
    }
  }
  final profiles = decoded['profiles'] is List ? (decoded['profiles'] as List).length : 0;
  final rules = decoded['rules'] is List ? (decoded['rules'] as List).length : 0;
  final hasSettings = decoded['settings'] is Map && (decoded['settings'] as Map).isNotEmpty;
  return BackupPreview(
    groups: groups,
    subscriptions: subs,
    profiles: profiles,
    rules: rules,
    hasSettings: hasSettings,
    containsSecrets: profiles > 0 || subs > 0,
  );
}

/// Summary of an imported desktop configuration backup.
class BackupImportSummary {
  const BackupImportSummary({
    required this.groups,
    required this.profiles,
    required this.rules,
    required this.settingsRestored,
  });

  final int groups;
  final int profiles;
  final int rules;
  final bool settingsRestored;
}

/// Builds a portable JSON backup map of all non-node groups, profiles, routing rules, daemon settings,
/// and window preferences. Raycontrol node groups and device keys are intentionally omitted because
/// device keys stay bound to a single machine (salamander-device-v1 §6).
Future<(Map<String, Object?> payload, int groups, int profiles, int rules, int skippedNodes)> buildDesktopBackup({
  required Daemon daemon,
  WindowSettings? windowSettings,
  DateTime? now,
}) async {
  final allGroups = await daemon.groups();
  final exportedGroups = <Map<String, Object?>>[];
  final exportedProfiles = <Map<String, Object?>>[];
  final groupIndexById = <int, int>{};
  final profileIndexById = <int, int>{};
  var skippedNodes = 0;

  for (final g in allGroups) {
    if (g.nodeId.isNotEmpty) {
      skippedNodes++;
      continue;
    }
    final idx = exportedGroups.length;
    groupIndexById[g.id] = idx;
    exportedGroups.add({
      'name': g.name,
      'ungrouped': g.ungrouped,
      'subscription': g.subscription,
      if (g.subscription && g.info != null)
        'info': {
          'link': g.info!.link,
          'autoUpdate': g.info!.autoUpdate,
          'autoUpdateDelay': g.info!.autoUpdateDelay,
          'deduplication': g.info!.deduplication,
          'forceResolve': g.info!.forceResolve,
          'updateWhenConnectedOnly': g.info!.updateWhenConnectedOnly,
          'customUserAgent': g.info!.customUserAgent,
        },
    });
    if (!g.subscription) {
      final rows = await daemon.profiles(groupId: g.id);
      for (final row in rows) {
        try {
          final saved = await daemon.profile(row.id);
          profileIndexById[row.id] = exportedProfiles.length;
          exportedProfiles.add({
            'groupIndex': idx,
            'type': saved.row.type,
            'beanJson': saved.beanJson,
          });
        } catch (_) {
          // Skip profiles whose secrets cannot be decrypted on this machine.
        }
      }
    }
  }

  final ruleRows = await daemon.rules();
  final exportedRules = [
    for (final r in ruleRows)
      {
        'name': r.name,
        'enabled': r.enabled,
        'domains': r.domains,
        'ip': r.ip,
        'port': r.port,
        'sourcePort': r.sourcePort,
        'network': r.network,
        'source': r.source,
        'protocol': r.protocol,
        'programs': r.programs,
        'dpiBypass': r.dpiBypass,
        'outbound': r.outbound,
        if (r.outbound > 0 && profileIndexById.containsKey(r.outbound))
          'outboundProfileIndex': profileIndexById[r.outbound],
        'config': r.config,
      },
  ];

  final daemonSettings = await daemon.settings();
  final payload = <String, Object?>{
    'format': desktopBackupFormat,
    'version': desktopBackupVersion,
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'groups': exportedGroups,
    'profiles': exportedProfiles,
    'rules': exportedRules,
    'settings': daemonSettings,
    if (windowSettings != null)
      'windowSettings': {
        'advanced': windowSettings.advanced,
        'theme': windowSettings.theme,
        'language': windowSettings.language,
        'connectOnStartup': windowSettings.connectOnStartup,
        'closeToTray': windowSettings.closeToTray,
        'notifications': windowSettings.notifications,
      },
  };

  final customGroups = exportedGroups.where((g) => g['ungrouped'] != true).length;
  return (payload, customGroups, exportedProfiles.length, exportedRules.length, skippedNodes);
}

/// Exports the desktop configuration backup to a timestamped JSON file inside [destDir]
/// (chmod 0600 on Unix since profile beans contain proxy credentials).
Future<BackupExportSummary> exportDesktopBackup({
  required Daemon daemon,
  required Directory destDir,
  WindowSettings? windowSettings,
  DateTime? now,
}) async {
  final stampTime = (now ?? DateTime.now()).toUtc();
  final (payload, groups, profiles, rules, skippedNodes) = await buildDesktopBackup(
    daemon: daemon,
    windowSettings: windowSettings,
    now: stampTime,
  );
  await destDir.create(recursive: true);
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${stampTime.year}${two(stampTime.month)}${two(stampTime.day)}-${two(stampTime.hour)}${two(stampTime.minute)}${two(stampTime.second)}';
  final path = '${destDir.path}${Platform.pathSeparator}niko-backup-$stamp.json';
  final file = File(path);
  final encoder = const JsonEncoder.withIndent('  ');
  // Create empty file and lock down permissions BEFORE writing any plaintext credentials (H6).
  await file.create(exclusive: false);
  if (!Platform.isWindows) {
    try {
      await Process.run('chmod', ['600', path]);
    } catch (_) {}
  } else {
    final user = Platform.environment['USERNAME']?.trim();
    if (user != null && user.isNotEmpty) {
      try {
        await Process.run('icacls', [path, '/inheritance:r', '/grant:r', '$user:(R,W)']);
      } catch (_) {}
    }
  }
  await file.writeAsString('${encoder.convert(payload)}\n', flush: true);
  return BackupExportSummary(
    path: path,
    groups: groups,
    profiles: profiles,
    rules: rules,
    skippedNodes: skippedNodes,
  );
}

/// Imports a portable desktop backup JSON string into [daemon] and optionally [windowSettings].
Future<BackupImportSummary> importDesktopBackupJson({
  required Daemon daemon,
  required String jsonText,
  WindowSettings? windowSettings,
}) async {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('backup file must be a JSON object');
  }
  if (decoded['format'] != desktopBackupFormat) {
    throw const FormatException('unsupported backup format');
  }
  final version = decoded['version'];
  if (version is! int || version < 1 || version > desktopBackupVersion) {
    throw FormatException('unsupported backup version: $version');
  }

  final existingGroups = await daemon.groups();
  final ungroupedId = existingGroups.where((g) => g.ungrouped).firstOrNull?.id ?? 0;
  final basicGroupByName = <String, int>{
    for (final g in existingGroups)
      if (!g.ungrouped && !g.subscription && g.nodeId.isEmpty) g.name: g.id,
  };
  final existingSubLinks = <String>{
    for (final g in existingGroups)
      if (g.subscription && g.info != null && g.info!.link.isNotEmpty) g.info!.link,
  };

  final importedGroupIds = <int, int>{};
  var createdGroups = 0;

  final rawGroups = decoded['groups'];
  if (rawGroups is List) {
    for (var i = 0; i < rawGroups.length; i++) {
      final entry = rawGroups[i];
      if (entry is! Map<String, dynamic>) continue;
      final ungrouped = entry['ungrouped'] == true;
      final subscription = entry['subscription'] == true;
      final name = (entry['name'] as String? ?? '').trim();

      if (ungrouped) {
        importedGroupIds[i] = ungroupedId;
        continue;
      }
      if (subscription) {
        final infoMap = entry['info'] is Map<String, dynamic> ? entry['info'] as Map<String, dynamic> : null;
        final link = (infoMap?['link'] as String? ?? '').trim();
        if (link.isNotEmpty && !existingSubLinks.contains(link)) {
          final task = await daemon.importSubscription(link);
          if (task.groupId != 0) {
            importedGroupIds[i] = task.groupId;
            createdGroups++;
            existingSubLinks.add(link);
            if (name.isNotEmpty || infoMap != null) {
              await daemon.saveGroup(
                GroupRow(
                  id: task.groupId,
                  name: name,
                  subscription: true,
                  info: SubscriptionInfo(
                    link: link,
                    autoUpdate: infoMap?['autoUpdate'] == true,
                    autoUpdateDelay: (infoMap?['autoUpdateDelay'] as num?)?.toInt() ?? 1440,
                    deduplication: infoMap?['deduplication'] == true,
                    forceResolve: infoMap?['forceResolve'] == true,
                    updateWhenConnectedOnly: infoMap?['updateWhenConnectedOnly'] == true,
                    customUserAgent: infoMap?['customUserAgent'] as String? ?? '',
                  ),
                ),
              );
            }
          }
        }
        continue;
      }
      if (name.isEmpty) {
        importedGroupIds[i] = ungroupedId;
        continue;
      }
      final existing = basicGroupByName[name];
      if (existing != null) {
        importedGroupIds[i] = existing;
      } else {
        final saved = await daemon.saveGroup(GroupRow(id: 0, name: name));
        importedGroupIds[i] = saved.id;
        basicGroupByName[name] = saved.id;
        createdGroups++;
      }
    }
  }

  var importedProfiles = 0;
  final importedProfileIds = <int, int>{};
  final rawProfiles = decoded['profiles'];
  if (rawProfiles is List) {
    // Build per-group signature sets so re-importing the same backup does not duplicate profiles (H6).
    final existingByGroup = <int, Map<String, int>>{};
    Future<Map<String, int>> loadGroupSigs(int groupId) async {
      final cached = existingByGroup[groupId];
      if (cached != null) return cached;
      final map = <String, int>{};
      try {
        final rows = await daemon.profiles(groupId: groupId);
        for (final row in rows) {
          try {
            final saved = await daemon.profile(row.id);
            map['${saved.row.type}|${_canonicalJson(saved.beanJson)}'] = row.id;
          } catch (_) {}
        }
      } catch (_) {}
      existingByGroup[groupId] = map;
      return map;
    }

    for (var i = 0; i < rawProfiles.length; i++) {
      final entry = rawProfiles[i];
      if (entry is! Map<String, dynamic>) continue;
      final type = (entry['type'] as String? ?? '').trim();
      final beanJson = (entry['beanJson'] as String? ?? '').trim();
      if (type.isEmpty || beanJson.isEmpty) continue;
      final gIdx = (entry['groupIndex'] as num?)?.toInt() ?? -1;
      final targetGroupId = importedGroupIds[gIdx] ?? ungroupedId;
      final sigs = await loadGroupSigs(targetGroupId);
      final sig = '$type|${_canonicalJson(beanJson)}';
      if (sigs.containsKey(sig)) {
        importedProfileIds[i] = sigs[sig]!;
        continue;
      }
      final added = await daemon.addProfile(groupId: targetGroupId, type: type, beanJson: beanJson);
      sigs[sig] = added;
      importedProfileIds[i] = added;
      importedProfiles++;
    }
  }

  var importedRules = 0;
  final rawRules = decoded['rules'];
  if (rawRules is List && rawRules.isNotEmpty) {
    final existingRules = await daemon.rules();
    String ruleSig(RuleRow r) =>
        '${r.name}|${r.domains}|${r.ip}|${r.port}|${r.protocol}|${r.programs.join(",")}|${r.outbound}|${r.dpiBypass}|${r.config}';
    final seenRules = {for (final r in existingRules) ruleSig(r)};
    for (final entry in rawRules) {
      if (entry is! Map<String, dynamic>) continue;
      final outProfileIdx = (entry['outboundProfileIndex'] as num?)?.toInt();
      final rawOut = entry['outbound'];
      final int outbound;
      if (outProfileIdx != null && importedProfileIds.containsKey(outProfileIdx)) {
        outbound = importedProfileIds[outProfileIdx]!;
      } else {
        outbound = rawOut is int
            ? (rawOut == RuleOutbound.direct || rawOut == RuleOutbound.block ? rawOut : RuleOutbound.proxy)
            : switch (rawOut) {
                'direct' => RuleOutbound.direct,
                'block' => RuleOutbound.block,
                _ => RuleOutbound.proxy,
              };
      }
      final rawProgs = entry['programs'];
      final programs = rawProgs is List
          ? [for (final p in rawProgs) if (p is String && p.isNotEmpty) p]
          : const <String>[];
      final row = RuleRow(
        name: entry['name'] as String? ?? '',
        enabled: entry['enabled'] != false,
        domains: entry['domains'] as String? ?? '',
        ip: entry['ip'] as String? ?? '',
        port: entry['port'] as String? ?? '',
        sourcePort: entry['sourcePort'] as String? ?? '',
        network: entry['network'] as String? ?? '',
        source: entry['source'] as String? ?? '',
        protocol: entry['protocol'] as String? ?? '',
        programs: programs,
        dpiBypass: entry['dpiBypass'] == true,
        outbound: outbound,
        config: entry['config'] as String? ?? '',
      );
      final sig = ruleSig(row);
      if (seenRules.contains(sig)) continue;
      await daemon.saveRule(row);
      seenRules.add(sig);
      importedRules++;
    }
  }

  var settingsRestored = false;
  final rawSettings = decoded['settings'];
  if (rawSettings is Map<String, dynamic> && rawSettings.isNotEmpty) {
    final patch = <String, Object>{};
    for (final e in rawSettings.entries) {
      final v = e.value;
      if (v is String || v is int || v is bool) {
        patch[e.key] = v as Object;
      }
    }
    if (patch.isNotEmpty) {
      await daemon.updateSettings(patch);
      settingsRestored = true;
    }
  }

  final rawWindow = decoded['windowSettings'];
  if (windowSettings != null && rawWindow is Map<String, dynamic>) {
    if (rawWindow['advanced'] is bool) windowSettings.advanced = rawWindow['advanced'] as bool;
    if (rawWindow['language'] is String) windowSettings.language = rawWindow['language'] as String;
    if (rawWindow['connectOnStartup'] is bool) {
      windowSettings.connectOnStartup = rawWindow['connectOnStartup'] as bool;
    }
    if (rawWindow['closeToTray'] is bool) windowSettings.closeToTray = rawWindow['closeToTray'] as bool;
    if (rawWindow['notifications'] is bool) windowSettings.notifications = rawWindow['notifications'] as bool;
    if (rawWindow['theme'] is String) {
      windowSettings.theme = rawWindow['theme'] as String;
    }
    await windowSettings.save();
  }

  return BackupImportSummary(
    groups: createdGroups,
    profiles: importedProfiles,
    rules: importedRules,
    settingsRestored: settingsRestored,
  );
}

String _canonicalJson(String raw) {
  try {
    return jsonEncode(_sortJson(jsonDecode(raw)));
  } catch (_) {
    return raw.trim();
  }
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sortJson(value[k])};
  }
  if (value is List) {
    return [for (final item in value) _sortJson(item)];
  }
  return value;
}
