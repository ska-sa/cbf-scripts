# resources:name:when       - last time we checked it
# resources:name:status     - what the user status is
# resources:name:type       - what type of resource it is
# resources:name:mode       - did the user decide its status
# resources:name:holder     - which subarray owns it
# resources:name:switch     - on which switch does it live

# special case: allows one to exclude devices in cmc.conf
declare -A resources_excluded

function reload_resource_exclusions()
{
  local key board

  for key in "${!resources_excluded[@]}" ; do
    unset resources_excluded[${key}]
  done

  for board in "${standby_resources[@]}" ; do
    resources_excluded[${board,,}]="${board,,}"
  done
}

### support functions ###################################

function init_resources()
{
  push_failure
  send_request   var-declare  "resources*"  map,readonly
  retrieve_reply var-declare

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to declare essential resource tracking state"
    return 1
  fi

  return 0
}

function compute_resources()
{
  local -A location_free
  local -A location_busy
  local -A location_pool
  local -A solution_pool
  local -a host_vector

  local prior key location instrument art engine failed best count take total word template target group holder prefix index actual status match

  push_failure

  fetch_var "resources"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables"
    return 1
  fi

# this requires the existence of a switch subfield

  for key in "${!var_result[@]}" ; do
    if [ "${key##*:}" = "switch" ] ; then
      location="${var_result[${key}]}"

      tmp="${key#resources:}"
      board="${tmp%%:*}"

      holder="${var_result[resources:${board}:holder]}"

      if [ -n "${holder}" ] ; then
        location_busy[${location}]="${holder}"
      else
        if [ -z "${location_free[${location}]}" ] ; then
          prior=0
          location_pool[${location}]="${board}"
        else
          prior="location_free[${location}]"
          location_pool[${location}]="${location_pool[${location}]} ${board}"
        fi
        location_free[${location}]=$[prior+1]
      fi
    fi
  done

# now location_free[$switch] should contain a number
#     location_pool[$switch] should contain a set of *free* boards
# and location_busy[$switch] be nonzero if somebody else already using a part of it

  local name

  for name in "${!location_free[@]}" ; do
    if [ -n "${location_busy[${name}]}" ] ; then
      kcpmsg "shared switch ${name} has ${location_free[${name}]} slots available namely ${location_pool[${name}]}"
    else
      kcpmsg "empty switch ${name} has ${location_free[${name}]} slots available namely ${location_pool[${name}]}"
    fi
  done

  push_failure

  fetch_var "instruments"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables"
    return 1
  fi

# now the hardcoded heuristics/rules
# BIG FAT WARNING: can't split same engine over multiple switches yet

  failed=""
  total=0

  while [ "$#" -ge 1 ] ; do

    instrument="$1"
    total=$[total+1]

    kcpmsg "checking if it is feasible to instantiate ${instrument}"

    for art in ${resource_types[*]} ; do
      for engine in ${engine_types[*]} ; do
        if [ "${var_result[instruments:${instrument}:resources:${art}:${engine}]}" -gt 0 ] ; then
          count=0
          for location in "${!location_free[@]}" ; do
            if [ -z "${location_busy[${location}]}" ] ; then
              if [ "${location_free[${location}]}" -ge "${var_result[instruments:${instrument}:resources:${art}:${engine}]}" ] ; then
                kcpmsg "switch ${location} has ${location_free[${location}]} ${engine} ${art} resources available which meets the requirement of ${var_result[instruments:${instrument}:resources:${art}:${engine}]}"
                if [ "${count}" -le 0 ] ; then
                  count="${location_free[${location}]}"
                  best="${location}"
                elif [ "${count}" -gt "${location_free[${location}]}" ] ; then
                  count="${location_free[${location}]}"
                  best="${location}"
                fi
              fi
            fi
          done

          if [ "${count}" -gt 0 ] ; then
            kcpmsg "selected switch ${best} which has ${count} available slots for ${engine} ${art} use"
            solution_pool[${art}:${engine}]=${best}
            location_free[${best}]=$[location_free[${best}]-${count}]
            kcpmsg -l debug "reduced free count on switch ${best} by ${count} to ${location_free[${best}]}"
          else
            kcpmsg -l warn "unable to satisfy the need for ${var_result[instruments:${instrument}:resources:${art}:${engine}]} ${art} boards need by ${instrument} ${engine}"
            failed=1
          fi

        else
          kcpmsg "instrument ${instrument} does not require any dynamic ${art} resources for ${engine}"
        fi
      done
    done

    shift
  done

  if [ -n "${failed}" ]; then
    return 2
  fi

  if [ -n "${!solution_pool[*]}" ] ; then
    kcpmsg "solution keys are ${!solution_pool[@]}"
    for name in "${!solution_pool[@]}" ; do
      art=${name%:*}
      engine=${name#*:}
      kcpmsg "proposing switch ${solution_pool[${name}]} to hold ${engine} ${art} resources"
    done
  fi

  if [ -z "${SUBARRAY}" ] ; then
    kcpmsg "not in a subarray thus operating in probe mode only"
    return 0
  fi

  if [ "${total}" -ne 1 ] ; then
    kcpmsg -l error "only able to allocate one instrument at a time"
    return 1
  fi

# Now the actual allocation step using solution_pool as a guide

  template=${CORR_TEMPLATE}/${instrument}

  kcpmsg "about to allocate resources for ${instrument} via ${template}"

  push_failure

  fetch_var "resources"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables for a second time"
    return 1
  fi

  push_failure

  for word in $(ike -k hosts ${template}) ; do
    engine="${word%%.*}"
    group="${word#*=}"
    host_vector=()

    for name in ${group//,/ } ; do
      match=""
      for art in ${resource_types[*]} ; do
        if [ "${name#${art^^}}" != "${name}" ] ; then
# TODO: could try to notice collisions, uniq ?
          host_vector+=(${name})
          match=${art}
        fi
      done
      if [ -z "${match}" ] ; then
        kcpmsg "reserving static resource ${name}"
        send_request   var-set  resources "${SUBARRAY}" string ":${name}:holder"
        retrieve_reply var-set
      fi
    done

    index=0

    kcpmsg "need to map placeholders ${host_vector[*]} to actual resources"
    actual=""

    for key in "${!var_result[@]}" ; do
      if [ "${index}" -lt "${#host_vector[@]}" ] ; then

        name="${host_vector[${index}]}"
        if [ -z "${actual}" ] ; then
          for art in ${resource_types[*]} ; do
            if [ "${name#${art^^}}" != "${name}" ] ; then
              actual=${art}
            fi
          done
        fi

        if [ -n "${actual}" ] ; then
# TODO: solution pool will be a set, not single-valued once the heuristics are smarter
          location="${solution_pool[${actual}:${engine}]}"
# WARNING - will also have to check if any element on switch hasn't also been allocated elsewhere behind our back - might end up implying a global lock

          if [ "${key##*:}" = "switch" ] ; then
            if [ "${location}" = "${var_result[${key}]}" ] ; then
              prefix="${key%:*}"
              holder="${var_result[${prefix}:holder]}"
              status="${var_result[${prefix}:status]}"

              if [ "${status}" = up ] ; then
                if [ -z "${holder}" ] ; then
                  tmp="${key#resources:}"
                  target="${tmp%%:*}"
                  kcpmsg "substituting ${name} on switch ${var_result[${key}]} with ${target}"

                  send_request   var-set  resources "${SUBARRAY}" string ":${target}:holder"
                  retrieve_reply var-set

                  export ${name}=${target}
                  index=$[index+1]
                  actual=""
                fi
              else
                kcpmsg "disqualifying ${prefix} for ${name} as its status is ${status}"
              fi
            fi
          fi
        else
          kcpmsg "no way of establishing resource type of ${name}"
          set_failure
          index=$[index+1]
        fi
      fi
    done
  done

  if [ "${index}" -lt "${#host_vector[@]}" ] ; then
    kcpmsg "resource pool could not supply ${#host_vector[@]} dynamic resources"
    set_failure
  fi


  if ! pop_failure ; then
    kcpmsg -l error "unable to assign needed resources to instrument ${instrument}"
    return 1
  fi

  return 0
}

function check_resources()
{
  local -l board
  local -i budget limit grace
  local now mode art status when fresh key tmp board holder network

  for art in ${resource_types[*]} ; do
    resource_free[${art}]=0
  done

# our initial grace period in seconds - makes allowance for skarabs to reboot
  budget=${CHECK_BUDGET:-10}

  now=$(date +%s)
  limit=$[now+budget]

  fresh=0

  kcpmsg "checking set of available resources"

# Fetch our existing set

  push_failure

  fetch_var "resources"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables"
    return 1
  fi

# Try to find new devices from the leases file

  push_failure

  for art in roach skarab ; do

    for board in $(grep ${art} ${leases} | cut -f4 -d ' ' ) ; do

      if [ -z "${var_result[resources:${board}:mode]}" ] ; then
        fresh=$[fresh+1]

        send_request   var-declare resources map      ":${board}"
        retrieve_reply var-declare

        send_request   var-set     resources "${art}" string ":${board}:type"
        retrieve_reply var-set

        send_request   var-set     resources auto     string ":${board}:mode"
        retrieve_reply var-set

        send_request   var-set     resources 0        string ":${board}:when"
        retrieve_reply var-set

        send_request   var-set     resources standby  string ":${board}:status"
        retrieve_reply var-set

# NOTE: special case: the 3rd octet of a scarab encodes its switch
        if [ "${art}" = "skarab" ] ; then
          network=$(grep -i "${board}" ${leases} | cut -f3 -d '.' | head -1 )
          if [ -n "${network}" ] ; then
            send_request   var-set     resources "${network}" string ":${board}:switch"
            retrieve_reply var-set
          fi
        fi

      fi
    done
  done

  if ! pop_failure ; then
    kcpmsg -l error "unable to identify new resources"
  fi

  if [ "${fresh}" -gt 0 ] ; then
    push_failure

    fetch_var "resources"

    if ! pop_failure ; then
      kcpmsg -l warn "unable to reacquire resource variables"
    fi
  fi

# WARNING: do we still use this global variable ?
  for art in roach skarab ; do
    resource_free[${art}]=0
  done

  push_failure

  for key in "${!var_result[@]}" ; do
    if [ "${key##*:}" = "when" ] ; then
      when="${var_result[${key}]}"
      if [ "$[when+checkperiod]" -le "${now}" ] ; then
        tmp="${key#resources:}"
        board="${tmp%%:*}"

        art="${var_result[resources:${board}:type]}"
#        status="${var_result[resources:${board}:status]}"
        mode="${var_result[resources:${board}:mode]}"
        holder="${var_result[resources:${board}:holder]}"

        if [ "${mode}" = "auto" ] ; then

          now=$(date +%s)

          if [ "${limit}" -gt "${now}" ] ; then
            grace=$[limit-now]
          else
            grace=1
          fi

          if [ -n "${resources_excluded[${board}]}" ] ; then
            status=standby
          else
            if [ "${art}" = "roach" ] ; then
              if kcpcmd -kir -f -t ${grace} -s "${board}" watchdog >& /dev/null ; then
                if [ -z "${holder}" ] ; then
                  resource_free[${art}]=${resource_free[${art}]+1}
                fi
                status=up
              else
                status=standby
              fi
            elif [ "${art}" = "skarab" ] ; then

              if ping -c 1 -w ${grace} "${board}" >& /dev/null ; then
                if [ -z "${holder}" ] ; then
                  resource_free[${art}]=${resource_free[${art}]+1}
                fi
                status=up
              else
                kcpmsg -l warn "ping failed on ${board} after timeout ${grace}"
                status=standby
              fi
            else
              status=standby
            fi
          fi

          if [ "${status}" != "${var_result[resources:${board}:status]}" ] ; then

            send_request   var-delete  "resources:${board}:status"
            retrieve_reply var-delete

            send_request   var-set     "resources" ${status} string ":${board}:status"
            retrieve_reply var-set

            kcpmsg "updated status of ${board} from ${var_result[resources:${board}:status]} to ${status}"
          fi

          send_request   var-delete  "resources:${board}:when"
          retrieve_reply var-delete

          send_request   var-set     "resources" ${now} string ":${board}:when"
          retrieve_reply var-set
        fi
      fi
    fi
  done

  if ! pop_failure ; then
    kcpmsg -l warn "unable to re-check resource status"
    return 1
  fi

  kcpmsg "completed checking resources"
  return 0
}
