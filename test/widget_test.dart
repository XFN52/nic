import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:nic/main.dart';

void main() {
  // Настройка моков для платформенных каналов, чтобы избежать MissingPluginException
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel notificationChannel =
      MethodChannel('dexterous.com/flutter/local_notifications');
  const MethodChannel timezoneChannel =
      MethodChannel('com.tunitco/flutter_timezone');

  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, (MethodCall methodCall) async {
      if (methodCall.method == 'initialize' || methodCall.method == 'pendingNotificationRequests') {
        return null;
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(timezoneChannel, (MethodCall methodCall) async {
      if (methodCall.method == 'getLocalTimezone') {
        return 'UTC';
      }
      return null;
    });
  });

  group('TrackerPage Logic Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('Verify day transition and dose logic', (WidgetTester tester) async {
      // Инициализируем SharedPreferences с тестовыми значениями
      // Старт курса: 19 июля 2026 года в 15:00
      final startDate = DateTime(2026, 7, 19, 15, 0);
      SharedPreferences.setMockInitialValues({
        'course_start_date': startDate.toIso8601String(),
        'doses_log': <String>[
          DateTime(2026, 7, 19, 16, 0).toIso8601String(), // День 1
          DateTime(2026, 7, 19, 18, 0).toIso8601String(), // День 1
        ],
      });

      // Строим приложение
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();

      // Находим состояние страницы TrackerPage
      final stateFinder = find.byType(TrackerPage);
      expect(stateFinder, findsOneWidget);
      
      final state = tester.state(stateFinder) as dynamic;
      // Принудительно задаем _startDate и _doses для тестов
      state.setTestState(
        startDate,
        [
          DateTime(2026, 7, 19, 16, 0), // День 1
          DateTime(2026, 7, 19, 18, 0), // День 1
        ],
      );

      // 1. Тестирование _getCurrentDay()
      // В тот же день (19 июля 2026 в 23:59) -> День 1
      state.setMockNow(DateTime(2026, 7, 19, 23, 59));
      expect(state.getCurrentDayTest(), 1);

      // В следующий календарный день (20 июля 2026 в 00:01) -> День 2
      state.setMockNow(DateTime(2026, 7, 20, 0, 1));
      expect(state.getCurrentDayTest(), 2);

      // Через два дня (21 июля 2026 в 12:00) -> День 3
      state.setMockNow(DateTime(2026, 7, 21, 12, 0));
      expect(state.getCurrentDayTest(), 3);


      // 2. Тестирование _getDosesForDay()
      // День 1 должен содержать 2 дозы
      expect(state.getDosesForDayTest(1).length, 2);
      // День 2 должен содержать 0 доз
      expect(state.getDosesForDayTest(2).length, 0);


      // 3. Тестирование _adjustForNightTime()
      // Дневное время (15:00) не должно меняться
      final dayTime = DateTime(2026, 7, 19, 15, 0);
      expect(state.adjustForNightTimeTest(dayTime), dayTime);

      // Ночное время (23:30) должно сдвинуться на 08:00 следующего дня
      final nightTimeLate = DateTime(2026, 7, 19, 23, 30);
      expect(
        state.adjustForNightTimeTest(nightTimeLate),
        DateTime(2026, 7, 20, 8, 0),
      );

      // Раннее утро (03:00) должно сдвинуться на 08:00 этого же дня
      final nightTimeEarly = DateTime(2026, 7, 20, 3, 0);
      expect(
        state.adjustForNightTimeTest(nightTimeEarly),
        DateTime(2026, 7, 20, 8, 0),
      );


      // 4. Тестирование _getNextDoseTime()
      // Сценарий A: Первая доза за день, сейчас ночь (20 июля 02:00) -> Должно вернуть 08:00 утра
      state.setMockNow(DateTime(2026, 7, 20, 2, 0));
      // Очистим дозы за День 2 (их и так 0)
      expect(
        state.getNextDoseTimeTest(2),
        DateTime(2026, 7, 20, 8, 0),
      );

      // Сценарий B: Первая доза за день, сейчас день (20 июля 10:00) -> Должно вернуть текущее время (10:00)
      final testNow = DateTime(2026, 7, 20, 10, 0);
      state.setMockNow(testNow);
      expect(state.getNextDoseTimeTest(2), testNow);

      // Сценарий C: Не первая доза, лимит не исчерпан. 
      // Последняя доза была 19 июля в 18:00. Интервал на День 1 - 2 часа.
      // Следующая доза должна быть 19 июля в 20:00.
      state.setMockNow(DateTime(2026, 7, 19, 18, 30));
      expect(
        state.getNextDoseTimeTest(1),
        DateTime(2026, 7, 19, 20, 0),
      );

      // Сценарий D: Лимит на сегодня исчерпан.
      // Зададим 6 доз для Дня 1 (максимум для Дня 1 = 6)
      state.setTestState(
        startDate,
        [
          DateTime(2026, 7, 19, 10, 0),
          DateTime(2026, 7, 19, 12, 0),
          DateTime(2026, 7, 19, 14, 0),
          DateTime(2026, 7, 19, 16, 0),
          DateTime(2026, 7, 19, 18, 0),
          DateTime(2026, 7, 19, 20, 0),
        ],
      );
      state.setMockNow(DateTime(2026, 7, 19, 20, 30));
      // Должно вернуть полночь следующего дня (20 июля 00:00), 
      // скорректированную методом _adjustForNightTime на 20 июля 08:00.
      expect(
        state.getNextDoseTimeTest(1),
        DateTime(2026, 7, 20, 8, 0),
      );
    });
  });
}
