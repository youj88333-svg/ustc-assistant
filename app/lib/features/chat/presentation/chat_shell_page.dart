import 'package:flutter/material.dart';

class ChatShellPage extends StatelessWidget {
  const ChatShellPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: const Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.forum_outlined, size: 40),
                    SizedBox(height: 12),
                    Text(
                      '智能体尚未接入',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '首个本地版本暂不提供聊天与每日简报。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: TextField(
              enabled: false,
              decoration: InputDecoration(
                hintText: '等待智能体接入',
                suffixIcon: IconButton(
                  onPressed: null,
                  tooltip: '发送',
                  icon: const Icon(Icons.send),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
