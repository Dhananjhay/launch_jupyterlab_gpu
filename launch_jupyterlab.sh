#!/usr/bin/env bash
set -euo pipefail

SERVER="gpu-instance-$USER"
FLOATING_IP_LIST=("206.12.92.67" "206.12.94.44")
TMP="/tmp/${SERVER}_console.log"
GREEN='\033[32m'
RED='\033[31m'
NC='\033[0m'  # No Color

# Logic to delete the instance
exit_script() {
  echo -e "${RED}Script failed or was interrupted!${NC}"
  echo -e "${RED}Shutting down JupyterLab and deleting instance: ${SERVER}${NC}"
  [ -n "$SERVER" ] && openstack server delete "$SERVER"
}

# trap exit_script EXIT
trap exit_script SIGINT SIGTERM

# To use an OpenStack cloud you need to authenticate against the Identity
# service named keystone, which returns a **Token** and **Service Catalog**.
# The catalog contains the endpoints for all services the user/tenant has
# access to - such as Compute, Image Service, Identity, Object Storage, Block
# Storage, and Networking (code-named nova, glance, keystone, swift,
# cinder, and neutron).
#
# *NOTE*: Using the 3 *Identity API* does not necessarily mean any other
# OpenStack API is version 3. For example, your cloud provider may implement
# Image API v1.1, Block Storage API v2, and Compute API v2.0. OS_AUTH_URL is
# only for the Identity API served through keystone.
export OS_AUTH_URL=https://arbutus.cloud.computecanada.ca:5000
# With the addition of Keystone we have standardized on the term **project**
# as the entity that owns the resources.
export OS_PROJECT_ID=2e8dbbe67d9c4b5cb26c4e22dab7de50
export OS_PROJECT_NAME="rrg-akhanf"
export OS_USER_DOMAIN_NAME="CCDB"
if [ -z "$OS_USER_DOMAIN_NAME" ]; then unset OS_USER_DOMAIN_NAME; fi
export OS_PROJECT_DOMAIN_ID="e05dc10d20cf47f38ce2443f4c0d7ee5"
if [ -z "$OS_PROJECT_DOMAIN_ID" ]; then unset OS_PROJECT_DOMAIN_ID; fi
# unset v2.0 items in case set
unset OS_TENANT_ID
unset OS_TENANT_NAME
# In addition to the owning entity (tenant), OpenStack stores the entity
# performing the action as the **user**.
echo "Please enter your OpenStack Username for project $OS_PROJECT_NAME: "
read -r OS_USERNAME_INPUT
export OS_USERNAME=$OS_USERNAME_INPUT
# With Keystone you pass the keystone password.
echo "Please enter your OpenStack Password for project $OS_PROJECT_NAME as user $OS_USERNAME: "
read -sr OS_PASSWORD_INPUT
export OS_PASSWORD=$OS_PASSWORD_INPUT
# If your configuration has multiple regions, we set that information here.
# OS_REGION_NAME is optional and only valid in certain environments.
export OS_REGION_NAME="RegionOne"
# Don't leave a blank variable, unset it if it was empty
if [ -z "$OS_REGION_NAME" ]; then unset OS_REGION_NAME; fi
export OS_INTERFACE=public
export OS_IDENTITY_API_VERSION=3

echo "Checking for available Floating IP"

# check which of two floatig ips is available
for i in "${FLOATING_IP_LIST[@]}"; do
  out=$(openstack floating ip show "$i" -f value -c fixed_ip_address 2>/dev/null)
  rc=$?
  out=$(echo "$out" | xargs)
  if [ $rc -eq 0 ] && [ -n "$out" ] && [ "$out" = "None" ]; then
    FLOATING_IP=$i
    break
  fi
  echo -e "${RED}$i not available${NC}"
done
[ -n "${FLOATING_IP:-}" ] || { echo "no available floating IP" >&2; exit 1; }
echo -e "${GREEN}selected $FLOATING_IP${NC}"

# Check if an instance with the same name already exists



echo -e "${GREEN}Launching a GPU instance: $SERVER${NC}"
# Create a server
openstack server create --image "Ubuntu-22.04.4-Jammy-x64-2024-06" --flavor "g1-8gb-c4-22gb" --network rrg-akhanf-network --user-data cloud-init.yml --key-name my-keypair $SERVER >/dev/null


# Waiting for runner to become active
echo "Waiting for instance to become active..."
for i in {1..60}; do
  status=$(openstack server show "$SERVER" -f value -c status 2>/dev/null || true)
  status=$(echo "$status" | xargs)   # trim
  if [ "$status" = "ACTIVE" ]; then
    echo -e "${GREEN}Instance Active${NC}"
    openstack server add floating ip "$SERVER" "$FLOATING_IP"
    echo -e "${GREEN}Floating ip $FLOATING_IP associated${NC}"
    break
  fi
    sleep 10
    if [ "$i" -eq 60 ]; then
        echo -e "${RED}Instance did not become active after $((i*10))s; aborting${NC}" >&2
        echo -e "{$RED}Instance did not become active after $((i*10))s; aborting${NC}" >&2
        openstack server delete $SERVER
        exit 1
    fi
done


token=""
echo "Waiting for jupyterlab to start (Takes around 5 minutes)..."
while true; do
  openstack console log show "$SERVER" --lines 500 2>/dev/null > "$TMP"
  # look for the localhost URL
  if grep -E -q 'http://localhost:8181' "$TMP"; then
    token=$(sed -nE 's/.*token=([^&[:space:]]+).*/\1/p' "$TMP" | head -n1)
    echo "Jupyter started — printing recent console lines:"
    tail -n 20 "$TMP"
    break
  fi
  sleep 5
done

echo -e "${GREEN}Remote tunneling into Jupyterlab server now...${NC}"

ssh-keygen -R "$FLOATING_IP" # remove old entry
ssh-keyscan -H "$FLOATING_IP" >> "/home/UWO/${USER}/.ssh/known_hosts"

echo -e "${GREEN}JupyterLab started successfully!${NC}"
echo -e "${GREEN}Open Firefox → localhost:8000${NC}"
echo -e "${GREEN}JupyterLab token:${NC} $token"
echo -e "${RED}Press Ctrl+C to exit${NC}"

ssh -i ~/.ssh/id_rsa "ubuntu@$FLOATING_IP" -L 8000:localhost:8181 -N