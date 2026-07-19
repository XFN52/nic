import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Citizine Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const TrackerPage(),
    );
  }
}

// Модель для правил приема
class ScheduleRule {
  final String label;
  final Duration interval;
  final int maxDoses;

  ScheduleRule(this.label, this.interval, this.maxDoses);
}

class TrackerPage extends StatefulWidget {
  const TrackerPage({super.key});

  @override
  State<TrackerPage> createState() => _TrackerPageState();
}

class _TrackerPageState extends State<TrackerPage> {
  DateTime? _startDate;
  List<DateTime> _doses = [];
  bool _loading = true;
  DateTime? _mockNow;

  DateTime get _now => _mockNow ?? DateTime.now();

  // Правила курса
  final Map<int, ScheduleRule> _schedule = {};

  @override
  void initState() {
    super.initState();
    _initSchedule();
    _loadData();
    NotificationService.requestNotificationPermission();
  }

  void _initSchedule() {
    // Заполняем правила для каждого дня
    for (int i = 1; i <= 25; i++) {
      if (i <= 3) {
        _schedule[i] = ScheduleRule("1 таб. каждые 2 часа", const Duration(hours: 2), 6);
      } else if (i <= 12) {
        _schedule[i] = ScheduleRule("1 таб. каждые 2.5 часа", const Duration(minutes: 150), 5);
      } else if (i <= 16) {
        _schedule[i] = ScheduleRule("1 таб. каждые 3 часа", const Duration(hours: 3), 4);
      } else if (i <= 20) {
        _schedule[i] = ScheduleRule("1 таб. каждые 5 часов", const Duration(hours: 5), 3);
      } else {
        _schedule[i] = ScheduleRule("1-2 таблетки в день", const Duration(hours: 0), 2);
      }
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final startString = prefs.getString('course_start_date');
    final dosesList = prefs.getStringList('doses_log');

    setState(() {
      if (startString != null) {
        _startDate = DateTime.parse(startString);
      }
      if (dosesList != null) {
        _doses = dosesList.map((e) => DateTime.parse(e)).toList();
      }
      _loading = false;
    });

    if (_startDate != null) {
      await _scheduleNextNotification();
    }
  }

  Future<void> _startCourse() async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Точные напоминания'),
        content: const Text(
          'Чтобы получать уведомления о приеме таблеток вовремя, '
          'приложению требуется доступ к точным будильникам. \n\n'
          'Пожалуйста, в открывшемся системном окне настроек разрешите '
          'приложению "Доступ к точным будильникам".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Позже (неточно)'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Перейти к настройкам'),
          ),
        ],
      ),
    );

    if (proceed == true) {
      await NotificationService.requestExactAlarmsPermission();
    }

    final now = DateTime.now();
    setState(() {
      _startDate = now;
      _doses.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('course_start_date', now.toIso8601String());
    await prefs.setStringList('doses_log', []);
    _scheduleNextNotification();
  }

  Future<void> _stopCourse() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сбросить курс?'),
        content: const Text('Вся история будет удалена. Начать заново?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сбросить', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('course_start_date');
      await prefs.remove('doses_log');
      setState(() {
        _startDate = null;
        _doses = [];
      });
      await NotificationService.cancelAll();
    }
  }

  Future<void> _takePill() async {
    final now = DateTime.now();
    setState(() {
      _doses.add(now);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('doses_log', _doses.map((e) => e.toIso8601String()).toList());
    _scheduleNextNotification();
  }

  Future<void> _scheduleNextNotification() async {
    try {
      await NotificationService.cancelAll();
      final currentDay = _getCurrentDay();
      final nextTime = _getNextDoseTime(currentDay);

      if (nextTime != null) {
        await NotificationService.scheduleNotification(
          id: 0,
          scheduledTime: nextTime,
          title: 'Время принять таблетку',
          body: 'Пора принять очередную таблетку Цитизина по схеме.',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Ошибка при планировании уведомлений: $e\n$stackTrace');
    }
  }

  int _getCurrentDay() {
    if (_startDate == null) return 0;
    final now = _now;
    final startMidnight = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
    final nowMidnight = DateTime(now.year, now.month, now.day);
    final diff = nowMidnight.difference(startMidnight);
    final day = diff.inDays + 1;
    return day < 1 ? 1 : day;
  }

  List<DateTime> _getDosesForDay(int day) {
    if (_startDate == null) return [];
    
    return _doses.where((d) {
       final startMidnight = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
       final doseMidnight = DateTime(d.year, d.month, d.day);
       final doseDay = doseMidnight.difference(startMidnight).inDays + 1;
       return doseDay == day;
    }).toList();
  }

  DateTime _adjustForNightTime(DateTime time) {
    if (time.hour >= 22) {
      final nextDay = time.add(const Duration(days: 1));
      return DateTime(nextDay.year, nextDay.month, nextDay.day, 8, 0);
    } else if (time.hour < 8) {
      return DateTime(time.year, time.month, time.day, 8, 0);
    }
    return time;
  }

  DateTime? _getNextDoseTime(int currentDay) {
    if (_startDate == null) return null;
    final rule = _schedule[currentDay];
    if (rule == null) return null;
    if (rule.interval.inMinutes == 0) return null; // Ручной режим

    final todayDoses = _getDosesForDay(currentDay);
    
    // Если на сегодня лимит исчерпан
    if (todayDoses.length >= rule.maxDoses) {
      if (currentDay < 25) {
        // Следующий день курса начинается в полночь следующего дня
        final startMidnight = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
        final nextDayMidnight = startMidnight.add(Duration(days: currentDay));
        return _adjustForNightTime(nextDayMidnight);
      }
      return null; // Курс завершен
    }

    if (todayDoses.isEmpty) {
      final now = _now;
      final morningTime = DateTime(now.year, now.month, now.day, 8, 0);
      if (now.isBefore(morningTime)) {
        return morningTime;
      }
      return now;
    }

    todayDoses.sort();
    final lastDose = todayDoses.last;
    
    final rawNextTime = lastDose.add(rule.interval);
    return _adjustForNightTime(rawNextTime);
  }

  @visibleForTesting
  void setTestState(DateTime start, List<DateTime> doses) {
    _startDate = start;
    _doses = doses;
  }

  @visibleForTesting
  void setMockNow(DateTime mockTime) {
    _mockNow = mockTime;
  }

  @visibleForTesting
  int getCurrentDayTest() => _getCurrentDay();

  @visibleForTesting
  List<DateTime> getDosesForDayTest(int day) => _getDosesForDay(day);

  @visibleForTesting
  DateTime adjustForNightTimeTest(DateTime time) => _adjustForNightTime(time);

  @visibleForTesting
  DateTime? getNextDoseTimeTest(int currentDay) => _getNextDoseTime(currentDay);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    if (_startDate == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.medication_liquid, size: 80, color: Colors.teal),
              const SizedBox(height: 20),
              const Text("Курс Цитизина", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              const Text("Схема приема на 25 дней", style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 40),
              ElevatedButton(
                onPressed: _startCourse,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                ),
                child: const Text("НАЧАТЬ КУРС", style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
      );
    }

    final currentDay = _getCurrentDay();

    return Scaffold(
      appBar: AppBar(
        title: Text("День $currentDay из 25"),
        actions: [
          IconButton(onPressed: _stopCourse, icon: const Icon(Icons.refresh))
        ],
      ),
      body: Column(
        children: [
          // ВЕРХНЯЯ ПАНЕЛЬ: Статус и таймер
          _buildStatusCard(currentDay),

          const Divider(height: 1),
          
          // НИЖНЯЯ ПАНЕЛЬ: Сетка дней
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                childAspectRatio: 1.0,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: 25,
              itemBuilder: (ctx, index) {
                final dayNum = index + 1;
                return _buildDayCard(dayNum, currentDay);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(int currentDay) {
    if (currentDay > 25) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        color: Colors.green[100],
        child: const Column(
          children: [
            Icon(Icons.check_circle, size: 50, color: Colors.green),
            Text("Курс завершен!", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    final rule = _schedule[currentDay]!;
    final dosesToday = _getDosesForDay(currentDay);
    final count = dosesToday.length;
    final nextTime = _getNextDoseTime(currentDay);

    String timerText = "Можно принять";
    Color timerColor = Colors.green;

    if (count >= rule.maxDoses) {
      timerText = "На сегодня всё";
      timerColor = Colors.grey;
    } else if (dosesToday.isEmpty) {
      timerText = "Можно принять";
      timerColor = Colors.green;
    } else if (nextTime != null && nextTime.isAfter(_now)) {
      if (nextTime.day != _now.day) {
        timerText = DateFormat('Завтра в HH:mm').format(nextTime);
      } else {
        timerText = DateFormat('HH:mm').format(nextTime);
      }
      timerColor = Colors.orange;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        // ignore: deprecated_member_use
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Column(
        children: [
          Text("Схема на сегодня:", style: TextStyle(color: Colors.grey[600])),
          Text(rule.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          
          Text("Следующий прием:", style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          Text(timerText, style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: timerColor)),
          
          const SizedBox(height: 10),
          Text("Выпито сегодня: $count из ${rule.maxDoses}", style: const TextStyle(fontWeight: FontWeight.bold)),
          
          const SizedBox(height: 20),
          if (count < rule.maxDoses)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: (nextTime != null && nextTime.isAfter(_now) && dosesToday.isNotEmpty) 
                    ? null // Кнопка неактивна, если рано и уже были приемы сегодня
                    : _takePill,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.check),
                label: const Text("ПРИНЯТЬ ТАБЛЕТКУ"),
              ),
            ),
             if (nextTime != null && nextTime.isAfter(_now) && dosesToday.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text("Ждите времени приема...", style: TextStyle(color: Colors.orange[800], fontSize: 12)),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await NotificationService.scheduleNotification(
                    id: 999,
                    scheduledTime: DateTime.now().add(const Duration(seconds: 3)),
                    title: 'Тест уведомлений',
                    body: 'Уведомления на Android 14 работают отлично! 🚀',
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Уведомление придет через 3 секунды. Закройте приложение для проверки!')),
                  );
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blueGrey,
                  side: const BorderSide(color: Colors.blueGrey),
                ),
                icon: const Icon(Icons.notification_important),
                label: const Text("ТЕСТ УВЕДОМЛЕНИЯ (3 сек)"),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayCard(int dayNum, int currentDay) {
    final isCurrent = dayNum == currentDay;
    final isPast = dayNum < currentDay;
    final rule = _schedule[dayNum]!;

    Color bgColor = Colors.white;
    Color textColor = Colors.black;

    if (isCurrent) {
      bgColor = Colors.teal;
      textColor = Colors.white;
    } else if (isPast) {
      bgColor = Colors.grey[300]!;
      textColor = Colors.grey[700]!;
    }

    return InkWell(
      onTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text("День $dayNum"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Режим приема:", style: TextStyle(color: Colors.grey)),
                Text(rule.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Text("Максимум в день: ${rule.maxDoses}"),
              ],
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ОК"))],
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: isCurrent ? Border.all(color: Colors.teal.shade700, width: 2) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text("$dayNum", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
            if (isCurrent) 
              const Text("СЕГОДНЯ", style: TextStyle(fontSize: 8, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}