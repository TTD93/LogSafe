# Changelog

The versions follow [Semantic Versioning](https://semver.org). Until 1.0, a minor version can change
what is in the README's Reference.

## [0.1.0] - 2026-11-25

The first version.

- **Shipping:** settings for Vector that send the lines of labelled Docker containers to S3-compatible
  storage, Google Cloud Storage or a folder, under `parts/<stream>/<date>/`. They come with the gem, in
  `shipper/`.
- **Merging:** `Logsafe::MergeJob` turns each finished day into one sorted, compressed file per stream. It
  can be run again at any time, a line that was sent twice is kept once, and parts are removed only once
  a later run has found all their lines in the day's file. Several runs at the same time do not lose each
  other's lines.
- **Searching:** `Logsafe::Web`, a Rack app to mount in your routes behind your own sign-in: by day,
  stream, level and words, today's lines included.
- **Encryption:** with a key, Vector encrypts every line before it leaves the server, and the day's files
  are written encrypted. `logsafe key` makes a key and `logsafe decrypt` reads what it encrypted.
  `Logsafe.old_keys` and `Logsafe::ReencryptJob` change the key, and encrypt what was there before.
- **Limits on what is not trusted:** `Logsafe.streams` names the streams there are. A part that cannot be
  read, unpacks to more than 256 MB or has a line of more than 2 MB is left where it is and named, and
  neither the merge nor the page fills the disk.
