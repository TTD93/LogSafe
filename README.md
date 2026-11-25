# Logsafe

Keep your logs without paying a logging service: one sorted, compressed file per day, in storage you own.

For apps that run in Docker on servers you control. The app logs to STDOUT as usual, and three pieces
do the rest:

1. Docker writes each container's output to its normal log file on the server.
2. [Vector](https://vector.dev), a log shipper, runs on every app server. It follows those files and
   sends what is new to your storage about once a minute, as small parts.
3. `Logsafe::MergeJob`, a background job in your Rails app, turns each finished day into a single file.

```
my-logs/
  2026/11/shop-prod.2026-11-23.log.gz     one file per stream per day
  2026/11/shop-prod.2026-11-24.log.gz
  parts/shop-prod/2026-11-25/…            today, not merged yet
```

A *stream* is a name you choose, such as `shop-prod` or `shop-prod-worker`. Containers with the same
name share a file, on however many servers they run, and whatever language they are written in. Days
are UTC.

Every line gets the time Docker received it in front:

```
2026-11-24T10:15:02.123456789Z Started GET "/orders" for 203.0.113.7
```

Storage can be Amazon S3 or anything that speaks its protocol (DigitalOcean Spaces, MinIO or Garage on
your own server), Google Cloud Storage, or a plain folder. The job runs on whatever runs your jobs:
Solid Queue, Sidekiq, GoodJob, Resque, or cron.

You can also [search the logs in the browser](#in-the-browser), on a page you mount in your app, and
[encrypt them](#encryption) before they leave your servers.

**Contents:** [Requirements](#requirements) · [Try it](#try-it) · [Setup](#setup) ·
[Reading the logs](#reading-the-logs) · [Lograge and other loggers](#lograge-and-other-loggers) ·
[Encryption](#encryption) · [Reference](#reference) · [Good to know](#good-to-know) ·
[What has been run](#what-has-been-run) · [Development](#development) · [Disclaimer](#disclaimer)

## Requirements

- Ruby 3.3 or newer, and Active Job 7.1 or newer. The page needs no Rails: any Rack app can mount it.
- Docker on the app servers, with its default `json-file` log driver.
- For storage in a bucket, the gem of that storage: `aws-sdk-s3` 1.197 or newer, or
  `google-cloud-storage`. Logsafe does not install them for you.
- Where the merge job and the page run: the `sort`, `gzip`, `df`, `grep`, `awk`, `cut` and `tail`
  commands, which every common Linux image has. On Alpine, add `coreutils`.

## Try it

A look at the page on your own machine, with a folder for storage and no Vector:

```sh
bundle add logsafe

day=$(date -u +%F)
mkdir -p tmp/logs/parts/demo/$day
echo "${day}T08:00:00.000000001Z ERROR hello" > tmp/logs/parts/demo/$day/a.log
touch -t 202601010000 tmp/logs/parts/demo/$day/a.log   # a part that was just written is left alone
```

```ruby
# config/initializers/logsafe.rb
Logsafe.storage = Rails.root.join("tmp/logs")

# config/routes.rb
mount Logsafe::Web, at: "logsafe" if Rails.env.development?
```

Start the app and open `/logsafe`. For your own logs, go on with Setup.

## Setup

### 1. Storage

**A bucket (S3-compatible or Google Cloud Storage)**

- Keep it private and turn **versioning** on, so a deleted or overwritten file can be brought back. Add
  a lifecycle rule that removes old versions after a week or two.
- Use one bucket for production and another for staging. Let staging expire after a few weeks.
- Make one access key per environment for the app servers, allowed only to write under `parts/`. On
  AWS:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      { "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::my-logs/parts/shop-prod*" }
    ]
  }
  ```

  A server that is broken into can then neither read nor delete logs. It can still add lines of its
  own, under any stream the key covers.
- Make one more key for the merge job, allowed to list, read, write and delete in the bucket.

**A folder (a disk on your own server, a network share, or your own machine in development)**

- Every app server and the machine that runs the merge job must see the same folder.
- Make it so that other users of the machine cannot enter it, and give the job's user (1000 here)
  rights on everything that is created in it later. Vector writes as root, and the job must be allowed
  to delete what Vector wrote:

  ```sh
  install -d -m 750 /mnt/logs /mnt/logs/parts
  setfacl -R -m u:1000:rwX -m d:u:1000:rwX -m d:o::--- /mnt/logs
  ```

  Run the job as that user and not as root. A server that is broken into can write to the folder, so
  the job does not follow links in it; on Linux it opens each folder in a way that cannot be swapped
  in between.
- Where you can, let the app servers write to `parts/` only, and not to the year folders.

### 2. Your app's containers

Give each container a `logs` label with its stream name, tell Docker to write that label into the log
file, and limit the size of the log files. Containers without the label are not shipped.
A stream name is made of letters, digits, `.`, `_` and `-`, and starts with a letter or a digit.
Lines with any other name end up in the stream `unparsed`.

```sh
docker run --label logs=shop-prod \
  --log-opt labels=logs --log-opt max-size=50m --log-opt max-file=5 …
```

Docker Compose:

```yaml
services:
  web:
    labels: { logs: shop-prod }
    logging:
      options: { labels: logs, max-size: 50m, max-file: "5" }
```

Kamal (`config/deploy.yml`):

```yaml
logging:
  options: { labels: logs, max-size: 50m, max-file: "5" }
servers:
  web:
    hosts: [203.0.113.10]
    labels: { logs: shop-prod-web }
  job:
    hosts: [203.0.113.10]
    cmd: bin/jobs
    labels: { logs: shop-prod-worker }
```

The app must log to STDOUT, which is what a new Rails app does in production by default.

`max-size` times `max-file` is how much each container keeps on the server. It is also how far behind
Vector can fall before lines are lost, so don't set it small.

### 3. Vector, on every app server

The files for Vector come with the gem. `bundle info logsafe --path` prints where it is, and they are
in its `shipper/` folder. Take them from the version of the gem your app uses, and look at them again
when you update it: how Vector writes a line has to fit how the gem reads it.

Copy [shipper/vector.yaml](shipper/vector.yaml) to `/etc/vector/`, together with **one** of these, and
fill in the name of your bucket:

| Storage | File | The key |
| --- | --- | --- |
| S3-compatible | [shipper/to-s3.yaml](shipper/to-s3.yaml) | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in `/etc/vector/keys` |
| Google Cloud Storage | [shipper/to-gcs.yaml](shipper/to-gcs.yaml) | the service account's key file |
| Folder | [shipper/to-folder.yaml](shipper/to-folder.yaml) | none |

Copy [shipper/start](shipper/start) there too, and make the file for the keys so that only root can
read it. Keys belong in that file and not on a command line, where other users can see them:

```sh
install -m 600 /dev/null /etc/vector/keys   # then write the keys into it, one NAME=value per line
```

Then start it. For S3-compatible storage:

```sh
docker run -d --name vector --restart unless-stopped \
  --env-file /etc/vector/keys \
  -v /etc/vector:/etc/vector:ro \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v vector-data:/var/lib/vector \
  --entrypoint sh timberio/vector:0.62.0-alpine /etc/vector/start \
  --config /etc/vector/vector.yaml --config /etc/vector/to-s3.yaml
```

For Google Cloud Storage, name `to-gcs.yaml` and put
`GOOGLE_APPLICATION_CREDENTIALS=/etc/vector/key.json` in `/etc/vector/keys`. For a folder, name
`to-folder.yaml` and add `-v /mnt/logs/parts:/logs/parts`. `start` sees to it that other users of the
machine cannot read what Vector writes there.

Keep the `vector-data` volume: it holds Vector's position in each log file and the lines waiting to be
sent. The first time it starts, Vector also ships what is already in the log files.

**Check `docker logs vector` after the first minute.** If the bucket's name or the key is wrong, Vector
does not wait: it drops what the storage refuses. Vector's start-up health check also lists the bucket,
which a write-only key may not do; if that is the only error, set `healthcheck: { enabled: false }`
under the sink.

### 4. The merge job, in one Rails app

```ruby
# Gemfile
gem "logsafe"
gem "aws-sdk-s3", ">= 1.197" # for S3-compatible storage
gem "google-cloud-storage"  # for Google Cloud Storage
```

```ruby
# config/initializers/logsafe.rb, one of:
Logsafe.storage = { s3: "my-logs", region: "eu-west-1" }
Logsafe.storage = { s3: "my-logs", region: "ams3", endpoint: "https://ams3.digitaloceanspaces.com",
                    access_key_id: "…", secret_access_key: "…" }
Logsafe.storage = { gcs: "my-logs", project_id: "my-project", credentials: "/path/to/key.json" }
Logsafe.storage = "/mnt/logs"
```

What follows the bucket's name goes to `Aws::S3::Resource.new` or `Google::Cloud::Storage.new` as it
is. Without keys, each library looks where it usually does, such as `AWS_ACCESS_KEY_ID`. For storage
of another kind, give `Logsafe.storage` an object of your own; the five methods it needs are listed in
[lib/logsafe/storage.rb](lib/logsafe/storage.rb).

Then have `Logsafe::MergeJob` run **every hour**. It is a plain Active Job, so it runs on the backend
your app already uses:

```yaml
# Solid Queue, config/recurring.yml
production:
  merge_logs:
    class: Logsafe::MergeJob
    schedule: "30 * * * *"
```

```yaml
# Sidekiq with sidekiq-cron, config/schedule.yml
merge_logs:
  cron: "30 * * * *"
  class: Logsafe::MergeJob
```

```ruby
# GoodJob, config/application.rb
config.good_job.enable_cron = true
config.good_job.cron = { merge_logs: { cron: "30 * * * *", class: "Logsafe::MergeJob" } }
```

```
# Anything else, or no job backend at all: cron
30 * * * * cd /app && bin/rails runner "Logsafe.merge"
```

Why every hour: the first run after midnight UTC writes the day's file, and the run after it removes
the parts, once it has found every one of their lines in that file. A run with nothing to do only
lists the bucket.

- **Name your streams** in `config/initializers/logsafe.rb`, as they are in your containers' labels:

  ```ruby
  Logsafe.streams = %w[shop-prod-web shop-prod-worker]
  ```

  Then nothing else is merged, shown on the page or encrypted again, however many other names a server
  that was broken into makes up. A stream you forget to name is not lost: its parts stay, and every
  run says in the worker's log which names it left alone. Without the list, every stream is taken.
- **One app is enough.** Without arguments the job merges every stream in the storage, so one Rails app
  can do it for all your apps. If several apps run the job on the same storage, give each its own
  streams: `Logsafe::MergeJob.perform_later("shop-prod-web", "shop-prod-worker")`.
- **It can be run again at any time.** A run that fails deletes nothing, one day that fails does not
  hold up the others, and parts that arrive late are added to their day's file. Several runs at the
  same time do not lose each other's lines: a day's file is only replaced by a run that has read the
  latest one. Amazon S3 and Google Cloud Storage see to that themselves, and a folder does it with a
  lock. With an S3-compatible storage that does not know conditional writes, or a network share without
  locks, a moment between the look and the write is left.
- **A run ends after 50 minutes** and leaves the rest to the next one. Parts of a date more than a year
  ago are left alone.
- **A part that cannot be read** stays where it is. The others are merged without it, and the run
  fails with its name, every hour until you have looked at it and removed it. That is a part that is
  damaged, unpacks to more than 256 MB, has a line of more than 2 MB, or was encrypted with another key.
- **A line that does not start with a time of its day** gets the start of that day in front. Vector
  sends no such lines. What is not under `parts/<stream>/<date>/` is left alone, and counted in the
  worker's log.
- **Where it runs** it needs the `sort`, `gzip` and `df` commands, which every common Linux image has,
  and free disk in the temporary folder for about four times a day's logs, uncompressed. With less
  than that the day fails and nothing is changed, so that the disk is not filled.
  On Alpine, add `apk add coreutils` to the image: the `sort` Alpine comes with keeps the whole day
  in memory.
- **Watch that it succeeds**, the way you watch your other jobs. A merge that fails silently leaves you
  with parts, not with nothing, but the parts keep piling up.

## Reading the logs

```sh
aws s3 cp s3://my-logs/2026/11/shop-prod.2026-11-24.log.gz - | gzip -dc | grep "OrdersController"
```

Today's lines are still in parts:

```sh
aws s3 cp s3://my-logs/parts/shop-prod/$(date -u +%F)/ today --recursive
gzip -dc today/* | LC_ALL=C sort | less
```

### In the browser

`Logsafe::Web` is a page to read and search the logs on: pick the days (today unless you say
otherwise), a stream and a level, type words, and read the lines that match, the newest at the bottom.
It reads the day's files and the parts together, so today's lines are there too, and it decrypts with
`Logsafe.key`.

It is a Rack app, so you mount it where you want it, in the app that has `Logsafe.storage` set:

```ruby
# config/routes.rb
authenticate :user, ->(user) { user.admin? } do   # Devise
  namespace :admin do
    mount Logsafe::Web, at: "logsafe", as: :logsafe   # /admin/logsafe, admin_logsafe_path
  end
end
```

**The page does not ask who is looking, and whoever reaches it reads every log.** A `namespace :admin`
block is not enough: a mounted app does not go through your controllers, so their `before_action` does
not guard it. Without Devise, use a constraint that reads your session:

```ruby
mount Logsafe::Web, at: "admin/logsafe",
                    constraints: ->(request) { User.find_by(id: request.session[:user_id])&.admin? }
```

- **Words:** a line must hold every word you type, in any case (for the letters a to z). The first
  eight words count, and the first 16 KB of a line, which is as much as Docker puts in one.
- **Level:** Docker does not know a line's level, so the page looks for the word in the line: `ERROR`,
  `level=error` and `"level":"error"` are all found by "error". Lines without the word, such as the
  lines of a stack trace, are not. Rails' production logger does not print the level; give it a
  formatter that does, in `config/environments/production.rb`:

  ```ruby
  config.logger = ActiveSupport::TaggedLogging.new(Logger.new($stdout, formatter: Logger::Formatter.new))
  ```
- **It shows 500 lines** at a time, with a link to the ones before. Times and days are UTC. A search
  spans seven days at most, and 50 streams: with more, choose one.
- **A search from another website** is not run. Its words and days are filled in, and you press Search.
  So a link to a search in a chat or a mail takes one click more. Browsers that do not say where a
  request comes from (`Sec-Fetch-Site`) are not asked.
- **The first search of a day waits** while the server fetches that day: its file, or for today every
  part so far. After that only new parts are fetched, and the storage is listed once a minute at
  most. A very large day can take longer than a proxy in front of your app allows. What was fetched
  is kept, a thousand parts at a time, so load the page again and it goes on from there. While one
  search fetches a day, another search for the same day is told so and does not wait.
- **The server keeps a copy** of each day you search, in plain text, in a folder of its own in the
  temporary folder, until nobody has searched that day for 30 minutes or the app stops. An app that
  is killed leaves its copies there until the next search on that server. It needs the disk for those
  days, uncompressed, and about four times a day's size more while it fetches one; and the `sort`,
  `gzip`, `grep`, `awk`, `cut`, `tail` and `df` commands. The copies never take more than they leave
  free: the ones not used for longest go first. Each server keeps its own copies: with several servers
  behind a load balancer, each fetches a day the first time a search for it lands there.
- **What cannot be read is named on the page**, and the rest is shown: a part that is damaged or was
  encrypted with another key, or a stream whose day's file was.
- **New lines** appear once Vector has shipped them and the storage is listed again: one to two
  minutes, or up to four with a folder.
- **Run the merge job no more often than every half hour** if you use the page. A copy knows what it
  holds by the names of the files. A part that arrives late for a finished day is listed for as long
  as two merges are apart, and a copy that is in use all that time sees it only if that is longer
  than the 30 minutes a copy can go unused.

## Lograge and other loggers

Logsafe does not touch your app's logger. It ships what the container writes to STDOUT, so lograge,
semantic_logger, tagged logging and JSON formatters work as they are. The one thing to check is that
they write to STDOUT and not to a file.

[Lograge](https://github.com/roidrage/lograge) goes well with the page. A request is one line, so a
search shows all of it, and its fields are words you can search for:

| Lograge writes | Search for | The level "error" finds |
| --- | --- | --- |
| key=value, its default | `status=500` | nothing: the line has no level |
| key=value, with the formatter from [Level](#in-the-browser) above | `status=500` | what is logged as an error; a failed request is logged as info |
| JSON, with a `level` of its own | `"status":500` | requests that raised an error |

For the last one:

```ruby
# config/environments/production.rb
config.lograge.enabled = true
config.lograge.formatter = Lograge::Formatters::Json.new
config.lograge.custom_options = ->(event) { { level: event.payload[:exception] ? "error" : "info" } }
```

Words are found in the text of a line and nothing else: `status=500` also finds `status=5001`, and
there is no search by field.

## Encryption

Without a key, whoever can read the storage can read the logs. With one, they cannot read what the
lines say: Vector encrypts every line before it leaves the server, and the merge job writes each
day's file encrypted, as `shop-prod.2026-11-24.log.gz.enc`. The names of the files, the length of each
line in a part and, to the nearest 64 KB, the size of a day's file stay visible.

Make a key once:

```sh
bundle exec logsafe key
```

**Keep a copy somewhere safe. Without the key nobody can read the logs, you included.**

Give the same key to both sides, the app first: an app with the key reads plain parts too, but an app
without it cannot merge what Vector has encrypted.

- **The merge job:** `Logsafe.key = ENV.fetch("LOGSAFE_KEY")` in `config/initializers/logsafe.rb`, or
  take it from your Rails credentials.
- **Vector, on every app server:** add a line `LOGSAFE_KEY=…` to `/etc/vector/keys`. Copy
  [shipper/start](shipper/start) and [shipper/vector.yaml](shipper/vector.yaml) again if yours are from
  before there was encryption: an older `vector.yaml` ignores the key. Then remove the running
  container with `docker rm -f vector` and start it again with the same `docker run` as in Setup.
  Removing it loses nothing, the `vector-data` volume stays; `docker restart` is not enough, because
  it does not read the key again.

  **Check each server:** a minute or two later, every line in its newest parts starts with `enc:`. A
  server you missed keeps sending plain text, and nothing else will tell you.

To read a day, with the key in `LOGSAFE_KEY`. `logsafe` is the gem's command: `bundle exec logsafe`
in the app, or plain `logsafe` after `gem install logsafe` on your own machine.

```sh
aws s3 cp s3://my-logs/2026/11/shop-prod.2026-11-24.log.gz.enc day.enc
logsafe decrypt day.enc | gzip -dc | grep "OrdersController"
```

Today's lines, from the parts, need the stream and the day as well. A part that cannot be read is
named, and the others are printed.

```sh
aws s3 cp s3://my-logs/parts/shop-prod/$(date -u +%F)/ today --recursive
logsafe decrypt shop-prod $(date -u +%F) today/* | LC_ALL=C sort | less
```

- **A key that is not one stops Vector from starting.** `start` checks that `LOGSAFE_KEY` is 32 bytes
  in Base64 with nothing around it, such as quotes. If it is not, it says so in `docker logs vector`
  and the container keeps restarting. Nothing is lost meanwhile: the lines wait in Docker's log
  files. Vector itself cannot refuse a key, so started without `start` it drops every line it cannot
  encrypt. With no key at all it ships plain text, and the merge accepts that.
- **You can turn it on later.** Parts from before are merged as they are, into encrypted files. A
  day's file from before stays plain until you run `Logsafe::ReencryptJob.perform_later`, or
  `bin/rails runner "Logsafe.reencrypt"`: that encrypts every plain day's file, and every plain line
  still in the parts. Run it a few minutes after Vector has the key on every server. More about the
  job under [Changing the key](#changing-the-key).
- **Parts take more room.** An encrypted line hardly compresses, so a day's parts are about as large
  as its logs, uncompressed, until the day is merged. A day's file is compressed before it is
  encrypted and stays small.
- **What is encrypted cannot be changed unnoticed.** `logsafe decrypt`, the page and the merge job
  refuse an encrypted file or line that was changed, that another key encrypted, or that belongs to
  another stream or day, and a file that is named as encrypted and is not. It promises no more than
  that: someone who can write to the storage can still add plain lines of their own, remove files, or
  put back an earlier version of the same day's file.
- **How well lines compress can say something about them.** Someone who can add lines and see the sizes
  of the files could guess at what other lines of that day say, one merge at a time, because similar
  lines compress together. Sizes are rounded to 64 KB, which makes that slow and not impossible. Keep
  secrets out of the logs, encrypted or not.
- **The key is on every app server.** A server that is broken into has it, and with it can read
  whatever of the storage it can reach. Keep the server's storage key write-only, as in Setup.
- **One storage, one key.** Every app that merges in this storage needs the same key, and the job
  that encrypts what is already there takes everything in it, whichever app's streams they are, unless
  `Logsafe.streams` names the ones that are yours.
- **Earlier versions stay as they were.** If the bucket keeps versions, as Setup recommends, then
  whatever was replaced or removed is still there as an earlier version, in plain text or under an
  old key, until your lifecycle rule removes it. Remove those versions yourself if the plain text
  must go, or if an old key has leaked.
- **Where the logs are still readable:** on the app servers, in Docker's log files, in the merge
  job's temporary folder while it works, and, if you use the page in the browser, in its copies of
  the days that were searched in the last 30 minutes.

The formats are described in [lib/logsafe/cipher.rb](lib/logsafe/cipher.rb): AES-256-GCM for a day's
file, ChaCha20-Poly1305 for a line.

### Changing the key

1. Make a new key with `logsafe key`.
2. In the app, make it the key and keep the old one beside it:

   ```ruby
   Logsafe.key = ENV.fetch("LOGSAFE_KEY")
   Logsafe.old_keys = ENV["LOGSAFE_OLD_KEYS"] # one key, or several with commas between them
   ```

   From now on everything is read with either key and written with the new one.
3. Give Vector the new key on every app server: change `LOGSAFE_KEY`, then remove the container and
   run it again, as when you turned encryption on. `docker restart` would keep the old key.
4. Five minutes later, run `Logsafe::ReencryptJob.perform_later`, or
   `bin/rails runner "Logsafe.reencrypt"`. It encrypts with the new key every day's file and every
   line in the parts that the new key does not open: what the old key encrypted, and what was never
   encrypted. The wait is for what Vector had already encrypted with the old key, which it sends
   within a minute, and for a folder, where a part is left alone for two minutes.
5. When it has succeeded, take the old key out of `Logsafe.old_keys`. The runner has succeeded when
   it ends without an error; the job, when your job backend shows it finished and not failed. The
   current files in the storage need the old key no more. Keep your own copy of it until a few days
   of merges have succeeded, and until the earlier versions in the bucket are gone.

- **The job reads everything in the storage**, so it takes a while on a large archive. It can be run
  again at any time: what the new key already opens is left as it is. A file that fails does not
  hold up the others; the job names it on STDERR, in the worker's log, and fails at the end.
- **A day's plain file is removed only after a check.** The job writes the encrypted file, reads it
  back from the storage, and removes the plain one once every line of it is found there.
- **A line can still arrive under the old key** after the job has run: from a server you had not
  given the new key yet, or from lines Vector was holding while the storage was down. Nothing is
  lost. The merge of that day says so and fails, and those parts stay until the old key is back in
  `Logsafe.old_keys` and the merge has run again.
- **`logsafe decrypt`** takes old keys from `LOGSAFE_OLD_KEYS`.

## Reference

What is listed here is what you can count on from one patch version to the next. Until 1.0 a minor
version can change it, and [CHANGELOG.md](CHANGELOG.md) says so. Everything else in the gem is for its
own use.

### Settings

Set them in `config/initializers/logsafe.rb`. None is read from the environment by itself.

| Setting | What it takes | Without it |
| --- | --- | --- |
| `Logsafe.storage` | a path, `{ folder: path }`, `{ s3: bucket, … }`, `{ gcs: bucket, … }` or [an object of your own](#storage-of-your-own) | nothing works |
| `Logsafe.streams` | the names of the streams that are merged, shown and encrypted again | every stream |
| `Logsafe.key` | a key from `logsafe key` | nothing is encrypted, and what is cannot be read |
| `Logsafe.old_keys` | keys that were in use before: a list, or one text with commas between them | only `Logsafe.key` reads |

### Jobs and methods

| Job | The same, without a job | What it does |
| --- | --- | --- |
| `Logsafe::MergeJob.perform_later(*streams)` | `Logsafe.merge(*streams)` | Merges the finished days of these streams, or of all. Run it every hour. |
| `Logsafe::ReencryptJob.perform_later` | `Logsafe.reencrypt` | Encrypts with the key in use what is plain or under an old key. Run it after the key was set or changed. |
| | `Logsafe.generate_key` | A new key, as `logsafe key` prints it. |
| | `Logsafe.decrypt(from, into)` | Writes the gzip of a day's encrypted file to a path. |

`Logsafe::Web` is a Rack app and takes no settings. What Logsafe itself refuses is a `Logsafe::Error`;
what a storage raises, such as a network error, is passed on as it is.

### The command line

| Command | What it does |
| --- | --- |
| `logsafe key` | Prints a new key. |
| `logsafe decrypt FILE` | Prints a day's file as gzip. |
| `logsafe decrypt STREAM YYYY-MM-DD PART…` | Prints the lines of these parts, of that stream and day. |

The keys come from `LOGSAFE_KEY` and `LOGSAFE_OLD_KEYS`. It needs neither Rails nor a storage.

### Storage of your own

Any object with these five methods can be `Logsafe.storage`. What each has to promise is written in
[lib/logsafe/storage.rb](lib/logsafe/storage.rb), and `Logsafe::Storage::GCS` there is a short example.

| Method | What it does |
| --- | --- |
| `keys(prefix)` | The keys that start with the prefix. |
| `fetch(key, path)` | Copies a key's content to a local file. Several threads call it at once. |
| `version(key)` | What tells the content the key has now from any other, or nil when there is none. |
| `store(path, key, was)` | Copies a local file to the key if it still has the version `was`, and otherwise raises `Logsafe::Storage::Changed.new(key)`. |
| `delete(keys)` | Removes them. One that is gone already is no failure. |

Give it a `to_s` that says which storage it is, so that the page keeps two of them apart.

## Good to know

- **One file per day** holds once the day is over and two merges have run. During the day there are
  parts.
- **Order** is the time Docker received each line, to the nanosecond, across containers and servers.
  It is as good as the servers' clocks; keep them synchronised (NTP).
- **A line sent twice is kept once.** Vector can send a batch twice after a failure; the merge drops
  the copy. The cost: two identical lines with the same nanosecond time become one.
- **Lines over 16 KB** are cut into pieces by Docker, and stay in pieces.
- **A line Vector can't read** as Docker's format is kept under the stream `unparsed`.
- **In a folder** the parts are plain text, a new file per server every minute, and the job leaves a
  part alone until it has not changed for two minutes.
- **A copy on a local disk:** point `aws s3 sync` or `rclone` at the year folders from the machine that
  has the disk.
- **Personal data:** keep passwords, tokens and personal data out of logs (`filter_parameters` in
  Rails), and decide how long production logs are kept.

## What has been run

`shipper/test` runs every check on one machine with Docker:

- The whole path, for an S3 stand-in and for a folder: labelled containers write, Docker rotates a log
  file, Vector is restarted on the way, and the merge must end with one complete, sorted file.
- The S3 and Google Cloud Storage code against local stand-ins.
- Vector's own tests of how lines are rewritten, and the validity of all three storage files.
- The whole path once more with a key, for the S3 stand-in: the parts hold only encrypted lines, and
  the merge job opens what Vector encrypted.
- `shipper/start` with keys that are not keys, with a key and with none.

`bundle exec rake` runs the part that needs no Docker: order, duplicates, late parts, a run that
fails, today left alone, encryption with a right, a wrong and a missing key, a change of key with
everything encrypted again, plain files and lines encrypted afterwards, the jobs through Active
Job, and the page in the browser as a Rack app: its searches, an address that was made up, a fetch
that is cut off, a part that is removed meanwhile, two searches for one day, and the removal of its
copies. And what someone could do who may write parts, or to the storage: parts that unpack to very
much or cannot be read, lines of another day, streams and dates that were made up, links in a folder,
encrypted files that were swapped, and searches that another website starts. Several runs at the same
time, with each kind of storage.

By hand, with the built gem installed: the page mounted in a Rails app, in a namespace and behind the
session constraint above, and the merge through Active Job, on Rails 7.1 with Ruby 3.3 and on Rails 8.1
with Ruby 4.0. What the page finds of lograge's lines, on Rails 8.1.

Not run: the Devise example; real AWS, Google or DigitalOcean storage; Vector sending to Google Cloud Storage (the stand-in
refuses the kind of upload Vector makes); Kamal; the scheduling examples above, which follow each
tool's documentation; more than one server; long outages; folder permissions on Linux.

## Development

```sh
bin/setup            # installs what is needed
bundle exec rake     # specs and RuboCop
shipper/test         # the same specs and the ones that need Docker: run this after a change to shipper/ or storage
```

Bug reports and pull requests are welcome on [GitHub](https://github.com/TTD93/LogSafe). Please don't
paste real log lines or keys into an issue.

To publish a version: set it in `lib/logsafe/version.rb`, run `bundle install`, name it with its date in
[CHANGELOG.md](CHANGELOG.md), merge to `master`, wait for CI, and run `bundle exec rake release` there.
That builds the gem, pushes the tag, and pushes the gem to RubyGems, which asks for a second factor.

## Disclaimer

Logsafe comes as is, without warranty of any kind, and its authors are not liable for any loss or damage
from using it. The [license](LICENSE.txt) has the exact terms.

Log lines can be lost, for instance when a server's disk dies before Vector has sent them, or when a
container is removed while Vector is down. Don't make Logsafe the only place for anything you have to
keep, such as an audit trail or records the law requires. Save those in your database.

Try it on your own setup before you depend on it: [What has been run](#what-has-been-run) says what has
been tested and what has not. Your keys, who can reach the page and the storage, the personal data in
your logs and the storage bill are your responsibility. If you lose the encryption key, nobody can
recover the logs.

Logsafe is not affiliated with or endorsed by the makers of the products named in this README.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
