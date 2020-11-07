#!/bin/bash

#Some infor from: https://github.com/ralish/bash-script-template/blob/stable/script.sh


netName="onos-cluster-net"
creatorKey="creator"
creatorValue="onos-cluster-create"

atomixVersion="3.1.5"
atomixImage="atomix/atomix:$atomixVersion"
onosVersion="2.2.1"
onosImage="onosproject/onos:$onosVersion"
atomixNum=3
onosNum=3

customSubnet=172.20.0.0/16
customGateway=172.20.0.1

allocatedAtomixIps=()
allocatedOnosIps=()

# Handling arguments, taken from (goodmami)
# https://gist.github.com/goodmami/f16bf95c894ff28548e31dc7ab9ce27b
die() { echo "$1"; exit 1; }

usage() {
  cat <<EOF
    Options:
      -h, --help                  display this help message
      -o, --onos-version          version for ONOS: e.g. 2.2.1
      -a, --atomix-version        version for Atomix: e.g 3.1.5
      -i, --atomix-num            number of Atomix containers
      -j, --onos-num              number of ONOS containers
EOF
}

parse_params() {
# Option parsing
  while [ $# -gt 0 ]; do
      case "$1" in
          --*=*)               a="${1#*=}"; o="${1#*=}"; shift; set -- "$a" "$o" "$@" ;;
          -h|--help)           usage; exit 0; shift ;;
          -a|--atomix-version) atomixVersion="$2"; shift 2 ;;
          -o|--onos-version)   onosVersion="$2"; shift 2 ;;
          -i|--atomix-num)     atomixNum="$2"; shift 2 ;;
          -j|--onos-num)       onosNum="$2"; shift 2 ;;
          --)                  shift; break ;;
          -*)                  usage; die "Invalid option: $1" ;;
          *)                   break ;;
      esac
  done
  echo "atomix-version: $atomixVersion"
  echo "onos-version: $onosVersion"
  echo "atomix-containers: $atomixNum"
  echo "onos-containers: $onosNum"
  echo "subnet: $customSubnet"
}


containsElement () {
  local e match="$1"
  shift
  for e; do [[ $e == "$match" ]] && return 0; done
  return 1
}

# https://unix.stackexchange.com/a/465372
in_subnet() {
    local ip ip_a mask netmask sub sub_ip rval start end

    # Define bitmask.
    local readonly BITMASK=0xFFFFFFFF

    # Set DEBUG status if not already defined in the script.
    [[ "${DEBUG}" == "" ]] && DEBUG=0

    # Read arguments.
    IFS=/ read sub mask <<< "${1}"
    IFS=. read -a sub_ip <<< "${sub}"
    IFS=. read -a ip_a <<< "${2}"

    # Calculate netmask.
    netmask=$(($BITMASK<<$((32-$mask)) & $BITMASK))

    # Determine address range.
    start=0
    for o in "${sub_ip[@]}"
    do
        start=$(($start<<8 | $o))
    done

    start=$(($start & $netmask))
    end=$(($start | ~$netmask & $BITMASK))

    # Convert IP address to 32-bit number.
    ip=0
    for o in "${ip_a[@]}"
    do
        ip=$(($ip<<8 | $o))
    done

    # Determine if IP in range.
    (( $ip >= $start )) && (( $ip <= $end )) && rval=1 || rval=0

    (( $DEBUG )) &&
        printf "ip=0x%08X; start=0x%08X; end=0x%08X; in_subnet=%u\n" $ip $start $end $rval 1>&2

    return ${rval}
}

nextIp(){

  subnet=$1
  ip=$2

  #echo "subnet:$subnet, ip:$ip"

  ip_hex=$(printf '%.2X%.2X%.2X%.2X\n' `echo $ip | sed -e 's/\./ /g'`)
  next_ip_hex=$(printf %.8X `echo $(( 0x$ip_hex + 1 ))`)
  next_ip=$(printf '%d.%d.%d.%d\n' `echo $next_ip_hex | sed -r 's/(..)/0x\1 /g'`)

  val=$(in_subnet $subnet $next_ip)
  #echo "in_subnet:$val"

  if ! $val;
  then
    next_ip=""
  fi

  echo "$next_ip"
}

create_net_ine(){
  if [[ ! $(sudo docker network ls --format "{{.Name}}" --filter label=$creatorKey=$creatorValue) ]];
  then
      sudo docker network create -d bridge $netName --subnet $customSubnet --gateway $customGateway --label "$creatorKey=$creatorValue" >/dev/null
      echo "Creating Docker network $netName ..."
  fi
}

pull_if_not_present(){
  echo "Pulling $1"
  if [ "$(docker images --format '{{.Repository}}:{{.Tag}}' )" != *"$1"* ]; then
    sudo docker pull $1 >/dev/null
  fi
}


clone_onos(){

  if [ ! -d "$HOME/onos" ] ; then
    cd
    git clone https://gerrit.onosproject.org/onos
  fi

}

create_atomix(){

  emptyArray=()
  #NEW=("${OLD1[@]}" "${OLD2[@]}")
  for (( i=1; i<=$atomixNum; i++ ))
  do
    usedIps=("${emptyArray[@]}" "${allocatedAtomixIps[@]}")
    subnet=$(sudo docker inspect $netName | jq -c '.[0].IPAM.Config[0].Subnet' | tr -d '"')
    usedIps+=($(sudo docker inspect $netName | jq -c '.[0].IPAM.Config[0].Gateway' | tr -d '"'))
    sudo docker inspect onos-cluster-net | jq -c '.[0].Containers[] | .IPv4Address' |\
    while read -r ipAndMask;
    do
      usedIp=$(echo $ipAndMask | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
      usedIps+=(usedIp)
    done


    goodIP=""
    IFS=/ read sub mask <<< "$subnet"
    currentIp=$(nextIp $subnet $sub)
    while [ -z "$goodIP" ]
    do
      #if [[ ! " ${usedIps[@]} " =~ " ${currentIp} " ]]; then
      if ! containsElement $currentIp "${usedIps[@]}";
      then
        sudo docker create -t --name atomix-$i --hostname atomix-$i --net $netName --ip $currentIp $atomixImage >/dev/null
        echo "Creating atomix-$i container with IP: $currentIp"
        goodIP=$currentIp
      fi
      sleep 1
      currentIp=$(nextIp $subnet $currentIp)
    done

    export OC$i=$goodIP

    allocatedAtomixIps+=($goodIP)
    #atomixIp=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' atomix-$i)

  done
}

create_onos(){

  emptyArray=()
  #NEW=("${OLD1[@]}" "${OLD2[@]}")
  for (( i=1; i<=$onosNum; i++ ))
  do
    usedIps=("${emptyArray[@]}" "${allocatedOnosIps[@]}" "${allocatedAtomixIps[@]}")
    subnet=$(sudo docker inspect $netName | jq -c '.[0].IPAM.Config[0].Subnet' | tr -d '"')
    usedIps+=($(sudo docker inspect $netName | jq -c '.[0].IPAM.Config[0].Gateway' | tr -d '"'))
    sudo docker inspect onos-cluster-net | jq -c '.[0].Containers[] | .IPv4Address' |\
    while read -r ipAndMask;
    do
      usedIp=$(echo $ipAndMask | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
      usedIps+=(usedIp)
    done

    goodIP=""
    IFS=/ read sub mask <<< "$subnet"
    currentIp=$(nextIp $subnet $sub)
    while [ -z "$goodIP" ]
    do
      if ! containsElement $currentIp "${usedIps[@]}";
      then
        echo "Starting onos$i container with IP: $currentIp"
        sudo docker run -t -d \
          --name onos$i \
          --hostname onos$i \
          --net $netName \
          --ip $currentIp \
          -e ONOS_APPS="drivers,openflow-base,netcfghostprovider,lldpprovider,gui2" \
          $onosImage >/dev/null

        goodIP=$currentIp
      fi
      sleep 1
      currentIp=$(nextIp $subnet $currentIp)
    done

    allocatedOnosIps+=($goodIP)
    #atomixIp=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' atomix-$i)

  done
}

apply_atomix_config(){
  for (( i=1; i<=$atomixNum; i++ ))
  do
    pos=$((i-1))
    cd
    ./onos/tools/test/bin/atomix-gen-config "${allocatedAtomixIps[$pos]}" /tmp/atomix-$i.conf "${allocatedAtomixIps[*]}" >/dev/null
    sudo docker cp /tmp/atomix-$i.conf atomix-$i:/opt/atomix/conf/atomix.conf
    sudo docker container start atomix-$i >/dev/null
    echo "Starting container atomix-$i"
  done
}

apply_onos_config(){
  for (( i=1; i<=$onosNum; i++ ))
  do
    pos=$((i-1))
    cd
    ./onos/tools/test/bin/onos-gen-config "${allocatedOnosIps[$pos]}" /tmp/cluster-$i.json -n "${allocatedAtomixIps[*]}" >/dev/null
    sudo docker exec onos$i mkdir /root/onos/config
    echo "Copying configuration to onos$i"
    sudo docker cp /tmp/cluster-$i.json onos$i:/root/onos/config/cluster.json
    echo "Restarting container onos$i"
    sudo docker restart onos$i >/dev/null
  done
}

function main() {

    parse_params "$@"

    create_net_ine

    pull_if_not_present $atomixImage
    pull_if_not_present $onosImage
    apply_atomix_config

    clone_onos
    
    create_onos
    apply_onos_config
}

# Make it rain
main "$@"
