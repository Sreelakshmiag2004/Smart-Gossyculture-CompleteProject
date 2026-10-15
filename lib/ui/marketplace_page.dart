import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dashboard.dart';
import 'Harvest.dart';
import 'pest_alerts_page.dart';
import 'notifications_page.dart';

import 'settings_profile_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MarketplacePage extends StatefulWidget {
  const MarketplacePage({super.key});

  @override
  State<MarketplacePage> createState() => _MarketplacePageState();
}

class _MarketplacePageState extends State<MarketplacePage> {
  final TextEditingController cottonBollsController =
      TextEditingController(text: '1200');
  final TextEditingController cottonLintController =
      TextEditingController(text: '50');
  final TextEditingController cottonSeedsController =
      TextEditingController(text: '300');

  @override
  void initState() {
    super.initState();
    _loadStockData();
  }

  Future<void> _loadStockData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      cottonBollsController.text = prefs.getString('stock_bolls') ?? '1200';
      cottonLintController.text = prefs.getString('stock_lint') ?? '50';
      cottonSeedsController.text = prefs.getString('stock_seeds') ?? '300';
    });
  }

  Future<void> _saveStockData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('stock_bolls', cottonBollsController.text);
    await prefs.setString('stock_lint', cottonLintController.text);
    await prefs.setString('stock_seeds', cottonSeedsController.text);
  }

  @override
  void dispose() {
    cottonBollsController.dispose();
    cottonLintController.dispose();
    cottonSeedsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA), // Matching Dashboard
      appBar: AppBar(
        backgroundColor: const Color(0xFFFAFAFA),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Marketplace',
           style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 20.0,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Inventory Management Section
            _buildSectionCard(
              title: 'Inventory Management',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStockInput('Cotton Bolls', cottonBollsController, 'kg'),
                  const SizedBox(height: 16),
                  _buildStockInput(
                      'Cotton Lint', cottonLintController, 'bales'),
                  const SizedBox(height: 16),
                  _buildStockInput('Cotton Seeds', cottonSeedsController, 'kg'),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () async {
                        await _saveStockData();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Stock levels updated and saved!'),
                              behavior: SnackBarBehavior.floating,
                              backgroundColor: Color(0xFF5FA62C),
                            ),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5FA62C),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Update Stock Levels',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Future Stock Outlook Section
            _buildSectionCard(
              title: 'Future Stock Outlook',
              child: Container(
                height: 220,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: StockGraphPainter(),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Available Buyers Section
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Available Buyers',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: Colors.black87,
                ),
              ),
            ),
            
            ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildBuyerCard(
                  companyName: 'AgriCorp Global',
                  description:
                      'Seeking 1000 bales of premium long-staple cotton monthly.',
                  contactIcon: Icons.chat_bubble_outline,
                  contactText: 'Platform Chat',
                  tag: 'Premium Buyer',
                ),
                _buildBuyerCard(
                  companyName: 'Textile Innovations',
                  description:
                      'Requires 500kg of organic cotton for sustainable fabrics.',
                  contactIcon: Icons.email_outlined,
                  contactText: 'contact@textileinnov.com',
                  tag: 'Organic',
                ),
                _buildBuyerCard(
                  companyName: 'Local Ginning Co.',
                  description:
                      'Purchasing raw cotton bolls weekly. Flexible volumes.',
                  contactIcon: Icons.phone_outlined,
                  contactText: '+1 (555) 123-4567',
                  tag: 'Local',
                ),
                 _buildBuyerCard(
                  companyName: 'Eco-Wear Apparel',
                  description:
                      'Looking for ethical and traceable cotton sources.',
                  contactIcon: Icons.chat_bubble_outline,
                  contactText: 'Platform Chat',
                  tag: 'Ethical',
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),

    );
  }

  Widget _buildSectionCard({
    required String title,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  Widget _buildStockInput(
      String label, TextEditingController controller, String unit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                   color: const Color(0xFFF5F5F5),
                   borderRadius: BorderRadius.circular(12),
                   border: Border.all(color: Colors.transparent),
                ),
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              unit,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBuyerCard({
    required String companyName,
    required String description,
    required IconData contactIcon,
    required String contactText,
    required String tag,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
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
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                companyName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.black87,
                ),
              ),
              Container(
                 padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                 decoration: BoxDecoration(
                   color: const Color(0xFFE9F7E5),
                   borderRadius: BorderRadius.circular(8),
                 ),
                 child: Text(
                   tag,
                   style: const TextStyle(
                     color: Color(0xFF5FA62C),
                     fontSize: 12,
                     fontWeight: FontWeight.bold
                   ),
                 ),
              )
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.black54,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      contactIcon,
                      color: Colors.grey[600],
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      contactText,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Connecting with $companyName...')),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF5FA62C),
                  elevation: 0,
                  side: const BorderSide(color: Color(0xFF5FA62C)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                child: const Text('Connect'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class StockGraphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final pointPaint = Paint()
      ..color = const Color(0xFF5FA62C)
      ..style = PaintingStyle.fill;
    
    final linePaint1 = Paint()
      ..color = const Color(0xFF5FA62C)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final linePaint2 = Paint()
       ..color = const Color(0xFF4A90E2)
       ..strokeWidth = 2.5
       ..style = PaintingStyle.stroke;

    // Draw axes
    final leftMargin = 40.0;
    final bottomMargin = 30.0;
    final rightMargin = 10.0;
    final topMargin = 10.0;

    // Y-axis
    canvas.drawLine(
      Offset(leftMargin, topMargin),
      Offset(leftMargin, size.height - bottomMargin),
      Paint()
        ..color = Colors.grey[300]!
        ..strokeWidth = 1,
    );

    // X-axis
    canvas.drawLine(
      Offset(leftMargin, size.height - bottomMargin),
      Offset(size.width - rightMargin, size.height - bottomMargin),
      Paint()
        ..color = Colors.grey[300]!
        ..strokeWidth = 1,
    );

    // Y-axis labels
    final yLabels = [
      '0',
      '80',
      '160',
      '240',
      '320'
    ];
    for (int i = 0; i < yLabels.length; i++) {
      final y = size.height -
          bottomMargin -
          (i * (size.height - bottomMargin - topMargin) / 4);
      final textPainter = TextPainter(
        text: TextSpan(
          text: yLabels[i],
          style: TextStyle(fontSize: 10, color: Colors.grey[500]),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(5, y - textPainter.height / 2));
    }

    // X-axis labels
    final xLabels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];
    for (int i = 0; i < xLabels.length; i++) {
      final x = leftMargin + (i * (size.width - leftMargin - rightMargin) / 5);
      final textPainter = TextPainter(
        text: TextSpan(
          text: xLabels[i],
          style: TextStyle(fontSize: 10, color: Colors.grey[500]),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas,
          Offset(x - textPainter.width / 2, size.height - bottomMargin + 6));
    }

    // Draw data points and lines
    final dataPoints = [
      {'x': 0, 'y': 160}, // Jan
      {'x': 1, 'y': 180}, // Feb
      {'x': 2, 'y': 200}, // Mar
      {'x': 3, 'y': 240}, // Apr
      {'x': 4, 'y': 280}, // May
      {'x': 5, 'y': 300}, // Jun
    ];

    final dataPoints2 = [
      {'x': 0, 'y': 160}, // Jan
      {'x': 1, 'y': 170}, // Feb
      {'x': 2, 'y': 190}, // Mar
      {'x': 3, 'y': 220}, // Apr
      {'x': 4, 'y': 240}, // May
      {'x': 5, 'y': 260}, // Jun
    ];

    // Draw first line
    _drawDataLine(canvas, dataPoints, size, leftMargin, bottomMargin, topMargin,
        rightMargin, linePaint1, pointPaint);

    // Draw second line
    _drawDataLine(canvas, dataPoints2, size, leftMargin, bottomMargin,
        topMargin, rightMargin, linePaint2, pointPaint);
  }

  void _drawDataLine(
      Canvas canvas,
      List<Map<String, int>> dataPoints,
      Size size,
      double leftMargin,
      double bottomMargin,
      double topMargin,
      double rightMargin,
      Paint paint,
      Paint pointPaint) {
    final path = Path();
    bool firstPoint = true;

    for (int i = 0; i < dataPoints.length; i++) {
      final point = dataPoints[i];
      final x = leftMargin +
          (point['x']! * (size.width - leftMargin - rightMargin) / 5);
      // Normalized Y
      final y = size.height -
          bottomMargin -
          ((point['y']! / 320.0) * (size.height - bottomMargin - topMargin));

      if (firstPoint) {
        path.moveTo(x, y);
        firstPoint = false;
      } else {
        path.lineTo(x, y);
      }
      
      canvas.drawCircle(Offset(x, y), 3.5, pointPaint);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
