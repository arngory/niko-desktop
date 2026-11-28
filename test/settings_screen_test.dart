import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/l10n/strings.dart';
import 'package:niko_desktop/settings/setting_values.dart';
import 'package:niko_desktop/settings/settings_screen.dart';
import 'package:niko_desktop/state/window_settings.dart';
import 'package:niko_desktop/theme/niko_theme.dart';
import 'package:niko_desktop/ui/dialog.dart';
import 'package:niko_desktop/ui/fields.dart';

import 'fonts.dart';

/// Настройки (SettingsScreen, B-Settings), made by hand on the settings components: its picture in both themes with a
/// computer's defaults, and what its rows and dialogs do with the values; the daemon behind them is
/// main_screen_test's.
void main() {
  setUpAll(loadFonts);

  MemorySettingValues defaults() => MemorySettingValues(flags: _defaultFlags, texts: _defaultTexts);

  Widget frame(Brightness brightness, Widget child) => MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: NikoTheme(colors: NikoTheme.forBrightness(brightness), child: child),
        ),
      );

  Future<void> show(
    WidgetTester tester,
    SettingValues values, {
    WindowSettings? window,
    ValueChanged<String>? onLanguage,
    String coreVersion = '',
    String nikoVersion = '',
    (String, String)? notice,
    Brightness brightness = Brightness.light,
    Size size = const Size(1040, 2240),
    String locale = 'ru',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      frame(
        brightness,
        SettingsScreen(
          values: values,
          window: window,
          onLanguage: onLanguage,
          coreVersion: coreVersion,
          nikoVersion: nikoVersion,
          notice: notice,
          strings: NikoStrings.of(Locale(locale)),
        ),
      ),
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name}: the picture', (tester) async {
      await show(tester, defaults(), brightness: brightness);
      expect(tester.takeException(), isNull);
      // compared on Linux, where they were made: text is drawn a little differently elsewhere
      if (Platform.isLinux) {
        await expectLater(find.byType(SettingsScreen), matchesGoldenFile('goldens/settings_${brightness.name}.png'));
      }
    });
  }

  testWidgets('the rows: the values shown, a switch and a choice changed', (tester) async {
    final values = defaults();
    await show(tester, values, size: const Size(1040, 3200));
    expect(find.text('2080'), findsOneWidget);
    expect(find.text('cloudflare-dns.com +1'), findsOneWidget, reason: 'the first server\'s host, and one after it');
    expect(find.text('не заданы'), findsOneWidget);
    expect(find.text('Авто'), findsWidgets, reason: 'every domain strategy the core\'s own');
    // All 12 B-Settings sections are present in Advanced mode
    for (final section in ['Узлы raycontrol', 'naive', 'Yggdrasil', 'Резервная копия']) {
      expect(find.text(section), findsWidgets, reason: section);
    }
    expect(find.text('Clash API'), findsOneWidget);

    await tester.ensureVisible(find.text('Пускать из локальной сети'));
    await tester.tap(find.text('Пускать из локальной сети'));
    await tester.pump();
    expect(values.flag('allowAccess'), isTrue);
    await tester.ensureVisible(find.text('Сниффинг'));
    await tester.tap(find.text('Сниффинг'));
    await tester.pump();
    expect(values.flag('trafficSniffing'), isFalse);
    await tester.ensureVisible(find.text('Сначала'));
    await tester.tap(find.text('Сначала'));
    await tester.pump();
    expect(values.text('ipv6Mode'), '2');
    await tester.ensureVisible(find.text('VPN'));
    await tester.tap(find.text('VPN'));
    await tester.pump();
    expect(values.text('serviceMode'), 'vpn');
    await tester.ensureVisible(find.text('debug'));
    await tester.tap(find.text('debug'));
    await tester.pump();
    expect(values.text('logLevel'), '3');
  });

  testWidgets('simple mode hides advanced sections while keeping core settings', (tester) async {
    final values = defaults();
    tester.view.physicalSize = const Size(1040, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      frame(
        Brightness.light,
        SettingsScreen(
          values: values,
          advanced: false,
          strings: NikoStrings.of(const Locale('ru')),
        ),
      ),
    );
    expect(find.text('Тема'), findsOneWidget);
    expect(find.text('Узлы raycontrol'), findsWidgets);
    expect(find.text('Локальная сеть напрямую'), findsOneWidget);
    expect(find.text('Сбросить настройки…'), findsOneWidget);
    expect(find.text('Вход для других программ'), findsNothing);
    expect(find.text('Опыты'), findsNothing);
    expect(find.text('naive'), findsNothing);
  });

  testWidgets('a value row\'s dialog: typed, saved, closed; Отмена and Escape keep the value', (tester) async {
    final values = defaults();
    await show(tester, values, size: const Size(1040, 3200));
    await tester.ensureVisible(find.text('Порт'));
    await tester.tap(find.text('Порт'));
    await tester.pump();
    expect(find.text('Сохранить'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), '2a081');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(values.text('mixedPort'), '2081', reason: 'digits only');
    expect(find.text('Сохранить'), findsNothing);
    expect(find.text('2081'), findsOneWidget);

    await tester.tap(find.text('MTU'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '1500');
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    expect(values.text('mtu'), '9000');
    await tester.tap(find.text('MTU'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '1500');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Сохранить'), findsNothing);
    expect(values.text('mtu'), '9000');

    // the login: both fields at once, the password in dots; the row says the user
    await tester.tap(find.text('Пользователь и пароль'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText).at(0), 'niko');
    await tester.enterText(find.byType(EditableText).at(1), 'aaaa1111');
    expect(tester.widget<EditableText>(find.byType(EditableText).at(1)).obscureText, isTrue);
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect((values.text('mixedUsername'), values.text('mixedPassword')), ('niko', 'aaaa1111'));
    expect(find.text('niko'), findsOneWidget);

    // the domain strategies: three choices in one dialog
    await tester.tap(find.text('Стратегия доменов'));
    await tester.pump();
    await tester.tap(find.text('Только IPv4').first);
    await tester.pump();
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(values.text('domainStrategyForRemote'), 'ipv4_only');
    expect(values.text('domainStrategyForDirect'), 'auto');
    expect(find.text('разные'), findsOneWidget);
  });

  testWidgets('the programs through Niko (D-RULES-06): the choice, and the list a line each', (tester) async {
    final values = defaults();
    await show(tester, values, size: const Size(1040, 3200));
    expect(find.text('не выбраны'), findsOneWidget);
    await tester.ensureVisible(find.text('Кроме выбранных'));
    await tester.tap(find.text('Кроме выбранных'));
    await tester.pump();
    expect(values.text('programsMode'), '2');
    await tester.tap(find.text('Выбранные программы'));
    await tester.pump();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect((field.maxLines, field.keyboardType), (6, TextInputType.multiline));
    await tester.enterText(find.byType(EditableText), 'firefox.exe\nC:\\Tools\\curl.exe\n\n firefox.exe \nTelegram.exe');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(values.text('programs'), 'firefox.exe\nC:\\Tools\\curl.exe\n\n firefox.exe \nTelegram.exe');
    // each program once, an empty line none
    expect(find.text('3 программы'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the programs counted in words', () {
    final ru = NikoStrings.of(const Locale('ru')), en = NikoStrings.of(const Locale('en'));
    expect([for (final n in [1, 2, 5, 11, 12, 21, 22, 25, 111]) ru.programsCount(n)], [
      '1 программа', '2 программы', '5 программ', '11 программ', '12 программ', '21 программа', '22 программы',
      '25 программ', '111 программ',
    ]);
    expect((en.programsCount(1), en.programsCount(3)), ('1 program', '3 programs'));
  });

  testWidgets('a value the store refuses: said in the dialog, which stays open', (tester) async {
    final values = _Refusing();
    await show(tester, values);
    await tester.tap(find.text('Удалённый DNS'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'ftp://dns.example');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Не сохранено'), findsOneWidget);
    expect(find.text('invalid: remoteDns: Unsupported DNS transport: ftp'), findsOneWidget);
    expect(find.text('Сохранить'), findsOneWidget);
    expect(values.text('remoteDns'), _defaultTexts['remoteDns']);
    if (Platform.isLinux) {
      await expectLater(find.byType(SettingsScreen), matchesGoldenFile('goldens/settings_refused_light.png'));
    }
  });

  testWidgets('the menu: a section pressed comes into view, and is the one marked', (tester) async {
    await show(tester, defaults(), size: const Size(1040, 640));
    expect(find.text('Уровень журнала').hitTestable(), findsNothing);
    await tester.tap(find.text('Журнал и вид'));
    await tester.pumpAndSettle();
    expect(find.text('Уровень журнала').hitTestable(), findsOneWidget);
    FontWeight? weight(String item) => tester.widget<Text>(find.text(item)).style?.fontWeight;
    expect((weight('Журнал и вид'), weight('Общие')), (FontWeight.w600, FontWeight.w400));
  });

  testWidgets('narrow: no menu, nothing overflows; English', (tester) async {
    await show(tester, defaults(), size: const Size(560, 900), locale: 'en');
    expect(tester.takeException(), isNull);
    expect(find.text('Inbound for other programs'.toUpperCase()), findsOneWidget);
    expect(find.text('Experiments'), findsNothing, reason: 'the menu is for a wide window');
    expect(find.byType(NikoChoiceRow<String>), findsNWidgets(10));
  });

  testWidgets('theme and language rows stay available without daemon; language dialog notifies callback', (tester) async {
    final window = WindowSettings.memory();
    String? notified;
    await show(
      tester,
      defaults(),
      window: window,
      onLanguage: (lang) => notified = lang,
      notice: ('Нет связи со службой', ''),
      size: const Size(1040, 720),
    );
    expect(find.text('Тема'), findsOneWidget);
    expect(find.text('Язык'), findsOneWidget);
    expect(find.text('Нет связи со службой'), findsOneWidget);
    expect(find.text('Порт'), findsNothing);
    // sidebar menu stays visible
    expect(find.bySemanticsLabel('Разделы настроек'), findsOneWidget);

    await tester.tap(find.text('Тёмная'));
    await tester.pump();
    expect(window.theme, 'dark');

    await tester.tap(find.text('Язык'));
    await tester.pump();
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Русский'), findsOneWidget);
    await tester.tap(find.text('English'));
    await tester.pump();
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(window.language, 'en');
    expect(notified, 'en');
  });

  testWidgets('dialog traps Tab focus inside itself and restores focus on close', (tester) async {
    await show(tester, defaults());
    // focus the Port link row before opening it with Enter
    final portRow = find.ancestor(of: find.text('Порт'), matching: find.byType(Focus)).first;
    final portNode = tester.widget<Focus>(portRow).focusNode ?? Focus.of(tester.element(find.text('Порт')));
    portNode.requestFocus();
    await tester.pump();
    expect(portNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(NikoDialog), findsOneWidget);

    final dialogElement = tester.element(find.byType(NikoDialog));
    final dialogScope = FocusScope.of(dialogElement);
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final current = FocusManager.instance.primaryFocus;
      expect(current, isNotNull);
      expect(current!.enclosingScope, dialogScope, reason: 'Tab #$i escaped the dialog');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.byType(NikoDialog), findsNothing);
    expect(portNode.hasFocus, isTrue, reason: 'focus returns to the row that opened the dialog');
  });

  testWidgets('about section shows window version, signing key, and connected daemon versions (D-SET-12)', (
    tester,
  ) async {
    await show(
      tester,
      defaults(),
      coreVersion: '1.14.4-niko',
      nikoVersion: '1.58.0',
      notice: ('Нет связи со службой', ''),
      size: const Size(1040, 720),
    );
    expect(find.text('Niko 0.1.0'), findsOneWidget);
    expect(find.text('sing-box 1.14.4-niko'), findsOneWidget);
    expect(find.text('nikod 1.58.0'), findsOneWidget);
    expect(find.text('minisign D5D2D2E799D74D8D'), findsOneWidget);
    if (Platform.isLinux) {
      await expectLater(find.byType(SettingsScreen), matchesGoldenFile('goldens/settings_about_light.png'));
    }

    // without daemon versions, sing-box/nikod lines are omitted while window version and signing key remain
    await show(tester, defaults(), notice: ('Нет связи со службой', ''), size: const Size(1040, 720));
    expect(find.text('Niko 0.1.0'), findsOneWidget);
    expect(find.textContaining('sing-box'), findsNothing);
    expect(find.textContaining('nikod'), findsNothing);
    expect(find.text('minisign D5D2D2E799D74D8D'), findsOneWidget);
  });
}

// a computer's defaults (nikoconf.DesktopSettings), as SettingsFeed gives them
const _defaultFlags = {'enableFakeDns': true, 'trafficSniffing': true};
const _defaultTexts = {
  'serviceMode': 'proxy',
  'tunImplementation': '0',
  'mtu': '9000',
  'ipv6Mode': '0',
  'remoteDns': 'https://cloudflare-dns.com/dns-query\nhttps://dns.quad9.net/dns-query',
  'directDns': 'local',
  'mixedPort': '2080',
  'logLevel': '0',
  'programsMode': '0',
};

/// Values whose store refuses a DNS server it does not know, in the daemon's words.
class _Refusing extends MemorySettingValues {
  _Refusing() : super(flags: _defaultFlags, texts: _defaultTexts);

  @override
  Future<String?> save({Map<String, bool> flags = const {}, Map<String, String> texts = const {}}) async {
    final dns = texts['remoteDns'];
    if (dns != null && dns.startsWith('ftp:')) return 'invalid: remoteDns: Unsupported DNS transport: ftp';
    return super.save(flags: flags, texts: texts);
  }
}
