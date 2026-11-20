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
# 2026.11.20
#
## Steps
# 1. parses environment variables
# 2. Test if the VPN gateway supports port forwarding (Proton uses 10.2.0.1)
# 3. If port forwarding support is present, request port forwarding for UDP/TCP and output to console
# 4. if syncing qBittorrent is enabled:
# 		a. checks current listen port via API
#		b. compares listen port to mapped port from natpmp (tcp)
#		c. if needed, sets the listen port via API to match natpmp (tcp)
#		d. verifies the new port matches natpmp (tcp)
# 5. if any step fails then the script will output the command output for debugging and reduce loop wait time
##############################################################################


## Configuration Constants
# bash settings
set -euo pipefail
# the URL used to retrieve the public IP address
readonly CURL_IP_URL='https://ip.me'
# the PMP gateway for ProtonVPN from the article
readonly PROTON_GW_IP='10.2.0.1'
# the key name for the public IP returned by natpmpc
readonly NATPMP_READ_PUBLIC_IP_STR='Public IP'
# if a NAT response returns a success then the output will have the following format
readonly NATPMP_SUCCESS_REGEX='readnatpmpresponseorretry returned [0-9]+ \((OK|SUCCESS)\)'
# if port mapping is successful then the output will have the following format for UDP/TCP
readonly NATPMP_PORT_MAP_REGEX='Mapped public port [0-9]+ protocol (UDP|TCP)'
# ipv4 address regex
readonly IPV4_REGEX='([0-9]{1,3}\.){3}[0-9]{1,3}'
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
## general functions
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

log_section() {
    echo "$OUTPUT_DIVIDER"
}

# show additional informational messages to indicate where in the script the loop is better
log_subsection() {
    if [[ "$COMPACT_OUTPUT" == false ]]; then
        echo "[$1]"
    fi
}

# show error messages between a sub-divider
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

# show checkmark for successful operations
log_success() {
    echo "✓ $1"
}

invoke_curl_ip_get_cmd() {
    local output
	if output="$(curl -s "$CURL_IP_URL" 2>&1)"; then
		echo "$output"
        return 0
	else
        return 1
	fi
}

parse_curl_ip_get_cmd_output() {
    local input
    input="$1"
    if grep -qE "$IPV4_REGEX" <<< "$input"; then
        echo "$input" | grep -E "$IPV4_REGEX" | tr -d ' '
        return 0
    else
        echo "$input"
        return 1
    fi
}
##############################################################################

##############################################################################
## natpmp functions
parse_natpmp_cmd_success() {
    local input
    input="$1"
    if grep -qE "$NATPMP_SUCCESS_REGEX" <<< "$input"; then
        return 0
    else
        return 1
    fi
}

invoke_test_natpmp_gateway_cmd() {
    local testoutput
    if testoutput="$(natpmpc -g "$PROTON_GW_IP" 2>&1)"; then
        if parse_natpmp_cmd_success "$testoutput"; then
            echo "$testoutput"
            return 0
        else
            echo "$testoutput"
            return 1
        fi
    else
        echo "$testoutput"
        return 1
    fi
}

parse_test_natpmp_gateway_cmd_public_ip() {
    local input
    input="$1"
    if parse_natpmp_cmd_success "$input"; then
        echo "$input" | grep "$NATPMP_READ_PUBLIC_IP_STR" | cut -d ':' -f 2 | tr -d ' '
        return 0
    else
        echo "$input"
        return 1
    fi
}

invoke_port_forward_request_cmd() {
    local output
	local protocol
	protocol="$1"
	if output="$(natpmpc -a 1 0 "$protocol" 60 -g "$PROTON_GW_IP" 2>&1)"; then
		echo "$output"
        return 0
	else
		echo "$output"
		return 1
	fi
}

# parse port forward request output, if error return the original command output
parse_port_forward_request_cmd_port() {
    local input
    input="$1"
    if parse_natpmp_cmd_success "$input"; then
        echo "$input" | grep -oE "$NATPMP_PORT_MAP_REGEX" | awk '{print $4}'
        return 0
    else
        echo "$input"
        return 1
    fi
}
##############################################################################

##############################################################################
## qBittorrent API Functions (only called if QB_SYNC_ENABLED=true)
# get the preferences
qbit_get_preferences_cmd() {
    local apiRequest
    if apiRequest="$(curl -s -X GET "$QB_GET_ENDPOINT" -H "Authorization: Bearer $QB_API_KEY_NORMALIZED" 2>&1)"; then
		echo "$apiRequest"
        return 0
	else
		echo "$apiRequest"
		return 1
	fi
}

parse_qbit_get_preferences_cmd_listen_port() {
    local input
    local listen_port
    input="$1"
    if listen_port="$(echo "$input" | jq -r '.listen_port' 2>&1)"; then
        echo "$listen_port"
        return 0
    else
        echo "$input"
        return 1
    fi
}

qbit_update_preferences_cmd() {
    local apiRequest
    local listen_port="$1"
    local qb_json_payload
	qb_json_payload="{\"listen_port\":${listen_port},\"random_port\":false,\"upnp\":false}"
    if apiRequest="$(curl -s -X POST "$QB_SET_ENDPOINT" -H "Authorization: Bearer $QB_API_KEY_NORMALIZED" --data-urlencode "json=${qb_json_payload}" 2>&1)"; then
        echo "$apiRequest"
        return 0
    else
        echo "$apiRequest"
        return 1
    fi
}
##############################################################################

##############################################################################
## Main Execution
main() {
	## Parse all environment variables once at startup  
    parse_environment

    ## start loop
    while true; do
        log_section
        # Initialize variables for this loop iteration
        local curl_ip_get_output=""
        local curl_public_ip_output=""
        local natpmpc_allowed_output=""
        local natpmpc_allowed=false
        local natpmpc_public_ip_output=""
        local natpmpc_public_ip_parse_success=false
        local natpmpc_udp_output=""
        local natpmpc_udp_request_success=false
        local natpmpc_udp_parse_success=false
        local natpmpc_tcp_output=""
        local natpmpc_tcp_request_success=false
        local natpmpc_tcp_parse_success=false
        local natpmp_mapped_udp_port=""
        local natpmp_mapped_tcp_port=""
		local qb_current_listen_port=0
		local qb_preferences=""
		local qb_verified_listen_port=0
        local wait_time="$DEFAULT_WAIT_TIME"
        
        if [[ "$SKIP_IPME_CHECK" == false ]]; then
            ## get public IP from ip.me (SKIP_IPME_CHECK=false)
            # this should always match what natpmp returns
            # should only be different if we're not connected to VPN
            log_subsection "Fetching public IP from ip.me. (SKIP_IPME_CHECK=false)"
            # if curl command fails then log error and continue
            if ! curl_ip_get_output=$(invoke_curl_ip_get_cmd); then
                log_error "Failed to get public IP from ip.me. Command output:" "$curl_ip_get_output"
            # if curl command succeeds
            else
                # if parsing the output fails then log error and continue
                if ! curl_public_ip_output="$(parse_curl_ip_get_cmd_output "$curl_ip_get_output")"; then
                    log_error "Failed to parse public IP from ip.me. Command output:" "$curl_ip_get_output"
                # if parsing the output succeeds then log success with public IP
                else
                    log_success "Public IP (ip.me): $curl_public_ip_output"
                fi
            fi
        ## if SKIP_IPME_CHECK=true then skip the public IP fetch from ip.me            
        else
            log_subsection "Skipping public IP fetch from ip.me. (SKIP_IPME_CHECK=true)"
        fi

        ## test if the gateway allows port forwarding
		# this will take a long time if we're not connected to VPN or not on a P2P enabled server
		log_subsection "Testing natpmp gateway support for $PROTON_GW_IP"
        # if testing the nat-pmp gateway fails then log error
        if ! natpmpc_allowed_output=$(invoke_test_natpmp_gateway_cmd); then
            # if parsing the output fails then log error and reduce wait time for next loop iteration
            log_error "Gateway support (NAT-PMP): false. Check if server is P2P enabled, check VPN connection, or check container traffic routing. Command output:" "$natpmpc_allowed_output"
            wait_time="$FAILURE_WAIT_TIME"
        # if testing the nat-pmp gateway succeeds
        else
            natpmpc_allowed=true
        fi

        if [[ "$natpmpc_allowed" == true ]]; then
            # log gateway support test success
            log_success "Gateway support (NAT-PMP): true"
            ## fetch the public IP from natpmpc and log success or error
            log_subsection "Fetching public IP from NAT-PMP"
            # if parsing the output fails then log error and reduce wait time for next loop iteration
            if ! natpmpc_public_ip_output=$(parse_test_natpmp_gateway_cmd_public_ip "$natpmpc_allowed_output"); then
                log_error "Failed to get public IP from NAT-PMP. Command output:" "$natpmpc_allowed_output"
                wait_time="$FAILURE_WAIT_TIME"
            # if parsing the output succeeds then log success with public IP
            else
                natpmpc_public_ip_parse_success=true
                log_success "Public IP (NAT-PMP): $natpmpc_public_ip_output"
            fi
        fi

        ## request the UDP port forward and log success or error
        if [[ "$natpmpc_allowed" == true && "$natpmpc_public_ip_parse_success" == true ]]; then
            log_subsection "Requesting UDP port forward via NAT-PMP from $PROTON_GW_IP"
            # if requesting the UDP port forward fails then log error and reduce wait time for next loop iteration
            if ! natpmpc_udp_output=$(invoke_port_forward_request_cmd "udp"); then
                log_error "Failed to request UDP port forward via NAT-PMP. Command output:" "$natpmpc_udp_output"
                wait_time="$FAILURE_WAIT_TIME"
            # if requesting the UDP port forward succeeds
            else
                natpmpc_udp_request_success=true
            fi
        fi

        ## parse the output for the mapped UDP port and log success or error
        if [[ "$natpmpc_allowed" == true && "$natpmpc_public_ip_parse_success" == true && "$natpmpc_udp_request_success" == true ]]; then
            # if parsing the output for the mapped UDP port fails then log error and reduce wait time for next loop iteration
            if ! natpmp_mapped_udp_port=$(parse_port_forward_request_cmd_port "$natpmpc_udp_output"); then
                log_error "Failed to parse UDP port from forward request response. Command output:" "$natpmp_mapped_udp_port"
                wait_time="$FAILURE_WAIT_TIME"
            # if parsing the output for the mapped UDP port succeeds then log success with mapped UDP port
            else
                natpmpc_udp_parse_success=true
                log_success "Forwarded port (UDP): $natpmp_mapped_udp_port"
            fi
        fi

        ## request the TCP port forward and log success or error
        if [[ "$natpmpc_allowed" == true && "$natpmpc_public_ip_parse_success" == true && "$natpmpc_udp_request_success" == true && "$natpmpc_udp_parse_success" == true ]]; then
            log_subsection "Requesting TCP port forward via NAT-PMP from $PROTON_GW_IP"
            # if requesting the TCP port forward fails then log error and reduce wait time for next loop iteration
            if ! natpmpc_tcp_output=$(invoke_port_forward_request_cmd "tcp"); then
                log_error "Failed to request TCP port forward via NAT-PMP. Command output:" "$natpmpc_tcp_output"
                wait_time="$FAILURE_WAIT_TIME"
            # if requesting the TCP port forward succeeds
            else
                natpmpc_tcp_request_success=true
            fi
        fi

        ## parse the output for the mapped TCP port and log success or error
        if [[ "$natpmpc_allowed" == true && "$natpmpc_public_ip_parse_success" == true && "$natpmpc_udp_request_success" == true && "$natpmpc_udp_parse_success" == true && "$natpmpc_tcp_request_success" == true ]]; then
            # if parsing the output for the mapped TCP port fails then log error and reduce wait time for next loop iteration
            if ! natpmp_mapped_tcp_port=$(parse_port_forward_request_cmd_port "$natpmpc_tcp_output"); then
                log_error "Failed to parse TCP port from forward request response. Command output:" "$natpmp_mapped_tcp_port"
                wait_time="$FAILURE_WAIT_TIME"
            # if parsing the output for the mapped TCP port succeeds then log success with mapped TCP port
            else
                natpmpc_tcp_parse_success=true
                log_success "Forwarded port (TCP): $natpmp_mapped_tcp_port"
            fi
        fi

        ## Sync forwarded TCP port with qBittorrent listen port
        if [[ "$QB_SYNC_ENABLED" == true && "$natpmpc_tcp_parse_success" == true ]]; then
            local qb_preferences_get_success
            qb_preferences_get_success=false
            local qb_listen_port_parse_success
            qb_listen_port_parse_success=false
            local qb_port_mismatch
            qb_port_mismatch=false
            local qb_port_update_success
            qb_port_update_success=false
            local qb_preferences_verify_get_success
            qb_preferences_verify_get_success=false

            ## qBittorrent preferences fetch
            log_subsection "Fetching current qBittorrent preferences from: $QB_GET_ENDPOINT"
            # if fetching the preferences fails then log error and reduce wait time for next loop iteration
            if ! qb_preferences=$(qbit_get_preferences_cmd); then
                log_error "Failed to get qBittorrent preferences. Please check API key and WebUI URL. Command output:" "$qb_preferences"
                wait_time="$FAILURE_WAIT_TIME"
            # if fetching the preferences succeeds
            else
                qb_preferences_get_success=true
            fi

            ## parse the listen port from the preferences
            if [[ "$qb_preferences_get_success" == true ]]; then
                # if parsing the listen port from the preferences fails then log error and reduce wait time for next loop iteration
                if ! qb_current_listen_port=$(parse_qbit_get_preferences_cmd_listen_port "$qb_preferences"); then
                    log_error "Failed to parse qBittorrent listen port from preferences. Command output:" "$qb_current_listen_port"
                    wait_time="$FAILURE_WAIT_TIME"
                # if parsing the listen port from the preferences succeeds then log success with current listen port
                else
                    log_success "Current qBittorrent listen port (TCP): $qb_current_listen_port"
                    qb_listen_port_parse_success=true
                fi
            fi

            ## compare the current listen port to the mapped TCP port
            if [[ "$qb_preferences_get_success" == true && "$qb_listen_port_parse_success" == true ]]; then
                # if the current listen port does not match the mapped TCP port then update the listen port
                if [[ "$qb_current_listen_port" != "$natpmp_mapped_tcp_port" ]]; then
                    qb_port_mismatch=true
                    log_subsection "$qb_current_listen_port (QBT) != $natpmp_mapped_tcp_port (NATPMP). JSON payload: {\"listen_port\":${natpmp_mapped_tcp_port},\"random_port\":false,\"upnp\":false}"
                else
                    qb_port_mismatch=false
                    log_subsection "$qb_current_listen_port (QBT) == $natpmp_mapped_tcp_port (NATPMP). No update needed."
                fi
            fi

            ## update the listen port to match the mapped TCP port
            if [[ "$qb_preferences_get_success" == true && "$qb_listen_port_parse_success" == true && "$qb_port_mismatch" == true ]]; then
                log_subsection "Updating qBittorrent listen port to match mapped TCP port: $natpmp_mapped_tcp_port"
                # if updating the listen port fails then log error and reduce wait time for next loop iteration
                if ! qb_update_output=$(qbit_update_preferences_cmd "$natpmp_mapped_tcp_port"); then
                    log_error "Failed to update qBittorrent listen port. Command output:" "$qb_update_output"
                    wait_time="$FAILURE_WAIT_TIME"
                # if updating the listen port succeeds then log success with updated listen port
                else
                    qb_port_update_success=true
                fi
            fi

            ## get the preferences again to verify the listen port was updated
            if [[ "$qb_preferences_get_success" == true && "$qb_listen_port_parse_success" == true && "$qb_port_mismatch" == true && "$qb_port_update_success" == true ]]; then
                log_subsection "Fetching qBittorrent preferences again to verify listen port update from: $QB_GET_ENDPOINT"
                # if fetching the preferences fails then log error and reduce wait time for next loop iteration
                if ! qb_preferences_verify=$(qbit_get_preferences_cmd); then
                    log_error "Failed to get qBittorrent preferences after listen port update. Command output:" "$qb_update_output"
                    wait_time="$FAILURE_WAIT_TIME"
                # if fetching the preferences succeeds then log success
                else
                    qb_preferences_verify_get_success=true
                fi
            fi
            
            ## verify the listen port matches the mapped TCP port
            if [[ "$qb_preferences_get_success" == true && "$qb_listen_port_parse_success" == true  && "$qb_port_mismatch" == true && "$qb_port_update_success" == true && "$qb_preferences_verify_get_success" == true ]]; then
                # if fetching the preferences fails then log error and reduce wait time for next loop iteration
                if ! qb_verified_listen_port=$(parse_qbit_get_preferences_cmd_listen_port "$qb_preferences_verify"); then
                    log_error "Failed to verify updated qBittorrent listen port. Command output:" "$qb_verified_listen_port"
                    wait_time="$FAILURE_WAIT_TIME"
                # if fetching the preferences succeeds then log success with verified listen port
                else
                    log_success "Updated qBittorrent listen port (TCP): $qb_verified_listen_port"
                fi
            fi
        fi

        ## loop complete
		if [[ "$QB_SYNC_ENABLED" == true ]]; then
			log_subsection "Loop complete. Waiting $wait_time seconds before next port forward request and qBittorrent listen port sync"
		else
			log_subsection "Loop complete. Waiting $wait_time seconds before next port forward request"
		fi
		log_section
		# wait before next iteration
        sleep "$wait_time"
    done
}
##############################################################################

##############################################################################
## start the main function
main "$@"
##############################################################################