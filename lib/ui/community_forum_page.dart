import 'package:flutter/material.dart';

class CommunityForumPage extends StatelessWidget {
  const CommunityForumPage({super.key});

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
          'Community Forum',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.black87),
            onPressed: () {},
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Create post feature coming soon!')),
          );
        },
        backgroundColor: const Color(0xFF5FA62C),
        icon: const Icon(Icons.edit, color: Colors.white),
        label: const Text('New Post', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildTopicCard(
            context,
            author: 'Rajesh Kumar',
            timeAgo: '2h ago',
            title: 'Best organic pesticide for Aphids?',
            preview: 'I have been seeing a lot of aphids on my cotton plants lately. Has anyone had success with neem oil mixtures?',
            likes: 12,
            comments: 5,
            tag: 'Pest Control',
            tagColor: Colors.red[100]!,
            tagTextColor: Colors.red[700]!,
          ),
          const SizedBox(height: 16),
          _buildTopicCard(
            context,
            author: 'Sarah Jenkins',
            timeAgo: '5h ago',
            title: 'Cotton market prices expected to rise',
            preview: 'According to the latest reports, demand for organic cotton is increasing in Europe. Good news for us!',
            likes: 45,
            comments: 18,
            tag: 'Market',
            tagColor: Colors.blue[100]!,
            tagTextColor: Colors.blue[700]!,
          ),
          const SizedBox(height: 16),
          _buildTopicCard(
            context,
            author: 'Amit Singh',
            timeAgo: '1d ago',
            title: 'Water management in dry season',
            preview: 'Sharing my drip irrigation setup that saved me 30% water this season. Photos included below.',
            likes: 89,
            comments: 32,
            tag: 'Farming Tips',
            tagColor: Colors.green[100]!,
            tagTextColor: Colors.green[700]!,
          ),
          const SizedBox(height: 16),
           _buildTopicCard(
            context,
            author: 'Priya Patel',
            timeAgo: '2d ago',
            title: 'Looking for BollBot sensor setup help',
            preview: 'Just bought the new sensor but having trouble pairing it. Any tips?',
            likes: 8,
            comments: 12,
            tag: 'Tech Support',
            tagColor: Colors.orange[100]!,
            tagTextColor: Colors.orange[700]!,
          ),
        ],
      ),
    );
  }

  Widget _buildTopicCard(
    BuildContext context, {
    required String author,
    required String timeAgo,
    required String title,
    required String preview,
    required int likes,
    required int comments,
    required String tag,
    required Color tagColor,
    required Color tagTextColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: Colors.grey[200],
                          child: Text(
                            author[0],
                            style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          author,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '• $timeAgo',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: tagColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          color: tagTextColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  preview,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                    height: 1.5,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildInteractionIcon(Icons.thumb_up_alt_outlined, likes.toString()),
                    const SizedBox(width: 24),
                    _buildInteractionIcon(Icons.chat_bubble_outline_rounded, comments.toString()),
                    const Spacer(),
                    const Icon(Icons.share_outlined, size: 20, color: Colors.grey),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInteractionIcon(IconData icon, String count) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey[600]),
        const SizedBox(width: 6),
        Text(
          count,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
