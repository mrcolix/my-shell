#!/bin/bash

# Function to check the result of each operation
function check_installation {
  if [ $? -eq 0 ]; then
    echo "$1 successfully installed!"
  else
    echo "Error occurred while installing $1"
    exit 1
  fi
}

# Function to prompt the user on what to do if a file exists
function handle_existing_file {
  local FILE_PATH="$1"
  
  if [ -f "$FILE_PATH" ]; then
    echo "The file $FILE_PATH already exists."
    
    # Loop to prompt the user
    while true; do
      read -p "What do you want to do? (O)verwrite, (B)ackup, (C)ancel: " choice
      case "$choice" in
        [Oo]* )
          echo "Overwriting the file $FILE_PATH."
          return 0 # Proceed with overwriting
          ;;
        [Bb]* )
          backup_file "$FILE_PATH"
          return 0 # Proceed with modification
          ;;
        [Cc]* )
          echo "Operation canceled for $FILE_PATH."
          return 1 # Cancel the operation
          ;;
        * )
          echo "Please answer with (O)verwrite, (B)ackup, or (C)ancel."
          ;;
      esac
    done
  fi
}

# Function to backup a file if it exists
function backup_file {
  if [ -f "$1" ]; then
    local TIMESTAMP=$(date +"%Y%m%d%H%M%S")
    local BACKUP_FILE="$1.bak.$TIMESTAMP"
    cp "$1" "$BACKUP_FILE"
    echo "Backup of $1 created as $BACKUP_FILE"
  fi
}

# Identify the distribution and assign the correct package manager
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    PKG_MANAGER="sudo apt"
    UPDATE_CMD="sudo apt update -y"
    INSTALL_CMD="sudo apt install -y"
elif [ -f /etc/redhat-release ]; then
    # RedHat/CentOS/Fedora
    if command -v dnf &>/dev/null; then
        PKG_MANAGER="sudo dnf"
        UPDATE_CMD="sudo dnf check-update -y"
        INSTALL_CMD="sudo dnf install -y"
    else
        PKG_MANAGER="sudo yum"
        UPDATE_CMD="sudo yum check-update -y"
        INSTALL_CMD="sudo yum install -y"
    fi
elif [ -f /etc/arch-release ]; then
    # Arch Linux
    PKG_MANAGER="sudo pacman"
    UPDATE_CMD="sudo pacman -Syu --noconfirm"
    INSTALL_CMD="sudo pacman -S --noconfirm"
else
    echo "Unsupported distribution!"
    exit 1
fi

# Update the system
echo "Updating the system..."
$UPDATE_CMD
check_installation "System update"

# Install basic dependencies
echo "Installing basic dependencies..."
$INSTALL_CMD git curl wget
check_installation "git, curl, wget"

# Install zsh
echo "Installing zsh..."
$INSTALL_CMD zsh
check_installation "zsh"

# Set zsh as the default shell
#chsh -s $(which zsh)
#echo "zsh is now the default shell."

# Interactive handling of the .zshrc file
echo "Handling .zshrc..."
if handle_existing_file "$HOME/.zshrc"; then
  # Install Oh My Zsh (needed for plugins)
  echo "Installing Oh My Zsh..."
  yes | sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  check_installation "Oh My Zsh"
  
  # Install zsh plugins (zsh-syntax-highlighting, zsh-autosuggestions)
  echo "Installing zsh plugins..."
  
  # Install zsh-syntax-highlighting
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
  check_installation "zsh-syntax-highlighting"
  
  # Install zsh-autosuggestions
  git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  check_installation "zsh-autosuggestions"
  
  # Installa kube-ps1
  echo "PROMPT='$(kube_ps1)'$PROMPT;kubeoff # or RPROMPT='$(kube_ps1)'" >> ~/.zshrc

  # Modify the .zshrc file to enable the plugins
  echo "Configuring zsh..."
  sed -i 's/plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions kube-ps1)/' ~/.zshrc
else
  echo "Operations on .zshrc canceled by user."
fi

# Install Powerlevel10k theme
echo "Installing Powerlevel10k..."
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
cp ./config_files/p10k.zsh ~/.p10k.zsh
rm -f ~/.p10k.zsh
sed -i 's/^ZSH_THEME=".*"/ZSH_THEME="powerlevel10k/powerlevel10k"/' ~/.zshrc

# Interactive handling of the .vimrc file
echo "Handling .vimrc..."
if handle_existing_file "$HOME/.vimrc"; then
  # Install vim
  echo "Installing vim..."
  $INSTALL_CMD vim
  check_installation "vim"
  
  # Customize vim settings
  echo "Customizing vim..."
  cat <<EOL >> ~/.vimrc
" Enable line numbers
set number

" Highlight search results
set hlsearch

" Use desert colorscheme
colorscheme desert

" Always show the status bar
set laststatus=2

" Set automatic indentation
set autoindent
set tabstop=4
set shiftwidth=4
set expandtab
EOL
else
  echo "Operations on .vimrc canceled by user."
fi

# Final message
echo "Installation complete! Restart the terminal or run 'source ~/.zshrc' to apply the changes."
