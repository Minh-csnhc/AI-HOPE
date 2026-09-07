import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const AIHopeApp());
}

// ============================================================
// APP
// ============================================================

class AIHopeApp extends StatelessWidget {
  const AIHopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI-HOPE',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFFFBF5),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFBF5),
          foregroundColor: Color(0xFF292929),
          elevation: 0,
        ),
      ),
      home: const ChatPage(),
    );
  }
}

// ============================================================
// CHAT MESSAGE
// ============================================================

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime? createdAt;
  final List<String> suggestions;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.createdAt,
    this.suggestions = const [],
  });
}

// ============================================================
// RECENT CHAT
// ============================================================

class RecentChat {
  final String conversationId;
  final String title;
  final DateTime updatedAt;

  RecentChat({
    required this.conversationId,
    required this.title,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'conversationId': conversationId,
      'title': title,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory RecentChat.fromJson(Map<String, dynamic> json) {
    return RecentChat(
      conversationId: json['conversationId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'New chat',
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

// ============================================================
// CHAT PAGE
// ============================================================

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // ----------------------------------------------------------
  // CONTROLLERS
  // ----------------------------------------------------------

  final TextEditingController _controller = TextEditingController();

  final ScrollController _scrollController = ScrollController();

  // ----------------------------------------------------------
  // MESSAGES
  // ----------------------------------------------------------

  final List<ChatMessage> _messages = [];

  // ----------------------------------------------------------
  // CLOUDFLARE
  // ----------------------------------------------------------

  static const String workerBaseUrl =
      'https://cloudflare-worker.ducminhnhc2010.workers.dev';

  static const String chatApiUrl = '$workerBaseUrl/api/chat';

  static const String historyApiUrl = '$workerBaseUrl/api/chat/history';

  static const String conversationsApiUrl = '$workerBaseUrl/api/conversations';

  // ----------------------------------------------------------
  // SHARED PREFERENCES
  // ----------------------------------------------------------

  static const String _userIdKey = 'ai_hope_user_id';

  static const String _conversationIdKey = 'ai_hope_conversation_id';

  static const String _recentChatsKey = 'ai_hope_recent_chats';

  // ----------------------------------------------------------
  // STATE
  // ----------------------------------------------------------

  String? userId;
  String? conversationId;

  String userName = 'AI-HOPE User';

  bool isInitializing = true;
  bool isLoading = false;
  bool isLoadingHistory = false;
  bool isSidebarOpen = false;

  List<RecentChat> _recentChats = [];

  // ==========================================================
  // INITIALIZATION
  // ==========================================================

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadSavedData();

    // Server/D1 is the source of truth for Recents.
    // This also removes old conversations that only existed
    // in the local SharedPreferences cache.
    await _loadRecentChatsFromServer();

    if (!mounted) {
      return;
    }

    setState(() {
      isInitializing = false;
    });

    // Only restore the current conversation if it still exists
    // on the server. Otherwise clear the stale local ID.
    if (conversationId != null &&
        conversationId!.isNotEmpty &&
        _recentChats.any(
          (chat) => chat.conversationId == conversationId,
        )) {
      await _loadConversationHistory(conversationId!);
    } else if (conversationId != null && conversationId!.isNotEmpty) {
      conversationId = null;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_conversationIdKey);
      } catch (error) {
        debugPrint('Failed to clear stale conversation ID: $error');
      }
    }
  }

  // ==========================================================
  // LOAD SAVED DATA
  // ==========================================================

  Future<void> _loadSavedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // --------------------------------------------------------
      // USER ID
      // --------------------------------------------------------

      userId = prefs.getString(_userIdKey);

      if (userId == null || userId!.trim().isEmpty) {
        userId = 'ai-hope-${DateTime.now().millisecondsSinceEpoch}';

        await prefs.setString(_userIdKey, userId!);
      }

      // --------------------------------------------------------
      // CURRENT CONVERSATION
      // --------------------------------------------------------

      conversationId = prefs.getString(_conversationIdKey);

      // --------------------------------------------------------
      // RECENT CHATS
      // --------------------------------------------------------

      final recentJson = prefs.getString(_recentChatsKey);

      if (recentJson != null && recentJson.isNotEmpty) {
        final decoded = jsonDecode(recentJson);

        if (decoded is List) {
          _recentChats = decoded
              .whereType<Map>()
              .map(
                (item) => RecentChat.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((chat) => chat.conversationId.isNotEmpty)
              .toList();

          _recentChats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      }

      debugPrint('AI-HOPE user ID: $userId');
      debugPrint('AI-HOPE conversation ID: $conversationId');
      debugPrint('AI-HOPE recent chats: ${_recentChats.length}');
    } catch (error) {
      debugPrint('Failed to load saved data: $error');

      userId = 'ai-hope-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  // ==========================================================
  // LOAD RECENT CHATS FROM SERVER
  // ==========================================================

  Future<void> _loadRecentChatsFromServer() async {
    if (userId == null || userId!.trim().isEmpty) {
      return;
    }

    try {
      final uri = Uri.parse(conversationsApiUrl).replace(
        queryParameters: {'userId': userId!},
      );

      debugPrint('Loading recent chats: $uri');

      final response = await http.get(uri);

      debugPrint('Recent chats response: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'Recent chats request failed: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        throw Exception('Recent chats API returned success=false');
      }

      final rawConversations = data['conversations'];

      final List<RecentChat> serverChats = [];

      if (rawConversations is List) {
        for (final raw in rawConversations) {
          if (raw is! Map) {
            continue;
          }

          final item = Map<String, dynamic>.from(raw);

          final id = item['id']?.toString().trim() ?? '';
          final title = item['title']?.toString().trim() ?? 'New chat';
          final updatedAtString = item['updated_at']?.toString() ??
              item['updatedAt']?.toString() ??
              '';

          if (id.isEmpty) {
            continue;
          }

          serverChats.add(
            RecentChat(
              conversationId: id,
              title: title.isEmpty ? 'New chat' : title,
              updatedAt:
                  DateTime.tryParse(updatedAtString) ?? DateTime.now(),
            ),
          );
        }
      }

      serverChats.sort(
        (a, b) => b.updatedAt.compareTo(a.updatedAt),
      );

      _recentChats = serverChats.take(50).toList();

      // Server is authoritative, so replace the old local cache.
      await _saveRecentChats();

      if (mounted) {
        setState(() {});
      }

      debugPrint(
        'Loaded ${_recentChats.length} recent chats from server.',
      );
    } catch (error) {
      // If the server is temporarily unavailable, keep the local
      // cache instead of breaking the app.
      debugPrint('Failed to load recent chats from server: $error');
    }
  }

  // ==========================================================
  // SAVE CURRENT CONVERSATION
  // ==========================================================

  Future<void> _saveConversationId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(_conversationIdKey, id);
    } catch (error) {
      debugPrint('Failed to save conversation ID: $error');
    }
  }

  // ==========================================================
  // SAVE RECENT CHATS
  // ==========================================================

  Future<void> _saveRecentChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final encoded = jsonEncode(
        _recentChats.map((chat) => chat.toJson()).toList(),
      );

      await prefs.setString(_recentChatsKey, encoded);
    } catch (error) {
      debugPrint('Failed to save recent chats: $error');
    }
  }

  // ==========================================================
  // ADD / UPDATE RECENT CHAT
  // ==========================================================

  Future<void> _updateRecentChat({
    required String conversationId,
    required String title,
  }) async {
    final cleanTitle = title.trim().isEmpty ? 'New chat' : title.trim();

    final existingIndex = _recentChats.indexWhere(
      (chat) => chat.conversationId == conversationId,
    );

    final updatedChat = RecentChat(
      conversationId: conversationId,
      title: cleanTitle,
      updatedAt: DateTime.now(),
    );

    if (existingIndex >= 0) {
      _recentChats[existingIndex] = updatedChat;
    } else {
      _recentChats.insert(0, updatedChat);
    }

    _recentChats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    // Keep the sidebar clean.
    if (_recentChats.length > 50) {
      _recentChats = _recentChats.take(50).toList();
    }

    await _saveRecentChats();

    if (mounted) {
      setState(() {});
    }
  }

  // ==========================================================
  // LOAD CONVERSATION HISTORY
  // ==========================================================

  Future<void> _loadConversationHistory(String targetConversationId) async {
    if (userId == null || targetConversationId.trim().isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        isLoadingHistory = true;
      });
    }

    try {
      final uri = Uri.parse(historyApiUrl).replace(
        queryParameters: {
          'userId': userId!,
          'conversationId': targetConversationId,
        },
      );

      debugPrint('Loading history: $uri');

      final response = await http.get(uri);

      debugPrint('History response: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception('History request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        throw Exception('History API returned success=false');
      }

      final rawMessages = data['messages'];

      final List<ChatMessage> loadedMessages = [];

      if (rawMessages is List) {
        for (final raw in rawMessages) {
          if (raw is! Map) {
            continue;
          }

          final message = Map<String, dynamic>.from(raw);

          final payload = message['payload'];

          if (payload is! Map) {
            continue;
          }

          final type = payload['type']?.toString();

          final text = payload['text']?.toString();

          if (type != 'text' || text == null || text.trim().isEmpty) {
            continue;
          }

          final messageUserId = message['userId']?.toString();

          final createdAtString = message['createdAt']?.toString();

          final createdAt = createdAtString == null
              ? null
              : DateTime.tryParse(createdAtString);

          loadedMessages.add(
            ChatMessage(
              text: text,
              isUser: messageUserId == userId,
              createdAt: createdAt,
            ),
          );
        }
      }

      // --------------------------------------------------------
      // Sort oldest -> newest
      // --------------------------------------------------------

      loadedMessages.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) {
          return 0;
        }

        if (a.createdAt == null) {
          return -1;
        }

        if (b.createdAt == null) {
          return 1;
        }

        return a.createdAt!.compareTo(b.createdAt!);
      });

      if (!mounted) {
        return;
      }

      setState(() {
        conversationId = targetConversationId;

        _messages
          ..clear()
          ..addAll(loadedMessages);
      });

      await _saveConversationId(targetConversationId);

      debugPrint('Loaded ${loadedMessages.length} messages.');

      _scrollToBottom();
    } catch (error) {
      debugPrint('Failed to load conversation history: $error');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không thể tải lịch sử cuộc trò chuyện.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoadingHistory = false;
        });
      }
    }
  }

  // ==========================================================
  // SEND MESSAGE
  // ==========================================================

  Future<void> sendMessage() async {
    if (isInitializing || isLoading || isLoadingHistory) {
      return;
    }

    final text = _controller.text.trim();

    if (text.isEmpty) {
      return;
    }

    final currentUserId = userId;

    if (currentUserId == null) {
      return;
    }

    _controller.clear();

    final isFirstMessage = _messages.isEmpty;

    setState(() {
      _messages.add(
        ChatMessage(text: text, isUser: true, createdAt: DateTime.now()),
      );

      isLoading = true;
    });

    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse(chatApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': currentUserId,
          'userName': userName,
          'message': text,
          if (conversationId != null) 'conversationId': conversationId,
        }),
      );

      debugPrint('Cloudflare response: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        throw Exception('Chat API returned success=false');
      }

      // --------------------------------------------------------
      // SAVE CONVERSATION ID
      // --------------------------------------------------------

      final returnedConversationId = data['conversationId']?.toString();

      if (returnedConversationId != null && returnedConversationId.isNotEmpty) {
        conversationId = returnedConversationId;

        await _saveConversationId(returnedConversationId);
      }

      // --------------------------------------------------------
      // SAVE RECENT CHAT
      // --------------------------------------------------------

      if (conversationId != null) {
        String title = text;

        // First message becomes chat title.
        if (isFirstMessage) {
          title = text;
        } else {
          final existing = _recentChats.where(
            (chat) => chat.conversationId == conversationId,
          );

          if (existing.isNotEmpty) {
            title = existing.first.title;
          }
        }

        await _updateRecentChat(conversationId: conversationId!, title: title);
      }

      // --------------------------------------------------------
      // AI REPLY + SUGGESTIONS
      // --------------------------------------------------------

      final reply = data['reply']?.toString();
      final rawSuggestions = data['suggestions'];

      final List<String> suggestions = rawSuggestions is List
          ? rawSuggestions
                .map((item) => item.toString().trim())
                .where((item) => item.isNotEmpty)
                .take(4)
                .toList()
          : <String>[];

      debugPrint('AI-HOPE suggestions: $suggestions');

      if (reply != null && reply.trim().isNotEmpty) {
        if (mounted) {
          setState(() {
            _messages.add(
              ChatMessage(
                text: reply,
                isUser: false,
                createdAt: DateTime.now(),
                suggestions: suggestions,
              ),
            );
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _messages.add(
              ChatMessage(
                text: 'Xin lỗi, mình chưa nhận được câu trả lời 😥',
                isUser: false,
                createdAt: DateTime.now(),
                suggestions: const [],
              ),
            );
          });
        }
      }
    } catch (error) {
      debugPrint('AI-HOPE chat error: $error');

      if (mounted) {
        setState(() {
          _messages.add(
            ChatMessage(
              text: 'Không thể kết nối với AI-HOPE 😥',
              isUser: false,
              createdAt: DateTime.now(),
            ),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }

      _scrollToBottom();
    }
  }

  // ==========================================================
  // RENAME CONVERSATION
  // ==========================================================

  Future<void> _renameConversation(RecentChat chat) async {
    if (isLoading || isLoadingHistory || userId == null) {
      return;
    }

    final controller = TextEditingController(text: chat.title);

    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(hintText: 'Tên cuộc trò chuyện'),
            onSubmitted: (value) {
              final title = value.trim();
              if (title.isNotEmpty) {
                Navigator.of(dialogContext).pop(title);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final title = controller.text.trim();
                if (title.isNotEmpty) {
                  Navigator.of(dialogContext).pop(title);
                }
              },
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (newTitle == null || newTitle.trim().isEmpty) {
      return;
    }

    final title = newTitle.trim();

    try {
      final response = await http.patch(
        Uri.parse(
          '$conversationsApiUrl/${Uri.encodeComponent(chat.conversationId)}',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': userId, 'title': title}),
      );

      debugPrint('Rename response: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception('Rename failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        throw Exception('Rename API returned success=false');
      }

      final index = _recentChats.indexWhere(
        (item) => item.conversationId == chat.conversationId,
      );

      if (index >= 0) {
        final oldChat = _recentChats[index];

        setState(() {
          _recentChats[index] = RecentChat(
            conversationId: oldChat.conversationId,
            title: title,
            updatedAt: oldChat.updatedAt,
          );
        });

        await _saveRecentChats();
      }
    } catch (error) {
      debugPrint('Failed to rename conversation: $error');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể đổi tên cuộc trò chuyện.')),
        );
      }
    }
  }

  // ==========================================================
  // DELETE CONVERSATION
  // ==========================================================

  Future<void> _deleteConversation(RecentChat chat) async {
    if (isLoading || isLoadingHistory || userId == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            'Bạn có chắc muốn xóa "${chat.title}" không?\n\n'
            'Tin nhắn trong cuộc trò chuyện này cũng sẽ bị xóa.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD94B4B),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      final uri = Uri.parse(
        '$conversationsApiUrl/${Uri.encodeComponent(chat.conversationId)}',
      ).replace(queryParameters: {'userId': userId!});

      final response = await http.delete(uri);

      debugPrint('Delete response: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception('Delete failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        throw Exception('Delete API returned success=false');
      }

      final wasCurrent = conversationId == chat.conversationId;

      setState(() {
        _recentChats.removeWhere(
          (item) => item.conversationId == chat.conversationId,
        );

        if (wasCurrent) {
          conversationId = null;
          _messages.clear();
        }
      });

      await _saveRecentChats();

      if (wasCurrent) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_conversationIdKey);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã xóa cuộc trò chuyện.')),
        );
      }
    } catch (error) {
      debugPrint('Failed to delete conversation: $error');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể xóa cuộc trò chuyện.')),
        );
      }
    }
  }

  // ==========================================================
  // NEW CHAT
  // ==========================================================

  Future<void> _startNewConversation() async {
    if (isLoading) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.remove(_conversationIdKey);

      if (!mounted) {
        return;
      }

      setState(() {
        conversationId = null;
        _messages.clear();
        isSidebarOpen = false;
      });

      debugPrint('Started new AI-HOPE conversation');
    } catch (error) {
      debugPrint('Failed to start new conversation: $error');
    }
  }

  // ==========================================================
  // OPEN SIDEBAR
  // ==========================================================

  void _openSidebar() {
    if (!mounted) {
      return;
    }

    setState(() {
      isSidebarOpen = true;
    });
  }

  // ==========================================================
  // CLOSE SIDEBAR
  // ==========================================================

  void _closeSidebar() {
    if (!mounted) {
      return;
    }

    setState(() {
      isSidebarOpen = false;
    });
  }

  // ==========================================================
  // OPEN RECENT CHAT
  // ==========================================================

  Future<void> _openRecentChat(RecentChat chat) async {
    if (isLoading || isLoadingHistory) {
      return;
    }

    _closeSidebar();

    await _loadConversationHistory(chat.conversationId);
  }

  // ==========================================================
  // SCROLL
  // ==========================================================

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  // ==========================================================
  // MARKDOWN + LATEX
  // ==========================================================

  Widget _buildMarkdownMessage(ChatMessage message) {
    return MarkdownBody(
      data: message.text,

      // --------------------------------------------------------
      // LATEX
      // --------------------------------------------------------
      builders: {'latex': LatexElementBuilder()},

      extensionSet: md.ExtensionSet(
        [LatexBlockSyntax()],
        [LatexInlineSyntax()],
      ),

      // --------------------------------------------------------
      // MARKDOWN STYLE
      // --------------------------------------------------------
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(fontSize: 16, color: Color(0xFF292929), height: 1.5),

        strong: const TextStyle(
          fontSize: 16,
          color: Color(0xFF292929),
          fontWeight: FontWeight.bold,
        ),

        em: const TextStyle(
          fontSize: 16,
          color: Color(0xFF292929),
          fontStyle: FontStyle.italic,
        ),

        code: const TextStyle(
          fontSize: 14,
          color: Color(0xFF292929),
          fontFamily: 'monospace',
        ),

        listBullet: const TextStyle(fontSize: 16, color: Color(0xFF292929)),

        h1: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Color(0xFF292929),
        ),

        h2: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.bold,
          color: Color(0xFF292929),
        ),

        h3: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.bold,
          color: Color(0xFF292929),
        ),

        blockquote: const TextStyle(
          fontSize: 16,
          color: Color(0xFF555555),
          height: 1.5,
        ),

        a: const TextStyle(
          color: Color(0xFF6C63FF),
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  // ==========================================================
  // SUGGESTION BUTTONS
  // ==========================================================

  Widget _buildSuggestions(ChatMessage message) {
    if (message.suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: message.suggestions.map((suggestion) {
          return OutlinedButton(
            onPressed: isLoading ? null : () => _sendSuggestion(suggestion),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF6C63FF),
              side: const BorderSide(color: Color(0xFFD8D2FF)),
              backgroundColor: const Color(0xFFF8F6FF),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              minimumSize: const Size(0, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              suggestion,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _sendSuggestion(String suggestion) {
    if (isLoading || isInitializing || isLoadingHistory) {
      return;
    }

    _controller.text = suggestion;
    sendMessage();
  }

  // ==========================================================
  // MESSAGE BUBBLE
  // ==========================================================

  Widget _buildMessage(ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: message.isUser
              ? const Color(0xFF6C63FF)
              : const Color(0xFFF0EBE3),
          borderRadius: BorderRadius.circular(18),
        ),
        child: message.isUser
            ? Text(
                message.text,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                  height: 1.4,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMarkdownMessage(message),
                  _buildSuggestions(message),
                ],
              ),
      ),
    );
  }

  // ==========================================================
  // WELCOME
  // ==========================================================

  Widget _buildWelcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFE9E5FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.favorite,
                size: 36,
                color: Color(0xFF6C63FF),
              ),
            ),

            const SizedBox(height: 20),

            const Text(
              'Xin chào 👋',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF292929),
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              'Mình là AI-HOPE.\n'
              'Mình ở đây để giúp bạn.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: Color(0xFF666666),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // SIDEBAR
  // ==========================================================

  Widget _buildSidebar() {
    final screenWidth = MediaQuery.of(context).size.width;

    final sidebarWidth = screenWidth < 500 ? screenWidth * 0.82 : 320.0;

    return Stack(
      children: [
        // ------------------------------------------------------
        // DARK TRANSPARENT OVERLAY
        // ------------------------------------------------------
        Positioned.fill(
          child: GestureDetector(
            onTap: _closeSidebar,
            child: Container(color: Colors.black.withValues(alpha: 0.12)),
          ),
        ),

        // ------------------------------------------------------
        // SIDEBAR
        // ------------------------------------------------------
        Align(
          alignment: Alignment.centerLeft,
          child: Material(
            elevation: 12,
            color: const Color(0xFFFFFBF5),
            child: SizedBox(
              width: sidebarWidth,
              height: double.infinity,
              child: Column(
                children: [
                  // ------------------------------------------------
                  // HEADER
                  // ------------------------------------------------
                  SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'AI-HOPE',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF292929),
                              ),
                            ),
                          ),

                          IconButton(
                            tooltip: 'Đóng',
                            onPressed: _closeSidebar,
                            icon: const Icon(
                              Icons.chevron_left,
                              color: Color(0xFF292929),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ------------------------------------------------
                  // NEW CHAT
                  // ------------------------------------------------
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: isLoading ? null : _startNewConversation,
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(
                          Icons.edit_square,
                          size: 20,
                          color: Color(0xFF292929),
                        ),
                        label: const Text(
                          'New chat',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF292929),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // ------------------------------------------------
                  // RECENTS TITLE
                  // ------------------------------------------------
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Recents',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF777777),
                        ),
                      ),
                    ),
                  ),

                  // ------------------------------------------------
                  // RECENT CHATS
                  // ------------------------------------------------
                  Expanded(
                    child: _recentChats.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Text(
                                'Chưa có cuộc trò chuyện nào.',
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _recentChats.length,
                            itemBuilder: (context, index) {
                              final chat = _recentChats[index];

                              final isCurrent =
                                  chat.conversationId == conversationId;

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Material(
                                  color: isCurrent
                                      ? const Color(0xFFE9E5FF)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    onTap: () => _openRecentChat(chat),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 11,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.chat_bubble_outline,
                                            size: 19,
                                            color: isCurrent
                                                ? const Color(0xFF6C63FF)
                                                : const Color(0xFF555555),
                                          ),

                                          const SizedBox(width: 10),

                                          Expanded(
                                            child: Text(
                                              chat.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 15,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                color: const Color(0xFF292929),
                                              ),
                                            ),
                                          ),

                                          PopupMenuButton<String>(
                                            tooltip: 'Chat options',
                                            icon: const Icon(
                                              Icons.more_horiz,
                                              size: 20,
                                              color: Color(0xFF666666),
                                            ),
                                            onSelected: (value) {
                                              if (value == 'rename') {
                                                _renameConversation(chat);
                                              } else if (value == 'delete') {
                                                _deleteConversation(chat);
                                              }
                                            },
                                            itemBuilder: (context) => const [
                                              PopupMenuItem<String>(
                                                value: 'rename',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.edit_outlined),
                                                    SizedBox(width: 10),
                                                    Text('Rename'),
                                                  ],
                                                ),
                                              ),
                                              PopupMenuItem<String>(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.delete_outline),
                                                    SizedBox(width: 10),
                                                    Text('Delete'),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  // ------------------------------------------------
                  // USER PROFILE
                  // ------------------------------------------------
                  Container(
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0xFFE5DED4))),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: const BoxDecoration(
                                color: Color(0xFFB36BDB),
                                shape: BoxShape.circle,
                              ),
                              child: const Center(
                                child: Text(
                                  'T',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(width: 10),

                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Test_User',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF292929),
                                    ),
                                  ),

                                  SizedBox(height: 2),

                                  Text(
                                    'Free',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF777777),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            IconButton(
                              tooltip: 'Tài khoản',
                              onPressed: () {},
                              icon: const Icon(
                                Icons.more_horiz,
                                color: Color(0xFF555555),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFBF5),

      // ========================================================
      // APP BAR
      // ========================================================
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFFBF5),
        elevation: 0,

        leading: IconButton(
          tooltip: 'Lịch sử trò chuyện',
          onPressed: _openSidebar,
          icon: const Icon(Icons.menu, color: Color(0xFF292929)),
        ),

        title: const Row(
          children: [
            Icon(Icons.favorite, color: Color(0xFF6C63FF)),

            SizedBox(width: 8),

            Text(
              'AI-HOPE',
              style: TextStyle(
                color: Color(0xFF292929),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),

        actions: [
          IconButton(
            tooltip: 'Cuộc trò chuyện mới',
            onPressed: isLoading ? null : _startNewConversation,
            icon: const Icon(
              Icons.add_comment_outlined,
              color: Color(0xFF292929),
            ),
          ),
        ],
      ),

      // ========================================================
      // BODY
      // ========================================================
      body: Stack(
        children: [
          Column(
            children: [
              // --------------------------------------------------
              // CHAT
              // --------------------------------------------------
              Expanded(
                child: isInitializing || isLoadingHistory
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF6C63FF),
                        ),
                      )
                    : _messages.isEmpty
                    ? _buildWelcome()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(top: 12, bottom: 12),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          final isLatestMessage = index == _messages.length - 1;

                          if (isLatestMessage) {
                            return _buildMessage(message);
                          }

                          return _buildMessage(
                            ChatMessage(
                              text: message.text,
                              isUser: message.isUser,
                              createdAt: message.createdAt,
                              suggestions: const [],
                            ),
                          );
                        },
                      ),
              ),

              // --------------------------------------------------
              // LOADING
              // --------------------------------------------------
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.only(left: 20, right: 20, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF6C63FF),
                          ),
                        ),

                        SizedBox(width: 10),

                        Text(
                          'AI-HOPE đang trả lời...',
                          style: TextStyle(color: Color(0xFF777777)),
                        ),
                      ],
                    ),
                  ),
                ),

              // --------------------------------------------------
              // INPUT
              // --------------------------------------------------
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,

                          enabled:
                              !isLoading &&
                              !isInitializing &&
                              !isLoadingHistory,

                          minLines: 1,

                          maxLines: 6,

                          textInputAction: TextInputAction.newline,

                          style: const TextStyle(
                            color: Color(0xFF292929),
                            fontSize: 16,
                          ),

                          decoration: InputDecoration(
                            hintText: 'Nhập tin nhắn...',

                            hintStyle: const TextStyle(
                              color: Color(0xFF888888),
                            ),

                            filled: true,

                            fillColor: const Color(0xFFF4EFE7),

                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: const BorderSide(
                                color: Color(0xFFE0D8CC),
                              ),
                            ),

                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: const BorderSide(
                                color: Color(0xFFE0D8CC),
                              ),
                            ),

                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: const BorderSide(
                                color: Color(0xFF6C63FF),
                                width: 2,
                              ),
                            ),

                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // ------------------------------------------------
                      // SEND BUTTON
                      // ------------------------------------------------
                      Container(
                        decoration: const BoxDecoration(
                          color: Color(0xFF6C63FF),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed:
                              isLoading || isInitializing || isLoadingHistory
                              ? null
                              : sendMessage,
                          icon: const Icon(Icons.send, color: Colors.white),
                          iconSize: 24,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // ======================================================
          // SIDEBAR
          // ======================================================
          if (isSidebarOpen) Positioned.fill(child: _buildSidebar()),
        ],
      ),
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();

    super.dispose();
  }
}
