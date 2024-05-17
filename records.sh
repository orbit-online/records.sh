#!/usr/bin/env bash

_records_fallback_loglevel=info
_records_fallback_logformat=cli
_records_fallback_program=$(basename "$0")

_records() {
  local format=$1 level=$2 program=$3 tpl=$4 message output_fn
        shift;    shift;   shift;     shift
  # shellcheck disable=SC2059
  message=$(printf -- "${tpl}" "$@")
  if ${LOG_GITHUB_ACTIONS:-${GITHUB_ACTIONS:-false}}; then
    output_fn=_records_github_actions
  elif [[ -z $format ]]; then
    output_fn=_records_output_${_records_fallback_logformat//-/_}
  else
    output_fn=_records_output_${format//-/_}
  fi
  "$output_fn" "$level" "$program" "$message"
  if ${LOG_TO_JOURNALD:-false}; then
    _records_journal "$level" "$program" "$message"
  fi
}

_records_pipe() {
  local format=$1 level=$2 program=$3 message output_fn
        shift;    shift;   shift
  if ${LOG_GITHUB_ACTIONS:-${GITHUB_ACTIONS:-false}}; then
    output_fn=_records_github_actions
  elif [[ -z $format ]]; then
    output_fn=_records_output_${_records_fallback_logformat//-/_}
  else
    output_fn=_records_output_${format//-/_}
  fi
  local message
  while IFS= read -r -d $'\n' message || [[ -n $message ]]; do
    "$output_fn" "$level" "$program" "$message"
    if ${LOG_TO_JOURNALD:-false}; then
      _records_journal "$level" "$program" "$message"
    fi
  done
}

# Returns 0 if left>=right, 1 if left<right
_records_level_ge() {
  local level_left=$1 level_right=$2
  case $level_left in
    debug) [[ $level_right = debug ]] && return 0 ;;
    verbose) [[ $level_right = debug || $level_right = verbose ]] && return 0 ;;
    info) [[ $level_right != warning && $level_right != error && $level_right != silent ]] && return 0 ;;
    warning) [[ $level_right != error && $level_right != silent ]] && return 0 ;;
    error) [[ $level_right != silent ]] && return 0 ;;
    silent) return 0 ;;
  esac
  return 1
}

log_forward_to_journald() {
  if ! type systemd-cat >/dev/null 2>&1; then
    LOGPROGRAM=log.sh warning 'systemd-cat not available, cannot forward logs to journald'
    return 0
  fi
  if [[ $1 != true && $1 != false ]]; then
    LOGPROGRAM=log.sh fatal_stacktrace "log_forward_to_journald() only accepts true or false as the first argument"
  elif [[ $LOG_TO_JOURNALD != true && $1 = true ]]; then
    # shellcheck disable=2097,2098
    verbose "Forwarding logs to journald, retrieve them with \`journalctl SYSLOG_IDENTIFIER=%s'" \
      "${LOGPROGRAM:-$_records_fallback_program}"
  elif [[ $LOG_TO_JOURNALD = true && $1 = false ]]; then
    # shellcheck disable=2097,2098
    verbose "No longer forwarding logs to journald"
  fi
  export LOG_TO_JOURNALD=${1:?}
}

_records_journal() {
  local level=$1 program=$2 message=$3 priority
  # Always log verbose and upwards, log debug as well when LOGLEVEL is debug
  if ! _records_level_ge "$level" "verbose" && [[ ${LOGLEVEL:-$_records_fallback_loglevel} != 'debug' ]]; then
    return 0
  fi

  # https://en.wikipedia.org/wiki/Syslog#Severity_level
  # https://github.com/secoya/operations/blob/f8fc760768f86f6e9206d53110078185443793ec/manifests/fluentd/config/base/dictionaries/levels.json
  case $level in
    debug|verbose) priority=7 ;;
    info) priority=6 ;;
    warning) priority=4 ;;
    error) priority=3 ;;
  esac
  # shellcheck disable=2086
  printf -- $'<%d>%s\n' "$priority" "$message" | \
    systemd-cat --identifier="${program:-$_records_fallback_program}"
}

_records_github_actions() {
  local level=$1 output_fn
  if [[ -z $format ]]; then
    output_fn=_records_output_${_records_fallback_logformat//-/_}
  else
    output_fn=_records_output_${LOGFORMAT//-/_}
  fi
  # Github hides ::debug:: logs. So we prefix any loglevel below the current one
  # with ::debug:: and output all logs.
  _records_level_ge "$level" "${LOGLEVEL:-$_records_fallback_loglevel}" || printf -- "::debug::" >&2
  LOGLEVEL=debug _records_output_cli "$@"
}

log_begin_grp() {
  if ${LOG_GITHUB_ACTIONS:-${GITHUB_ACTIONS:-false}}; then
    local executable=$1
    shift
    printf -- "::group::%s %s\n" "${executable#"$ORBIT_PATH/"}" "$*" >&2
  fi
  return 0
}

log_end_grp() {
  if ${LOG_GITHUB_ACTIONS:-${GITHUB_ACTIONS:-false}}; then
    printf -- "::endgroup::\n" >&2
  fi
  return 0
}

_records_output_cli() {
  local level=$1 program=$2 message=$3 program_prefix=''
  _records_level_ge "$level" "${LOGLEVEL:-$_records_fallback_loglevel}" || return 0
  program_prefix="${program:-$_records_fallback_program}: "
  if [[ $level = warning && -t 2 ]]; then
    printf -- $'\e[0;33m%s%s\e[0m\n' "$program_prefix" "$message"
  elif [[ $level = error && -t 2 ]]; then
    printf -- $'\e[0;31m%s%s\e[0m\n' "$program_prefix" "$message"
  else
    printf -- $'%s%s\n' "$program_prefix" "$message"
  fi
}

_records_output_json() {
  local level=$1 program=$2 message=$3
  _records_level_ge "$level" "${LOGLEVEL:-$_records_fallback_loglevel}" || return 0
  jq -cM \
    --arg timestamp "$(date -Iseconds)" --arg level "$level" \
    --arg program "${program:-$_records_fallback_program}" --arg message "$message" \
    '.timestamp=$timestamp | .level=$level | .program=$program | .message=$message' <<<'{}'
}

_records_output_logfmt() {
  local level=$1 program=$2 message=$3
  _records_level_ge "$level" "${LOGLEVEL:-$_records_fallback_loglevel}" || return 0
  if printf -- '%s' "$message" | grep -Pzq '[\x00-\x20]'; then
    message=$(jq -cM --arg msg "$message" '. = $msg' <<<'""')
  fi
  printf -- 'timestamp=%s level=%s program=%s message=%s\n' \
    "$(date -Iseconds)" "$level" "${program:-$_records_fallback_program}" "$message"
}

# Output a stacktrace (https://stackoverflow.com/a/62757929/339505)
_records_get_stacktrace() {
   local level=1 line_no file func linetxt
   while read -r line_no func file < <(caller $level); do
      linetxt=$(sed -n "${line_no}p" "${file}" | sed 's/ *//')
      linetxt=${linetxt# *}
      [[ ${#linetxt} -le 60 ]] || linetxt=${linetxt:0:60}...
      printf "    in %s: %s (%s:%d)\n" "$func" "$linetxt" "${file#"$PWD/"}" "$line_no"
      ((level++))
   done
}

log_check_settings() {
  case ${LOGLEVEL:-$_records_fallback_loglevel} in
    debug) ;; verbose) ;; info) ;; warning) ;; error) ;; silent) ;;
    *) fatal_stacktrace "Unknown \$LOGLEVEL: \`%s'" "$LOGLEVEL" ;;
  esac
  case ${LOGFORMAT:-$_records_fallback_logformat} in
    json|logfmt)
      if ! type jq >/dev/null 2>&1; then
        _log cli warning log.sh "logs.sh: jq not found. Falling back to '%s'." "$_records_fallback_logformat"
        unset LOGFORMAT
      fi
      ;;
    github-actions|github_actions)
      LOGFORMAT=cli fatal_stacktrace "'github-actions' is not a \$LOGFORMAT. It can only be enabled with GITHUB_ACTIONS=true"
      ;;
    *)
      if ! type "_records_output_${LOGFORMAT:-$_records_fallback_logformat}" >/dev/null 2>&1; then
        # shellcheck disable=2097,2098
        LOGFORMAT=cli fatal_stacktrace "Unknown \$LOGFORMAT: \`%s'" "$LOGFORMAT"
      fi
      ;;
  esac
}

debug() { _records "$LOGFORMAT" debug "$LOGPROGRAM" "$@" >&2; }
verbose() { _records "$LOGFORMAT" verbose "$LOGPROGRAM" "$@" >&2; }
info() { _records "$LOGFORMAT" info "$LOGPROGRAM" "$@" >&2; }
warning() { _records "$LOGFORMAT" warning "$LOGPROGRAM" "$@" >&2; }
error() { _records "$LOGFORMAT" error "$LOGPROGRAM" "$@" >&2; }
pipe_debug() { _records_pipe "$LOGFORMAT" debug "$LOGPROGRAM" >&2; }
pipe_verbose() { _records_pipe "$LOGFORMAT" verbose "$LOGPROGRAM" >&2; }
pipe_info() { _records_pipe "$LOGFORMAT" info "$LOGPROGRAM" >&2; }
pipe_warning() { _records_pipe "$LOGFORMAT" warning "$LOGPROGRAM" >&2; }
pipe_error() { _records_pipe "$LOGFORMAT" error "$LOGPROGRAM" >&2; }
_records_warn_tee() { warning "tee_* functions are deprecated. Use pipe_* instead."; }
tee_debug() { _records_warn_tee; _records_pipe "$LOGFORMAT" debug "$LOGPROGRAM" >&2; }
tee_verbose() { _records_warn_tee; _records_pipe "$LOGFORMAT" verbose "$LOGPROGRAM" >&2; }
tee_info() { _records_warn_tee; _records_pipe "$LOGFORMAT" info "$LOGPROGRAM" >&2; }
tee_warning() { _records_warn_tee; _records_pipe "$LOGFORMAT" warning "$LOGPROGRAM" >&2; }
tee_error() { _records_warn_tee; _records_pipe "$LOGFORMAT" error "$LOGPROGRAM" >&2; }

fatal() {
  local exit_code=1
  if [[ $1 =~ ^([0-9]+)$ ]]; then
    exit_code=$1
    shift
  fi
  error "$@"
  # shellcheck disable=2086
  exit $exit_code
}

fatal_stacktrace() {
  local exit_code=1
  if [[ $1 =~ ^([0-9]+)$ ]]; then
    exit_code=$1
    shift
  fi
  message=$1
  shift
  error "$message\n%s" "$@" "$(_records_get_stacktrace)"
  # shellcheck disable=2086
  exit $exit_code
}

log_check_settings
