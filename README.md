# LiteMail

A fast, keyboard-driven macOS mail client. 3-pane layout, native AppKit, IMAP + JMAP, multi-account.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/haiz/mail_client/main/install.sh | bash
```

Requires macOS 14 (Sonoma) or later.

> **First launch:** If macOS shows "unidentified developer", go to System Settings > Privacy & Security > scroll down > **Open Anyway**.

## Features

- **3-pane layout** — sidebar, message list, thread detail
- **IMAP & JMAP** — works with Gmail, Fastmail, iCloud, Stalwart, Cyrus, and any standard IMAP server
- **Auto-discovery** — JMAP well-known, Mozilla autoconfig, provider presets
- **Multi-account** — all accounts in one view
- **Command palette** — keyboard-driven actions (`⌘K`)
- **Keyboard shortcuts** — cheat sheet built in
- **Inline reply & compose** — reply without leaving the thread
- **Labels & bulk actions** — tag, archive, delete in bulk
- **Send Later** — schedule outgoing messages
- **Full-text search** — FTS5 SQLite index, instant results
- **HTML rendering** — WebKit-based message viewer
- **OAuth2** — Gmail, iCloud; credentials stored in Keychain
- **Undo toast** — undo destructive actions

## Build from Source

Requires Swift 5.9+ and Xcode 15+.

```bash
git clone https://github.com/haiz/mail_client.git
cd mail_client
swift build
swift run LiteMail
```

## Tests

```bash
swift test --filter LiteMailTests               # Unit (~1s)
swift test --filter LiteMailIntegrationTests     # Integration (~2s)
swift test --filter LiteMailGUITests             # GUI (~5s)
swift test --filter LiteMailProtocolTests        # Protocol, requires Docker (~30s)
```

Docker-based protocol tests (GreenMail):

```bash
docker compose -f docker-compose.test.yml up -d
swift test --filter LiteMailProtocolTests
docker compose -f docker-compose.test.yml down
```

## Data

- **Database:** `~/Library/Application Support/LiteMail/mail.sqlite`
- **Keychain service:** `com.litemail.auth`

## License

MIT
