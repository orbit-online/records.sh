#!/usr/bin/env bash

set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
source "$PKGROOT/records.sh"

log_all_levels() {
  local level levels=(debug verbose info warning error)
  for level in "${levels[@]}"; do
    $level 'This is what a %s log message looks like in the %s format' "$level" "$LOGFORMAT"
  done
}

intermediate_fn() {
  fn_with_error
}

fn_with_error() {
  fatal_stacktrace 'Woops' # Way too long line to fit in a stacktrace so hopefully it is shortened to a little less so it doesn't mess up the readability
}

LOGLEVEL=${debug:-$LOGLEVEL}

LOGFORMAT=cli
log_all_levels

var=0x1f
info "The decimal version of %s is %d" "$var" "$var"

log_begin_grp 'A "printf | pipe" demonstration'
# shellcheck disable=SC2209
printf 'piping\nlines\nworks\nlike this' | LOGPROGRAM=printf pipe_verbose
log_end_grp

LOGFORMAT=json
log_all_levels

LOGFORMAT=logfmt
log_all_levels

LOGFORMAT=cli
intermediate_fn
