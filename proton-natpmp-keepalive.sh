#!/bin/bash


#### Author
# github.com/blomstertj
#### Description
# natpmpc port forward map request loop
#
# based on Proton's support article here: https://protonvpn.com/support/port-forwarding-manual-setup#linux
# original command line from article: 
# while true ; do date ; natpmpc -a 1 0 udp 60 -g 10.2.0.1 && natpmpc -a 1 0 tcp 60 -g 10.2.0.1 || { echo -e "ERROR with natpmpc command \a" ; break ; } ; sleep 45 ; done
#
# this script is an enhanced version of the original command line in the article:
# pipes all natpmpc output to temp files and uses grep/awk to parse results and errors
# echos to console the public IP from ip.me, the public IP from natpmp, and the mapped ports if successful
# if any step fails then the script will output the command output for debugging and reduce loop wait time


# the PMP gateway for ProtonVPN from the article
protonGwIp='10.2.0.1'
# the key name for the public IP returned by natpmpc
readNatPmpRespPublicIpStr='Public IP'
# if a NAT response returns a success then the output will have the following format
readNatPmpRespSuccessRegex='readnatpmpresponseorretry returned [0-9]+ \((OK|SUCCESS)\)'
# if port mapping is successful then the output will have the following format for UDP/TCP
readNatPmpPortMapRespRegex='Mapped public port [0-9]+ protocol (UDP|TCP)'
# divider for natpmpc output if errors
cmdOutputDivider='================================================'
# divider between loop iterations
outputDivider='================================================================================================'
# verbose output
checkCompactOutputEnv="$(printenv COMPACT_OUTPUT)"
if [[ $checkCompactOutputEnv == 'true' ]]
then
	verbose=false
else
	verbose=true
fi
# skip ip.me check
checkSkipIpMeEnv="$(printenv SKIP_IPME_CHECK)"
if [[ $checkSkipIpMeEnv == 'true' ]]
then
	skipIpMeCheck=true
else
	skipIpMeCheck=false
fi

while true; do
	echo "$outputDivider"
	#### initialize variables for this loop iteration
	natpmpcAllowed=''
	natpmpc_udp_output=''
	natpmpc_tcp_output=''
	curlPublicIp=''
	natPmpPublicIp=''
	testNatPmpAllowed=''
	testUdpPortMap=''
	mappedUdpPort=''
	testTcpPortMap=''
	mappedTcpPort=''
	scriptWaitTime=45
	
	#### get public IP from curl to Proton operated ip.me
	if [[ $skipIpMeCheck == false ]]
	then
		# this should always match what natpmp returns
		# should only be different if we're not connected to VPN
		curlPublicIp="$(curl --silent ip.me)"
		echo "Public IP (ip.me): $curlPublicIp"
	fi
	#### test if the gateway allows port forwarding
	# this will take a long time if we're not connected to VPN
	# or not on a P2P enabled server
	if [[ $verbose == true ]]
	then
		echo "Target Gateway IP: $protonGwIp"
		echo 'Testing if the gateway allows port forwarding...'
	fi
	# test if this server allows port forwarding
	natpmpcAllowed="$(natpmpc -g "$protonGwIp" 2>&1)"
	# grab the read response/retry lines
	testNatPmpAllowed="$(echo "$natpmpcAllowed" | grep -E "$readNatPmpRespSuccessRegex")"
	natPmpPublicIp="$(echo "$natpmpcAllowed" | grep "$readNatPmpRespPublicIpStr" | cut -d ':' -f 2 | xargs)"
	echo "Public IP (natpmp): $natPmpPublicIp"
	#### if the gateway allows port forwarding then request ports
	# if not allowed or test error then warn user and reduce wait time
	if [[ -z "$testNatPmpAllowed" ]]
	then
		echo 'NAT PMP test failed. Make sure your chosen server is P2P enabled. Make sure this containers traffic is routed through the VPN tunnel. Command output:'
		echo "$cmdOutputDivider"
		echo "$natpmpcAllowed"
		echo "$cmdOutputDivider"
		scriptWaitTime=10
	#### if allowed then request port fowarding for UDP/TCP for 60 second lifetime
	else
		#### UDP port forward request
		if [[ $verbose == true ]]
		then
			echo 'Sending UDP port forward request...'
		fi
		natpmpc_udp_output="$(natpmpc -a 1 0 udp 60 -g "$protonGwIp" 2>&1)"
		# grab the read response/retry lines
		testUdpPortMap="$(echo "$natpmpc_udp_output" | grep -E "$readNatPmpRespSuccessRegex")"
		# if test failed then warn user and reduce wait time
		if [[ -z "$testUdpPortMap" ]]
		then
			echo 'UDP port mapping failed. Command output:'
			echo "$cmdOutputDivider"
			echo "$natpmpc_udp_output"
			echo "$cmdOutputDivider"
			scriptWaitTime=10
		# if mapping was successful then display port
		else
			mappedUdpPort="$(echo "$natpmpc_udp_output" | grep -E "$readNatPmpPortMapRespRegex" | awk '{print $4}')"
			echo "Forwarded port (UDP): $mappedUdpPort"
		fi
		#### TCP port forward request
		if [[ $verbose == true ]]
		then
			echo 'Sending TCP port forward request...'
		fi
		natpmpc_tcp_output="$(natpmpc -a 1 0 tcp 60 -g "$protonGwIp" 2>&1)"
		# grab the read response/retry lines
		testTcpPortMap="$(echo "$natpmpc_tcp_output" | grep -E "$readNatPmpRespSuccessRegex")"
		# if test failed then warn user and reduce wait time
		if [[ -z "$testTcpPortMap" ]]
		then
			echo 'TCP port mapping failed. Command output:'
			echo "$cmdOutputDivider"
			echo "$natpmpc_tcp_output"
			echo "$cmdOutputDivider"
			scriptWaitTime=10
		# if mapping was successful then display port
		else
			mappedTcpPort="$(echo "$natpmpc_tcp_output" | grep -E "$readNatPmpPortMapRespRegex" | awk '{print $4}')"
			echo "Forwarded port (TCP): $mappedTcpPort"
		fi
	fi
	#### loop complete
	# delay next iteration by 10 or 45 seconds
	if [[ $verbose == true ]]
	then
		echo "Waiting $scriptWaitTime seconds before next port forward request..."
	fi
	echo "$outputDivider"
	sleep $scriptWaitTime
done