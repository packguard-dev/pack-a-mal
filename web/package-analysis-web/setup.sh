#!/bin/bash

# Auto-setup script for Package Analysis Web Project
# This script automates the installation and setup process

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
DB_NAME="packamal"
DB_USER="pakaremon"
DB_PASSWORD="rock-beryl-say-devices"
VENV_NAME="env"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -eq 0 ]; then 
        print_error "Please do not run this script as root. It will use sudo when needed."
        exit 1
    fi
}

# Function to check OS
check_os() {
    if [ ! -f /etc/os-release ]; then
        print_error "Cannot detect operating system"
        exit 1
    fi
    
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] && [[ "$ID_LIKE" != *"ubuntu"* ]] && [[ "$ID_LIKE" != *"debian"* ]]; then
        print_warning "This script is designed for Ubuntu/Debian. Other distributions may work but are not tested."
    fi
}

# Function to install system dependencies
install_system_dependencies() {
    print_info "Installing system dependencies..."
    
    sudo apt update
    sudo apt install -y \
        python3 \
        python3-pip \
        python3-dev \
        python3-venv \
        libpq-dev \
        postgresql \
        postgresql-contrib \
        git
    
    print_info "System dependencies installed successfully"
}

# Function to create virtual environment
setup_virtualenv() {
    print_info "Setting up Python virtual environment..."
    
    if [ -d "$VENV_NAME" ]; then
        print_warning "Virtual environment already exists. Removing old one..."
        rm -rf "$VENV_NAME"
    fi
    
    python3 -m venv "$VENV_NAME"
    print_info "Virtual environment created successfully"
}

# Function to activate virtual environment and install dependencies
install_python_dependencies() {
    print_info "Installing Python dependencies..."
    
    source "$VENV_NAME/bin/activate"
    pip install --upgrade pip
    pip install -r requirements.txt
    
    print_info "Python dependencies installed successfully"
}

# Function to setup PostgreSQL database
setup_database() {
    print_info "Setting up PostgreSQL database..."
    
    # Check if PostgreSQL is running
    if ! sudo systemctl is-active --quiet postgresql; then
        print_info "Starting PostgreSQL service..."
        sudo systemctl start postgresql
        sudo systemctl enable postgresql
    fi
    
    # Create database and user
    print_info "Creating database and user..."
    
    sudo -u postgres psql <<EOF
-- Drop database and user if they exist (for clean setup)
DROP DATABASE IF EXISTS $DB_NAME;
DROP USER IF EXISTS $DB_USER;

-- Create database
CREATE DATABASE $DB_NAME;

-- Create user with password
CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';

-- Configure user settings
ALTER ROLE $DB_USER SET client_encoding TO 'utf8';
ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';
ALTER ROLE $DB_USER SET timezone TO 'UTC';

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;

-- Make user a superuser (for development - remove in production)
ALTER USER $DB_USER CREATEDB;
EOF
    
    print_info "Database setup completed successfully"
}

# Function to create .env file
create_env_file() {
    print_info "Creating .env file..."
    
    ENV_FILE="$PROJECT_DIR/.env"
    
    if [ -f "$ENV_FILE" ]; then
        print_warning ".env file already exists. Creating backup..."
        cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Generate secret key
    source "$VENV_NAME/bin/activate"
    SECRET_KEY=$(python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())')
    
    cat > "$ENV_FILE" <<EOF
# Django Settings
SECRET_KEY=$SECRET_KEY
DEBUG=True
ALLOWED_HOSTS=127.0.0.1,localhost

# Database Settings
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_HOST=localhost
DB_PORT=5432
EOF
    
    print_info ".env file created successfully"
    print_warning "Please review and update the .env file if needed"
}

# Function to run Django migrations
run_migrations() {
    print_info "Running Django migrations..."
    
    source "$VENV_NAME/bin/activate"
    python manage.py collectstatic --noinput
    python manage.py makemigrations
    python manage.py migrate
    
    print_info "Migrations completed successfully"
}

# Function to collect static files
collect_static() {
    print_info "Collecting static files..."
    
    source "$VENV_NAME/bin/activate"
    python manage.py collectstatic --noinput
    
    print_info "Static files collected successfully"
}

# Function to install Docker
install_docker() {
    print_info "Setting up Docker..."
    
    # Check if Docker is already installed
    if command_exists docker; then
        print_warning "Docker is already installed. Skipping Docker installation."
        return 0
    fi
    
    # Install prerequisites
    print_info "Installing Docker prerequisites..."
    sudo apt install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common
    
    # Add Docker GPG key
    print_info "Adding Docker GPG key..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    print_info "Adding Docker repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package list
    print_info "Updating package list..."
    sudo apt update
    
    # Install Docker
    print_info "Installing Docker..."
    sudo apt install -y docker-ce
    
    # Add user to docker group
    print_info "Adding user to docker group..."
    sudo usermod -aG docker "${USER}"
    
    print_info "Docker installed successfully"
    print_warning "You may need to log out and log back in for Docker group changes to take effect."
}

# Function to setup analysis script
setup_analysis_script() {
    print_info "Setting up analysis script..."
    
    # Script is in the root scripts directory (two levels up from package-analysis-web)
    SCRIPT_PATH="$PROJECT_DIR/../../scripts/run_analysis.sh"
    
    if [ ! -f "$SCRIPT_PATH" ]; then
        print_warning "Analysis script not found at $SCRIPT_PATH. Skipping..."
        return 0
    fi
    
    if [ ! -x "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH"
        print_info "Analysis script made executable"
    else
        print_info "Analysis script is already executable"
    fi
}

# Main installation function
main() {
    print_info "Starting Package Analysis Web setup..."
    print_info "Project directory: $PROJECT_DIR"
    
    # Pre-flight checks
    check_root
    check_os
    
    # Check if we're in the right directory
    if [ ! -f "manage.py" ] || [ ! -f "requirements.txt" ]; then
        print_error "Please run this script from the package-analysis-web directory"
        exit 1
    fi
    
    # Installation steps
    install_system_dependencies
    setup_virtualenv
    install_python_dependencies
    setup_database
    create_env_file
    run_migrations
    collect_static
    install_docker
    setup_analysis_script
    
    print_info ""
    print_info "=========================================="
    print_info "Setup completed successfully!"
    print_info "=========================================="
    print_info ""
    print_info "Next steps:"
    print_info "1. Activate the virtual environment:"
    print_info "   source $VENV_NAME/bin/activate"
    print_info ""
    print_info "2. (Optional) Create a superuser:"
    print_info "   python manage.py createsuperuser"
    print_info ""
    print_info "3. Run the development server:"
    print_info "   python manage.py runserver"
    print_info ""
    print_info "4. Access the application at: http://127.0.0.1:8000/"
    print_info ""
    print_info "5. (If Docker was installed) Log out and log back in to use Docker without sudo"
    print_info ""
    print_warning "Remember to review and update the .env file for production settings!"
}

# Run main function
main

