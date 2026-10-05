# Macron

Schedule commands on macOS using launchd. Edit a JSON config, run `macron reload`, and view run output in Console. Jobs missed during sleep run once after wake.

## Build and install

Requires macOS 13+ and Apple's command-line tools. Builds with `swiftc`; no dependencies.

```sh
./build.sh
./macron-arm64 install  # macron-x86_64 on Intel
```

The binary is installed at `~/Library/Application Support/Macron/bin/macron`. Add that directory to PATH to use the commands below. Installation creates a config with a disabled example job and applies any existing jobs.

## Configuration

Edit `~/.config/macron/jobs.json` directly or with `macron edit`:

```json
{
  "jobs": [
    {
      "name": "morning",
      "schedule": "0 9 * * *",
      "command": "date"
    }
  ]
}
```

Jobs require a unique name, a five-field numeric cron schedule, and a shell command. Optional fields: `directory` (absolute path), `environment` (variable overrides), and `enabled` (defaults to `true`). See [jobs.example.json](jobs.example.json).

Schedules support wildcards, lists, ranges, and steps (`*/15`). They use local time; Sunday is `0` or `7`. Commands run with `/bin/zsh -c`, defaulting to your home directory.

Run `macron reload` after changes. To unschedule a job, delete it from the config or set `enabled` to `false`, then reload. Invalid config leaves existing schedules active. If an affected job is running, retry reload after it finishes.

Jobs run while you're logged in. Overlapping runs are skipped; missed runs during sleep combine into one. There is no catch-up after shutdown or logout.

## Commands and logs

```sh
macron edit             # Uses $EDITOR, or vi
macron validate         # Check config
macron reload           # Update launchd jobs
macron list
macron run morning
macron status morning   # Latest run and launchd status
macron version
macron uninstall        # Keep config and run results
```

In Console, choose **Log Reports → macron.log** for run history (`~/Library/Logs/macron.log`). Logs include stdout/stderr, run IDs, duration, and exit status.

For live unified logs, select your Mac under **Devices**, click **Start (▶)**, and filter by subsystem `dev.abdus.apps.macron`. Trigger a run after starting the stream. Command output is public text.

```sh
log stream --style compact --predicate 'subsystem == "dev.abdus.apps.macron"'
log show --last 1h --style compact --predicate 'subsystem == "dev.abdus.apps.macron"'
```

## Development

```sh
./test.sh
ARCH=x86_64 VERSION=v1.2.3 ./build.sh
```

`v*` tag pushes build arm64 and x86_64 binaries and create a draft GitHub release with conventional-commit release notes.
