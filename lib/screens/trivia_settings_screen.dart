import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TriviaSettingsScreen extends StatefulWidget {
  const TriviaSettingsScreen({super.key});

  @override
  State<TriviaSettingsScreen> createState() => _TriviaSettingsScreenState();
}

class _TriviaSettingsScreenState extends State<TriviaSettingsScreen> {
  static const Color _teal = Color(0xFF0d9488);

  static const List<(int, String)> _countdownOptions = [
    (5,  '5 seconds'),
    (10, '10 seconds (default)'),
    (15, '15 seconds'),
    (20, '20 seconds'),
    (30, '30 seconds'),
  ];

  String _triviaRevealMode = 'auto';
  int _triviaCountdownS = 10;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _triviaRevealMode = prefs.getString('trivia_reveal_mode') ?? 'auto';
      _triviaCountdownS = prefs.getInt('trivia_countdown_s') ?? 10;
      _loading = false;
    });
  }

  Future<void> _setTriviaRevealMode(String? mode) async {
    if (mode == null) return;
    setState(() => _triviaRevealMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trivia_reveal_mode', mode);
  }

  Future<void> _setCountdown(int? seconds) async {
    if (seconds == null) return;
    setState(() => _triviaCountdownS = seconds);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('trivia_countdown_s', seconds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trivia Settings'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ── Answer Reveal ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(
                    'Answer Reveal',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Choose how the trivia answer is revealed after the question plays.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                RadioGroup<String>(
                  groupValue: _triviaRevealMode,
                  onChanged: _setTriviaRevealMode,
                  child: const Column(
                    children: [
                      RadioListTile<String>(
                        title: Text('Auto (countdown)'),
                        subtitle: Text('Answer reveals after a countdown'),
                        value: 'auto',
                        activeColor: _teal,
                      ),
                      RadioListTile<String>(
                        title: Text('Manual (tap to reveal)'),
                        subtitle: Text('Tap a button to see the answer'),
                        value: 'manual',
                        activeColor: _teal,
                      ),
                      RadioListTile<String>(
                        title: Text('Instant (no pause)'),
                        subtitle: Text('Answer plays immediately'),
                        value: 'instant',
                        activeColor: _teal,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 32),

                // ── Countdown Duration ──
                AnimatedOpacity(
                  opacity: _triviaRevealMode == 'auto' ? 1.0 : 0.4,
                  duration: const Duration(milliseconds: 200),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Text(
                          'Countdown Duration',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          'How long to wait before revealing the answer. '
                          'Only applies when reveal mode is set to Auto.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: _triviaCountdownS,
                              isExpanded: true,
                              items: _countdownOptions
                                  .map((o) => DropdownMenuItem(
                                        value: o.$1,
                                        child: Text(o.$2),
                                      ))
                                  .toList(),
                              onChanged: _triviaRevealMode == 'auto'
                                  ? _setCountdown
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
