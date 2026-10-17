Changelog
===
- v2026.10.17
    - Changed to saving the natpmpc output to script variables instead of files in /tmp (reduces disk usage)
    - Updated to hardened Alpine 3.24-dev


Description
===
Source code: https://github.com/blomstertj/protonvpn-natpmp-docker

Runs the NATPMP loop from the ProtonVPN manual port forward guide in a nice script. This process is detailed in Proton's support article here: https://protonvpn.com/support/port-forwarding-manual-setup#linux

- This "microservice" container is:
    - lightweight and secure (based on Alpine Docker hardened image and uses nonroot user)
    - uses basic Linux tools (bash, curl, and libnatpmp)
    - relies on an external device/service/container to direct the traffic through VPN
        - Routers and firewalls can send traffic from specific IP addresses and/or MAC addresses through the VPN

The purpose of the container is to spit out the port numbers to put in your other applications like a BitTorrent client. You don't need to run natpmpc on the same device, the ports will work for all devices that use the VPN. I'm working on a separate version with a different tag to update qBittorrent torrent port via API.


How I use it
===
I connect to ProtonVPN using WireGuard with my router. This configuration does not support port forwarding unless you have a loop running all the time to keep the port forwards open. I decided to create my own light weight container based on Alpine to run this natpmpc loop with some cleaned up console output. I use Dockhand to view the console logs but you can run "docker logs ContainerName" to view the console.


Environment vars
===
- COMPACT_OUTPUT
    - only outputs public IP(s) and forwarded ports on successful loop run
- SKIP_IPME_CHECK
    - skips the public IP check to Proton operated https://ip.me
- TZ
    - Set timezone for correct log timestamps


Example docker compose
===
```
services:
  container_name: "protonvpn-natpmp"
    environment:
      - "COMPACT_OUTPUT=true"
      - "SKIP_IPME_CHECK=false"
      - "TZ=America/Chicago"
    hostname: "protonvpn-natpmp"
    image: "blomstertj/protonvpn-natpmp:latest"
    mac_address: "92:ec:7c:a2:69:fd"
    networks:
      bond0-macvlan:
        ipv4_address: "192.168.1.100"
    restart: "always"
networks:
  bond0-macvlan:
    external: true
    name: "bond0-macvlan"
```
Example console output
===
<br>
<img alt="Console Output Example" src="https://raw.githubusercontent.com/blomstertj/protonvpn-natpmp-docker/refs/heads/main/console-output-example.png">


Example compact console output
===
<img alt="Compact Console Output Example" src="https://raw.githubusercontent.com/blomstertj/protonvpn-natpmp-docker/refs/heads/main/compact-console-output-example.png">


Example console error output
===
<br>
<img alt="Console Output Example" src="https://raw.githubusercontent.com/blomstertj/protonvpn-natpmp-docker/refs/heads/main/console-output-error-example.png">