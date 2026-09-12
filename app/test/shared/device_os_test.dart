import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/shared/device_os.dart';

const _accepted = [
  'android',
  'ios',
  'macos',
  'windows',
  'linux',
  'fuchsia',
  'web',
];

void main() {
  group('версия ОС читается из того, что платформа называет релизом', () {
    // Источник — device_info_plus, а не Platform.operatingSystemVersion:
    // последний на Android отдаёт идентификатор СБОРКИ
    // (`B4.1-260810-1153` на A059, реальная система — Android 16), и первая
    // редакция выкусывала оттуда `260810`. Тест тогда был зелёным ровно
    // потому, что проверял строку, сочинённую мной, а не отданную телефоном.
    test('Android: Build.VERSION.RELEASE', () {
      final os = DeviceOs.from(operatingSystem: 'android', release: '16');
      expect(os.platform, 'android');
      expect(os.osVersion, '16');
    });

    test('iOS: UIDevice.systemVersion', () {
      expect(
        DeviceOs.from(operatingSystem: 'ios', release: '18.1').osVersion,
        '18.1',
      );
    });

    test('три части сохраняются целиком', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: '8.1.0').osVersion,
        '8.1.0',
      );
    });

    test('суффикс после номера отбрасывается, а не роняет разбор', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: '16 QPR1').osVersion,
        '16',
      );
    });

    test('четвёртая часть отсекается по границе CHECK', () {
      expect(
        DeviceOs.from(
          operatingSystem: 'android',
          release: '16.0.1.2',
        ).osVersion,
        '16.0.1',
      );
    });
  });

  group('всё, что сервер отверг бы, становится null', () {
    test('платформа не из списка ограничения', () {
      expect(
        DeviceOs.from(operatingSystem: 'haiku', release: '1.0').platform,
        isNull,
      );
    });

    test('релиз, названный буквой (превью Android)', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: 'R').osVersion,
        isNull,
      );
    });

    test('пустой релиз', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: '').osVersion,
        isNull,
      );
    });

    test('платформа релиза не сообщает вовсе', () {
      expect(DeviceOs.from(operatingSystem: 'linux').osVersion, isNull);
    });

    // Число в строке есть, но не в начале — ровно та форма, из которой
    // раньше получалось `260810`. Теперь якорь в начале её не пускает.
    test('число не в начале строки версией не считается', () {
      expect(
        DeviceOs.from(
          operatingSystem: 'android',
          release: 'B4.1-260810-1153',
        ).osVersion,
        isNull,
      );
    });
  });

  test('нормализованный результат проходит серверный CHECK', () {
    // Та же проверка, что стоит в БД: всё, что эта пара может выдать, должно
    // приниматься `push_registration_status_os_version_format`.
    for (final release in ['16', '18.1', '8.1.0', '16 QPR1', '16.0.1.2']) {
      final os = DeviceOs.from(operatingSystem: 'android', release: release);
      expect(os.osVersion, matches(r'^\d+(\.\d+){0,2}$'), reason: release);
    }
    for (final platform in _accepted) {
      expect(DeviceOs.from(operatingSystem: platform).platform, platform);
    }
  });
}
