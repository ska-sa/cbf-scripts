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
  local -A ip_key
  local -a replace_set component_ip ordered_boards
  local ip number

  local key instrument art engine failed count total subtotal word template target holder index status

  push_failure

  fetch_var "resources"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables"
    return 1
  fi

# this requires the existence of an ip subfield

  for key in "${!var_result[@]}" ; do
    if [ "${key##*:}" = "ip" ] ; then
      ip=${var_result[${key}]}
      component_ip=(${ip//./ })
      number=$[${component_ip[2]}*256+${component_ip[3]}]

#      location="${var_result[${key}]}"

      tmp="${key#resources:}"
      board="${tmp%%:*}"

      kcpmsg "candidate board ${board} with number ${number}"

      holder="${var_result[resources:${board}:holder]}"
      status="${var_result[resources:${board}:status]}"

      if [ -n "${number}" ] ; then
        if [ "${status}" = "up" ] ; then
          if [ -z "${holder}" ] ; then
            kcpmsg "inserting ${board} at priority ${number}"
            ip_key[${number}]="${board}"
          fi
        fi
      else
        kcpmsg -l error "no number computed for ${board} despite ip being ${ip}"
      fi
    fi
  done

# now ip_key[$ip] should contain the name of an unallocated skarab

  push_failure

  fetch_var "instruments"

  if ! pop_failure ; then
    kcpmsg -l warn "unable to retrieve resource variables"
    return 1
  fi

# now the hardcoded heuristics/rules

  failed=""
  total=0
  count=0

  while [ "$#" -ge 1 ] ; do

    instrument="$1"

    subtotal=0

    kcpmsg "checking if it is feasible to instantiate ${instrument}"

    for art in ${resource_types[*]} ; do
      for engine in ${engine_types[*]} ; do
        subtotal=$[${subtotal}+${var_result[instruments:${instrument}:resources:${art}:${engine}]}]
      done
    done

    kcpmsg "instrument ${instrument} requires ${subtotal} resources"

    total=$[${total}+${subtotal}]

    if [ "${#ip_key[*]}" -lt ${total} ] ; then
      kcpmsg -l warn "unable to satisfy resource needs of ${instrument} with ${#ip_key[*]} devices available and ${subtotal} of ${total} needed"
      failed=2
    fi

    count=$[count+1]

    shift

  done

  if [ -n "${failed}" ]; then
    kcpmsg "exiting with code ${failed}"
    return ${failed}
  fi

  if [ -z "${SUBARRAY}" ] ; then
    kcpmsg "not in a subarray thus operating in probe mode only"
    return 0
  fi

  if [ "${count}" -ne 1 ] ; then
    kcpmsg -l error "only able to allocate one instrument at a time"
    return 1
  fi

  template=${CORR_TEMPLATE}/${instrument}

  kcpmsg "about to allocate resources for ${instrument} via ${template}"

  push_failure

# WARNING: this only sorts numerically by skaraBnumber, roaches are broken
  replace_set=($(ike -o -k hosts ${template} | tr ,  '\n'  | sort -tB -n -k2))

  kcpmsg "unordered resources ${ip_key[@]}"

  for name in "echo ${!ip_key[@]} | tr ' ' '\n' | sort -n" ; do
    ordered_boards+=(${ip_key[${name}]})
  done

  kcpmsg "ordered resources ${ordered_boards[@]}"


  index=0
  for name in ${replace_set[*]} ; do
    if [ "${name#SKARAB}" != "${name}" ] ; then
# TODO: could try to notice collisions, uniq ?

      target=${ordered_boards[${index}]}
      index=$[index+1]

      kcpmsg "substituting ${name} with ${target}"
      send_request   var-set  resources "${SUBARRAY}" string ":${target}:holder"
      if ! retrieve_reply var-set ; then
        kcpmsg -l error "unable to reserve dynamic resource ${target} for ${name}"
      fi

      export ${name}=${target}
    else
      kcpmsg "reserving static resource ${name}"
      send_request   var-set  resources "${SUBARRAY}" string ":${name}:holder"
      if ! retrieve_reply var-set ; then
        kcpmsg -l error "unable to reserve static resource ${name}"
      fi
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
  local board art actual network ip

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
    ip=$(getent hosts ${board} | head -1 | cut -f1 -d ' ')
    network=$(echo ${ip} | cut -f3 -d .)
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
    send_request   var-set   resources "${network}" string ":${board}:switch"
    retrieve_reply var-set
  fi

  if [ -n "${ip}" ] ; then
    send_request   var-set   resources "${ip}"  string ":${board}:ip"
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

          ip=$(getent hosts ${board} | head -1 | cut -f1 -d ' ')
          network=$(echo ${ip} | cut -f3 -d .)

          if [ -n "${network}" ] ; then
            send_request   var-set   resources "${network}" string ":${board}:switch"
            retrieve_reply var-set

            send_request   var-set   resources "${ip}"  string ":${board}:ip"
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
