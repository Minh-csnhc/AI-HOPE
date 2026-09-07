# AI-HOPE

AI-HOPE is an accessibility-focused AI assistant application designed to provide friendly, simple, and supportive conversations for users, including people with disabilities.

The current architecture uses **Flutter + Cloudflare Workers + Cloudflare D1 + Botpress**. OpenAI API is not currently used because the project does not have a budget for paid API credits.

Current stack:

- Flutter client
- Cloudflare Workers + Hono backend
- Botpress Chat API
- Cloudflare D1 for persistent users, conversations, and messages
- SharedPreferences for local client persistence
- Markdown rendering for AI responses
- LaTeX/math rendering with `flutter_markdown_plus_latex`
- Structured AI follow-up suggestions

## Architecture

```text
Flutter App
    |
    | HTTPS
    v
Cloudflare Worker (Hono)
    |
    +--------------------+
    |                    |
    v                    v
Cloudflare D1         Botpress Chat API
    |                    |
    |                    v
    |                 AI conversation
    |
    v
Persistent users,
conversations,
and messages
```

The Flutter app communicates with the Cloudflare Worker, not directly with Botpress.

---

## Flutter App

Location:

```text
AI-HOPE/flutter_app/
```

Run:

```bash
fvm flutter run -d linux
```

Analyze:

```bash
fvm flutter analyze
```

Format Dart:

```bash
fvm dart format lib/main.dart
```

### Dependencies

Current important packages:

Important packages currently used include:

```text
http
shared_preferences
flutter_markdown_plus
flutter_markdown_plus_latex
markdown
```

The project uses `flutter_markdown_plus` instead of the discontinued `flutter_markdown` package.

---

## Chat UI

The app uses a light/creamy theme:

```text
Background: #FFFFFBF5
Primary:    #6C63FF
Text:       #292929
```

Implemented UI features:

- AI-HOPE header
- New chat button
- Chat bubbles
- Loading indicator
- Markdown AI messages
- Multiline input
- Send button
- ChatGPT-style sidebar
- Light-mode sidebar
- Close-sidebar button
- Recent chats/history UI
- User section in sidebar

### Message input

The input intentionally uses a maximum of 6 visible lines:

```dart
minLines: 1,
maxLines: 6,
textInputAction: TextInputAction.newline,
```

---

## Markdown

AI messages use `MarkdownBody`, allowing:

- bold
- italic
- lists
- code
- Markdown-formatted explanations

---

## Local Persistence

`shared_preferences` is used to persist local user/conversation information.

Important keys include:

```text
ai_hope_user_id
ai_hope_conversation_id
ai_hope_recent_chats
```

A local user ID is created when the app is first launched.

Conversation IDs are saved so the same Botpress conversation can be reused.

---

# Cloudflare Worker

Location:

```text
AI-HOPE/cloudflare-worker/
```

The Worker uses:

- Cloudflare Workers
- Hono
- TypeScript
- Botpress Chat API

Production URL:

```text
https://cloudflare-worker.ducminhnhc2010.workers.dev
```

## Development

Start locally:

```bash
npx wrangler dev
```

Usually available at:

```text
http://localhost:8787
```

Deploy:

```bash
npx wrangler deploy
```

---

## Worker Bindings

The Worker expects:

```ts
type Bindings = {
  BOTPRESS_WEBHOOK_ID: string;
  BOTPRESS_ENCRYPTION_KEY: string;
};
```

These values must remain secret and should never be hard-coded into Flutter or committed to Git.

---

# Cloudflare D1

Cloudflare D1 is now integrated into the Worker and is the server-side source of truth for persistent application data.

Database:

```text
ai-hope-db
```

Database ID:

```text
6c638667-9d03-4827-9a2e-2f24f3ff29a8
```

Worker binding:

```text
env.DB
```

The D1 binding is configured in `wrangler.jsonc`.

## Current D1 tables

```text
users
conversations
messages
```

Cloudflare migration metadata tables are also present.

Foreign-key enforcement has been verified locally.

## Migrations

Create:

```bash
npx wrangler d1 migrations create ai-hope-db MIGRATION_NAME
```

Apply locally:

```bash
npx wrangler d1 migrations apply ai-hope-db --local
```

Apply remotely:

```bash
npx wrangler d1 migrations apply ai-hope-db --remote
```

Execute SQL locally:

```bash
npx wrangler d1 execute ai-hope-db --local --command="SELECT * FROM users;"
```

Execute SQL remotely:

```bash
npx wrangler d1 execute ai-hope-db --remote --command="SELECT * FROM users;"
```

The `migrations/` directory contains versioned SQL migration files.

---

# POST /api/chat

Endpoint:

```text
POST /api/chat
```

Example:

```bash
curl -X POST "https://cloudflare-worker.ducminhnhc2010.workers.dev/api/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "flutter-test-user",
    "userName": "AI-HOPE Flutter",
    "message": "Xin chào!"
  }'
```

A later message can include the existing conversation:

```json
{
  "userId": "flutter-test-user",
  "userName": "AI-HOPE Flutter",
  "conversationId": "conv_...",
  "message": "Tôi đang buồn."
}
```

The Worker:

1. Validates the message.
2. Creates a signed Botpress user key.
3. Gets or creates the Botpress user.
4. Creates a conversation when needed.
5. Sends the user message.
6. Polls for a new Botpress response.
7. Returns the response to Flutter.

---

# Botpress Authentication

The Worker generates an HS256 JWT and sends it as:

```text
x-user-key
```

The key is generated from:

```text
userId
BOTPRESS_ENCRYPTION_KEY
```

The secret is handled by the Cloudflare Worker.

---

# Preventing Old Bot Replies

An important bug was found where the Worker could return an older bot response.

The Worker was changed to track:

```text
sentMessageId
sentMessageCreatedAt
```

A response is accepted only when it:

- is not from the current user
- is a text message
- is not the sent user message
- was created after the current user message

The Worker currently polls for up to:

```text
20 attempts × 500 ms
```

---

# AI-HOPE Suggestion System

The suggestion system is now working through the local Cloudflare Worker.

Botpress is instructed to append a structured block:

```text
[[AIHOPE_SUGGESTIONS]]
["Suggestion 1","Suggestion 2","Suggestion 3"]
[[/AIHOPE_SUGGESTIONS]]
```

The Worker:

1. Finds the suggestion block.
2. Parses its JSON content.
3. Cleans suggestions.
4. Removes duplicates.
5. Limits the result to a maximum of 4 suggestions.
6. Removes the block from the visible AI reply.
7. Returns the suggestions separately in the `/api/chat` JSON response.

Example:

```json
{
  "reply": "Jazz là một thể loại nhạc...",
  "suggestions": [
    "Jazz bắt nguồn từ đâu?",
    "Những nghệ sĩ jazz nổi tiếng là ai?",
    "Jazz có những phong cách nào?"
  ]
}
```

The next task is to consume this `suggestions` array in Flutter and render the suggestions as clickable buttons underneath the AI response.

---

# GET /api/chat/history

Endpoint:

```text
GET /api/chat/history
```

Required query parameters:

```text
userId
conversationId
```

Example:

```bash
curl "http://localhost:8787/api/chat/history?userId=ai-hope-debug-user&conversationId=YOUR_CONVERSATION_ID"
```

Successful response:

```json
{
  "success": true,
  "conversationId": "conv_...",
  "messages": []
}
```

The Flutter app uses this endpoint to restore previous messages.

---

# Conversation Ownership

A Botpress conversation belongs to a specific participant/user.

Using a conversation ID with the wrong user produces:

```text
403 Forbidden
You are not a participant in this message's conversation
```

Therefore:

```text
userId + conversationId
```

must stay associated with the same Botpress user.

---

# Botpress AI Instructions

The Botpress instructions were expanded so AI-HOPE is intended to handle more than casual conversation.

Target topics include:

- Vietnamese conversation
- Programming
- C
- C++
- Python
- Java
- JavaScript
- TypeScript
- Dart
- Flutter
- Algorithms
- Competitive programming
- Mathematics
- Science
- Technology
- Linux
- Computers
- School subjects
- Music
- Singers
- Musicians
- Entertainment
- Games
- General knowledge
- Everyday conversation

The instructions also emphasize:

- simple Vietnamese
- accessible explanations
- short paragraphs
- explaining technical terms
- useful programming debugging
- admitting uncertainty
- not fabricating facts
- not pretending to have live information without access to it

---

# Botpress API Behavior

The Cloudflare Worker successfully communicates with the Botpress Chat API.

During development, Botpress initially did not follow the suggestion-output instruction. Debug logging showed that the returned Botpress message contained only the normal AI answer and no suggestion markers.

The Botpress instruction was then changed to require the structured suggestion block, and the Worker now successfully receives and extracts suggestions in local testing.

The remaining Botpress-related improvement is to investigate any differences between Botpress Studio behavior and the public Chat API if restricted knowledge responses appear for specific topics.

---

# AI Provider Decision

OpenAI API integration was considered, but it is currently not being used because the project has no budget for paid API credits.

The current architecture therefore remains:

```text
Flutter
   |
Cloudflare Worker
   |
Botpress
```

Do not add an OpenAI API key to the project unless the project later has a budget for API usage.

---

# Testing

## Production chat

```bash
curl -X POST "https://cloudflare-worker.ducminhnhc2010.workers.dev/api/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "flutter-test-user",
    "userName": "AI-HOPE Flutter",
    "message": "Xin chào!"
  }'
```

## Local chat

Start:

```bash
npx wrangler dev
```

Then:

```bash
curl -X POST "http://localhost:8787/api/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "ai-hope-debug-user",
    "userName": "AI-HOPE Test",
    "message": "Xin chào!"
  }'
```

## History

```bash
curl "http://localhost:8787/api/chat/history?userId=ai-hope-debug-user&conversationId=YOUR_CONVERSATION_ID"
```

---

# Useful Development Commands

## Flutter

```bash
fvm flutter pub get
fvm flutter analyze
fvm dart format lib/main.dart
fvm flutter run -d linux
```

## Cloudflare Worker

```bash
npx wrangler dev
npx wrangler deploy
```

## Git

```bash
git status
```

---

# Important Dart Formatting Note

The correct command is:

```bash
fvm dart format lib/main.dart
```

not:

```bash
fvm flutter format lib/main.dart
```

If Dart reports:

```text
Directives must appear before any declarations.
```

check for accidentally duplicated imports or code such as:

```dart
}import 'dart:convert';
```

All imports must be at the top of the Dart file.

---

# Security

Never commit these values:

```text
BOTPRESS_WEBHOOK_ID
BOTPRESS_ENCRYPTION_KEY
```

Keep private credentials in Cloudflare/Wrangler secrets.

The Flutter app should only know the public Worker endpoint.

---

# Current Status

## Working

- [x] Flutter application
- [x] CachyOS/Linux development
- [x] Light creamy UI
- [x] Chat interface
- [x] Multiline input
- [x] Maximum 6-line input
- [x] Markdown AI responses
- [x] Cloudflare Worker
- [x] Hono backend
- [x] Botpress authentication
- [x] Botpress user creation
- [x] Conversation creation
- [x] Conversation reuse
- [x] Message sending
- [x] New bot-response detection
- [x] Local user persistence
- [x] Conversation persistence
- [x] Chat history API
- [x] Chat history UI
- [x] ChatGPT-style sidebar
- [x] Light-mode sidebar
- [x] New chat button
- [x] Recent conversations UI
- [x] User section
- [x] Close-sidebar button
- [x] Production Worker deployment
- [x] Cloudflare D1 database and migrations
- [x] D1 users/conversations/messages persistence
- [x] Conversation rename/delete API
- [x] Conversation rename UI
- [x] Conversation delete UI with confirmation
- [x] Botpress structured suggestion extraction
- [x] Suggestion data returned by `/api/chat`
- [x] Clickable suggestion buttons in Flutter
- [x] Suggestion buttons cleared when conversation continues
- [x] UI polish and demo testing

## Planned / Needs Improvement

- [ ] Robust multiple-conversation persistence
- [ ] Automatic conversation titles
- [ ] Improve Botpress public API knowledge behavior
- [ ] Voice input
- [ ] Voice output
- [ ] Firebase authentication
- [ ] Android build
- [ ] iOS build
- [ ] Windows build
- [ ] More accessibility improvements

---

# Recommended Next Step

The next immediate milestone is to package the current working app for real-device testing and the demo.

Current demo flow:

```text
Flutter App
   |
   | HTTPS
   v
Cloudflare Worker
   |
   +---- D1
   |
   v
Botpress
   |
   v
AI response + suggestions
   |
   v
Flutter App
```

The current Flutter demo supports:

1. Chat with the AI assistant.
2. Conversation history.
3. Creating a new chat.
4. Renaming conversations.
5. Deleting conversations with confirmation.
6. Markdown/LaTeX AI responses.
7. Clickable follow-up suggestions.
8. Clearing old suggestions when the conversation continues.
9. A polished, accessibility-focused chat UI.

## Demo / Real-Device Testing

The immediate goal is to build the Flutter app for an Android device and test the complete production path using the deployed Cloudflare Worker.

Recommended sequence:

```text
CachyOS
   |
   v
Flutter release/debug build
   |
   v
Android phone
   |
   | HTTPS
   v
Cloudflare Worker
   |
   +---- D1
   |
   v
Botpress
```

Before the demo, verify on the real device:

- App launches successfully.
- Chat messages send and receive correctly.
- Suggestions appear and can be tapped.
- New chat works.
- History loads correctly.
- Rename works.
- Delete works and asks for confirmation.
- The app can reconnect to the deployed Worker over HTTPS.
- The UI remains readable and usable on the phone screen.

After the demo, the next major development tasks are Firebase authentication and voice input/output.

---

# Project Goal

AI-HOPE is intended to become a cross-platform accessible AI assistant:

```text
                  AI-HOPE
                     |
        +------------+------------+
        |            |            |
        v            v            v
     Android        iOS        Windows
        |
        v
  Accessible AI Assistant
        |
   +----+----+----+
   |    |    |    |
   v    v    v    v
 Text Voice Suggestions History
```

The current priority is a reliable, accessible conversation system before adding the remaining features.
