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
  local key
  local -l board

  for key in "${!resources_excluded[@]}" ; do
    unset resources_excluded[${key}]
  done

  for board in "${standby_resources[@]}" ; do
    resources_excluded[${board}]="${board}"
  done
}

### support functions: multicast ########################

function init_multicast()
{
  push_failure
  send_request   var-declare  "multicast*" array,readonly
  retrieve_reply var-declare

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to declare essential multicast tracking state"
    return 1
  fi

  return 0
}

function compute_multicast()
{
  local template instrument word mutifix q fixed suffix
  local -i ceiling index got need already
  local -a address_vector fixed_vector

  instrument="$1"

  if [ -z "${instrument}" ] ; then
    kcpmsg -l error "need an instrument to compute multicast addresses"
    return 1
  fi

  template=${CORR_TEMPLATE}/${instrument}

  address_vector=()
  fixed_vector=()
  for word in $(ike -o -k output_destinations_base ${template}) ; do
    if [ "${word#MULTICAST}" != "${word}" ] ; then
      address_vector+=(${word%:*})
    else
      fixed_vector+=(${word%:*})
    fi
  done

  if [ -z "${MULTICAST_PREFIX}" ] ; then
    kcpmsg -l error "no multicast prefix defined"
    return 1
  fi

  q=${MULTICAST_PREFIX#*.*.}
  mutifix=${MULTICAST_PREFIX%$q}

  push_failure

  if [ -n "${fixed_vector[*]}" ] ; then
    kcpmsg "checking set of static multicast assignments"

    for fixed in "${fixed_vector[@]}" ; do
      suffix="${fixed#${mutifix}}"

      if [ "${suffix}" != "${fixed}" ] ; then

        index=${suffix%.*}

        if [ -n "${index}" ] ; then
          send_request   var-set  multicast "${SUBARRAY}" string "#${index}"
          retrieve_reply var-set
        else
          kcpmsg "unable to manage malformed multicast address ${fixed}"
        fi

      else
        kcpmsg "static address ${fixed} outside managed ${MULTICAST}/16 range so assumed to be unique"
      fi

    done
  else
    kcpmsg "no static output addresses found"
  fi

  if ! pop_failure ; then
    kcpmsg -l error "unable to reserve static output address set ${fixed_vector[*]} for array ${SUBARRAY}"
    return 1
  fi

  if [ -z "${address_vector[*]}" ] ; then
    kcpmsg "found no MULTICAST fields thus not allocating addresses dynamically"
    return 0
  fi

  kcpmsg "selecting multicast address ranges from ${mutifix}0.0/16"

  kcpmsg "need to find addresses for ${address_vector[*]}"

  need="${#address_vector[@]}"

  push_failure
  fetch_var "multicast"

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to retrieve multicast tracking state"
    return 1
  fi

  already="${#var_result[@]}"
  got=0
  index=0

  ceiling=$[already+need+1]
  if [ "${ceiling}" -gt 255 ] ; then
    kcpmsg -l error "unwilling to allocate a further ${need} address ranges given that the pool has ${already} already in use"
    return 1
  fi

  while [ "${got}" -lt "${need}" ] ; do
    if [ -z "${var_result[multicast#${index}]}" ] ; then
      push_failure

      send_request   var-set  multicast "${SUBARRAY}" string "#${index}"
      retrieve_reply var-set

      if pop_failure ; then
        export ${address_vector[${got}]}="${mutifix}${index}.0"
        kcpmsg "reserved range ${mutifix}${index}.0/24 for ${address_vector[${got}]}"
        got=$[got+1]
      else
        kcpmsg -l warn "unable to acquire range ${mutifix}${index}.0/24"
      fi
    fi

    index=$[index+1]

    if [ "${index}" -gt "${ceiling}" ] ; then
      if [ "${got}" -le 0 ] ; then
        kcpmsg -l error "unable to reserve any address range despite having checked ${index}"
        return 1
      elif [ "${index}" -gt 255 ] ; then
        kcpmsg -l error "only able to reserve ${got} of ${need} address ranges"
        return 1
      fi
    fi
  done

  kcpmsg "successfully reserved ${got} multicast ranges"

  return 0
}

function release_multicast()
{
  local subarray key
  local -i count

  subarray="$1"

  if [ -z "${subarray}" ] ; then
    kcpmsg -l error "need a subarray in order to release multicast addresses"
    return 1
  fi

  kcpmsg "releasing addresses held by subarray ${subarray}"

  push_failure
  fetch_var "multicast"

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to retrieve multicast tracking state"
    return 1
  fi

  count=0
  push_failure

  for key in "${!var_result[@]}" ; do
    if [ "${var_result[${key}]}" = "${subarray}" ] ; then
      kcpmsg "releasing address range .${key#multicast#}.0"
      send_request   var-delete  "${key}"
      retrieve_reply var-delete
      count=$[count+1]
    fi
  done

  if ! pop_failure ; then
    kcpmsg -l error "unable to release all ${count} addresses held by subarray ${subarray}"
    return 1
  fi

  kcpmsg "released ${count} address ranges held by subarray ${subarray}"

  return 0
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
  local -a switch_map
  local -a distribution
  local -a engine_map
  local group
  local host_list

  local prior key location locations instrument art engine failed count total word template target holder prefix index actual status match items bins bin switches

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
      status="${var_result[resources:${board}:status]}"

      if [ "${status}" = "up" ] ; then
        if [ -n "${holder}" ] ; then
          if [ -n "${location_busy[${location}]}" ] ; then
            if ! is_member "${holder}" ${location_busy[${location}]} ; then
              location_busy[${location}]="${holder} ${location_busy[${location}]}"
            fi
          else
            location_busy[${location}]="${holder}"
          fi
        else
          if [ -z "${location_free[${location}]}" ] ; then
            prior=0
            location_pool[${location}]="${board}"
            switch_map+=("${location}")
          else
            prior="location_free[${location}]"
            location_pool[${location}]="${location_pool[${location}]} ${board}"
          fi
          location_free[${location}]=$[prior+1]
        fi
      fi
    fi
  done

# now location_free[$switch] should contain the number of free boards
#     location_pool[$switch] should contain a set of *free* boards as space deliminted strings
# and location_busy[$switch] be nonempty if somebody else already using a part of it
# and switch_map[$number] contains the switch name

  local name

  for name in "${!location_free[@]}" ; do
    if [ -n "${location_busy[${name}]}" ] ; then
      kcpmsg "switch ${name} used by ${location_busy[${name}]} thus discarding ${location_free[${name}]} resources"
    else
      kcpmsg "empty switch ${name} has ${location_free[${name}]} slots available namely ${location_pool[${name}]}"
    fi
  done

  for index in ${!switch_map[@]} ; do
    name=${switch_map[${index}]}
    if [ -n "${location_busy[${name}]}" ] ; then
      bins="${bins} 0"
    else
      bins="${bins} ${location_free[${name}]}"
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

    unset engine_map
    local -a engine_map

    items=""

    for art in ${resource_types[*]} ; do
      for engine in ${engine_types[*]} ; do
        items="${items} ${var_result[instruments:${instrument}:resources:${art}:${engine}]}"
        engine_map+=("${art}:${engine}")
      done
    done

    kcpmsg "bins ${bins} (${switch_map[*]}) and items ${items} (${engine_map[*]})"

    if [ $(sum_args ${items}) -gt 0 ] ; then

      eval distribution=($(distribute -i ${items} -b ${bins} -s single -s binned -s disjoint -f shell))

      if [ "$?" -ne 0 ] ; then
        kcpmsg -l warn "unable to satisfy resource needs of ${instrument}"
        failed=2
      fi

      if [ "${#distribution[*]}" -gt 0 ] ; then

        solution_pool=()

        kcpmsg "distribution keys are ${!distribution[@]} and values ${distribution[@]}"

        for index in "${!distribution[@]}" ; do
          if [ -n "${index}" ]; then
            switches=""
            for bin in ${distribution[${index}]//\"/} ; do
              switches+="${switches:+ }${switch_map[${bin}]}"
            done

            if [ -n "${switches}" ] ; then
              solution_pool[${engine_map[${index}]}]="${switches}"
            fi
          fi
        done

        if [ -n "${!solution_pool[*]}" ] ; then
          kcpmsg "solution keys are ${!solution_pool[@]}"
          for name in "${!solution_pool[@]}" ; do
            art=${name%:*}
            engine=${name#*:}
            kcpmsg "proposing switch(es) ${solution_pool[${name}]} to hold ${engine} ${art} resources"
          done
        else
          kcpmsg -l error "nothing useful to extract from ${distribution[*]}"
          failed=3
        fi

      else
        kcpmsg -l warn "no solution found for the resource needs of ${instrument}"
        failed=2
      fi
    else
      kcpmsg "no dynamic resources needed by instrument ${instrument}"
    fi

    shift

  done

  if [ -n "${failed}" ]; then
    return ${failed}
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
    kcpmsg -l warn "unable to refresh resource variables"
    return 1
  fi

  push_failure

  for word in $(ike -k hosts ${template}) ; do
    engine="${word%%.*}"
    group="${word#*=}"
    host_list=""

    for name in ${group//,/ } ; do
      match=""
      for art in ${resource_types[*]} ; do
        if [ "${name#${art^^}}" != "${name}" ] ; then
# TODO: could try to notice collisions, uniq ?
          host_list="${host_list}${host_list:+ }${name}"
          match=${art}
        fi
      done
      if [ -z "${match}" ] ; then
        kcpmsg "reserving static resource ${name}"
        send_request   var-set  resources "${SUBARRAY}" string ":${name,,}:holder"
        if ! retrieve_reply var-set ; then
          kcpmsg -l error "unable to reserve static resource ${name}"
        fi
      fi
    done


    if [ -n "${host_list}" ]  ; then
      kcpmsg "need to map placeholders $host_list to actual resources"
      actual=""

      name="${host_list%% *}"
      host_list="${host_list#* }"

      for art in ${resource_types[*]} ; do
        for location in ${solution_pool[${art}:${engine}]} ; do

          kcpmsg "performing substitutions for board type ${art} and engine ${engine} at switch ${location}"

          for key in "${!var_result[@]}" ; do
            if [ "${key##*:}" = "switch" ] ; then
              if [ "${location}" = "${var_result[${key}]}" ] ; then
                if [ -n "${name}" ] ; then
                  prefix="${key%:*}"
                  holder="${var_result[${prefix}:holder]}"
                  status="${var_result[${prefix}:status]}"
                  if [ "${status}" = up ] ; then
                    if [ -z "${holder}" ] ; then

                      tmp="${key#resources:}"
                      target="${tmp%%:*}"

                      if [ "${target#${art}}" != "${target}" ] ; then

                        kcpmsg "substituting ${name} on switch ${var_result[${key}]} with ${target}"

                        send_request   var-set  resources "${SUBARRAY}" string ":${target}:holder"
                        retrieve_reply var-set

# BIG HAIRY WARNING: we are pushing things into var_result, which isn't really ours
                        var_result[${prefix}:holder]="${SUBARRAY}"

                        export ${name}=${target}
                      else
# skip this one as it isn't our type
                        host_list="${host_list} ${name}"
                      fi
                      name="${host_list%% *}"
                      if [ "${host_list#* }" = "${host_list}" ] ; then
                        host_list=""
                      else
                        host_list="${host_list#* }"
                      fi
                    fi
                  else
                    kcpmsg "disqualifying ${prefix} for ${name} as its status is ${status}"
                  fi
                fi
              fi
            fi
          done
        done
      done

      if [ -n "${host_list}" ] ; then
        kcpmsg "unable to make substiutions for dynamic resources ${host_list}"
        set_failure
      fi

    else
      kcpmsg "nothing dynamic to assign for ${engine}"
    fi
  done


  if ! pop_failure ; then
    kcpmsg -l error "unable to assign needed resources to instrument ${instrument}"
    return 1
  fi

  return 0
}

function add_resource()
{
  local board art actual network

  board="${1,,}"

  if [ -z "${board}" ] ; then
    kcpmsg -l error "no resource to add"
    return 1
  fi

  push_failure

  fetch_var "resources"

  if ! pop_failure ; then
    kcpmsg -l error "unable to retrieve resource variables"
    return 1
  fi

  if [ -n "${var_result[resources:${board}:mode]}" ] ; then
    kcpmsg -l warn "resource ${board} already enrolled"
    return 1
  fi

  actual=""

  for art in ${resource_types[*]} ; do

    if [ "${board/${art}/}" != "${board}" ] ; then
      actual="${art}"
    fi
  done

  if [ -z "${actual}" ] ; then
    kcpmsg -l error "unable to map ${board} to one of ${resource_types[*]}"
    return 1
  fi

  art="${actual}"

# NOTE: special case: the 3rd octet of a scarab encodes its switch
  if [ "${art}" = "skarab" ] ; then
    network=$(getent hosts ${board} | cut -f3 -d '.' | head -1 )
    if [ -z "${network}" ] ; then
      kcpmsg -l error "unable to determine IP of skarab ${board}"
      return 1
    fi
  fi

  push_failure

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

  if [ -n "${network}" ] ; then
    send_request   var-set     resources "${network}" string ":${board}:switch"
    retrieve_reply var-set
  fi

  if ! pop_failure ; then
    kcpmsg -l error "unable to enroll ${board}"
    return 1
  fi

  kcpmsg "manually added resource ${board} of type ${art}"

  return 0
}

function check_resources()
{
  local -l board
  local -i budget limit grace delta
  local now mode art status when fresh key tmp holder network earlier
  local -A skarabs

  for art in ${resource_types[*]} ; do
    resource_free[${art}]=0
  done

# our initial grace period in seconds - makes allowance for skarabs to reboot
  budget=${CHECK_BUDGET:-10}

  now=$(date +%s)
  limit=$[now+budget]

  fresh=0

#  kcpmsg "checking set of available resources"

# Fetch our existing set

  push_failure

  fetch_var "resources"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables"
    return 1
  fi

# Try to find new devices from the leases file

  push_failure

  for art in ${resource_types[*]} ; do

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

  for art in ${resource_types[*]} ; do
    resource_free[${art}]=0
  done

  delta=0

  skarabs=()

  push_failure

  for key in "${!var_result[@]}" ; do
    if [ "${key##*:}" = "when" ] ; then
      when="${var_result[${key}]}"
      if [ "$[when+checkperiod]" -le "${now}" ] ; then
        tmp="${key#resources:}"
        board="${tmp%%:*}"

        art="${var_result[resources:${board}:type]}"
        earlier="${var_result[resources:${board}:status]}"
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
            kcpmsg "marking ${board} manually managed as it is on the exclusion list"
            status=standby

            send_request   var-delete  "resources:${board}:mode"
            retrieve_reply var-delete

            send_request   var-set      resources user string ":${board}:mode"
            retrieve_reply var-set

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
              if [ -n "${holder}" ] ;  then
                kcpmsg "not testing ${board} as it is held by ${holder}"
              else
#                kcpmsg "adding ${board} to set to be checked"
                skarabs[${board}]=standby
              fi
              status=""
            else
              kcpmsg -l warn "board ${board} of unknown type ${art}"
              status=standby
            fi
          fi

          if [ -n "${status}" ] ; then
            if [ "${status}" != "${var_result[resources:${board}:status]}" ] ; then
              send_request   var-delete  "resources:${board}:status"
              retrieve_reply var-delete

              send_request   var-set      resources "${status}" string ":${board}:status"
              retrieve_reply var-set

#              kcpmsg "updated status of ${board} from ${var_result[resources:${board}:status]} to ${status}"
              delta=$[delta+1]
            fi

            send_request   var-delete  "resources:${board}:when"
            retrieve_reply var-delete

            send_request   var-set      resources "${now}" string ":${board}:when"
            retrieve_reply var-set
          fi
        else
          kcpmsg "not checking ${board} as it is managed manually"
        fi
      fi
    fi
  done

  if ! pop_failure ; then
    kcpmsg -l warn "unable to re-check resource status"
    return 1
  fi

  push_failure

  if [ "${#skarabs[@]}" -gt 0 ] ; then
    status=up
    for board in $(${skarab_check} ${!skarabs[@]}) ; do
      skarabs[${board}]=up
    done
    for board in ${!skarabs[@]} ; do
      if [ -n "${var_result[resources:${board}:status]}" ] ; then
        status="${skarabs[${board}]}"
        if [ "${status}" != "${var_result[resources:${board}:status]}" ] ; then
          send_request   var-delete  "resources:${board}:status"
          retrieve_reply var-delete

          send_request   var-set      resources "${status}" string ":${board}:status"
          retrieve_reply var-set

          send_request   var-delete  "resources:${board}:when"
          retrieve_reply var-delete

          send_request   var-set      resources "${now}"    string ":${board}:when"
          retrieve_reply var-set

          delta=$[delta+1]

#          kcpmsg "changed skarab ${board} from ${var_result[resources:${board}:status]} to ${status}"
#        else
#          kcpmsg "status skarab ${board} unchanged in ${status}"
        fi
      else
        kcpmsg -l error "${skarab_check} provided flaky value ${board}"
      fi
    done
  fi

  if ! pop_failure ; then
    kcpmsg -l warn "unable to update skarab resource status"
    return 1
  fi

  kcpmsg "${delta} resource marking changes"

  return 0
}
