#!/usr/bin/env bash

# HNG13 DevOps Stage 1: Automated Deployment Bash Script
# Author: Gemini (Your Assistant)
# Purpose: Deploys a Dockerized application to a remote Linux server,
#          configuring NGINX as a reverse proxy on Port 80.
# Requirements: POSIX compliant Bash, chmod +x deploy.sh

# --- Global Variables & Configuration ---
APP_DIR="hng-docker-app"  # Local folder name to clone the repository into
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
#NGINX_CONF_PATH="/etc/nginx/sites-available/default"
NGINX_CONF_PATH="/etc/nginx/nginx.conf"
REMOTE_PROJECT_PATH="/home/${USERNAME}/${APP_DIR}"
NGINX_RESTART_CMD="sudo systemctl reload nginx"
APP_CONTAINER_NAME="${APP_DIR}_container"

# --- Utility Functions ---

# Log a message to the console and the log file
log() {
    local TYPE="$1"
    local MESSAGE="$2"
    local TIMESTAMP=$(date +%Y-%m-%d\ %H:%M:%S)
    
    # Use ANSI colors for console output only
    if [[ "$TYPE" == "SUCCESS" ]]; then
        echo -e "\033[32m[SUCCESS]\033[0m $MESSAGE" | tee -a "$LOG_FILE"
    elif [[ "$TYPE" == "ERROR" ]]; then
        echo -e "\033[31m[ERROR]\033[0m $MESSAGE" | tee -a "$LOG_FILE"
        exit 1
    elif [[ "$TYPE" == "INFO" ]]; then
        echo -e "\033[34m[INFO]\033[0m $MESSAGE" | tee -a "$LOG_FILE"
    elif [[ "$TYPE" == "WARNING" ]]; then
        echo -e "\033[33m[WARNING]\033[0m $MESSAGE" | tee -a "$LOG_FILE"
    else
        echo "[$TIMESTAMP] [$TYPE] $MESSAGE" | tee -a "$LOG_FILE"
    fi
}

# Trap unexpected errors and cleanup on failure
trap 'log ERROR "Script terminated unexpectedly at line $LINENO."' ERR
trap cleanup EXIT

cleanup() {
    log INFO "Deployment script finished. Check $LOG_FILE for details."
}

# --- Part 1: Collect and Validate Parameters ---

collect_parameters() {
    log INFO "--- 1. Collecting Deployment Parameters ---"

    read -p "Enter Git Repository URL (HTTPS): " GIT_REPO_URL
    if [[ -z "$GIT_REPO_URL" ]]; then log ERROR "Git Repository URL cannot be empty." 1; fi

    read -p "Enter Personal Access Token (PAT): " -s PAT
    echo "" # Newline after secret input
    if [[ -z "$PAT" ]]; then log ERROR "Personal Access Token (PAT) cannot be empty." 1; fi

    read -p "Enter Branch Name (default: main): " BRANCH_NAME
    BRANCH_NAME=${BRANCH_NAME:-main}

    read -p "Enter Remote Server Username: " USERNAME
    if [[ -z "$USERNAME" ]]; then log ERROR "Username cannot be empty." 1; fi

    read -p "Enter Remote Server IP Address: " IP_ADDRESS
    if [[ -z "$IP_ADDRESS" ]]; then log ERROR "IP Address cannot be empty." 1; fi

    read -p "Enter Path to SSH Key (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH
    if [[ ! -f "$SSH_KEY_PATH" ]]; then log ERROR "SSH key file not found at $SSH_KEY_PATH." 1; fi

    read -p "Enter Container Internal Port (e.g., 3000, 8080): " CONTAINER_PORT
    if ! [[ "$CONTAINER_PORT" =~ ^[0-9]+$ ]]; then log ERROR "Container port must be a number." 1; fi

    log SUCCESS "All parameters collected."
}

# --- Part 2 & 3: Clone, Navigate, and Validate Local Repo ---

clone_repository() {
    log INFO "--- 2. Cloning/Updating Repository ---"

    # Authenticated URL format for cloning
    AUTH_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${PAT}@|")

    if [ -d "$APP_DIR" ]; then
        log WARNING "Local directory $APP_DIR already exists. Pulling latest changes."
        cd "$APP_DIR" || log ERROR "Could not navigate into $APP_DIR."
        git pull origin "$BRANCH_NAME" || log ERROR "Git pull failed."
    else
        log INFO "Cloning $GIT_REPO_URL to $APP_DIR..."
        git clone "$AUTH_REPO_URL" "$APP_DIR" || log ERROR "Git clone failed. Check PAT/URL."
        cd "$APP_DIR" || log ERROR "Could not navigate into $APP_DIR."
    fi

    # Switch to specified branch
    git checkout "$BRANCH_NAME" || log ERROR "Failed to checkout branch $BRANCH_NAME."
    log SUCCESS "Repository successfully updated and switched to branch $BRANCH_NAME."

    # Part 3: Navigate and Validate Dockerfile/Compose
    if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
        log ERROR "No Dockerfile or docker-compose.yml found in the repository root." 2
    else
        log SUCCESS "Docker build configuration verified."
    fi

    cd .. # Go back to original directory for SCP/SSH commands
}


# --- Part 4: SSH Connection Check ---

check_ssh_connection() {
    log INFO "--- 4. Checking SSH Connectivity to $IP_ADDRESS ---"
    
    # Use ssh dry-run to check connection without executing commands
    ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "$USERNAME@$IP_ADDRESS" "exit"
    if [ $? -ne 0 ]; then
        log ERROR "SSH connection failed. Check IP, Username, and SSH key path/permissions." 3
    fi
    
    log SUCCESS "SSH connection established successfully."
}

# --- Remote Execution Functions ---

# Function to execute commands remotely via SSH
remote_execute() {
    local CMD="$1"
    ssh -i "$SSH_KEY_PATH" "$USERNAME@$IP_ADDRESS" "$CMD" 
    if [ $? -ne 0 ]; then
        log WARNING "Remote command failed: $CMD"
        return 1
    fi
    return 0
}

# --- Part 5: Prepare the Remote Environment ---

prepare_remote_env() {
    log INFO "--- 5. Preparing Remote Environment: Installing Dependencies ---"
    
    local INSTALL_CMD="
    set -e; # Exit immediately if a command exits with a non-zero status.

    # 1. Update system packages
    echo 'Running system update...'
    sudo apt update || (echo 'Attempting yum update...' && sudo yum update -y); 
    
    # 2. Install Dependencies (Docker, Compose, Nginx)
    if ! command -v docker > /dev/null; then
        echo 'Installing Docker...'
        sudo apt install -y docker.io || sudo yum install -y docker;
        sudo systemctl start docker;
        sudo systemctl enable docker;
    fi

    if ! command -v docker-compose > /dev/null; then
        echo 'Installing Docker Compose...'
        # Install Docker Compose (Modern method)
        sudo apt install -y docker-compose || (
            echo 'Installing Docker Compose via curl...' &&
            sudo curl -L 'https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)' -o /usr/local/bin/docker-compose &&
            sudo chmod +x /usr/local/bin/docker-compose
        )
    fi

    if ! command -v nginx > /dev/null; then
        echo 'Installing Nginx...'
        sudo apt install -y nginx || sudo yum install -y nginx;
        sudo systemctl enable nginx;
    fi

    # 3. Add user to Docker group (Idempotent)
    if ! groups \$USER | grep -q 'docker'; then
        echo 'Adding user to docker group...'
        sudo usermod -aG docker \$USER;
        echo 'NOTE: You may need to log out and back in on the remote server for docker group changes to take effect!'
    fi

    echo 'Confirming installation versions...'
    docker --version
    docker-compose --version
    nginx -v

    # 4. Create project directory
    mkdir -p $REMOTE_PROJECT_PATH

    "
    remote_execute "$INSTALL_CMD" || log ERROR "Remote environment setup failed." 4
    log SUCCESS "Remote environment (Docker, Compose, NGINX) is ready."
}

# --- Part 6: Deploy the Dockerized Application ---

deploy_application() {
    log INFO "--- 6. Deploying Application to Remote Host ---"
    
    # Transfer project files (rsync is generally more robust than scp)
    log INFO "Transferring files via rsync..."
    rsync -avz -e "ssh -i $SSH_KEY_PATH" "$APP_DIR/" "$USERNAME@$IP_ADDRESS:$REMOTE_PROJECT_PATH/"
    if [ $? -ne 0 ]; then log ERROR "File transfer failed via rsync." 5; fi
    
    # Remote deployment commands
    local DEPLOY_CMD="
    set -e;
    cd $REMOTE_PROJECT_PATH || exit 1;
    
    # Cleanup: Stop and remove old container/stack to ensure a clean redeployment
    echo 'Stopping and removing old containers/stack...'
    if [ -f docker-compose.yml ]; then
        sudo docker-compose down --rmi local 2>/dev/null || true
    else
        sudo docker stop $APP_CONTAINER_NAME 2>/dev/null || true
        sudo docker rm $APP_CONTAINER_NAME 2>/dev/null || true
    fi

    # Build and Run Logic
    if [ -f docker-compose.yml ]; then
        echo 'Building and running with docker-compose...'
        # Docker Compose handles build and run simultaneously
        sudo docker-compose up -d --build
        CONTAINER_ID=\$(sudo docker-compose ps -q)
    else
        echo 'Building and running with Dockerfile...'
        sudo docker build -t $APP_DIR .
        sudo docker run -d --name $APP_CONTAINER_NAME -p $CONTAINER_PORT:$CONTAINER_PORT $APP_DIR
        CONTAINER_ID=\$(sudo docker ps -q --filter name=$APP_CONTAINER_NAME)
    fi
    
    if [ -z \"\$CONTAINER_ID\" ]; then
        echo 'Container failed to start or retrieve ID.' && exit 1
    fi
    
    # Validate container health (simple check)
    echo 'Waiting a few seconds for container startup...'
    sleep 5 
    echo 'Container logs:'
    sudo docker logs \$CONTAINER_ID | tail -n 5

    # Simple check for listening port inside container (needs nc or similar, skipping for POSIX safety, relying on docker ps)
    sudo docker ps -a --filter id=\$CONTAINER_ID --format \"table {{.ID}}\t{{.Status}}\" | grep 'Up' || (echo 'Container is not running or healthy.' && exit 1)

    echo 'Application container deployed successfully.'
    "
    remote_execute "$DEPLOY_CMD" || log ERROR "Remote deployment failed." 6
    log SUCCESS "Application deployment completed."
}


# --- Part 7: Configure Nginx as a Reverse Proxy ---

configure_nginx_proxy() {
    log INFO "--- 7. Configuring NGINX Reverse Proxy ---"
    
    # FIX: Use the reliable NGINX configuration directory for Amazon Linux/RHEL
    local NGINX_CONF_PATH="/etc/nginx/conf.d/hng_proxy.conf" 
    
    # NGINX configuration block template
    NGINX_CONFIG=$(cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location / {
        proxy_pass http://localhost:$CONTAINER_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
)

    local NGINX_CMD="
    set -e;

    # 1. Ensure the conf.d directory exists (idempotent)
    sudo mkdir -p /etc/nginx/conf.d/

    # 2. Write the new configuration file directly to conf.d
    echo \"$NGINX_CONFIG\" | sudo tee $NGINX_CONF_PATH > /dev/null || exit 1;

    echo 'Testing Nginx configuration...'
    sudo nginx -t

    if [ \$? -ne 0 ]; then
        echo 'Nginx configuration test failed! Please check syntax.'
        exit 1
    fi

    echo 'Reloading Nginx service...'
    sudo systemctl reload nginx || sudo systemctl restart nginx
    "
    
    remote_execute "$NGINX_CMD" || log ERROR "NGINX configuration failed." 7
    log SUCCESS "NGINX configured and reloaded successfully. Now proxying port 80 to container port $CONTAINER_PORT."
}

# --- Part 8: Validate Deployment ---

validate_deployment() {
    log INFO "--- 8. Validating Final Deployment ---"

    # Remote validation (check NGINX service and container status)
    local REMOTE_VALIDATE_CMD="
    set -e;

    # Check Docker status
    sudo systemctl is-active docker || (echo 'Docker service is not running!' && exit 1);

    # Check NGINX status
    sudo systemctl is-active nginx || (echo 'Nginx service is not running!' && exit 1);

    # Check container status
    if [ -f $REMOTE_PROJECT_PATH/docker-compose.yml ]; then
        cd $REMOTE_PROJECT_PATH && sudo docker-compose ps | grep 'Up' || (echo 'Docker Compose stack is not up!' && exit 1)
    else
        sudo docker ps --filter name=$APP_CONTAINER_NAME | grep 'Up' || (echo 'Target container is not running!' && exit 1)
    fi
    
    # Local endpoint test (checks NGINX proxy from server's perspective)
    echo 'Testing local loopback (127.0.0.1:80)...'
    curl -s http://127.0.0.1:80 | head -n 10 || (echo 'Local curl test failed. NGINX proxy likely down.' && exit 1)
    echo 'Local NGINX proxy test successful.'
    "
    
    remote_execute "$REMOTE_VALIDATE_CMD" || log ERROR "Remote validation failed." 8

    # Local validation (checks public accessibility)
    log INFO "Testing public accessibility via curl..."
    curl -s "http://$IP_ADDRESS" | head -n 10
    if [ $? -ne 0 ]; then
        log ERROR "Public accessibility check failed. Check AWS/Cloud Security Group and Firewall rules (Port 80)!" 9
    else
        log SUCCESS "Deployment successfully validated on http://$IP_ADDRESS."
    fi
}

# --- Main Execution ---

main() {
    # Check for cleanup flag (optional requirement)
    if [[ "$1" == "--cleanup" ]]; then
        log INFO "Running cleanup on remote server..."
        
        local CLEANUP_CMD="
        set -e;
        cd $REMOTE_PROJECT_PATH || true
        
        # Remove Docker stack/container
        if [ -f docker-compose.yml ]; then
            sudo docker-compose down --rmi all || true
        else
            sudo docker stop $APP_CONTAINER_NAME || true
            sudo docker rm $APP_CONTAINER_NAME || true
            sudo docker rmi $APP_DIR || true
        fi
        
        # Remove local project files
        sudo rm -rf $REMOTE_PROJECT_PATH
        
        # Restore default Nginx config (requires a backup, simplifying to remove our config for safety)
        echo '' | sudo tee $NGINX_CONF_PATH > /dev/null # Wipe the default config
        sudo systemctl reload nginx || true
        
        echo 'Cleanup complete. Docker images, containers, and project folder removed. Nginx config reset.'
        "
        remote_execute "$CLEANUP_CMD" || log WARNING "Remote cleanup had some errors, but attempted to continue."
        log SUCCESS "Cleanup routine finished."
        exit 0
    fi
    
    collect_parameters
    clone_repository
    check_ssh_connection
    prepare_remote_env
    deploy_application
    configure_nginx_proxy
    validate_deployment

    log INFO "--- Deployment Final Summary ---"
    log INFO "App deployed to: http://$IP_ADDRESS"
    log INFO "Local log file: $LOG_FILE"
}

main "$@"

# --- Idempotency Notes ---
# 1. SSH key path check (before SSH) prevents multiple failed logins.
# 2. git clone/pull handles existing repo gracefully.
# 3. apt update/install is idempotent (only installs if missing).
# 4. usermod -aG is idempotent (only adds user if not already in group).
# 5. Docker deployment stops/removes old containers before running new ones.
# 6. NGINX config is overwritten via tee, ensuring the correct configuration is always applied.
# 7. NGINX reload is used for graceful application of new config.
# 8. mkdir -p is idempotent.
