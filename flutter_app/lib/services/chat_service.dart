import 'dart:convert';

import 'package:http/http.dart' as http;

class ChatService {
  // TODO: Replace this with your deployed Cloudflare Worker URL.
  static const String baseUrl = 'https://YOUR-WORKER.workers.dev';

  Future<ChatResponse> sendMessage({
    required String message,
    required String userId,
    required String userName,
    String? conversationId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/chat'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        'userId': userId,
        'userName': userName,
        if (conversationId != null) 'conversationId': conversationId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Chat API failed (${response.statusCode}): ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return ChatResponse.fromJson(data);
  }
}

class ChatResponse {
  final bool success;
  final String conversationId;
  final String reply;

  ChatResponse({
    required this.success,
    required this.conversationId,
    required this.reply,
  });

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    return ChatResponse(
      success: json['success'] == true,
      conversationId: json['conversationId'] as String? ?? '',
      reply: json['reply'] as String? ?? '',
    );
  }
}
