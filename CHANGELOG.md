# Changelog

The versions follow [Semantic Versioning](https://semver.org). Until 1.0, a minor version can change
what is in the README's Reference.

## [0.4.0] - 2026-11-25

- **When no lines arrive:** `Logsafe::CheckJob`, or `Logsafe.check`, fails with `Logsafe::Quiet` when the
  storage has received no lines for 90 minutes, or for as long as you say. Vector drops what the storage
  refuses and tells only its own log, so until now nobody knew before they missed the lines. A storage
  of your own needs one more method for it, `times`.
- **Vector reads its files again when they change**, if you take the new `shipper/start`. A file that is not
  valid changes nothing. Keys come from the environment, and for those the container has to be made
  again, as before. Set `VECTOR_WATCH_CONFIG=false` in Vector's environment to turn it off.

  **If Vector is already running,** copy `shipper/start` to the servers again and restart Vector once. Until
  then it goes on as before. Nothing else has to change.

## [0.3.0] - 2026-11-25

- **In a bucket** the logs are now in the folder `logs/`: `logs/2026/11/<stream>.<date>.log.gz` and
  `logs/parts/<stream>/<date>/`. Before, they were at the top of the bucket. `prefix:` in
  `Logsafe.storage` names another folder, or none. A folder as storage, and one of your own, stay as
  they were.

  **If you already have logs in a bucket,** either keep them where they are, with `prefix: ""` and the
  `key_prefix` you have in Vector, or move them: put `logs/` in front of `parts/` in Vector's
  `key_prefix` and in the policy of its key, restart Vector, update the gem, and move `parts/` and the
  year folders into `logs/`. What is not below `logs/` is neither merged nor shown.

## [0.2.0] - 2026-11-25

- **In development** a Rails app that sets no `Logsafe.storage` now has its own log on the page, without
  any setting. What the app logs is kept in `tmp/logsafe` as well as in `log/development.log`, for three
  days. Set `Logsafe.storage` yourself and nothing of this happens. Before, the page said that there was
  no storage, and everywhere else it still does.

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
