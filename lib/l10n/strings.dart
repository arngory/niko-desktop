import 'dart:ui' show Locale;

import '../daemon/daemon.dart' show NatBehaviour;

/// The window's words, in Russian and English. A stopgap: the texts move to the shared layer with Android's
/// (docs/ui/platforms.md, one file a language), and this file is then generated from it.
class NikoStrings {
  const NikoStrings._(this._ru);

  factory NikoStrings.of(Locale locale) => NikoStrings._(locale.languageCode == 'ru');

  final bool _ru;

  String get statusOff => _ru ? 'Отключено' : 'Disconnected';
  String get statusConnecting => _ru ? 'Подключение' : 'Connecting';
  String get statusOn => _ru ? 'Подключено' : 'Connected';
  String get statusStopping => _ru ? 'Отключение' : 'Disconnecting';
  String get statusError => _ru ? 'Ошибка' : 'Error';

  String get connect => _ru ? 'Подключить' : 'Connect';
  String get disconnect => _ru ? 'Отключить' : 'Disconnect';
  String get retry => _ru ? 'Повторить' : 'Retry';

  String get errorTitle => _ru ? 'Ошибка подключения' : 'Connection error';
  String get noServiceTitle => _ru ? 'Служба не установлена' : 'The service is not installed';
  String get noServiceInstallText => _ru
      ? 'Установите службу Niko в Program Files (потребуются права администратора)'
      : 'Install the Niko service into Program Files (administrator privileges required)';
  String get noServiceInstallLinuxText => _ru
      ? 'Установите системную службу Niko для работы VPN (TUN); система запросит пароль администратора'
      : 'Install the Niko system service for VPN (TUN); the system will ask for your administrator password';
  String get installService => _ru ? 'Установить службу' : 'Install service';
  String get installingService => _ru ? 'Установка…' : 'Installing…';
  String get portableInstalledTitle =>
      _ru ? 'Служба Niko уже установлена' : 'The Niko service is already installed';
  String get portableInstalledText => _ru
      ? 'Запущена переносная копия. Откройте установленный Niko из Program Files или обновите службу'
      : 'Running from a portable folder. Open the installed Niko from Program Files or update the service';
  String get openInstalled => _ru ? 'Открыть установленный Niko' : 'Open installed Niko';
  String get updateService => _ru ? 'Обновить службу' : 'Update service';
  String get installCancelled => _ru ? 'Установка отменена пользователем' : 'Installation cancelled';
  String get installPolkitUnavailable => _ru
      ? 'Нет агента Polkit (pkexec). Установите службу вручную в терминале:'
      : 'Polkit agent (pkexec) is unavailable. Install the service manually in a terminal:';
  String get copyCommand => _ru ? 'Скопировать команду' : 'Copy command';
  String get commandCopied => _ru ? 'Команда скопирована' : 'Command copied';
  String get installNotElevated => _ru ? 'Нужны права администратора' : 'Administrator privileges are required';
  String get installInvalidLayout =>
      _ru ? 'Неверная структура папки: отсутствует resources\\daemon\\niko-daemon.exe' : 'Invalid folder layout: missing resources\\daemon\\niko-daemon.exe';
  String get installSignatureFailed =>
      _ru ? 'Подпись исполняемых файлов не прошла проверку' : 'Executable signature verification failed';
  String get installManifestFailed =>
      _ru ? 'Целостность файлов установки нарушена' : 'Installation file integrity check failed';
  String get installTargetBusy =>
      _ru ? 'Закройте работающий Niko и повторите установку' : 'Close the running Niko window and retry';
  String get installInvalidSource =>
      _ru ? 'Небезопасная исходная папка установки' : 'Unsafe source installation folder';
  String get installLaunchFailed => _ru
      ? 'Служба установлена, но не удалось открыть установленный Niko'
      : 'Service installed, but failed to open the installed Niko';
  String get installFailed => _ru ? 'Не удалось установить службу' : 'Failed to install the service';
  String get userModeTitle => _ru ? 'Режим без службы (только прокси)' : 'User mode (proxy only)';
  String get userModeText => _ru
      ? 'Прокси работает без прав администратора. Для режима VPN (TUN) установите системную службу Niko'
      : 'Proxy mode works without administrator privileges. Install the Niko system service to use VPN (TUN) mode';
  String get vpnNeedsServiceTitle =>
      _ru ? 'Для режима VPN нужна служба Niko' : 'VPN mode requires the Niko service';
  String get vpnNeedsServiceText => _ru
      ? 'Установите системную службу для маршрутизации всего трафика через TUN или переключитесь на режим Прокси'
      : 'Install the system service to route all traffic via TUN, or switch to Proxy mode';
  String get migrationTitle =>
      _ru ? 'Найдены данные из режима без службы' : 'Data from user mode found';
  String get migrationText => _ru
      ? 'Перенести профили, подписки, правила и узлы в системную службу Niko?'
      : 'Transfer profiles, subscriptions, rules, and nodes to the Niko system service?';
  String get migrationAction => _ru ? 'Перенести' : 'Transfer';
  String get migrationBusy => _ru ? 'Перенос…' : 'Transferring…';
  String get migrationDismiss => _ru ? 'Позже' : 'Dismiss';
  String migrationDone(int profiles, int rules, int nodes) => _ru
      ? 'Перенесено в службу: профилей $profiles, правил $rules, узлов $nodes'
      : 'Transferred to service: $profiles profiles, $rules rules, $nodes nodes';
  String get serviceSilentTitle => _ru ? 'Служба не отвечает' : 'The service does not answer';
  String get noConfigTitle => _ru ? 'Нет конфига' : 'No config';
  String get oldServiceTitle => _ru ? 'Служба Niko старее окна' : 'The Niko service is older than the window';
  String oldServiceText(int need, int have) =>
      _ru ? 'Нужен NikoService API $need, у службы — $have' : 'Needs NikoService API $need, the service has $have';

  String get sections => _ru ? 'Разделы' : 'Sections';
  String get sectionHome => _ru ? 'Главная' : 'Home';
  String get sectionCheck => _ru ? 'Проверка маршрута' : 'Route check';
  String get sectionConnections => _ru ? 'Соединения' : 'Connections';
  String get sectionLog => _ru ? 'Журнал' : 'Log';
  String get sectionNodes => _ru ? 'Узлы' : 'Nodes';

  String get groups => _ru ? 'Группы' : 'Groups';
  String get groupOwn => _ru ? 'Свои профили' : 'My profiles';
  String groupOwnSub(int count) => _ru ? 'вручную и по ссылкам · $count' : 'by hand and from links · $count';
  String groupBasicSub(int count) => _ru ? 'своя группа · $count' : 'own group · $count';
  String groupSubscriptionSub(int count) => _ru ? 'подписка · $count' : 'subscription · $count';
  String get groupEmpty => _ru ? 'В группе нет профилей' : 'No profiles in this group';
  String get profilesList => _ru ? 'Профили группы' : 'The group\'s profiles';
  String get storeUnreachable => _ru ? 'Профили не прочитаны' : 'The profiles were not read';
  String get storeNoLink => _ru ? 'Нет связи со службой' : 'No link to the service';
  String get add => _ru ? 'Добавить' : 'Add';
  String get addOverline => _ru ? 'Добавление' : 'Adding';
  String get addTitle => _ru ? 'Вставьте ссылку' : 'Paste a link';
  String get addSub => _ru ? 'Ссылка на профиль или несколько, по одной в строке' : 'A profile\'s link, or several, one a line';
  String get addField => _ru ? 'Ссылка' : 'Link';
  String get addPaste => _ru ? 'Вставить' : 'Paste';
  String get addFromQr => _ru ? 'Из QR' : 'From QR';
  String get addQrNotFound => _ru ? 'QR-код на изображении не найден' : 'No QR code found in the image';
  String get qrCopyLink => _ru ? 'Скопировать ссылку' : 'Copy link';
  String get qrTooLong => _ru ? 'Ссылка слишком длинная для QR-кода' : 'The link is too long for a QR code';
  String get close => _ru ? 'Закрыть' : 'Close';
  String addFound(int count) => _ru ? 'Профилей в ссылке: $count' : 'Profiles in the link: $count';
  String addButton(int count) => _ru ? 'Добавить: $count' : 'Add $count';
  String get addSubscriptionFound => _ru ? 'Это ссылка подписки' : 'This is a subscription\'s link';
  String get addSubscriptionText => _ru
      ? 'Добавится группа подписки, профили придут с её первым обновлением'
      : 'A group of the subscription is added, its profiles come with its first update';
  String get addSubscriptionButton => _ru ? 'Добавить подписку' : 'Add the subscription';
  String get addNodeInvite => _ru ? 'Приглашение узла' : 'A node\'s invite';
  String get addNodeDevice => _ru ? 'Пакет устройства узла' : 'A node\'s device package';
  String addNodeInviteText(String host) => _ru
      ? 'Компьютер зарегистрируется на узле $host и получит его способы подключения'
      : 'This computer registers with the node $host and gets its ways to connect';
  String addNodeDeviceText(String host) =>
      _ru ? 'Узел $host добавится с этим пакетом устройства' : 'The node $host is added with this device package';
  String addNodeName(String name) => _ru ? 'имя узла: $name' : 'the node\'s name: $name';
  String addNodeExpires(String at) => _ru ? 'приглашение действует до $at' : 'the invite works until $at';
  String get addNodeReplaces => _ru
      ? 'Этот узел уже добавлен: у устройства будет новый ключ, его группа и профили останутся'
      : 'This node is added already: the device gets a new key, its group and profiles stay';
  String addNodeMoved(String known, String host) => _ru
      ? 'Узел добавлен с адресом $known, приглашение — на $host. Узел мог переехать; если ссылка не от его администратора, не добавляйте'
      : 'The node is added with the address $known, the invite is for $host. The node may have moved; if the link is not its administrator\'s, do not add it';
  String get addNodePin => _ru ? 'PIN приглашения' : 'The invite\'s PIN';
  String get addNodePinHint => _ru ? '6 цифр от администратора узла' : '6 digits from the node\'s administrator';
  String get addNodePinFormat => _ru ? 'PIN — 6 цифр' : 'The PIN is 6 digits';
  String addNodePinWrong(int left) =>
      _ru ? 'PIN неверный, попыток осталось: $left' : 'The PIN is wrong, tries left: $left';
  String addNodePinLeft(int left) => _ru ? 'Попыток: $left' : 'Tries: $left';
  String get addNodeButton => _ru ? 'Добавить узел' : 'Add the node';
  String get addNodeRegistering => _ru ? 'Регистрация на узле…' : 'Registering with the node…';
  String groupNodeSub(int count) => _ru ? 'узел · $count' : 'node · $count';
  String get nodeNever => _ru ? 'подписка ещё не получена' : 'no subscription yet';
  String nodeUpdated(String at) => _ru ? 'обновлено $at' : 'updated $at';
  String nodeNext(String at) => _ru ? 'следующее обновление $at' : 'next update $at';
  String get nodeSigned => _ru
      ? 'Подписка заверена ключами узла ed25519 и ML-DSA-65, обе подписи проверены'
      : 'The subscription is signed by the node\'s ed25519 and ML-DSA-65 keys, both signatures checked';
  String nodeTraffic(String used, String limit) => _ru ? 'трафик $used из $limit' : 'traffic $used of $limit';
  String nodeTrafficReset(String at) => _ru ? 'сброс $at' : 'reset $at';
  String nodeTrafficExhausted(String at) => _ru
      ? 'трафик израсходован, профили вернутся $at'
      : 'the traffic is used up, the profiles come back $at';
  String get nodeTrafficExhaustedAdmin =>
      _ru ? 'трафик израсходован: лимит поднимает администратор' : 'the traffic is used up: the administrator raises the limit';
  String nodeExpires(String at) => _ru ? 'подписка действует до $at' : 'the subscription holds until $at';
  String nodeExpired(String at) => _ru ? 'подписка истекла $at' : 'the subscription expired $at';
  String get nodeRefused => _ru
      ? 'Узел отказал этому устройству: добавьте узел заново по новому приглашению'
      : 'The node refused this device: add it again by a new invite';
  String nodeFailing(int times) => _ru ? 'обновление не проходит: $times раз подряд' : 'the update fails: $times times in a row';
  String nodeClock(int skew) => _ru
      ? 'часы компьютера расходятся с узлом на $skew с: подключение по SPA не пройдёт'
      : 'this computer\'s clock is $skew s off the node\'s: SPA will fail';
  String nodeMinVersion(String version) =>
      _ru ? 'узел требует Niko $version или новее' : 'the node requires Niko $version or later';
  String get nodeUnreadable => _ru
      ? 'Ключи узла запечатаны на другом компьютере: добавьте узел заново по новому приглашению'
      : 'The node\'s keys were sealed on another computer: add it again by a new invite';
  String get mainNode => _ru ? 'Узел' : 'Node';
  String get nodeDelete => _ru ? 'Удалить узел' : 'Remove the node';
  String nodeDeleteConfirm(String name) => _ru
      ? 'Удалить узел «$name» и его ключ устройства? Вернуть его можно только новым приглашением.'
      : 'Remove the node “$name” and its device key? It comes back only with a new invite.';
  String get nodeUpdateFailed => _ru ? 'Узел не обновлён' : 'The node was not updated';
  String get subscriptionUpdate => _ru ? 'Обновить' : 'Update';
  String get subscriptionUpdating => _ru ? 'Обновление…' : 'Updating…';
  String get subscriptionUpdateFailed => _ru ? 'Подписка не обновлена' : 'The subscription was not updated';
  String get subscriptionNever => _ru ? 'ещё не обновлялась' : 'not updated yet';
  String subscriptionUpdated(String at) => _ru ? 'обновлена $at' : 'updated $at';
  String subscriptionTraffic(String used, String total) => _ru ? '$used из $total' : '$used of $total';
  String subscriptionUsed(String used) => _ru ? 'израсходовано $used' : '$used used';
  String subscriptionExpires(String date) => _ru ? 'до $date' : 'until $date';
  String get addNothing => _ru ? 'Ссылок на профили не найдено' : 'No profile links found';
  String get addFailed => _ru ? 'Не добавлено' : 'Not added';
  String get cancel => _ru ? 'Отмена' : 'Cancel';
  String profileDelete(String name) => _ru ? 'Удалить «$name»' : 'Delete “$name”';
  String profileShare(String name) => _ru ? 'Скопировать ссылку на «$name»' : 'Copy the link to “$name”';
  String linkCopied(String name) => _ru ? 'Ссылка на «$name» скопирована' : 'The link to “$name” copied';
  String profileDeleted(String name) => _ru ? 'Профиль «$name» удалён' : 'Profile “$name” deleted';
  String get undo => _ru ? 'Вернуть' : 'Undo';
  String get view => _ru ? 'Вид интерфейса' : 'Interface view';
  String get viewSimple => _ru ? 'Простой' : 'Simple';
  String get viewAdvanced => _ru ? 'Расширенный' : 'Advanced';

  String get logCore => _ru ? 'Журнал ядра' : 'The core\'s log';
  String get logClear => _ru ? 'Очистить журнал' : 'Clear the log';
  String get logEmpty => _ru ? 'Журнал пуст' : 'The log is empty';
  String get logClearFailed => _ru ? 'Журнал не очищен' : 'The log was not cleared';
  String get logCopy => _ru ? 'Скопировать журнал' : 'Copy the log';
  String get logCopied => _ru ? 'Журнал скопирован' : 'The log is copied';
  String get logSave => _ru ? 'Сохранить журнал в файл' : 'Save the log to a file';
  String get tools => _ru ? 'Инструменты' : 'Tools';
  String get natTitle => _ru ? 'Поведение NAT' : 'NAT behaviour';
  String get stunServer => _ru ? 'STUN-сервер' : 'STUN server';
  String get stunDetect => _ru ? 'Определить' : 'Detect';
  String get stunNeedsCore =>
      _ru ? 'Проверка идёт через подключение: сначала подключитесь' : 'The check goes through the connection: connect first';
  String get stunFailed => _ru ? 'NAT не определён' : 'NAT not detected';
  String get stunStopped => _ru
      ? 'Подключение остановилось во время проверки: подключитесь и проверьте снова'
      : 'The connection stopped during the check: connect and check again';
  String get natAddress => _ru ? 'Внешний адрес' : 'External address';
  String get natMapping => _ru ? 'Сопоставление' : 'Mapping';
  String get natFiltering => _ru ? 'Фильтрация' : 'Filtering';
  String get natLatency => _ru ? 'Задержка' : 'Latency';
  String get natUnsupported => _ru ? 'сервер говорит только адрес' : 'the server tells the address only';
  String nat(NatBehaviour behaviour) => switch (behaviour) {
        NatBehaviour.endpointIndependent => _ru ? 'не зависит от адреса назначения' : 'independent of the destination',
        NatBehaviour.addressDependent => _ru ? 'зависит от адреса' : 'depends on the address',
        NatBehaviour.addressAndPortDependent => _ru ? 'зависит от адреса и порта' : 'depends on the address and port',
        NatBehaviour.unknown => _ru ? 'не определено' : 'not known',
      };
  String get saved => _ru ? 'Сохранено' : 'Saved';
  String get saveFailed => _ru ? 'Не сохранено' : 'Not saved';
  String get reportCrash => _ru ? 'Прошлый запуск завершился сбоем' : 'The last run crashed';
  String get reportMemory => _ru ? 'Ядру не хватило памяти' : 'The core ran out of memory';
  String get reportSave => _ru ? 'Экспорт' : 'Export';
  String get reportFailed => _ru ? 'Отчёт не сохранён' : 'The report was not saved';

  String connectionsOpen(int count) => _ru ? 'открыто $count' : '$count open';
  String get connectionsList => _ru ? 'Открытые соединения' : 'Open connections';
  String get connectionsSearch => _ru ? 'Поиск' : 'Search';
  String get connectionsCloseAll => _ru ? 'Закрыть все' : 'Close all';
  String connectionClose(String name) => _ru ? 'Закрыть соединение с $name' : 'Close the connection to $name';
  String get connectionsIdle => _ru ? 'Подключение выключено' : 'Not connected';
  String get connectionsCloseFailed => _ru ? 'Соединение не закрыто' : 'The connection was not closed';
  String get rule => _ru ? 'правило' : 'rule';
  String get ruleFinal => _ru ? 'остальное' : 'final';

  String get development => _ru ? 'Разработка' : 'Development';
  String get service => _ru ? 'Служба' : 'Service';
  String get config => _ru ? 'Конфиг' : 'Config';
  String get session => _ru ? 'За сессию' : 'Session';

  String get sectionSettings => _ru ? 'Настройки' : 'Settings';
  String get settingsMenu => _ru ? 'Разделы настроек' : 'Settings sections';
  String get settingsUnread => _ru ? 'Настройки не прочитаны' : 'The settings were not read';
  String get settingsNotKept => _ru ? 'Не сохранено' : 'Not saved';
  String get save => _ru ? 'Сохранить' : 'Save';
  String get setGeneral => _ru ? 'Общие' : 'General';
  String get setTheme => _ru ? 'Тема' : 'Theme';
  String get themeSystem => _ru ? 'Как в системе' : 'As the system';
  String get themeLight => _ru ? 'Светлая' : 'Light';
  String get themeDark => _ru ? 'Тёмная' : 'Dark';
  String get setLanguage => _ru ? 'Язык' : 'Language';
  String get langSystem => _ru ? 'Как в системе' : 'As the system';
  String get setMode => _ru ? 'Режим' : 'Mode';
  String get setModeVpn => 'VPN';
  String get setModeProxy => _ru ? 'Прокси' : 'Proxy';
  String get setSystemProxy => _ru ? 'Системный прокси' : 'System proxy';
  String get setSystemProxySub => _ru ? 'В режиме прокси' : 'In proxy mode';
  String get setConnection => _ru ? 'Подключение' : 'Connection';
  String get setTun => _ru ? 'Реализация TUN' : 'TUN implementation';
  String get setMtu => 'MTU';
  String get setMtuHint => _ru ? 'От 1000 до 10000' : 'From 1000 to 10000';
  String get setIpv6 => 'IPv6';
  String get setIpv6Off => _ru ? 'Нет' : 'No';
  String get setIpv6On => _ru ? 'Да' : 'Yes';
  String get setIpv6Prefer => _ru ? 'Сначала' : 'First';
  String get setIpv6Only => _ru ? 'Только' : 'Only';
  String get setInsecure => _ru ? 'Не проверять сертификаты' : 'Do not check certificates';
  String get setDangerous => _ru ? 'Опасно' : 'Dangerous';
  String get setDns => _ru ? 'DNS и маршрут' : 'DNS and routing';
  String get setRemoteDns => _ru ? 'Удалённый DNS' : 'Remote DNS';
  String get setDirectDns => _ru ? 'Прямой DNS' : 'Direct DNS';
  String get setDnsHint => _ru ? 'Сервер: https://, tls://, quic://, udp:// или local' : 'A server: https://, tls://, quic://, udp:// or local';
  String get setRemoteDnsHint => _ru
      ? 'По серверу в строке: https://, tls://, quic:// или udp://. Когда сервер не отвечает или отвечает ошибкой, спрашивается следующий'
      : 'A server a line: https://, tls://, quic:// or udp://. When a server fails or keeps silent, the next one is asked';
  String get setFakeIp => 'FakeIP';
  String get setInVpn => _ru ? 'В режиме VPN' : 'In VPN mode';
  String get setStrategy => _ru ? 'Стратегия доменов' : 'Domain strategy';
  String get setStrategyRemote => _ru ? 'Для удалённого DNS' : 'For the remote DNS';
  String get setStrategyDirect => _ru ? 'Для прямого DNS' : 'For the direct DNS';
  String get setStrategyServer => _ru ? 'Для адресов серверов' : 'For the servers\' addresses';
  String get setStrategyMixed => _ru ? 'разные' : 'mixed';
  String strategy(String value) => switch (value) {
        'prefer_ipv4' => _ru ? 'IPv4 сначала' : 'IPv4 first',
        'prefer_ipv6' => _ru ? 'IPv6 сначала' : 'IPv6 first',
        'ipv4_only' => _ru ? 'Только IPv4' : 'IPv4 only',
        'ipv6_only' => _ru ? 'Только IPv6' : 'IPv6 only',
        _ => _ru ? 'Авто' : 'Auto',
      };
  String get setOptimisticCache => _ru ? 'Оптимистичный кэш' : 'Optimistic cache';
  String get setLanDirect => _ru ? 'Локальная сеть напрямую' : 'The LAN direct';
  String get setInbound => _ru ? 'Вход для других программ' : 'Inbound for other programs';
  String get setInboundMenu => _ru ? 'Вход для программ' : 'Inbound';
  String get setLogin => _ru ? 'Пользователь и пароль' : 'User and password';
  String get setLoginNone => _ru ? 'не заданы' : 'not set';
  String get setLoginSet => _ru ? 'заданы' : 'set';
  String get setLoginHint =>
      _ru ? 'Без пароля вход открыт. Пустой пользователь — user' : 'With no password, no login is asked. An empty user is “user”';
  String get setLanAccess => _ru ? 'Пускать из локальной сети' : 'Let the LAN in';
  String get setExperiments => _ru ? 'Опыты' : 'Experiments';
  String get setRefuseQuic => _ru ? 'QUIC → TCP на потоковых профилях' : 'QUIC → TCP on stream profiles';
  String get setNoPingReply => _ru ? 'Не отвечать на ping за сервер' : 'No ping reply for the server';
  String get setSniffing => _ru ? 'Сниффинг' : 'Sniffing';
  String get setResolveDestination => _ru ? 'Разрешать адрес назначения' : 'Resolve the destination';
  String get setPrograms => _ru ? 'Программы' : 'Programs';
  String get setProgramsThrough => _ru ? 'Через Niko' : 'Through Niko';
  String get setProgramsAll => _ru ? 'Все' : 'All';
  String get setProgramsOnly => _ru ? 'Только выбранные' : 'Only chosen';
  String get setProgramsExcept => _ru ? 'Кроме выбранных' : 'All but chosen';
  String get setProgramsList => _ru ? 'Выбранные программы' : 'Chosen programs';
  String get setProgramsNone => _ru ? 'не выбраны' : 'none';
  String programsCount(int count) {
    if (!_ru) return count == 1 ? '1 program' : '$count programs';
    final tens = count % 100, ones = count % 10;
    final word = tens >= 11 && tens <= 14
        ? 'программ'
        : ones == 1
            ? 'программа'
            : ones >= 2 && ones <= 4
                ? 'программы'
                : 'программ';
    return '$count $word';
  }

  String get setProgramsHint => _ru
      ? 'По одной в строке: имя (firefox.exe) или полный путь. Остальные программы идут напрямую или через Niko'
      : 'One a line: a name (firefox.exe) or a full path. The other programs go direct or through Niko';
  String get setLog => _ru ? 'Журнал' : 'Log';
  String get setLogLevel => _ru ? 'Уровень журнала' : 'Log level';
  String get setAbout => _ru ? 'О программе и обновления' : 'About and updates';
  String get setAboutMenu => _ru ? 'О программе' : 'About';
  String get setUpdateKey => _ru ? 'Подпись обновлений' : 'Update signing key';

  String get inboundUser => _ru ? 'Пользователь' : 'User';
  String get inboundPort => _ru ? 'Порт' : 'Port';
  String get inboundPassword => _ru ? 'Пароль' : 'Password';

  String get sectionRules => _ru ? 'Правила' : 'Rules';
  String get rulesList => _ru ? 'Правила маршрутизации' : 'Route rules';
  String get rulesEmpty => _ru
      ? 'Правил нет: всё идёт через прокси'
      : 'No rules: everything goes through the proxy';
  String get rulesSub =>
      _ru ? 'Сверху вниз: первое подошедшее правило решает' : 'From the top: the first rule that matches decides';
  String get rulesUnread => _ru ? 'Правила не прочитаны' : 'The rules were not read';
  String get ruleAdd => _ru ? 'Новое правило' : 'New rule';
  String ruleDisplayName(int id) => _ru ? 'Правило $id' : 'Rule $id';
  String ruleUpLabel(String name) => _ru ? 'Поднять: $name' : 'Move up: $name';
  String ruleDownLabel(String name) => _ru ? 'Опустить: $name' : 'Move down: $name';
  String ruleDeleteLabel(String name) => _ru ? 'Удалить правило: $name' : 'Delete the rule: $name';
  String ruleEnabledLabel(String name) => _ru ? 'Включено: $name' : 'On: $name';
  String get ruleEdit => _ru ? 'Правило' : 'Rule';
  String get ruleName => _ru ? 'Название' : 'Name';
  String get ruleDomains => _ru ? 'Домены' : 'Domains';
  String get ruleDomainsHint => _ru
      ? 'По одному в строке: суффикс, full:, domain:, keyword:, regexp:; srs:https://… — набор правил'
      : 'One a line: a suffix, full:, domain:, keyword:, regexp:; srs:https://… a rule-set';
  String get ruleIp => 'IP';
  String get rulePort => _ru ? 'Порт' : 'Port';
  String get ruleSourcePort => _ru ? 'Порт источника' : 'Source port';
  String get ruleSource => _ru ? 'Адрес источника' : 'Source address';
  String get ruleProtocol => _ru ? 'Протокол' : 'Protocol';
  String get ruleNetwork => _ru ? 'Сеть' : 'Network';
  String get ruleNetworkBoth => 'TCP + UDP';
  String get rulePrograms => _ru ? 'Программы' : 'Programs';
  String get ruleProgramsHint =>
      _ru ? 'По одной в строке: имя (firefox.exe) или полный путь' : 'One a line: a name (firefox.exe) or a full path';
  String get ruleOutbound => _ru ? 'Куда' : 'Where';
  String get routeProxy => _ru ? 'Прокси' : 'Proxy';
  String get routeDirect => _ru ? 'Напрямую' : 'Direct';
  String get routeBlock => _ru ? 'Блок' : 'Block';
  String routeProfile(int id) => _ru ? 'Профиль $id' : 'Profile $id';
  String get ruleDpi => _ru ? 'Обход DPI' : 'DPI bypass';
  String get ruleDpiSub => _ru
      ? 'Стратегия из настроек на прямых соединениях этого правила'
      : 'The settings\' strategy on this rule\'s direct connections';
  String get ruleApps => _ru ? 'приложения телефона' : 'the phone\'s apps';
  String get ruleOwnJson => _ru ? 'свой JSON' : 'own JSON';
  String get ruleSave => _ru ? 'Сохранить' : 'Save';
  String get ruleCancel => _ru ? 'Отмена' : 'Cancel';
  String get ruleNotSaved => _ru ? 'Правило не сохранено' : 'The rule was not saved';
  String get presetRussia => _ru ? 'Пресет «Россия»' : 'Preset: Russia';
  String get presetRussiaSub => _ru
      ? 'Заблокированное в России — через прокси, российские сервисы — напрямую (списки runetfreedom). Повторное добавление заменит правила пресета'
      : 'What is blocked in Russia through the proxy, Russian services directly (runetfreedom\'s lists). Adding it again replaces its rules';
  String get presetRussiaBlocked => _ru ? 'Заблокированное в России — через прокси' : 'Blocked in Russia: through the proxy';
  String get presetRussiaDirect => _ru ? 'Российские сервисы — напрямую' : 'Russian services: directly';
  String get ruleSetsTitle => _ru ? 'Наборы правил' : 'Rule-sets';
  String ruleSetsSub(int hours) => _ru
      ? 'Служба скачивает их сама и обновляет раз в $hours ч, пока ядро работает'
      : 'The service fetches them itself, and again every $hours h while the core runs';
  String get ruleSetsNone => _ru ? 'Правила не называют наборов' : 'No rule names a rule-set';
  String get ruleSetsUpdate => _ru ? 'Обновить' : 'Update';
  String get ruleSetsUpdating => _ru ? 'Обновление…' : 'Updating…';
  String get ruleSetsFailed => _ru ? 'Наборы не обновлены' : 'The rule-sets were not updated';
  String get ruleSetNotYet => _ru ? 'ещё не скачан' : 'not fetched yet';
  String get ruleSetNotHttps => _ru ? 'не https: не скачивается' : 'not https: never fetched';
  String get ruleSetOff => _ru ? 'правило выключено' : 'its rule is off';
  String ruleSetFetched(String size, String when) => _ru ? '$size, скачан $when' : '$size, fetched $when';
  String ruleSetKinds(int kinds) => switch (kinds) {
        1 => _ru ? 'домены' : 'domains',
        2 => _ru ? 'адреса' : 'addresses',
        3 => _ru ? 'домены и адреса' : 'domains and addresses',
        _ => '',
      };

  String get today => _ru ? 'сегодня' : 'today';
  String get yesterday => _ru ? 'вчера' : 'yesterday';
  String get checkAddress => _ru ? 'Адрес' : 'Address';
  String get checkProtocol => _ru ? 'Протокол' : 'Protocol';
  String get checkButton => _ru ? 'Проверить' : 'Check';
  String get checkChecking => _ru ? 'Проверяю…' : 'Checking…';
  String get checkResult => _ru ? 'Результат' : 'Result';
  String get checkRuleFinal => _ru ? 'Остальное' : 'Everything else';
  String get checkAnswerProxy => _ru ? 'Через прокси' : 'Through the proxy';
  String checkAnswerProxyNotIn(String names) =>
      _ru ? 'Через прокси: не в «$names»' : 'Through the proxy: not in “$names”';
  String checkAnswerProxyRule(String name) => _ru ? 'Через прокси: «$name»' : 'Through the proxy: “$name”';
  String checkAnswerDirect(String name) => _ru ? 'Напрямую: «$name»' : 'Direct: “$name”';
  String checkAnswerBlock(String name) => _ru ? 'Блок: «$name»' : 'Block: “$name”';
  String checkRuleSetUpdated(String name, String when) => _ru ? '«$name» обновлён $when' : '“$name” updated $when';
  String checkRuleSetNotFetched(String name) => _ru ? '«$name» ещё не скачан' : '“$name” not fetched yet';
  String get checkNoRoute => _ru ? 'Маршрута нет' : 'No route';
  String get checkNeedsNiko => _ru ? 'Проверке маршрута нужна служба Niko' : 'Route check needs the Niko service';
  String get checkFailed => _ru ? 'Не удалось проверить' : 'Could not check';
  String get checkRecent => _ru ? 'Недавние' : 'Recent';
  String get checkClearRecent => _ru ? 'Очистить недавние' : 'Clear recent';
  String get checkSteps => _ru ? 'Шаги' : 'Steps';
  String get checkNotes => _ru ? 'Заметки ядра' : 'Core notes';

  // Phase P5: Daily-driver UX
  String get groupNew => _ru ? 'Новая группа' : 'New group';
  String get groupNameField => _ru ? 'Название группы' : 'Group name';
  String get groupRename => _ru ? 'Переименовать' : 'Rename';
  String get groupDelete => _ru ? 'Удалить группу' : 'Delete group';
  String groupDeleteConfirm(String name) => _ru
      ? 'Удалить группу «$name» и все её профили?'
      : 'Delete group “$name” and all its profiles?';
  String get subscriptionsUpdateAll => _ru ? 'Обновить все' : 'Update all';
  String get subscriptionSettings => _ru ? 'Настройки' : 'Settings';
  String get subscriptionCopyLink => _ru ? 'Копировать ссылку' : 'Copy link';
  String get subscriptionLinkCopied => _ru ? 'Ссылка подписки скопирована' : 'Subscription link copied';
  String get subscriptionDelete => _ru ? 'Удалить подписку' : 'Delete subscription';
  String get subscriptionLink => _ru ? 'Ссылка подписки' : 'Subscription URL';
  String get subscriptionAutoUpdate => _ru ? 'Автообновление' : 'Auto-update';
  String get subscriptionDelay => _ru ? 'Интервал (мин)' : 'Interval (min)';
  String get subscriptionDedup => _ru ? 'Удалять дубликаты' : 'Deduplication';
  String get subscriptionForceResolve => _ru ? 'Резолвить адреса серверов' : 'Force resolve server addresses';
  String get subscriptionWhenConnected => _ru ? 'Обновлять только при подключении' : 'Update when connected only';
  String get subscriptionUserAgent => 'User-Agent';

  String get profileNew => _ru ? 'Новый профиль' : 'New profile';
  String get profileEdit => _ru ? 'Изменить профиль' : 'Edit profile';
  String get profileType => _ru ? 'Протокол' : 'Protocol';
  String get profileName => _ru ? 'Название' : 'Name';
  String get profileServer => _ru ? 'Сервер' : 'Server';
  String get profilePort => _ru ? 'Порт' : 'Port';
  String get profileUsername => _ru ? 'Пользователь' : 'Username';
  String get profilePassword => _ru ? 'Пароль / ключ / UUID' : 'Password / Key / UUID';
  String get profileSni => 'SNI';
  String get profileRawJson => _ru ? 'Сырой JSON (bean)' : 'Raw JSON (bean)';
  String get profileTestAll => _ru ? 'Проверить задержку' : 'Test latency';
  String get profileTesting => _ru ? 'Проверка…' : 'Testing…';

  String get addOpenFile => _ru ? 'Открыть файл' : 'Open file';
  String get addFileHint => _ru ? 'Поддерживаются .json, .conf, .txt, .zip и пакеты rcdev1' : 'Supports .json, .conf, .txt, .zip, and rcdev1 files';

  String get ruleConfigJson => _ru ? 'Свой JSON правила' : 'Custom rule JSON';
  String get ruleConfigHint => _ru ? 'Необязательный JSON-объект, объединяемый поверх правила' : 'Optional JSON object merged onto the rule';
  String get rulesReset => _ru ? 'Сбросить правила' : 'Reset rules';
  String get rulesResetConfirm => _ru ? 'Удалить все правила маршрутизации?' : 'Delete all route rules?';

  String get setEnableDnsRouting => _ru ? 'DNS-маршрутизация по правилам' : 'Rule-based DNS routing';
  String get setRuleSetHours => _ru ? 'Обновление наборов правил (ч)' : 'Rule-set update interval (h)';
  String get setDpiDirect => _ru ? 'Обход DPI для прямых правил' : 'DPI bypass for direct rules';
  String get setDpiOff => _ru ? 'Выкл' : 'Off';
  String get setDpiPreset => _ru ? 'Пресет' : 'Preset';
  String get setDpiCustom => _ru ? 'Своя строка' : 'Custom';
  String get setDpiPresetName => _ru ? 'Стратегия DPI' : 'DPI strategy';
  String get setDpiCustomArgs => _ru ? 'Аргументы ByeDPI' : 'ByeDPI arguments';

  String get setAutostart => _ru ? 'Запускать при входе в систему' : 'Launch on login';
  String get setConnectOnStartup => _ru ? 'Подключаться при запуске' : 'Connect on startup';
  String get setCloseToTray => _ru ? 'Сворачивать в трей при закрытии' : 'Minimize to tray on close';
  String get setNotifications => _ru ? 'Уведомления о подключении' : 'Connection notifications';
  String get setSaveFolder => _ru ? 'Папка для сохранения' : 'Save folder';
  String get setSaveFolderDefault => _ru ? 'Загрузки (по умолчанию)' : 'Downloads (default)';
  String get setSaveFolderReset => _ru ? 'Сбросить' : 'Reset';
  String get setSaveFolderChoose => _ru ? 'Выбрать…' : 'Choose…';

  String get mainTestConnection => _ru ? 'Проверить связь' : 'Test connection';
  String get mainTesting => _ru ? 'Проверка…' : 'Testing…';
  String get mainExitIp => _ru ? 'IP выхода' : 'Exit IP';
  String get mainExitConfirmTitle => _ru ? 'Проверить внешний IP?' : 'Check external exit IP?';
  String get mainExitConfirmText => _ru
      ? 'Выбранный HTTPS-сервис увидит IP-адрес выходного узла и время запроса. Продолжить?'
      : 'The chosen HTTPS lookup service will see the exit node IP address and request time. Continue?';
  String get mainExitConfirmGo => _ru ? 'Проверить' : 'Check';
  String get reloadBannerTitle => _ru ? 'Настройки изменены' : 'Settings changed';
  String get reloadBannerText => _ru
      ? 'Переподключитесь, чтобы применить изменения к работающему ядру'
      : 'Reconnect to apply changes to the running core';
  String get reloadBannerAction => _ru ? 'Переподключить' : 'Reconnect';
  String get networkRestoredTitle => _ru ? 'Связь со службой восстановлена' : 'Connection to service restored';

  String get trayOpen => _ru ? 'Открыть Niko' : 'Open Niko';
  String get trayQuit => _ru ? 'Выйти' : 'Quit';

  // Phase P6: raycontrol dynamics, D-WHY, D-ADMIN
  String get switchedBannerTitle => _ru ? 'Профиль переключён автоматически' : 'Profile switched automatically';
  String switchedBannerText(String from, String to) =>
      _ru ? 'Сторож переключил подключение с «$from» на «$to»' : 'Watchdog switched connection from “$from” to “$to”';
  String get switchedBannerDismiss => _ru ? 'Понятно' : 'Dismiss';

  String get nodeWhy => _ru ? 'Почему не работает?' : 'Why isn’t it working?';
  String get nodeAdmin => _ru ? 'Админ-панель' : 'Admin panel';
  String get nodeLanShow => _ru ? 'Показывать это устройство в LAN узла' : 'Show this device on node LAN';
  String nodeRelaysCount(int n) => _ru ? 'Ретрансляторов: $n' : 'Relays: $n';

  String get setRaycontrolSection => 'raycontrol';
  String get setRayAutoSwitch => _ru ? 'Автопереключение при сбое' : 'Auto-switch on failure';
  String get setRayAutoSwitchSub => _ru
      ? 'Сторож переключит узел на другой рабочий профиль, если текущий перестал отвечать'
      : 'Watchdog switches to another working profile on the node when the active one fails';
  String get setRayBrutal => _ru ? 'Hysteria2 Brutal по замеру канала' : 'Measured Hysteria2 Brutal';
  String get setRayBrutalSub => _ru
      ? 'Измерять полосу канала раз в сутки и понижать скорость при потерях'
      : 'Measure channel bandwidth daily and back off automatically on packet loss';
  String get setRayReports => _ru ? 'Анонимные сводки сети узлу' : 'Anonymous network summaries';
  String get setRayReportsSub => _ru
      ? 'Отправлять грубую статистику без идентификаторов не чаще раза в сутки'
      : 'Send coarse bucketed status without identifiers at most once per day';

  String get whyTitle => _ru ? 'Диагностика узла' : 'Node diagnostics';
  String get whyRunId => _ru ? 'ID прогона' : 'Run ID';
  String get whyStart => _ru ? 'Запустить проверку' : 'Start diagnostics';
  String get whyRunning => _ru ? 'Идёт проверка…' : 'Running diagnostics…';
  String get whyFindings => _ru ? 'Результаты' : 'Findings';
  String get whyWorking => _ru ? 'Работают' : 'Working';
  String get whyFailing => _ru ? 'Не работают' : 'Failing';
  String get whyNotes => _ru ? 'Сеть и узел' : 'Network & node';
  String get whySteps => _ru ? 'Ход проверки' : 'Progress log';
  String get whyCopyReport => _ru ? 'Копировать отчёт' : 'Copy report';
  String get whySaveReport => _ru ? 'Сохранить отчёт' : 'Save report';
  String get whyReportCopied => _ru ? 'Обезличенный отчёт скопирован' : 'Redacted report copied';
  String whyReportSaved(String path) => _ru ? 'Отчёт сохранён: $path' : 'Report saved: $path';
  String get whyBack => _ru ? 'Назад' : 'Back';

  String whyCause(String cause) => switch (cause) {
        'stalls' => _ru ? 'зависает после первых КБ (DPI)' : 'stalls after initial KB (DPI)',
        'timeout' => _ru ? 'таймаут ответа' : 'timed out',
        'reset' => _ru ? 'обрыв соединения (RST/EOF)' : 'connection reset (RST/EOF)',
        'refused' => _ru ? 'соединение отклонено' : 'connection refused',
        'tls' => _ru ? 'ошибка TLS / REALITY' : 'TLS / REALITY failure',
        'name' => _ru ? 'имя узла не резолвится' : 'DNS name failed to resolve',
        'unreachable' => _ru ? 'нет маршрута к узлу' : 'network unreachable',
        'busy' => _ru ? 'узел занят другой проверкой' : 'node probe busy',
        'http' => _ru ? 'HTTP-ошибка узла' : 'HTTP error from node',
        'limit' => _ru ? 'превышен лимит соединений' : 'connection limit reached',
        'auth' => _ru ? 'отказ авторизации профиля' : 'profile authentication rejected',
        'in_use' => _ru ? 'используется сейчас' : 'currently in use',
        _ => _ru ? 'ошибка' : 'error',
      };

  String whyNoteText(String note, int number, String detail) => switch (note) {
        'no_network' => _ru ? 'Нет сетевого подключения' : 'No network connection',
        'clock' => _ru ? 'Часы расходятся с узлом на $number с (SPA ломается >30 с)' : 'Clock skew with node: ${number}s (SPA fails >30s)',
        'no_subscription' => _ru ? 'Подписка не обновилась: $detail' : 'Subscription failed: $detail',
        'no_direct' => _ru ? 'Прямой путь к узлу не отвечает${detail.isEmpty ? '' : ': $detail'}' : 'Direct path did not answer${detail.isEmpty ? '' : ': $detail'}',
        'udp_blocked' => _ru ? 'UDP к узлу заблокирован' : 'Direct UDP to node is blocked',
        'udp_small' => _ru ? 'UDP MTU ограничен до $number байт (меньше 1200 для QUIC)' : 'Direct UDP MTU capped at $number bytes (<1200 for QUIC)',
        'dns_none' => _ru ? 'Ни один DNS-резолвер не пропускает туннель' : 'No DNS resolver passes the DNS tunnel',
        'dns_spare' => _ru ? 'Работает запасная DNS-зона #$number' : 'Spare DNS zone #$number is active',
        'relay_only' => _ru ? 'Работают только профили через ретранслятор' : 'Only relay profiles work on this network',
        'dns_only' => _ru ? 'Работают только DNS-туннели' : 'Only DNS tunnels work on this network',
        _ => note,
      };

  String get adminTitle => _ru ? 'Админ-панель' : 'Admin panel';
  String get adminTabStatus => _ru ? 'Состояние' : 'Status';
  String get adminTabUsers => _ru ? 'Пользователи' : 'Users';
  String get adminTabServices => _ru ? 'Сервисы' : 'Services';
  String get adminTabAudit => _ru ? 'Аудит' : 'Audit';
  String get adminRefresh => _ru ? 'Обновить' : 'Refresh';
  String get adminVersion => _ru ? 'Версия узла' : 'Node version';
  String get adminWarnings => _ru ? 'Предупреждения' : 'Warnings';
  String get adminDevices => _ru ? 'Устройства' : 'Devices';
  String get adminCreateInvite => _ru ? 'Создать инвайт' : 'Create invite';
  String get adminInviteUser => _ru ? 'Пользователь' : 'User';
  String get adminInviteDevice => _ru ? 'Устройство' : 'Device name';
  String get adminInviteRole => _ru ? 'Роль' : 'Role';
  String get adminInvitePin => _ru ? 'Защитить инвайт PIN-кодом' : 'Protect invite with PIN';
  String get adminInviteTtl => _ru ? 'Срок действия (ч)' : 'Expires in (hours)';
  String get adminInviteCreated => _ru ? 'Инвайт создан' : 'Invite created';
  String get adminCopyInvite => _ru ? 'Копировать инвайт' : 'Copy invite';
  String get adminInviteCopied => _ru ? 'Инвайт скопирован' : 'Invite copied';
  String get adminRevoke => _ru ? 'Отозвать' : 'Revoke';
  String adminRevokeConfirm(String name) => _ru ? 'Отозвать устройство «$name»?' : 'Revoke device “$name”?';
  String get adminRenewUser => _ru ? 'Сменить ключи' : 'Renew keys';
  String get adminSetLimit => _ru ? 'Лимит (ГБ)' : 'Limit (GB)';
  String get adminRotateService => _ru ? 'Ротация' : 'Rotate';
  String get adminEnable => _ru ? 'Включить' : 'Enable';
  String get adminDisable => _ru ? 'Выключить' : 'Disable';
  String get adminNoItems => _ru ? 'Пусто' : 'Empty';

  // Phase P7: Presets (China, Iran, Ads), Verified Updater (D-SET-12/33), Built-in FAQ (D-SET-31)
  String get presetChina => _ru ? 'Пресет Китай' : 'China preset';
  String get presetChinaProxy => _ru ? 'Некитайские сайты: через прокси' : 'Non-China sites: through the proxy';
  String get presetChinaDirect => _ru ? 'Китайские сервисы: напрямую' : 'China services: directly';
  String get presetIran => _ru ? 'Пресет Иран' : 'Iran preset';
  String get presetIranDirect => _ru ? 'Иранские сервисы: напрямую' : 'Iranian services: directly';
  String get presetAds => _ru ? 'Блокировка рекламы' : 'Block ads';
  String get presetAdsBlock => _ru ? 'Реклама и трекеры: блокировать' : 'Block ads and trackers';

  String get updateCheck => _ru ? 'Проверить обновления' : 'Check for updates';
  String get updateChecking => _ru ? 'Проверка…' : 'Checking…';
  String get updateDownload => _ru ? 'Скачать проверенное обновление' : 'Download verified update';
  String get updateDownloading => _ru ? 'Загрузка и проверка…' : 'Downloading & verifying…';
  String get updateUpToDate => _ru ? 'Установлена актуальная версия' : 'You are up to date';
  String updateAvailable(String version, String source) => _ru
      ? 'Доступна версия $version ($source)'
      : 'Version $version available ($source)';
  String get updateVerifiedBadge => _ru ? 'Подпись minisign проверена' : 'minisign signature verified';
  String get updateUnverifiedMirror =>
      _ru ? 'Из зеркала узла — подпись будет проверена при загрузке' : 'From node mirror — signature will be verified on download';
  String updateDownloaded(String path, String sha) => _ru
      ? 'Архив проверен и сохранён: $path (SHA-256 ${sha.length > 12 ? sha.substring(0, 12) : sha}…). Распакуйте его вручную для обновления.'
      : 'Archive verified and saved: $path (SHA-256 ${sha.length > 12 ? sha.substring(0, 12) : sha}…). Unpack it manually to update.';

  String get faqOpen => _ru ? 'Справка и FAQ' : 'Help & FAQ';
  String get faqTitle => _ru ? 'Справка и частые вопросы' : 'Help & FAQ';
  String get faqSubtitle => _ru
      ? 'Работает полностью офлайн · краткое руководство по Niko Desktop'
      : 'Available offline · quick guide to Niko Desktop';

  String get setSystemService => _ru ? 'Системная служба' : 'System service';
  String get serviceInstalledStatus => _ru ? 'Установлена (VPN / TUN доступен)' : 'Installed (VPN / TUN available)';
  String get serviceNotInstalledStatus => _ru ? 'Не установлена (только Прокси)' : 'Not installed (Proxy only)';
  String get uninstallService => _ru ? 'Удалить службу' : 'Uninstall service';
  String get uninstallingService => _ru ? 'Удаление службы…' : 'Uninstalling service…';
  String get uninstallServiceConfirmTitle => _ru ? 'Удалить системную службу?' : 'Uninstall system service?';
  String get uninstallServiceConfirmText => _ru
      ? 'Режим VPN (TUN) станет недоступен. Клиент переключится обратно на пользовательский режим Прокси.'
      : 'VPN (TUN) mode will no longer be available. The client will switch back to unprivileged Proxy mode.';
  String get uninstallServiceDone => _ru ? 'Системная служба удалена' : 'System service uninstalled';

  String get setBackup => _ru ? 'Резервная копия конфигурации' : 'Configuration backup';
  String get setBackupSub => _ru
      ? 'Профили, группы, правила и настройки (без ключей узлов raycontrol)'
      : 'Profiles, groups, rules, and settings (excluding raycontrol node keys)';
  String get backupExport => _ru ? 'Экспорт' : 'Export';
  String get backupImport => _ru ? 'Импорт' : 'Import';
  String get backupBusy => _ru ? 'Выполняется…' : 'Working…';
  String backupExported(String path, int profiles, int rules, int skippedNodes) => _ru
      ? 'Сохранено в $path (профилей: $profiles, правил: $rules${skippedNodes > 0 ? ', узлов пропущено: $skippedNodes' : ''})'
      : 'Saved to $path (profiles: $profiles, rules: $rules${skippedNodes > 0 ? ', nodes skipped: $skippedNodes' : ''})';
  String backupImported(int groups, int profiles, int rules) => _ru
      ? 'Импортировано: групп $groups, профилей $profiles, правил $rules'
      : 'Imported: $groups groups, $profiles profiles, $rules rules';
  String get backupFailed => _ru ? 'Ошибка резервной копии' : 'Backup failed';

  // API 18: 12-section B-Settings parity + localized NaiveProxy/Yggdrasil/Admin/Nodes/Main labels
  String get setRaycontrolNodes => _ru ? 'Узлы raycontrol' : 'raycontrol nodes';
  String get setNaiveSection => 'naive';
  String get setYggdrasilSection => 'Yggdrasil';
  String get setBackupSection => _ru ? 'Резервная копия' : 'Backup';
  String get setHelpSection => _ru ? 'Справка' : 'Help';
  String get setConnectLastMethod => _ru ? 'Последним выбранным способом' : 'With the last chosen method';
  String get setRayDnsttResolver => _ru ? 'Резолвер dnstt' : 'dnstt resolver';
  String get setRayMasterDnsResolvers => _ru ? 'Резолверы MasterDnsVPN' : 'MasterDnsVPN resolvers';
  String get setRayReportsShort => _ru ? 'Сводка для админа' : 'Summary for admin';
  String get setRayReportsNoAddr => _ru ? 'Без адресов и идентификаторов, не чаще раза в сутки' : 'No addresses or identifiers, at most once a day';
  String get setConnTestUrl => _ru ? 'URL проверки соединения' : 'Connection test URL';
  String get setConnTestConcurrency => _ru ? 'Параллельность проверки' : 'Test concurrency';
  String get setExitService => _ru ? 'Сервис для адреса выхода' : 'Exit address service';
  String get setNetworkChangeReset => _ru ? 'Сбрасывать соединения при смене сети' : 'Reset connections on network change';
  String get setWakeReset => _ru ? 'Сбрасывать соединения после сна' : 'Reset connections after sleep';
  String get setEnableClashApi => 'Clash API';
  String get setClashApiSecret => _ru ? 'Секрет Clash API' : 'Clash API secret';
  String get setClashApiHint => _ru ? 'Слушает на 127.0.0.1:9090' : 'Listens on 127.0.0.1:9090';
  String get setInsecureSubscription => _ru ? 'Не проверять сертификаты подписок' : 'Skip TLS verification for subscriptions';
  String get setSubscriptionMinTls => _ru ? 'Наименьший TLS у подписок' : 'Minimum TLS for subscriptions';
  String get setTlsAuto => _ru ? 'Авто' : 'Auto';
  String get setNaiveRoots => _ru ? 'Корневые сертификаты' : 'Root certificates';
  String get setNaiveRootsSystem => _ru ? 'Системные' : 'System';
  String get setNaiveQuicSystemRoots => _ru ? 'naive по QUIC: принимать системные корни' : 'naive over QUIC: trust system roots';
  String get setNaiveQuicSystemRootsSub => _ru
      ? 'Разрешить локально установленные сертификаты для HTTP/3 / QUIC'
      : 'Allow locally trusted system roots for HTTP/3 / QUIC';
  String get setYggdrasilEnable => _ru ? 'Включить Yggdrasil' : 'Enable Yggdrasil';
  String get setYggdrasilPeers => _ru ? 'Пиры Yggdrasil' : 'Yggdrasil peers';
  String get setYggdrasilPeersAuto => _ru ? 'публичные, 3 быстрейших' : 'public, 3 fastest';
  String get setYggdrasilViaProxy => _ru ? 'К пирам через прокси' : 'Connect to peers via proxy';
  String get setYggdrasilTlsChrome => _ru ? 'TLS к пирам как у Chrome' : 'Chrome TLS fingerprint to peers';
  String get setYggdrasilInbound => _ru ? 'Принимать входящие Yggdrasil' : 'Allow Yggdrasil inbound';
  String get setYggdrasilInboundPorts => _ru ? 'Разрешённые порты Yggdrasil' : 'Allowed Yggdrasil ports';
  String get setYggdrasilAddress => _ru ? 'Адрес этого устройства' : 'This device address';
  String get setYggdrasilAddressEmpty => _ru ? 'появится после первого запуска' : 'assigned on first start';
  String get setHonestConnect => _ru ? 'Честное подключение' : 'Honest connect';
  String get setHonestConnectSub => _ru
      ? 'Ждать подтверждения соединения от сервера (await_dial)'
      : 'Wait for server dial acknowledgement (await_dial)';
  String get setIcmpThroughNode => _ru ? 'ping через узел' : 'ping through node';
  String get setIcmpThroughNodeSub => _ru
      ? 'Проксировать ICMP-запросы через naive (если узел поддерживает)'
      : 'Tunnel ICMP echo through naive when supported by the node';
  String get setLogView => _ru ? 'Журнал и вид' : 'Log & view';
  String get setLogBufferSize => _ru ? 'Размер буфера журнала' : 'Log buffer size';
  String get setSpeedInterval => _ru ? 'Обновление скорости' : 'Speed refresh interval';
  String get setProfileTrafficStats => _ru ? 'Считать трафик профилей' : 'Count per-profile traffic';
  String get setDirectSpeed => _ru ? 'Скорость прямых соединений' : 'Show direct traffic speed';
  String get setShowServerAddress => _ru ? 'Адрес сервера в списке' : 'Show server address in list';
  String get setGlobalCustomConfig => _ru ? 'Общий свой конфиг (JSON)' : 'Global custom config (JSON)';
  String get setGlobalCustomConfigHint => _ru
      ? 'JSON-объект, объединяемый поверх итоговой конфигурации sing-box'
      : 'JSON object merged on top of the generated sing-box config';
  String get setResetSettings => _ru ? 'Сбросить настройки…' : 'Reset settings…';
  String get setResetConfirmTitle => _ru ? 'Сбросить все настройки?' : 'Reset all settings?';
  String get setResetConfirmText => _ru
      ? 'Все параметры вернутся к значениям по умолчанию. Профили, группы, правила, узлы и ключ Yggdrasil останутся.'
      : 'All settings will return to defaults. Profiles, groups, rules, nodes, and your Yggdrasil key are kept.';
  String get setResetConfirmGo => _ru ? 'Сбросить' : 'Reset';
  String get setResetDone => _ru ? 'Настройки сброшены к умолчаниям' : 'Settings reset to defaults';
  String get setAutoCheckUpdates => _ru ? 'Проверять обновления самому' : 'Check for updates automatically';
  String get setIncludePrerelease => _ru ? 'Предварительные сборки' : 'Include pre-releases';
  String get setHelpValues => _ru ? 'Справка и что значат величины' : 'Help & what values mean';
  String get copiedShort => _ru ? 'Скопировано' : 'Copied';

  // Localized naive-udp-v1 states (B3)
  String naiveUdpStateLabel(String state) => switch (state) {
        'quic' || 'allowed' => _ru ? 'HTTP/3 датаграммы (QUIC)' : 'HTTP/3 datagrams (QUIC)',
        'probing' => _ru ? 'проверка UDP…' : 'probing UDP…',
        'tcp_fallback' || 'refused' => _ru ? 'UDP через TCP (запасной)' : 'UDP over TCP (fallback)',
        'unsupported' => _ru ? 'не поддерживается сервером' : 'unsupported by server',
        'off' => _ru ? 'выключен' : 'off',
        _ => state,
      };

  // Step 5 strings (Nodes search/sort/menu, Group settings, Main active method, Why recommendation, Admin Network/Policies, Clash API)
  String get nodesSearchHint => _ru ? 'Поиск профилей…' : 'Search profiles…';
  String get nodesSortOrder => _ru ? 'Порядок' : 'Order';
  String get nodesSortName => _ru ? 'Имя' : 'Name';
  String get nodesSortLatency => _ru ? 'Задержка' : 'Latency';
  String get nodesMenuClearLatency => _ru ? 'Очистить задержки' : 'Clear latencies';
  String get nodesMenuDeleteFailed => _ru ? 'Удалить недоступные' : 'Delete unreachable';
  String get nodesMenuDeduplicate => _ru ? 'Удалить дубликаты' : 'Remove duplicates';
  String get groupSettingsTitle => _ru ? 'Настройки группы' : 'Group settings';
  String get groupIsSelector => _ru ? 'Ручной выбор (selector)' : 'Manual selector';
  String get groupAutoSelect => _ru ? 'Автовыбор быстрейшего (urltest)' : 'Auto-select fastest (urltest)';
  String get groupFrontProxy => _ru ? 'Входной прокси (front)' : 'Front proxy';
  String get groupLandingProxy => _ru ? 'Выходной прокси (landing)' : 'Landing proxy';
  String get groupProxyNone => _ru ? 'Нет' : 'None';
  String get mainActiveMethod => _ru ? 'Способ подключения' : 'Connection method';
  String get mainSwitchMethod => _ru ? 'Сменить' : 'Switch';
  String get mainReturnPrevious => _ru ? 'Вернуть' : 'Restore';
  String get whyRecommendTitle => _ru ? 'Рекомендация' : 'Recommendation';
  String whyRecommendSwitch(String name) => _ru ? 'Перейти на «$name»' : 'Switch to “$name”';
  String get adminTabNetwork => _ru ? 'Сеть' : 'Network';
  String get adminTabPolicies => _ru ? 'Политики' : 'Policies';
  String get adminAddUser => _ru ? 'Новый пользователь' : 'New user';
  String get adminCreateUserName => _ru ? 'Имя пользователя' : 'Username';
  String get logFilterAll => _ru ? 'Все' : 'All';
  String get clashApiCardTitle => 'Clash API';
  String get clashApiOpenHint => _ru ? 'Локальный контроллер 127.0.0.1:9090' : 'Local controller at 127.0.0.1:9090';
  String get addFullConfigWarning => _ru
      ? 'Импортируется полная конфигурация sing-box (сырой JSON). Подтвердите добавление.'
      : 'Importing a full sing-box raw JSON configuration. Confirm to add.';
  String get profileChainHops => _ru ? 'Цепочка прокси (хопы)' : 'Proxy chain hops';
  String get profileAddHop => _ru ? 'Добавить хоп' : 'Add hop';
  String get trayModeVpn => _ru ? 'Режим: VPN (TUN)' : 'Mode: VPN (TUN)';
  String get trayModeProxy => _ru ? 'Режим: Прокси' : 'Mode: Proxy';

  List<(String, String)> get faqEntries => _ru
      ? const [
          (
            'Прокси или VPN (TUN)?',
            'Режим Прокси запускает локальный mixed-прокси (по умолчанию 127.0.0.1:2080) и при включении «Системный прокси» настраивает систему без прав администратора. Режим VPN (TUN) перехватывает весь системный трафик через виртуальный интерфейс и требует установленной системной службы niko-daemon.',
          ),
          (
            'User-mode и системная служба',
            'Без установки службы Niko автоматически запускает пользовательский демон (--user-mode) для режима Прокси. При переходе на системную службу (в 1 клик через pkexec на Linux или UAC на Windows) профили, правила и ключи узлов raycontrol переносятся однократно и безопасно перешифровываются.',
          ),
          (
            'Узлы raycontrol, инвайты и сторож',
            'Инвайт (rcinv1/2/3) регистрирует компьютер на узле с отдельным ключом устройства; если узел требует PIN, введите 6 цифр от администратора. Сторож периодически проверяет связность и при включённом автопереключении переводит подключение на рабочий профиль узла.',
          ),
          (
            'Диагностика «Почему не работает?»',
            'Откройте карточку узла raycontrol и нажмите «Почему не работает?». Niko проверит прямой SPA-путь, UDP MTU, подписку и каждый профиль (включая ретрансляторы) и сформирует обезличенный отчёт без адресов узлов и ключей.',
          ),
          (
            'Проверка обновлений (minisign)',
            'Все официальные релизы Niko подписываются ключом minisign (D5D2D2E799D74D8D). Перед сохранением обновления демон проверяет подпись файла SHA256SUMS, комментарий релиза и SHA-256 скачанного архива. При недоступности GitHub используется зеркало узла raycontrol с той же криптографической проверкой.',
          ),
          (
            'Ссылки niko://, sn:// и clash://',
            'Установленный пакет регистрирует обработчики URL-схем. Переход по ссылке niko://, sn:// или clash:// открывает экран добавления с уже заполненным полем и предпросмотром до сохранения.',
          ),
        ]
      : const [
          (
            'Proxy vs VPN (TUN) mode',
            'Proxy mode runs a local mixed proxy (127.0.0.1:2080 by default) and optionally configures the desktop system proxy without administrator privileges. VPN (TUN) mode captures all system traffic through a virtual interface and requires the installed niko-daemon system service.',
          ),
          (
            'User-mode vs System Service',
            'Without installing a service, Niko starts an unprivileged user-mode daemon (--user-mode) for Proxy mode. When you install the system service (1-click pkexec on Linux or UAC on Windows), profiles, rules, and raycontrol keys migrate cleanly and are re-sealed under the service identity.',
          ),
          (
            'raycontrol Nodes, Invites & Watchdog',
            'An invite (rcinv1/2/3) registers this machine with its own sealed device key; enter the 6-digit PIN if required. When auto-switch is enabled, the watchdog recovers from network failures by refreshing the subscription, trying alternate credentials, or failing over to a working profile.',
          ),
          (
            '“Why isn’t it working?” Diagnostics',
            'Open a raycontrol node card and click “Why isn’t it working?”. Niko tests direct SPA reachability, UDP MTU, subscription refresh, and every profile (including relays), producing a redacted diagnostic log safe to share.',
          ),
          (
            'Verified Updates (minisign)',
            'Official releases are signed with minisign key D5D2D2E799D74D8D. The daemon verifies SHA256SUMS against SHA256SUMS.minisig, checks the release tag trusted comment, and validates the archive SHA-256 before saving. raycontrol node mirrors follow the exact same verification.',
          ),
          (
            'URL Schemes (niko://, sn://, clash://)',
            'Installed desktop packages register OS URL handlers. Opening a niko://, sn://, or clash:// link launches Niko directly into the Add screen prefilled with a safe preview before importing.',
          ),
        ];
}
