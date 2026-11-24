## [Unreleased]

- The merge job fetches several parts at a time. A storage object of your own must allow `fetch` to
  be called from several threads.
- Encryption: with a key in `Logsafe.key`, and in `LOGSAFE_KEY` for Vector, the parts and the daily
  files are encrypted. `logsafe key` makes a key and `logsafe decrypt` reads what it encrypted.

## [0.1.0] - 2026-11-24

- Initial release
