import 'package:flutter/material.dart';
import 'tutorials_help_page.dart';
import 'community_support_page.dart';
import 'dashboard.dart';

import '../core/app_services.dart';
import 'edit_profile_page.dart';
import 'sign_in_page.dart';

class SettingsProfilePage extends StatefulWidget {
  const SettingsProfilePage({super.key});

  @override
  State<SettingsProfilePage> createState() => _SettingsProfilePageState();
}

class _SettingsProfilePageState extends State<SettingsProfilePage> {
  bool voiceAlertsEnabled = true;
  bool pestAlertsEnabled = true;
  bool harvestRemindersEnabled = false;

  // Profile Data
  String _name = 'John Doe';
  String _phone = '+1 234 567 8900';
  String _email = 'john.doe@example.com';
  String _farmName = 'Cotton Farm, Green Valley';
  String _variety = 'Hybrid Cotton';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFAFAFA),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const Dashboard()),
            (route) => false,
          ),
        ),
        title: const Text(
          'Settings & Profile',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Profile Card
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                   Container(
                     padding: const EdgeInsets.all(4),
                     decoration: BoxDecoration(
                       shape: BoxShape.circle,
                       border: Border.all(color: const Color(0xFF5FA62C), width: 2),
                     ),
                     child: CircleAvatar(
                      radius: 32,
                      backgroundColor: const Color(0xFFE9F7E5),
                      child: const Icon(
                        Icons.person,
                        size: 36,
                        color: Color(0xFF5FA62C),
                      ),
                                       ),
                   ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _farmName,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _email,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      final result = await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => EditProfilePage(
                            currentName: _name,
                            currentPhone: _phone,
                            currentEmail: _email,
                            currentFarmName: _farmName,
                            currentVariety: _variety,
                          ),
                        ),
                      );

                      if (result != null && result is Map<String, String>) {
                        setState(() {
                          _name = result['name']!;
                          _phone = result['phone']!;
                          _email = result['email']!;
                          _farmName = result['farmName']!;
                          _variety = result['variety']!;
                        });
                      }
                    },
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.edit_outlined, size: 20, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Settings Sections
            _buildSectionHeader('PREFERENCES'),
            _buildSettingsGroup([
              _buildSettingItem(
                icon: Icons.language_outlined,
                title: 'Language',
                trailing: const Text(
                  'English (US)',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () {},
              ),
              const Divider(height: 1, indent: 56),
              _buildToggleSettingItem(
                icon: Icons.volume_up_outlined,
                title: 'Voice Alerts',
                value: voiceAlertsEnabled,
                onChanged: (value) => setState(() => voiceAlertsEnabled = value),
              ),
            ]),
            
            const SizedBox(height: 24),
            _buildSectionHeader('NOTIFICATIONS'),
            _buildSettingsGroup([
              _buildToggleSettingItem(
                icon: Icons.bug_report_outlined,
                title: 'Pest Alerts',
                value: pestAlertsEnabled,
                onChanged: (value) => setState(() => pestAlertsEnabled = value),
              ),
              const Divider(height: 1, indent: 56),
              _buildToggleSettingItem(
                icon: Icons.event_available_outlined,
                title: 'Harvest Reminders',
                value: harvestRemindersEnabled,
                onChanged: (value) => setState(() => harvestRemindersEnabled = value),
              ),
            ]),

            const SizedBox(height: 24),
            _buildSectionHeader('DEVICES'),
            _buildSettingsGroup([
              _buildSettingItem(
                icon: Icons.bluetooth_audio_outlined,
                title: 'BollBot Sensor',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9F7E5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Connected',
                    style: TextStyle(
                      color: Color(0xFF5FA62C),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                onTap: () {},
              )
            ]),

            const SizedBox(height: 24),
            _buildSectionHeader('SUPPORT'),
            _buildSettingsGroup([
               _buildSettingItem(
                icon: Icons.menu_book_outlined,
                title: 'Tutorials',
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const TutorialsHelpPage())
                ),
              ),
              const Divider(height: 1, indent: 56),
              _buildSettingItem(
                icon: Icons.help_outline_rounded,
                title: 'Support Contact',
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => const CommunitySupportPage())
                ),
              ),
            ]),

            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _showLogoutDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFEBEE),
                  foregroundColor: const Color(0xFFD32F2F),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Log Out',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),

    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12,
          color: Colors.grey,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSettingsGroup(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildSettingItem({
    required IconData icon,
    required String title,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Icon(icon, color: Colors.black54, size: 22),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.black87,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggleSettingItem({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.black54, size: 22),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.black87,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF5FA62C),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          titleTextStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 20,
            color: Colors.black87,
          ),
          contentTextStyle: const TextStyle(
            fontSize: 16,
            color: Colors.black54,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Log Out'),
          content: const Text('Are you sure you want to log out of your account?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: () async {
                // Revoke the session on the backend (best effort), delete the stored tokens,
                // then return to sign-in.
                final navigator = Navigator.of(context);
                final session = AppScope.of(this.context).session;
                navigator.pop();
                await session.logout();
                navigator.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => const SignInPage()),
                  (route) => false,
                );
              },
              child: const Text(
                'Log Out',
                style: TextStyle(color: Color(0xFFD32F2F), fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }
}
