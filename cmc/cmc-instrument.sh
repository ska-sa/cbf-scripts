### support functions ###################################

# about to be wrong:
# instrument-size:name           - how many inputs does it need
# instrument-input:name          - what input product does it require
# instrument-outputs:name:#N     - what output products does it generate
# instrument-resources:name:type - how many boards of what type do we need

function reload_instruments()
{
  local size instrument template geometry art count top available product i required inputs outputs channels boutput binput art engine candidates word

  if [ "${#instruments_deployed[@]}" -le 0 ] ; then
    kcpmsg -l fatal "no instruments deployed"
    return 1
  fi

  push_failure

  fetch_var "instruments"

  if pop_failure ; then
    push_failure

    kcpmsg "clearing previous instrument settings"

    send_request   var-delete  "instruments"
    retrieve_reply var-delete

    if ! pop_failure ; then
      kcpmsg -l fatal "unable to initialise essential instrument tracking state"
      return 1
    fi
  fi

  kcpmsg "initialising instrument settings"

  push_failure

  send_request   var-declare  "instruments*"           map
  retrieve_reply var-declare

  if ! pop_failure ; then
    kcpmsg -l fatal "unable to initialise essential instrument tracking state"
    return 1
  fi

  push_failure

  available=0

  for instrument in ${instruments_deployed[*]} ; do
    template=${CORR_TEMPLATE}/${instrument}

    kcpmsg -l debug "checking templates for instrument ${instrument}"

    if [ -f ${template} ] ; then

      size=$(ike -o -k source_mcast_ips ${template} | tr -s ',' '\n' | wc -l)
      inputs=$(ike -o -k source_products ${template})
      outputs=$(ike -o -k output_products ${template})
      channels=$(ike -o -k n_chans ${template})

      boutput=0
      binput=0
# TODO
# boutput=$(ike -o -k output_ ${template})
# binput=$(ike -o -k output_ ${template})

# TODO: more checking that we can find input and output products too ?

      if [ "${size}" -gt 0 -a -n "${inputs}" ] ; then

        kcpmsg "instrument ${instrument} uses ${size} inputs"

        send_request   var-declare instruments   map   ":${instrument}"
        retrieve_reply var-declare

        ############################

        send_request   var-declare instruments   string ":${instrument}:input-size"
        retrieve_reply var-declare

        send_request   var-declare instruments   array  ":${instrument}:input-products"
        retrieve_reply var-declare

        send_request   var-declare instruments   array  ":${instrument}:output-products"
        retrieve_reply var-declare

        send_request   var-declare instruments   string  ":${instrument}:input-bandwidth"
        retrieve_reply var-declare

        send_request   var-declare instruments   string  ":${instrument}:output-bandwidth"
        retrieve_reply var-declare

        send_request   var-declare instruments   string  ":${instrument}:channels"
        retrieve_reply var-declare

        send_request   var-declare instruments   map     ":${instrument}:resources"
        retrieve_reply var-declare

        for art in ${resource_types[*]} ; do
          send_request   var-declare instruments   map    ":${instrument}:resources:${art}"
          retrieve_reply var-declare

          for engine in ${engine_types[*]} ; do
            send_request   var-declare instruments   string ":${instrument}:resources:${art}:${engine}"
            retrieve_reply var-declare

            send_request   var-set     instruments 0 string ":${instrument}:resources:${art}:${engine}"
            retrieve_reply var-set
          done
        done

        send_request   var-set     instruments   "${size}"       string  ":${instrument}:input-size"
        retrieve_reply var-set

        send_request   var-set     instruments   "${channels}"   string  ":${instrument}:channels"
        retrieve_reply var-set

        send_request   var-set     instruments   "${binput}"     string  ":${instrument}:input-bandwidth"
        retrieve_reply var-set

        send_request   var-set     instruments   "${boutput}"    string  ":${instrument}:output-bandwidth"
        retrieve_reply var-set

        for product in ${inputs} ; do
          send_request   var-set     instruments   "${product}"  string  ":${instrument}:input-products#-"
          retrieve_reply var-set
        done

        for product in ${outputs} ; do
          send_request   var-set     instruments   "${product}"  string  ":${instrument}:output-products#-"
          retrieve_reply var-set
        done

        for art in ${resource_types[*]} ; do

          for word in $(ike -k hosts ${template} | grep ${art}) ; do
            kcpmsg -l debug "examing ${word} for dynamic resources"

            engine=${word%%.*}
            count=$(echo "${word#*=}" | tr ',' '\n' | grep ${art^^} | sort -n | uniq | wc -l)

            kcpmsg "instrument ${instrument} requires ${count} dynamically allocated ${art} resources as ${engine} components"

            send_request   var-set   instruments   "${count}"    string  ":${instrument}:resources:${art}:${engine}"
            retrieve_reply var-set
          done

        done

      else
        kcpmsg -l error "unable to establish what and how many inputs ${instrument} requires"
        set_failure
      fi

    else
      kcpmsg -l fatal "no template available in ${template} for instrument ${instrument}"
    fi

  done

  if ! pop_failure ; then
    kcpmsg -l error "unable to determine instrument layouts"
    return 1
  fi

  return 0
}

