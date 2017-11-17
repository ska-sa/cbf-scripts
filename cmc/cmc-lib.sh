### essential constants #################################

declare -a -r resource_types=(roach skarab)
declare -a -r engine_types=(fengine xengine)

configuration=${CMC_CONFIG:-/etc/cmc.conf}

### startup checks ######################################

if [ -f "${configuration}" ] ; then
  source "${configuration}"

  if [ "${state/verbose-log/}" != "${state}" ] ; then
    set -x
  fi

  leases=${LEASE_FILE:-/var/lib/misc/dnsmasq.leases}

elif [ -d "${TESTDIR}" ] ; then
  kcpmsg -l fatal "running in test mode using content of ${TESTDIR}"
  set -x

# bit risky, we stand a chance of missing some variables
  leases=${TESTDIR}/dnsmasq.leases
  instruments_deployed=(bc8n856M4k)

  CORR_TEMPLATE=${TESTDIR}

else
  kcpmsg -l fatal "no config file found and not in test mode"
  exit 1
fi

if [ ! -f "${leases}" ] ; then
  kcpmsg -l fatal "no lease file to be found"
fi

### queue library #######################################

declare -a queue_data
declare -i queue_tail=0

function clear_queue()
{
  local i=0

  while [ "${i}" -lt "${queue_tail}" ] ; do
    unset queue_data[${i}]
    i=$[i+1]
  done

  queue_tail=0
}

function add_queue()
{
  if [ "$#" -lt 1 ] ; then
    kcpmsg -l error "no parameters"
    return 1
  fi

  queue_data[${queue_tail}]="$*"

  kcpmsg -l debug "queue[${queue_tail}]: $*"

  queue_tail=$[queue_tail+1]
}

function show_queue()
{
  local i

  kcpmsg -l debug "#### dump start ####"

  i=0
  while [ "${i}" -lt "${queue_tail}" ] ; do
    kcpmsg -l debug "queue[${i}]: ${queue_data[${i}]}"
    i=$[i+1]
  done

  kcpmsg -l debug "#### dump end ####"
}

### error stack library #################################

declare -a failure_stack
declare -i failure_depth=0

function push_failure()
{
  failure_depth=$[failure_depth+1]
  failure_stack[${failure_depth}]=0
}

# pop failure to be used in if statement where we return or we are no longer interested in error codes
# clear failure to be used in if statements where there is no return

function pop_failure()
{
  result=${failure_stack[${failure_depth}]}

  kcpmsg -l trace "stack at ${failure_depth} has code ${result}"

  if [ "${failure_depth}" -gt "0" ] ; then
    failure_depth=$[failure_depth-1]
  else
    kcpmsg -l warn "unwound stack too far"
  fi

  return ${result}
}

function clear_failure()
{
  result=${failure_stack[${failure_depth}]}

  kcpmsg -l trace "stack at ${failure_depth} has code ${result}"

  failure_stack[${failure_depth}]=0

  return ${result}
}

function set_failure()
{
  failure_stack[${failure_depth}]=$[failure_stack[${failure_depth}]+1]
}

### io functions with failure stack #####################

send_count=0

function send_request()
{
  local name="$1"

  if [ -z "$name" ] ; then
    set_failure
    return 1
  fi

  if [ "${send_count}" -gt 0 ] ; then
    kcpmsg -l warn "sending ${name} request while ${send_count} request(s) still outstanding"
  fi

  send_count=$[send_count+1]

  echo -n "?${name}"
  shift

  while [ $# -gt 0 ] ; do
    echo -n " ${1// /\\_}"
    shift
  done

  echo
}

function retrieve_reply()
{
  local name="$1"
  local line art reply code
  local -a vector

  if [ -z "$name" ] ; then
    set_failure
    return 1
  fi

  while read line ; do
    art="${line:0:1}"
    if [ "${art}" = "?" ] ; then
      kcpmsg "deferring request ${line}"
      add_queue "${line}"
    else
      vector=(${line})
      reply=${vector[0]}

      if [ "${art}" = '#' ] ; then
        if [ -n "${inform_set[${reply:1}]}" ] ; then
          kcpmsg "deferring inform ${line}"
          add_queue "${line}"
        fi
      elif [ "${art}" = "!" ] ; then
        if [ "${reply:1}" = "${name}" ]; then
          send_count=$[send_count-1]
          code=${vector[1]}
          if [ "${code}" = "ok" ] ; then
            return 0
          else
            set_failure
            return 1
          fi
        else
          kcpmsg -l warn "discarding unexpected response ${reply:1}"
        fi
      fi
    fi
  done
}

declare -A inform_result

function retrieve_inform()
{
  local name="$1"
  local match="$2"
  local del line art reply label
  local -a vector

  for del in "${!inform_result[@]}" ; do
    unset inform_result[${del}]
  done

  while read line ; do
    art=${line:0:1}
    if [ "${art}" = "?" ] ; then
      add_queue ${line}
    else
      vector=(${line})
      reply="${vector[0]}"

      if [ "${art}" = '#' ] ; then
        if [ "${reply:1}" = "${name}" ] ; then
          label=${vector[1]}
          if [ -z "${match}" -o "${match}" = "${label}" ] ; then
            inform_result[${label}]="${line#* * }"
          fi
        elif [ -n "${inform_set[${reply:1}]}" ] ; then
          add_queue ${line}
        fi
      elif [ "${art}" = "!" ] ; then
        if [ "${reply:1}" = "${name}" ]; then
          send_count=$[send_count-1]
          code=${vector[1]}
          if [ "${code}" = "ok" ] ; then
            return 0
          else
            set_failure
            return 1
          fi
        else
          kcpmsg -l warn "discarding unexpected response ${reply:1}"
        fi
      fi
    fi
  done
}

declare -A var_result

function fetch_var()
{
  local match
  local del line art reply label
  local -a vector

  for del in "${!var_result[@]}" ; do
    unset var_result[${del}]
  done

  if [ "$1" = '-a' ] ; then
    shift
    echo "?var-show"
  else
    echo "?var-show $1"
  fi

  match=$1

  while read line ; do
    art=${line:0:1}
    if [ "${art}" = "?" ] ; then
      add_queue ${line}
    else
      vector=(${line})
      reply="${vector[0]}"

      if [ "${art}" = '#' ] ; then
        if [ "${reply}" = "#var-show" ] ; then
          label=${vector[1]}
          if [ -z "${match}" -o "${label}" != "${label#${match}}" ] ; then
            var_result[${label}]="${vector[2]}"
          fi
        elif [ -n "${inform_set[${reply:1}]}" ] ; then
          add_queue ${line}
        fi
      elif [ "${art}" = "!" ] ; then
        if [ "${reply}" = "!var-show" ]; then
          if [ "${vector[1]}" = "ok" ] ; then
            return 0
          else
            set_failure
            return 1
          fi
        else
          kcpmsg -l warn "discarding unexpected response ${reply:1}"
        fi
      fi
    fi
  done
}

## command loop ###################################

function enable_misc_informs()
{
  push_failure

  send_request   client-config info-all
  retrieve_reply client-config

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to inhibit logging to script"
    return 1
  fi

  return 0
}

function inhibit_logging()
{
  push_failure

  send_request   log-limit off
  retrieve_reply log-limit

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to inhibit logging to script"
    return 1
  fi

  return 0
}

## command loop ###################################

declare -a command_vector
declare -i command_size=0

function register_commands()
{
  local target name usage

  if [ "$#" -lt 1 ] ; then
    kcpmsg -l fatal "need to specify name of target to forward commands"
    return 1
  fi

  target="$1"

  push_failure

  for name in "${!command_set[@]}" ; do
    usage="${command_help[${name}]}"
    if [ -z "${usage}" ]; then
      usage="undocumented command handled by ${target}"
    fi

    send_request   forward-symbolic "${name}" "${target}"
    retrieve_reply forward-symbolic

    send_request   cmd-help "${name}" "${usage}"
    retrieve_reply cmd-help
  done

  if ! pop_failure ; then
    kcpmsg -l error "unable to register forwarded command handled by $target"
    return 1
  fi

  return 0
}

function make_vector()
{
  local i

  i=0
  while [ ${i} -lt ${command_size} ] ; do
    unset command_vector[$i]
    i=$[i+1]
  done

  command_size=0
  while [ $# -gt 0 ] ; do
    command_vector[${command_size}]=$1
    command_size=$[command_size+1]
    shift
  done

  kcpmsg -l debug "parsed ${command_size} parameters"
}

function main_loop()
{
  local k line string first cmd actual

  if [ -z "${!command_set[@]}" ] ; then
     kcpmsg -l fatal "no command set defined thus main loop pointless"
     exit 1
  fi

  while read line ; do
    add_queue ${line}
#  show_queue

    k=0
    while [ "${k}" -lt "${queue_tail}" ] ; do

      string="${queue_data[${k}]}"
      k=$[k+1]

      if [ "${string:0:1}" = "?" ] ; then
        make_vector ${string}

        first=${command_vector[0]}
        cmd=${first:1}

        if [ -z "${command_set[${cmd}]}" ] ; then
          kcpmsg -l warn "cmc primary got unsupported request ${cmd}"
          echo "!${cmd} fail unknown-item"
        else
          if [ "${command_size}" -lt "${command_set[${cmd}]}" ] ; then
            kcpmsg -l warn "need at least ${command_set[${cmd}]} parameters for ${cmd} but saw only ${command_size}"
            echo "!${cmd} fail usage"
          else
            actual=${cmd//-/_}
            ${actual} ${command_vector[@]}
          fi
        fi
      elif [ "${string:0:1}" = '#' ] ; then
        make_vector ${string}

        first=${command_vector[0]}
        cmd=${first:1}

        if [ -n "${inform_set[${cmd}]}" ] ; then
          if [ "${command_size}" -ge "${inform_set[${cmd}]}" ] ; then
            actual=${cmd//-/_}
            ${actual} ${command_vector[@]}
          fi
        fi
      fi

    done

    clear_queue

  done

  date "+%s: main loop exit with last command ${cmd}"
  kcpmsg "main loop exited with last command ${cmd}"
}
