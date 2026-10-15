import 'package:flutter/material.dart';
import 'dashboard.dart';
import 'Harvest.dart';
import 'pest_alerts_page.dart';
import 'notifications_page.dart';
import 'widgets/bottom_nav_bar.dart';
import 'settings_profile_page.dart';


class TutorialsHelpPage extends StatefulWidget {
  const TutorialsHelpPage({super.key});

  @override
  State<TutorialsHelpPage> createState() => _TutorialsHelpPageState();
}

class _TutorialsHelpPageState extends State<TutorialsHelpPage> {
  bool gettingStartedExpanded = true;
  bool monitoringExpanded = false;
  bool pestsExpanded = false;
  bool harvestExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFAFAFA),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Tutorials & Help',
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
            // Guides & Support Header
            const Text(
              'Guides & Support',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Find step-by-step instructions and video tutorials to master BollBot.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 24),
            
            // Getting Started with BollBot Section
            _buildTutorialSection(
              icon: Icons.eco_outlined,
              title: 'Getting Started with BollBot',
              description: 'Essentials of setup and app navigation.',
              isExpanded: gettingStartedExpanded,
              onToggle: () => setState(() => gettingStartedExpanded = !gettingStartedExpanded),
              expandedContent: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  _buildStepText(
                    '1. Welcome to BollBot!', 
                    'Start by ensuring your location services are enabled. This allows us to provide hyper-local weather and soil data crucial for your cotton crop.'
                  ),
                  const SizedBox(height: 12),
                  _buildStepText(
                    '2. Profile Setup', 
                    'Go to Settings > Edit Profile to add your Farm Name and Cotton Variety. This helps our AI tailor recommendations specifically for your yield goals.'
                  ),
                  const SizedBox(height: 16),
                  _buildVideoPlaceholder('Dashboard Overview'),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Monitoring Cotton Health Section
            _buildTutorialSection(
              icon: Icons.show_chart_rounded,
              title: 'Monitoring Cotton Health',
              description: 'Track boll count, moisture, and growth.',
              isExpanded: monitoringExpanded,
              onToggle: () => setState(() => monitoringExpanded = !monitoringExpanded),
              expandedContent: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  _buildStepText(
                    'Understanding Metrics', 
                    'The Dashboard shows real-time data from your connected sensors. "Moisture Level" indicates soil hydration, while "Boll Count" is estimated via our visual AI.'
                  ),
                  const SizedBox(height: 12),
                  _buildInfoBox(
                    Icons.water_drop_outlined, 
                    'Keep moisture levels between 40-60% for optimal vegetative growth during the early stages.'
                  ),
                  const SizedBox(height: 12),
                   _buildStepText(
                    'Analyzing Graphs', 
                    'Tap on the graphs in the Harvest Logs page to see historical trends. Sudden drops in growth rate often indicate pest stress or nutrient deficiency.'
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Identifying Pests & Diseases Section
            _buildTutorialSection(
              icon: Icons.bug_report_outlined,
              title: 'Identifying Pests & Diseases',
              description: 'AI detection and treatment plans.',
              isExpanded: pestsExpanded,
              onToggle: () => setState(() => pestsExpanded = !pestsExpanded),
              expandedContent: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  _buildStepText(
                    'Using the Scanner', 
                    'Navigate to the "Pests" tab and tap "Scan Now". Point your camera at a leaf or boll. Ensure good lighting for the most accurate diagnosis.'
                  ),
                  const SizedBox(height: 12),
                  _buildStepText(
                    'Interpreting Results', 
                    'The AI will identify pests like Aphids or Bollworms with a confidence score. If a pest is found, you will receive immediate chemical and organic treatment options.'
                  ),
                  const SizedBox(height: 16),
                  _buildVideoPlaceholder('Pest Detection Demo'),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Logging Your Harvest Section
            _buildTutorialSection(
              icon: Icons.inventory_2_outlined,
              title: 'Logging Your Harvest',
              description: 'Record yields and export reports.',
              isExpanded: harvestExpanded,
              onToggle: () => setState(() => harvestExpanded = !harvestExpanded),
              expandedContent: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                   _buildStepText(
                    'Digital Logbook', 
                    'In the "Logs" tab, you can manually add entries for each harvest batch. Record the weight (bales), quality status, and date.'
                  ),
                  const SizedBox(height: 12),
                   _buildStepText(
                    'Exporting Data', 
                    'Need to share data with buyers or insurers? Use the "Export" button in Harvest Logs to download a neatly formatted Excel sheet of your season\'s performance.'
                  ),
                  const SizedBox(height: 12),
                  _buildInfoBox(
                    Icons.storefront_outlined, 
                    'Verified harvest logs increase your credibility when selling on the Marketplace.'
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildStepText(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          content,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.black54,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoBox(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F7E5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF5FA62C).withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF5FA62C)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF2E5E1B),
                fontWeight: FontWeight.w500,
                height: 1.4
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildVideoPlaceholder(String label) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
        image: const DecorationImage(
           image: AssetImage('assets/MLPhoto.png'), // Reusing an asset as functional placeholder
           fit: BoxFit.cover,
           opacity: 0.2,
        )
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: const Color(0xFF5FA62C),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Watch: $label',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTutorialSection({
    required IconData icon,
    required String title,
    required String description,
    required bool isExpanded,
    required VoidCallback onToggle,
    Widget? expandedContent,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isExpanded ? const Color(0xFF5FA62C).withOpacity(0.5) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isExpanded ? const Color(0xFF5FA62C) : const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        icon,
                        color: isExpanded ? Colors.white : Colors.black54,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      color: Colors.grey,
                      size: 24,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isExpanded && expandedContent != null)
            Padding(
               padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
               child: Column(
                 children: [
                   const Divider(height: 1),
                   expandedContent,
                 ]
               ),
            ),
        ],
      ),
    );
  }
}
