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

  A server that is broken into can then neither read nor delete logs.
- Make one more key for the merge job, allowed to list, read, write and delete in the bucket.

**A folder (a disk on your own server, a network share, or your own machine in development)**

- Every app server and the machine that runs the merge job must see the same folder.
- Vector writes as root. The job must be allowed to delete what Vector wrote: run it as root, or give
  its user rights on the folder and on everything created in it later, for example
  `setfacl -R -m u:1000:rwX -m d:u:1000:rwX /mnt/logs`.

### 2. Your app's containers

Give each container a `logs` label with its stream name, tell Docker to write that label into the log
file, and limit the size of the log files. Containers without the label are not shipped.

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

Copy [shipper/vector.yaml](shipper/vector.yaml) to `/etc/vector/`, together with **one** of these, and
fill in the name of your bucket:

| Storage | File | The key |
| --- | --- | --- |
| S3-compatible | [shipper/to-s3.yaml](shipper/to-s3.yaml) | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in `/etc/vector/keys` |
| Google Cloud Storage | [shipper/to-gcs.yaml](shipper/to-gcs.yaml) | the service account's key file |
| Folder | [shipper/to-folder.yaml](shipper/to-folder.yaml) | none |

Then start it. For S3-compatible storage:

```sh
docker run -d --name vector --restart unless-stopped \
  --env-file /etc/vector/keys \
  -v /etc/vector:/etc/vector:ro \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v vector-data:/var/lib/vector \
  timberio/vector:0.62.0-alpine \
  --config /etc/vector/vector.yaml --config /etc/vector/to-s3.yaml
```

For Google Cloud Storage, name `to-gcs.yaml` and replace the `--env-file` line with
`-e GOOGLE_APPLICATION_CREDENTIALS=/etc/vector/key.json`. For a folder, name `to-folder.yaml` and
replace it with `-v /mnt/logs:/logs`.

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
of another kind, give `Logsafe.storage` an object of your own; the four methods it needs are listed in
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

- **One app is enough.** Without arguments the job merges every stream in the storage, so one Rails app
  can do it for all your apps. If several apps run the job on the same storage, give each its own
  streams: `Logsafe::MergeJob.perform_later("shop-prod-web", "shop-prod-worker")`.
- **It can be run again at any time.** A run that fails deletes nothing, one day that fails does not
  hold up the others, and parts that arrive late are added to their day's file.
- **Where it runs** it needs the `sort` and `gzip` commands, which every common Linux image has, and
  free disk in the temporary folder for about three times a day's logs, uncompressed.
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
  eight words count.
- **Level:** Docker does not know a line's level, so the page looks for the word in the line: `ERROR`,
  `level=error` and `"level":"error"` are all found by "error". Lines without the word, such as the
  lines of a stack trace, are not. Rails' production logger does not print the level; give it a
  formatter that does, for example
  `config.logger = ActiveSupport::TaggedLogging.logger(STDOUT, formatter: Logger::Formatter.new)`.
- **It shows 500 lines** at a time, with a link to the ones before. Times and days are UTC. A search
  spans seven days at most.
- **The first search of a day waits** while the server fetches that day: its file, or for today every
  part so far. After that only new parts are fetched, and the storage is listed once a minute at
  most. A very large day can take longer than a proxy in front of your app allows. What was fetched
  is kept, a thousand parts at a time, so load the page again and it goes on from there. While one
  search fetches a day, another search for the same day is told so and does not wait.
- **The server keeps a copy** of each day you search, in plain text, in a folder of its own in the
  temporary folder, until nobody has searched that day for 30 minutes. It needs the disk for those
  days, uncompressed, and about three times a day's size more while it fetches one; and the `sort`,
  `gzip`, `grep`, `awk` and `tail` commands. Each server keeps its own copies: with several servers
  behind a load balancer, each fetches a day the first time a search for it lands there.
- **One stream that cannot be read**, because a part is damaged or was encrypted with another key,
  is named on the page, and the other streams are shown.
- **New lines** appear once Vector has shipped them and the storage is listed again: one to two
  minutes, or up to four with a folder.
- **Run the merge job no more often than every half hour** if you use the page. A copy knows what it
  holds by the names of the files. A part that arrives late for a finished day is listed for as long
  as two merges are apart, and a copy that is in use all that time sees it only if that is longer
  than the 30 minutes a copy can go unused.

## Encryption

Without a key, whoever can read the storage can read the logs. With one, they cannot read what the
lines say: Vector encrypts every line before it leaves the server, and the merge job writes each
day's file encrypted, as `shop-prod.2026-11-24.log.gz.enc`. The names of the files, their sizes and
the length of each line in a part stay visible.

Make a key once:

```sh
bundle exec logsafe key
```

**Keep a copy somewhere safe. Without the key nobody can read the logs, you included.**

Give the same key to both sides, the app first: an app with the key reads plain parts too, but an app
without it cannot merge what Vector has encrypted.

- **The merge job:** `Logsafe.key = ENV.fetch("LOGSAFE_KEY")` in `config/initializers/logsafe.rb`, or
  take it from your Rails credentials.
- **Vector, on every app server:** add a line `LOGSAFE_KEY=…` to `/etc/vector/keys`, or
  `-e LOGSAFE_KEY=…` to the `docker run` if you don't use that file. Copy
  [shipper/start](shipper/start) to `/etc/vector/`, and [shipper/vector.yaml](shipper/vector.yaml)
  again if yours is from before there was encryption: an older one ignores the key. Then remove the
  running container with `docker rm -f vector` and start Vector through `start`. Removing it loses
  nothing, the `vector-data` volume stays; `docker restart` is not enough, because it does not read
  the key again.

  ```sh
  docker run -d --name vector --restart unless-stopped \
    --env-file /etc/vector/keys \
    -v /etc/vector:/etc/vector:ro \
    -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
    -v vector-data:/var/lib/vector \
    --entrypoint sh timberio/vector:0.62.0-alpine /etc/vector/start \
    --config /etc/vector/vector.yaml --config /etc/vector/to-s3.yaml
  ```

  **Check each server:** a minute or two later, every line in its newest parts starts with `enc:`. A
  server you missed keeps sending plain text, and nothing else will tell you.

To read a day, with the key in `LOGSAFE_KEY`. `logsafe` is the gem's command: `bundle exec logsafe`
in the app, or plain `logsafe` after `gem install logsafe` on your own machine.

```sh
aws s3 cp s3://my-logs/2026/11/shop-prod.2026-11-24.log.gz.enc day.enc
logsafe decrypt day.enc | gzip -dc | grep "OrdersController"
```

Today's lines, from the parts, need the stream and the day as well. In a folder the parts are not
compressed: use `cat` in place of `gzip -dc`.

```sh
aws s3 cp s3://my-logs/parts/shop-prod/$(date -u +%F)/ today --recursive
gzip -dc today/* | logsafe decrypt shop-prod $(date -u +%F) | LC_ALL=C sort | less
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
- **What is encrypted cannot be changed unnoticed.** `logsafe decrypt` and the merge job refuse an
  encrypted file or line that was changed, or that another key encrypted. It promises no more than
  that: someone who can write to the storage can still add plain lines, or put one day's encrypted
  file in the place of another's.
- **One storage, one key.** Every app that merges in this storage needs the same key, and the job
  that encrypts what is already there takes everything in it, whichever app's streams they are.
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
  lost. The merge of that day fails and says so, and its parts stay until the old key is back in
  `Logsafe.old_keys` and the merge has run again.
- **`logsafe decrypt`** takes old keys from `LOGSAFE_OLD_KEYS`.

## What can still be lost

| What happens | What is lost |
| --- | --- |
| The app crashes or is killed | Nothing. A line written to STDOUT has already left the process. |
| The network or the storage is down | Nothing, for as long as it fits on the server: 1 GB in Vector's buffer, then Docker's own log files up to their limit. |
| The merge job or the job backend is down | Nothing. The parts wait. |
| The server loses power | The last few seconds, which the system had not yet written to disk. |
| The server's disk is destroyed | What was not sent yet: up to a minute. |
| A container is removed (`docker rm`, `--rm`, a deploy tidying up) | Its log file goes with it. Normally Vector has read all but the last second or less. If Vector was down, everything it had not read from that container. |
| Vector is down for a long time | Lines that Docker's rotation (`max-size` × `max-file`) removed meanwhile. |
| The bucket's name or the key is wrong | What Vector tried to send meanwhile. While the lines are still in Docker's log files you can get them back: correct the setting, remove the `vector-data` volume and start Vector again. It ships everything again, and the merge drops what it already has. |
| A file in the bucket is deleted or overwritten | Nothing, with versioning on. |

So watch that Vector is running and not logging errors, not only that the merge succeeds.

Nothing can promise that no line is ever lost without making the app wait for each line to be stored.
What must never be lost, such as an audit trail, belongs in your database, saved together with the
change it describes.

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
copies.

Not run: the page mounted in a Rails app, and the routing examples for it; real AWS, Google or
DigitalOcean storage; Vector sending to Google Cloud Storage (the stand-in
refuses the kind of upload Vector makes); Kamal; the scheduling examples above, which follow each
tool's documentation; more than one server; long outages; folder permissions on Linux.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
