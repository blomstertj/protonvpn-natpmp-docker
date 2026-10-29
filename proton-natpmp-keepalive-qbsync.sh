#!/bin/bash

##############################################################################
#### README
## Author
# github.com/blomstertj
#
## Description
# natpmpc port forward map request loop with qBittorrent listen port sync via API
# over engineered and stable - Proton's one liner now 350+ lines
# based on Proton's support article here: https://protonvpn.com/support/port-forwarding-manual-setup#linux
# original command line from article: 
# while true ; do date ; natpmpc -a 1 0 udp 60 -g 10.2.0.1 && natpmpc -a 1 0 tcp 60 -g 10.2.0.1 || { echo -e "ERROR with natpmpc command \a" ; break ; } ; sleep 45 ; done
#
## Version
# 2026.10.28
#
## Steps
# 1. pipes all output to variables and uses grep/awk to parse
# 2. shows on console the public IP from ip.me, the public IP from natpmp, and the mapped ports if successful
# 3. if syncing qBittorrent is enabled:
# 		a. checks current listen port via API
#		b. compares listen port to mapped port from natpmp (tcp)
#		c. if needed, sets the listen port via API to match natpmp (tcp)
#		d. verifies the new port matches natpmp (tcp)
# 4. if any step fails then the script will output the command output for debugging and reduce loop wait time
##############################################################################

##############################################################################
#### bash settings
set -euo pipefail
##############################################################################

##############################################################################
#### Configuration Constants
# the PMP gateway for ProtonVPN from the article
readonly PROTON_GW_IP='10.2.0.1'
# the key name for the public IP returned by natpmpc
readonly NATPMP_READ_PUBLIC_IP_STR='Public IP'
# if a NAT response returns a success then the output will have the following format
readonly NATPMP_SUCCESS_REGEX='readnatpmpresponseorretry returned [0-9]+ \((OK|SUCCESS)\)'
# if port mapping is successful then the output will have the following format for UDP/TCP
readonly NATPMP_PORT_MAP_REGEX='Mapped public port [0-9]+ protocol (UDP|TCP)'
# divider for natpmpc output if errors
readonly CMD_OUTPUT_DIVIDER='================================================'
# divider between loop iterations
readonly OUTPUT_DIVIDER='================================================================================================'
# loop wait time if no errors
readonly DEFAULT_WAIT_TIME=45
# loop wait time if errors found
readonly FAILURE_WAIT_TIME=10
##############################################################################

##############################################################################
#### Environment Variable Parsing (called once at startup)
## parse container environment variables
parse_environment() {
    # Parse COMPACT_OUTPUT environment variable - convert string true/false to bool
    local compact_output_value
    compact_output_value="$(printenv COMPACT_OUTPUT 2>/dev/null)" || compact_output_value=''
    if [[ "$compact_output_value" == 'true' ]]; then
        COMPACT_OUTPUT=true
    else
        COMPACT_OUTPUT=false
    fi
    # Parse SKIP_IPME_CHECK environment variable - convert string true/false to bool
    local skip_ipme_check_value
    skip_ipme_check_value="$(printenv SKIP_IPME_CHECK 2>/dev/null)" || skip_ipme_check_value=''
    if [[ "$skip_ipme_check_value" == 'true' ]]; then
        SKIP_IPME_CHECK=true
    else
        SKIP_IPME_CHECK=false
    fi
    # Parse qBittorrent environment variables (optional - only enabled when both are set)
    local qbittorrent_api_key_value
	qbittorrent_api_key_value="$(printenv QBITTORRENT_API_KEY 2>/dev/null)" || qbittorrent_api_key_value=''
    local qbittorrent_webui_url_value
	qbittorrent_webui_url_value="$(printenv QBITTORRENT_WEBUI_URL 2>/dev/null)" || qbittorrent_webui_url_value=''
    if [[ -n "$qbittorrent_api_key_value" && -n "$qbittorrent_webui_url_value" ]]; then
        QB_SYNC_ENABLED=true
		# trim trailing slash and whitespace
        QB_WEBUI_NORMALIZED="$(echo "${qbittorrent_webui_url_value%/}" | tr -d ' ')"
		# trim whitespace
		QB_API_KEY_NORMALIZED="$(echo "$qbittorrent_api_key_value" | tr -d ' ')"
        QB_GET_ENDPOINT="${QB_WEBUI_NORMALIZED}/api/v2/app/preferences"
        QB_SET_ENDPOINT="${QB_WEBUI_NORMALIZED}/api/v2/app/setPreferences"
    else
        QB_SYNC_ENABLED=false
        QB_WEBUI_NORMALIZED=''
		QB_API_KEY_NORMALIZED=''
        QB_GET_ENDPOINT=''
        QB_SET_ENDPOINT=''
    fi
}
##############################################################################

##############################################################################
#### Logging Functions
## divide loop start/stop iterations
log_section() {
    echo "$OUTPUT_DIVIDER"
}

## show additional informational messages to indicate where in the script the loop is better
log_subsection() {
    if [[ "$COMPACT_OUTPUT" == false ]]; then
        echo "[$1]"
    fi
}

## show error messages between a sub-divider
log_error() {
	local error_title
	error_title="$1"
	local error_body
	error_body="${2:-""}"
    echo "$CMD_OUTPUT_DIVIDER"
    echo "✗ $error_title"
	echo "$error_body"
    echo "$CMD_OUTPUT_DIVIDER"
}

## show checkmark for successful operations
log_success() {
    echo "✓ $1"
}
##############################################################################

##############################################################################
#### natpmp functions
## test if port forwarding is allowed and return public IP
test_natpmp_gateway() {
	natpmpc -g "$PROTON_GW_IP" 2>/dev/null || return 1    
}

## get the public ip from natpmp gateway test
get_natpmp_public_ip() {
	local gateway_test
	gateway_test="$1"
	if grep -qE "$NATPMP_SUCCESS_REGEX" <<< "$gateway_test"; then
        echo "$gateway_test" | grep "$NATPMP_READ_PUBLIC_IP_STR" | cut -d ':' -f 2 | tr -d ' '
    else
        return 1
    fi
}

## request mapping
request_port_forward() {
	local output
	local protocol
	protocol="$1"
	output="$(natpmpc -a 1 0 $protocol 60 -g "$PROTON_GW_IP" 2>&1)"
    if grep -qE "$NATPMP_SUCCESS_REGEX" <<< "$output"; then
        echo "$output" | grep -oE "$NATPMP_PORT_MAP_REGEX" | awk '{print $4}'
    else
        return 1
    fi
}

##############################################################################

##############################################################################
#### qBittorrent API Functions (only called if QB_SYNC_ENABLED=true)
## get the preferences
qbit_get_preferences() {   
    if [[ -z "$QB_API_KEY_NORMALIZED" ]]; then
        return 1
    else
		curl -s -X GET "$QB_GET_ENDPOINT" -H "Authorization: Bearer $QB_API_KEY_NORMALIZED" 2>&1
	fi
}

## parse the preferences to find listen port
qbit_get_listen_port() {
    local preferences
	preferences="$1"
    echo "$preferences" | jq -r '.listen_port' 2>/dev/null || return 1
}

## set the preferences
qbit_update_preferences() {
    local listen_port
	listen_port="$1"
    if [[ -z "$QB_API_KEY_NORMALIZED" || -z "$listen_port" ]]; then
        return 1
    else
		local qb_json_payload
		qb_json_payload="{\"listen_port\":${listen_port},\"random_port\":false,\"upnp\":false}"
		curl -s -X POST "$QB_SET_ENDPOINT" -H "Authorization: Bearer $QB_API_KEY_NORMALIZED" --data-urlencode "json=${qb_json_payload}" 2>&1
	fi
}

## get preferences and verify the port is what it should be
qbit_verify_update() {
    local expected_port
	expected_port="$1"  
    if [[ -z "$QB_API_KEY_NORMALIZED" ]]; then
        return 1
    else
		# Fetch updated preferences
		local preferences
		preferences="$(qbit_get_preferences "$QB_API_KEY_NORMALIZED")"
		if [[ $? -ne 0 ]]; then
			return 1
		else
			# Extract actual listen port from response
			local actual_port
			actual_port="$(qbit_get_listen_port "$preferences")"
			if [[ -z "$actual_port" || "$actual_port" != "$expected_port" ]]; then
				return 1
			else
				echo "$actual_port"
			fi
		fi
	fi
}
##############################################################################

##############################################################################
#### Main Execution
main() {
	## Parse all environment variables once at startup  
    parse_environment
	
	## start loop
    while true; do
        log_section
        # Initialize variables for this loop iteration
        local natpmpc_allowed=''
        local natpmpc_udp_output=''
        local natpmpc_tcp_output=''
        local curl_public_ip=''
        local natpmpc_public_ip=''
        local test_natpmp_allowed=''
        local test_udp_port_map=''
        local proton_mapped_udp_port=''
        local test_tcp_port_map=''
        local proton_mapped_tcp_port=''
		local qb_current_listen_port=''
		local qb_preferences=''
		local qb_verified_listen_port=''
        local wait_time="$DEFAULT_WAIT_TIME"
		
        ## get public IP from ip.me (skipped if SKIP_IPME_CHECK=true)
		# this should always match what natpmp returns and should only be different if we're not connected to VPN
        if [[ "$SKIP_IPME_CHECK" == false ]]; then
			log_subsection "Fetching public IP from ip.me"
			if ! curl_public_ip="$(curl -s "https://ip.me")"; then
				log_error "ip.me public IP check failed. Please ensure the container has an internet connection"
			else           
				log_success "Public IP (ip.me): $curl_public_ip"
			fi
        fi
		
        ## test if the gateway allows port forwarding
		# this will take a long time if we're not connected to VPN or not on a P2P enabled server
		log_subsection "Testing natpmp gateway support for $PROTON_GW_IP"
		# if not allowed or test error then warn user and reduce wait time
		if ! natpmpc_allowed="$(test_natpmp_gateway)"; then
            log_error "natpmp support test failed. Please ensure your server is P2P enabled. Container traffic must be routed through the VPN tunnel. Command output:" "$natpmpc_allowed"
            wait_time="$FAILURE_WAIT_TIME"
        # if allowed then parse the public IP from natpmp
		else
			if ! natpmpc_public_ip="$(get_natpmp_public_ip "$natpmpc_allowed")"; then
				log_error "Failed to get public IP from natpmp" "$natpmpc_allowed"
			else
				log_success "Public IP (natpmp): $natpmpc_public_ip"
			fi
			
			## UDP port forward request
			log_subsection "Requesting UDP port forward"
			# if test failed then warn user and reduce wait time
			if ! proton_mapped_udp_port="$(request_port_forward udp)"; then
				log_error "UDP port mapping failed. Command output:" "$natpmpc_udp_output"
				wait_time="$FAILURE_WAIT_TIME"
			# if mapping was successful then display port
			else
				log_success "Forwarded port (UDP): $proton_mapped_udp_port"
			fi
        
			## TCP port forward request
			log_subsection "Requesting TCP port forward"
			# if test failed then warn user and reduce wait time
			if ! proton_mapped_tcp_port="$(request_port_forward tcp)"; then
				log_error "TCP port mapping failed. Command output:" "$natpmpc_tcp_output"
				wait_time="$FAILURE_WAIT_TIME"
			# if mapping was successful then display port
			else
				log_success "Forwarded port (TCP): $proton_mapped_tcp_port"
			fi
		fi
        
        ## qbittorrent port sync (skipped if QB_SYNC_ENABLED=false)
        if [[ "$QB_SYNC_ENABLED" == true ]]; then
			# get the current qBittorrent preferences via API request
			log_subsection "Fetching current qBittorrent preferences from: $QB_GET_ENDPOINT"
			# if the GET request failed then warn user
            if ! qb_preferences="$(qbit_get_preferences)"; then
                log_error "Failed to get qBittorrent preferences. Please check API key and WebUI URL"
                wait_time="$FAILURE_WAIT_TIME"
			
			## parse the qBittorrent preferences JSON response to get the current listen port
            else
				# parse json response to get the current listen port
				qb_current_listen_port="$(qbit_get_listen_port "$qb_preferences")"
				# if parsing the JSON response failed then warn user
				if [[ -z "$qb_current_listen_port" ]]; then
					log_error "Failed to extract listen_port from qBittorrent preferences response. Current qBittorrent preferences:" "qb_preferences"
					wait_time="$FAILURE_WAIT_TIME"
					
				## if parsing did not fail then set the qBittorrent listen port
				else
					# display the current listen port
					log_success "Current qBittorrent listen port (TCP): $qb_current_listen_port"
					# if the current listen port does not match the mapped TCP port
					if [[ "$qb_current_listen_port" != "$proton_mapped_tcp_port" ]]; then
						log_subsection "Port mismatch. Updating port $qb_current_listen_port to $proton_mapped_tcp_port"					
						log_subsection "JSON payload: {\"listen_port\":${proton_mapped_tcp_port},\"random_port\":false,\"upnp\":false}"						
						# if the POST request failed then warn user
						if ! qbit_update_preferences "$proton_mapped_tcp_port"; then
							log_error "Failed to update qBittorrent listen port via API"
							wait_time="$FAILURE_WAIT_TIME"
						# if the POST request was successful then check preferences again to confirm the listen port was updated
						else
							# verify the listen port was updated
							log_subsection "Verifying qBittorrent port update"
							# if parsing the JSON response failed then warn user
							if ! qb_verified_listen_port="$(qbit_verify_update "$proton_mapped_tcp_port")"; then
								log_error "Failed to verify qBittorrent listen port update. Expected: $proton_mapped_tcp_port."
								wait_time="$FAILURE_WAIT_TIME"
							# display the updated listen port
							else
								log_success "Updated qBittorrent listen port (TCP): $qb_verified_listen_port"
							fi
						fi
					# if the current listen port does match
					else
						log_subsection "Port match. Nothing to do"
					fi
				fi
			fi
		fi
		
        ## loop complete
		if [[ "$QB_SYNC_ENABLED" == true ]]; then
			log_subsection "Loop complete. Waiting $wait_time seconds before next port forward request and qBittorrent sync"
		else
			log_subsection "Loop complete. Waiting $wait_time seconds before next port forward request"
		fi
		log_section
		# wait before next iteration
        sleep "$wait_time"
    done
}
##############################################################################

main "$@"
