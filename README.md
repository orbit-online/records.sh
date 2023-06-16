# records.sh

A small (~200 lines) logging library for bash.  
Supports `cli`, `json`, `logfmt`, and custom formats.
Integrates with journald and Github actions.

## Contents

- [Usage](#usage)
- [Dependencies](#dependencies)
- [Environment variables](#environment-variables)
- [Formats](#formats)
  - [`cli`](#cli)
  - [`json`](#json)
  - [`logfmt`](#logfmt)
  - [Custom format](#custom-format)
- [Levels](#levels)
- [Tee'ing](#teeing)
- [journald integration](#journald-integration)
- [Exiting with an error](#exiting-with-an-error)
  - [Stacktraces](#stacktraces)
- [Github actions](#github-actions)
  - [Log groups](#log-groups)
- [Changing preferences](#changing-preferences)
- [Naming clashes](#naming-clashes)

## Usage

Source the script with `source "records.sh"` and log messages with the
lowercased [loglevel](#levels) as the function name:

```
debug 'Starting up.'
verbose 'Startup completed'
info 'Hello world!'
warning 'Careful!'
error 'Oh no!'
```

The method signature of the logging functions mimic that of `printf`:
`info FORMAT [ARGS...]`. Which means you can format variables.

```
$ var=0x1f
$ info "The decimal version of %s is %d" "$var" "$var"
example.sh: The decimal version of 0x1f is 31
```

All log messages are output to stderr. If you want to log something to stdout
simply run e.g. `info 'message' 2>&1`.

## Dependencies

The `json` and `logfmt` formats require `jq`. Invoking `jq` for every log line
is not super fast and could probably be optimized by using some internal bash
JSON escaping (however, safe JSON escaping is a can of worms that should
probably be left unopened).

## Environment variables

- `$LOGPROGRAM`: Specifies the logging program. Defaults to `$(basename "$0")`
  This is especially useful when integrating multiple scripts, allowing you to
  determine the source of a message.
- `$LOGFORMAT`: Specifies the log format. Defaults to `cli`. See [Formats](#formats)
- `$LOGLEVEL`: Specifies the log level. Defaults to `info`. See [Levels](#levels)

`$LOGFORMAT` and `$LOGLEVEL` are case-sensitive.
Tip: If you are inheriting these variables from a parent process or passing them
on to a child process but the casing doesn't fit you can easily change that
with `${LOGLEVEL,,}` (for lowercasing) and `${LOGLEVEL^^}` (for uppercasing).

All environment variables are left unset, and you do not need to set them if
the defaults are fine. You also do not need to `export` the variables in order
for them to be available in bash subshells.

## Formats

Specify the log format by setting `$LOGFORMAT`

### `cli`

A human readable (custom) format.

```
example.sh: This is what a info log message looks like in the cli format
```

There are no timestamps in the `cli` format.  
When stderr is a tty (`[[ -t 2 ]]`) `warning` is colored yellow and `error` is
colored red, all other levels are the default color.

### `json`

```
{"timestamp":"2023-06-13T11:50:33+02:00","level":"info","program":"example.sh","message":"This is what a info log message looks like in the json format"}
```

It is not possible to add additional keys to the `json` log format.
`timestamp` is of course in ISO8601.

### `logfmt`

```
timestamp=2023-06-13T11:50:33+02:00 level=info program=example.sh message="This is what a info log message looks like in the logfmt format"
```

It is not possible to add additional keys to the `logfmt` log format.
`timestamp` is of course in ISO8601.

### Custom format

You can create your own log format by implementing the
`_records_output_${LOGFORMAT}` function.
The method signature is `level=$1 program=$2 message=$3`.

## Levels

The possible logging levels are (in that severity order):

|           |
| --------- |
| `error`   |
| `warning` |
| `info`    |
| `verbose` |
| `debug`   |

For example: Setting the `$LOGLEVEL` to `warning` causes all lower severity
levels (`info`, `verbose`, `debug`) to not be logged.

You can silence all logging by setting `$LOGLEVEL` to `silent`.  
Note that there is no `silent()` log function.

## Exiting with an error

You can use `fatal` to exit your script with an error message and exit code `1`:

```
fatal 'Encountered an error: %s' "$errout"
```

Optionally, you can change the exit code by prefixing the message with a number:

```
fatal 15 'Encountered an error: %s' "$errout"
fatal $retcode 'Encountered an error: %s' "$errout"
```

### Stacktraces

It is even possible to fail with a stacktrace by using `fatal_stacktrace`:

```
example.sh: Woops
    in fn_with_error: fatal_stacktrace 'Woops' # Way too long line to fit in a sta... (./example.sh:21)
    in intermediate_fn: fn_with_error (./example.sh:17)
    in log_all_levels: intermediate_fn (./example.sh:13)
    in main: log_all_levels (./example.sh:27)
```

## Tee'ing

When running other commands in bash it can be useful to hide their output during
normal operations but show it during debugging. You can do this with the
`tee_*()` functions (one for each loglevel). Their usage is rather
straightforward:

```
tar -xvf file.tar | tee_verbose
some-command --errors-only | LOGPROGRAM=some-command tee_error
```

If you want to tee stderr instead of stdout you can use redirects:

```
output=$(command-that-logs-to-stderr 2> >(LOGPROGRAM=command-that-logs-to-stderr tee_warning))
```

It is not possible to change the loglevel mid-stream.

## journald integration

When creating scripts that run on servers their log output might become
important at a later date. You can enable forwarding of all log messages to
journald by running `log_forward_to_journald true` (`false` to disable again).  
Regardless of the log level, all logs down to the `verbose` severity will be
forwarded. `debug` severity will be logged as well when `$LOGLEVEL=debug`.

Both normal log messages and `tee_*`'d log messages are forwarded.  
For timestamping `records.sh` relies on journald itself.  
`$LOGPROGRAM` is used to set the syslog identifier, meaning the logs can be retrieved with
`journalctl SYSLOG_IDENTIFIER=example.sh` (this is also logged verbosely when
calling `log_forward_to_journald`).  
Log levels are mapped to journald severities like this:

| records.sh | Syslog    |
| ---------- | --------- |
| `error`    | `error`   |
| `warning`  | `warning` |
| `info`     | `info`    |
| `verbose`  | `debug`   |
| `debug`    | `debug`   |

## Github actions

Github actions support a [`::debug::` log message prefix](https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#setting-a-debug-message),
which hides log messages [unless debug logging is enabled](https://docs.github.com/en/actions/monitoring-and-troubleshooting-workflows/enabling-debug-logging).

When `$GITHUB_ACTIONS=true` (which Github automatically sets for all workflows),
records.sh prefixes all log messages below the current log level with
`::debug::`. This is independent of the actual log format, which can be set to
whatever you like.

To explicitly disable this behavior set `$LOG_GITHUB_ACTIONS=false` (setting it
to `true` will explicitly enable it).

### Log groups

Github actions support grouping log messages with `::group::NAME`. To start and
end such groups use `log_begin_grp NAME` and `log_end_grp`. The groups are only
output when `$GITHUB_ACTIONS=true` (`$LOG_GITHUB_ACTIONS` also works here).

## Changing preferences

After changing logging settings it is advisable to verify that the new values
are valid (especially when doing it dynamically) to avoid weird error messages
like `_records_output_josn: command not found`.  
You can do this with `log_check_settings()` (it is run automatically when
sourcing `records.sh`).

## Naming clashes

All internal functions are prefixed with `_records` to avoid clashes.
If you run into naming clashes with the any of the function names and normal
commands, you can still access them by using `command` (e.g. `info` by calling
`command info`).
