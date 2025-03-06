#!/bin/bash
set -e

echo "Building Application...."

##############################
# 1. System Update & Upgrade
##############################
read -p "Perform System Updates? (y/n) " update_choice
if [[ "$update_choice" =~ ^[Yy]$ ]]; then
    echo "Updating system..."
    apt-get update && apt-get upgrade -y
fi

##############################
# 2. Uninstall Conflicting Docker Packages
##############################
echo "Preparing Environment..."
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg || true
done

##############################
# 3. Install Prerequisites for Docker
##############################
echo "Installing prerequisites..."
apt-get install -y ca-certificates curl gnupg

##############################
# 4. Set Up Docker’s Apt Repository
##############################
echo "Setting up Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the Docker repository to your sources list.
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update

##############################
# 5. Install Docker Engine and Plugins
##############################
echo "Installing Docker Engine..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

##############################
# 6. Start and Enable Docker Service
##############################
echo "Starting/Enabling Docker..."
systemctl enable docker
systemctl start docker

# Test Docker installation (optional)
echo "Verifying Docker installation..."
docker run --rm hello-world

##############################
# 7. Post-installation Steps for Docker
##############################
# Add the invoking non-root user (from sudo) to the docker group so docker commands run without sudo.
if [ "$SUDO_USER" ]; then
    NON_ROOT_USER="$SUDO_USER"
else
    NON_ROOT_USER="$(whoami)"
fi

echo "Adding user '$NON_ROOT_USER' to the docker group..."
usermod -aG docker "$NON_ROOT_USER"
echo "NOTE: You may need to log out and back in (or run 'newgrp docker') for the group change to take effect."

##############################
# 8. Install Additional Packages
##############################
echo "Installing additional packages..."
apt-get install -y git rsyslog python3 python3-venv python3-pip npm

##############################
# 9. Clone Repositories
##############################
if [ ! -d "Backend" ]; then
    echo "Cloning Backend repository..."
    git clone https://github.com/ValorenceCLE/Backend.git
else
    echo "Backend repository already exists. Skipping clone."
fi

if [ ! -d "Frontend" ]; then
    echo "Cloning Frontend repository..."
    git clone https://github.com/ValorenceCLE/Frontend.git
else
    echo "Frontend repository already exists. Skipping clone."
fi

##############################
# 10. Collect Environment Variables & Secrets
##############################
echo "Setting up custom environment and secrets..."
read -p "Enter App Name: " APP_NAME
read -p "Enter App Secret Key: " SECRET_KEY
read -p "Enter Access Token Expire Minutes: " ACCESS_TOKEN_EXPIRE_MINUTES
read -p "Enter USER username: " USER_USERNAME
read -s -p "Enter USER password: " USER_PASSWORD
echo ""
read -p "Enter ADMIN username: " ADMIN_USERNAME
read -s -p "Enter ADMIN password: " ADMIN_PASSWORD
echo ""

# Ensure the secrets directory exists in the Backend repository
mkdir -p Backend/secrets

echo "Hashing passwords..."
HASHED_USER_PASSWORD=$(python3 -c "import sys, hmac, hashlib; print(hmac.new(sys.argv[2].encode(), sys.argv[1].encode(), hashlib.sha256).hexdigest())" "$USER_PASSWORD" "$SECRET_KEY")
HASHED_ADMIN_PASSWORD=$(python3 -c "import sys, hmac, hashlib; print(hmac.new(sys.argv[2].encode(), sys.argv[1].encode(), hashlib.sha256).hexdigest())" "$ADMIN_PASSWORD" "$SECRET_KEY")

echo "Saving settings..."
cat <<EOF > Backend/secrets/settings.env
APP_NAME=$APP_NAME
SECRET_KEY=$SECRET_KEY
ACCESS_TOKEN_EXPIRE_MINUTES=$ACCESS_TOKEN_EXPIRE_MINUTES
USER_USERNAME=$USER_USERNAME
HASHED_USER_PASSWORD=$HASHED_USER_PASSWORD
ADMIN_USERNAME=$ADMIN_USERNAME
HASHED_ADMIN_PASSWORD=$HASHED_ADMIN_PASSWORD
EOF

##############################
# 11. Build Docker Containers
##############################
echo "Building Docker containers..."
# Using the official Docker Compose plugin, we use "docker compose" (with a space)
docker compose build

##############################
# 12. Full Setup vs. Demo Setup
##############################
read -p "Do you want to setup the development environment? (y/n): " setup_type
if [ "$setup_type" == "y" ]; then
    echo "Setting up development environment..."

    # Frontend Setup: Install dependencies and build
    echo "Installing Frontend Packages..."
    cd Frontend
    npm install
    npm run build
    cd ..

    # Backend Setup: Create a virtual environment and install Python dependencies
    echo "Installing Backend Packages..."
    cd Backend
    python3 -m venv venv
    source venv/bin/activate
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    else
        echo "requirements.txt not found in Backend directory."
    fi
    deactivate
    cd ..
else
    echo "Proceeding with Lite setup..."
fi


##############################
# 13. Systemd Service for Docker Compose
##############################
read -p "Do you want Docker Compose to run on startup? (y/n) " startup_choice
if [[ "$startup_choice" =~ ^[Yy]$ ]]; then
    echo "Creating service for Docker Compose..."
    SERVICE_FILE="/etc/systemd/system/docker-compose-ValorenceCLE.service"
    # Use the docker command (with the compose subcommand) from the installed plugin
    DOCKER_CMD=$(which docker)
    WORKING_DIR=$(pwd)
    
    cat <<EOF > $SERVICE_FILE
[Unit]
Description=Docker Compose Application Service
Requires=docker.service
After=docker.service

[Service]
WorkingDirectory=$WORKING_DIR
ExecStart=$DOCKER_CMD compose up
ExecStop=$DOCKER_CMD compose down
Restart=always
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable docker-compose-ValorenceCLE.service
    echo "Service enabled. Docker Compose will run on startup."

    read -p "Do you want to reboot now? (y/n) " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo "Rebooting system..."
        reboot
    else
        echo "Reboot skipped. Setup complete."
    fi
else
    read -p "Do you want to run 'docker compose up' now? (y/n) " run_choice
    if [[ "$run_choice" =~ ^[Yy]$ ]]; then
        docker compose up
    else
        read -p "Do you want to reboot now? (y/n) " reboot_choice
        if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
            echo "Rebooting system..."
            reboot
        else
            echo "Reboot skipped. Setup done."
            exit 0
        fi
    fi
fi
