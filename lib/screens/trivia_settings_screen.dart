import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TriviaSettingsScreen extends StatefulWidget {
  const TriviaSettingsScreen({super.key});

  @override
  State<TriviaSettingsScreen> createState() => _TriviaSettingsScreenState();
}

class _TriviaSettingsScreenState extends State<TriviaSettingsScreen> {
  static const Color _teal = Color(0xFF0d9488);

  String _triviaRevealMode = 'auto';
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
      _loading = false;
    });
  }

  Future<void> _setTriviaRevealMode(String? mode) async {
    if (mode == null) return;
    setState(() => _triviaRevealMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trivia_reveal_mode', mode);
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
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
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
