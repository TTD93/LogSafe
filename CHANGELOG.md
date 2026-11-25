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

- A part that cannot be read no longer holds up its day, in the merge or on the page. It stays where
  it is and is named, and the merge fails until it is gone.
- Parts have limits: 256 MB unpacked and 2 MB for a line. Neither the merge nor the page fills the disk.
- A line whose time is not of its day gets the start of that day, so that it cannot change the order
  or the paging of the others.
- Folder storage does not follow links, and its files are not for every user of the machine to read.
- An encrypted day's file belongs to its stream and day, its size is rounded to 64 KB, and a file named
  `.enc` has to be encrypted. **Files encrypted by an earlier version of this branch cannot be opened.**
- Google Cloud Storage: gzip is no longer unpacked in memory.
- The page: searches that another website starts are not run, lines of one time are not skipped when
  paging, what is searched for is not visible to other users of the machine, and there are limits to
  streams, words, line length and the size of the copies.
- `logsafe decrypt STREAM DATE` takes the parts as files and no longer reads its input.
- A day's file is only replaced by a run that has read the latest one, also when several merges, or a
  merge and `Logsafe::ReencryptJob`, run at the same time. A storage object of your own needs a fifth
  method, `version(key)`, and `store` takes the version as its third argument.
- `Logsafe.streams` names the streams there are, so that made-up ones are not merged or shown. Parts of
  a date more than a year ago are left alone, and a merge ends after 50 minutes.

## [0.1.0] - 2026-11-24

- Initial release
