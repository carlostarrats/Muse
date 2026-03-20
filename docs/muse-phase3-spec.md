# Muse Phase 3 -- AI Tagging
## Build Specification for Claude Code

---

## Prerequisites

Phase 1 (data layer, Grid view) and Phase 2 (3D views) should be complete. You should have:

- Working import pipeline with thumbnails
- Tag CRUD via ImageRepository
- Detail panel with manual tag editing
- Settings view with placeholder AI section

This spec adds AI-powered image tagging using the user's own API keys. Three providers are supported: Claude (Anthropic), OpenAI, and Gemini.

---

## File Structure (new files only)

```
Muse/
├── AI/
│   ├── AIProvider.swift           # Protocol all providers conform to
│   ├── AITaggingService.swift     # Orchestrator: picks provider, manages queue
│   ├── ClaudeProvider.swift       # Anthropic Claude implementation
│   ├── OpenAIProvider.swift       # OpenAI GPT-4o implementation
│   └── GeminiProvider.swift       # Google Gemini implementation
```

---

## AI Provider Protocol

### AIProvider

A protocol that all providers conform to:

- `var name: String { get }` -- human-readable name ("Claude", "OpenAI", "Gemini")
- `func generateTags(for imageURL: URL) async throws -> AITagResult`

### AITagResult

A struct returned by all providers:

- `tags: [String]` -- 5-10 descriptive tags
- `suggestedCollection: String?` -- a suggested collection name
- `description: String?` -- one-sentence description of the image

### AIError

An enum for common errors across providers:

- `noAPIKey` -- key not configured
- `imageLoadFailed` -- could not read the image file
- `requestFailed(statusCode: Int, message: String)` -- HTTP error from the API
- `parseError` -- response was not valid JSON or did not match expected format
- `rateLimited` -- 429 response
- `timeout` -- request took longer than 30 seconds

---

## Provider Implementations

All three providers follow the same pattern:

1. Read the image file from disk
2. Base64-encode it
3. Determine the media type from the file extension (png, jpeg, webp, gif, heic)
4. Send a vision API request asking the model to return JSON
5. Parse the JSON response into AITagResult

### Prompt (same across all providers)

Use this prompt text for all providers:

```
Analyze this image as design inspiration. Return JSON only, no other text.
Format:
{
  "tags": ["tag1", "tag2", ...],
  "collection": "suggested collection name",
  "description": "one sentence description"
}

Tags should be specific and useful for a designer's reference library. Include: dominant colors, mood/atmosphere, subject matter, design style, materials or textures, composition type, era or movement if identifiable. Return 5-10 tags. All tags lowercase.
```

### ClaudeProvider

- API endpoint: `https://api.anthropic.com/v1/messages`
- Model: `claude-sonnet-4-20250514` (not Opus, Sonnet is the right cost/quality tradeoff for tagging)
- Max tokens: 300
- Headers: `Content-Type: application/json`, `x-api-key: <key>`, `anthropic-version: 2023-06-01`
- Message format: single user message with an image content block (type "image", base64 source) followed by a text content block with the prompt
- Parse the first text content block from the response

### OpenAIProvider

- API endpoint: `https://api.openai.com/v1/chat/completions`
- Model: `gpt-4o`
- Max tokens: 300
- Headers: `Content-Type: application/json`, `Authorization: Bearer <key>`
- Message format: single user message with an image_url content block (data URI: `data:<mediaType>;base64,<data>`) and a text content block
- Parse `choices[0].message.content` from the response

### GeminiProvider

- API endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=<key>`
- No auth header needed (key is in the URL)
- Request body: `contents` array with one entry containing `parts` -- an `inlineData` part (with `mimeType` and base64 `data`) and a `text` part with the prompt
- Parse `candidates[0].content.parts[0].text` from the response

### JSON Parsing

All providers return freeform text that should contain JSON. The model might wrap it in markdown code fences. Handle this:

1. Get the raw text response
2. Strip leading/trailing whitespace
3. If it starts with ` ```json ` or ` ``` `, strip the fences
4. Attempt to parse as JSON
5. Validate the parsed object has a `tags` array of strings
6. If parsing fails, throw `AIError.parseError`

Use a shared `TagJSON` struct (Codable) with fields: `tags: [String]`, `collection: String?`, `description: String?`.

---

## AI Tagging Service

### AITaggingService

The orchestrator that the rest of the app calls. It should not know the details of any provider.

Responsibilities:

**Pick the active provider:**
- Read `@AppStorage("defaultAIProvider")` to determine which provider to use
- Read the corresponding API key from `@AppStorage`
- If the key is empty, throw `AIError.noAPIKey`
- Instantiate the appropriate provider with the key

**Tag a single image:**
- `func tagImage(_ image: MuseImage) async throws`
- Call the active provider's `generateTags`
- For each returned tag string, create a Tag record with source `.ai` and save via ImageRepository
- If a `suggestedCollection` is returned and the image has no collection assigned:
  - Check if a collection with that name already exists (case-insensitive)
  - If yes, assign the image to it
  - If no, create the collection and assign the image
- If a `description` is returned, save it to the image's `notes` field (only if notes is currently empty, do not overwrite user notes)
- Record which provider was used (save the provider name on the image record, add an `aiProvider: String?` field to MuseImage if not already present)

**Tag multiple images (bulk):**
- `func tagImages(_ images: [MuseImage], progress: @escaping (Int, Int) -> Void) async`
- Process images sequentially, not concurrently (to avoid rate limits)
- Call the progress closure with (completed, total) after each image
- If a single image fails, log the error and continue to the next one
- Add a 0.5-second delay between requests to avoid rate limiting

**Auto-tag on import:**
- After ImportManager finishes importing an image, check if an API key is configured
- If yes, queue the image for tagging in the background
- Tagging must never block the import flow. Import completes immediately, tags arrive later.
- When tags arrive, update the image record and notify AppState to refresh

---

## Settings Updates

Update the existing SettingsView to make the AI section functional:

1. Provider picker: Dropdown to select default provider (Claude, OpenAI, Gemini)
2. API key fields: One `SecureField` per provider. Store in `@AppStorage` with keys `claudeAPIKey`, `openAIAPIKey`, `geminiAPIKey`.
3. Test button: A "Test Connection" button next to each key field. When clicked, send a tiny test request (tag a bundled sample image or just validate the key format). Show a green checkmark or red X with error message.
4. Auto-tag toggle: A toggle for "Automatically tag images on import". Store in `@AppStorage("autoTagOnImport")`, default false.

Note on key storage: `@AppStorage` uses `UserDefaults` which stores data in plaintext on disk. This is acceptable for v1 since the app is local-only and single-user. Add a small caption below the key fields: "API keys are stored locally on this Mac." A future version could migrate to Keychain.

---

## Detail Panel Updates

Add to the existing ImageDetailPanel:

1. If the image has an `aiProvider` value, show it in the file info section as "Tagged by: Claude" (or whichever provider)
2. Add a "Tag with AI" button below the tags section. Tapping it runs AITaggingService.tagImage on the current image. Show a small spinner while it runs. When complete, refresh the tags display.
3. If AI tags already exist (source = .ai), the button label should say "Re-tag with AI". Re-tagging removes existing AI tags and replaces them with new ones. Manual tags are never touched.

---

## Bulk Tagging

Add a bulk tag action accessible from the Grid view:

1. Add a selection mode: long-press or Cmd+click on images to select multiple
2. When images are selected, show a floating action bar at the bottom with: "Tag Selected with AI" button, selection count, and a "Deselect All" button
3. Tapping "Tag Selected with AI" runs AITaggingService.tagImages on the selected set
4. Show a progress indicator (e.g. "Tagging 5 of 23...")
5. When complete, deselect all and refresh the grid

To support selection, add to AppState:
- `selectedImageIDs: Set<UUID>`
- `isSelectionMode: Bool`

---

## Error Handling

- No API key: Show an inline message "Set your API key in Settings" rather than a modal alert
- Rate limited (429): Wait 5 seconds and retry once. If it fails again, skip and log.
- Timeout: Use a 30-second URLRequest timeout. If exceeded, throw AIError.timeout.
- Parse error: Log the raw response for debugging. Skip the image, do not crash.
- Network error: Surface a brief toast or inline message. Do not show a modal for background tagging failures.

---

## What Is NOT in This Spec

- Smart/semantic search using AI-generated descriptions
- Batch re-tag of entire library
- Custom prompt editing
- Provider-specific model selection UI
- Cost estimation or usage tracking

---

## Build Order

1. Add `aiProvider` field to MuseImage if not present. Add a database migration.
2. Build AIProvider protocol, AITagResult, AIError.
3. Build the shared JSON parsing utility (strip fences, decode TagJSON).
4. Build ClaudeProvider. Test: hardcode an API key, tag a test image, verify tags are returned.
5. Build OpenAIProvider. Test same way.
6. Build GeminiProvider. Test same way.
7. Build AITaggingService with single-image tagging. Wire it to a "Tag with AI" button in the detail panel. Test end-to-end.
8. Update SettingsView with functional API key fields and provider picker.
9. Add the test connection button in Settings.
10. Wire auto-tag on import (behind the toggle).
11. Add re-tag functionality in the detail panel.
12. Build selection mode in Grid view.
13. Build the bulk tagging action bar and progress indicator.
14. Test with 20+ images across all three providers.
