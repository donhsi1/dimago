import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException, UserAttributes;

import 'language_prefs.dart';
import 'supabase_bootstrap.dart';

class SetNewPasswordPage extends StatefulWidget {
  final VoidCallback? onDone;
  const SetNewPasswordPage({super.key, this.onDone});

  @override
  State<SetNewPasswordPage> createState() => _SetNewPasswordPageState();
}

class _SetNewPasswordPageState extends State<SetNewPasswordPage> {
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _saving = false;
  bool _obscure = true;

  L10n get _l => L10n(AppLangNotifier().uiLang);

  @override
  void dispose() {
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final p1 = _pw1.text;
    final p2 = _pw2.text;
    if (p1.isEmpty || p2.isEmpty) return;
    if (p1 != p2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? 'Passwords do not match.' : '两次输入的密码不一致。')),
      );
      return;
    }
    if (p1.length < 6) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? 'Password must be at least 6 characters.' : '密码至少需要 6 个字符。')),
      );
      return;
    }

    final client = SupabaseBootstrap.clientOrNull;
    if (client == null) return;

    setState(() => _saving = true);
    try {
      await client.auth.updateUser(
        UserAttributes(password: p1),
      );

      // Security posture: end the recovery session; user signs in with new password.
      try {
        await client.auth.signOut();
      } catch (_) {}

      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_l.isEn ? 'Password updated. Please sign in again.' : '密码已更新，请重新登录。'),
          duration: const Duration(seconds: 4),
        ),
      );
      widget.onDone?.call();
      if (Navigator.canPop(context)) Navigator.pop(context);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? e.message : '设置失败：${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l.isEn ? 'Update failed: $e' : '设置失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        title: Text(
          l.isEn ? 'Set new password' : (l.isZhTW ? '設定新密碼' : '设置新密码'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              l.isEn
                  ? 'Enter a new password for your account.'
                  : (l.isZhTW ? '請為你的帳戶設定新密碼。' : '请为你的账号设置新密码。'),
              style: TextStyle(color: Colors.grey.shade700, height: 1.3),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pw1,
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l.isEn ? 'New password' : (l.isZhTW ? '新密碼' : '新密码'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pw2,
              obscureText: _obscure,
              onSubmitted: (_) => _saving ? null : _submit(),
              decoration: InputDecoration(
                labelText: l.isEn ? 'Confirm password' : (l.isZhTW ? '確認密碼' : '确认密码'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l.isEn ? 'Update password' : (l.isZhTW ? '更新密碼' : '更新密码')),
            ),
          ],
        ),
      ),
    );
  }
}

