## [Unreleased]

- `Logsafe::Web`: a page to read and search the logs in the browser, by day, stream, level and words.
  A Rack app that you mount in your routes, behind your own sign-in.
- The merge job fetches and unpacks several parts at a time, and from S3 with one request per file
  where it took two. A storage object of your own must allow `fetch` to be called from several
  threads, and should say which storage it is in `to_s`.
- Encryption: with a key in `Logsafe.key`, and in `LOGSAFE_KEY` for Vector, the parts and the daily
  files are encrypted. `logsafe key` makes a key and `logsafe decrypt` reads what it encrypted.
- `shipper/start` does not start Vector with a key that is not one.
- Changing the key: `Logsafe.old_keys` keeps what an old key encrypted readable, and
  `Logsafe::ReencryptJob` encrypts all of it again with the new key, after which the old key can go.
  The same job encrypts what was stored before there was a key.
- A stream name is made of letters, digits, `.`, `_` and `-`. Vector ships lines with any other
  `logs` label as the stream `unparsed`: with a slash in the name they were never merged.
- Two merges at the same time no longer fail when both remove the same parts, and parts in Google
  Cloud Storage are removed several at a time.
- The page's copies of the days searched are deleted when the app stops.
- Needs Ruby 3.3 or newer.

## [0.1.0] - 2026-11-24

- Initial release
