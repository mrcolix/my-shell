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
    PKG_MANAGER="apt"
    UPDATE_CMD="sudo apt update -y"
    INSTALL_CMD="sudo apt install -y"
elif [ -f /etc/redhat-release ]; then
    # RedHat/CentOS/Fedora
    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        UPDATE_CMD="sudo dnf check-update -y"
        INSTALL_CMD="sudo dnf install -y"
    else
        PKG_MANAGER="yum"
        UPDATE_CMD="sudo yum check-update -y"
        INSTALL_CMD="sudo yum install -y"
    fi
elif [ -f /etc/arch-release ]; then
    # Arch Linux
    PKG_MANAGER="pacman"
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
$INSTALL_CMD git curl wget unzip 
check_installation "git, curl, wget, unzip"

# Install fonts
FONT_DIR="/usr/share/fonts"

mkdir -p /tmp/fonts

# Download and install Hack font from Nerd Fonts repository and MesloLGS NF Regular font.
wget https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/Hack.zip -O /tmp/fonts/Hack.zip && \
unzip /tmp/fonts/Hack.zip -d /tmp/fonts && \
sudo mv /tmp/fonts/*.ttf $FONT_DIR && \
sudo wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf -O $FONT_DIR/MesloLGS_NF_Regular.ttf && \
fc-cache -f -v

# Install zsh
echo "Installing zsh..."
$INSTALL_CMD zsh 
check_installation "zsh"

# Interactive handling of the .zshrc file
echo "Handling .zshrc..."
if handle_existing_file "$HOME/.zshrc"; then
  
  # Remove existing .oh-my-zsh directory if it exists.
  rm -rf "$HOME/.oh-my-zsh" && echo ".oh-my-zsh folder removed."
  
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

  # Install kube-ps1 for Kubernetes context in prompt.
  echo "PROMPT='$(kube_ps1)'$PROMPT;kubeoff # or RPROMPT='$(kube_ps1)'" >> ~/.zshrc

  # Modify the .zshrc file to enable the plugins.
  echo "Configuring zsh..."  
  sed -i 's/plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions kube-ps1)/' ~/.zshrc

else 
   echo "Operations on .zshrc canceled by user."
fi

# Install Powerlevel10k theme.
echo "Installing Powerlevel10k..."
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k || { echo "Failed to install Powerlevel10k"; exit 1; }
rm -f ~/.p10k.zsh
cp ./config_files/p10k.zsh ~/.p10k.zsh 
sed -i 's/^ZSH_THEME=".*"/ZSH_THEME="powerlevel10k\/powerlevel10k"/' ~/.zshrc
echo "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh" >> ~/.zshrc

# Interactive handling of the .vimrc file.
echo "Handling .vimrc..."
if handle_existing_file "$HOME/.vimrc"; then
  
  # Install vim.
  echo "Installing vim..."
  $INSTALL_CMD vim
  check_installation "vim"
  
  # Customize vim settings.
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

# Install kubectl and oc using binaries.
echo "Installing kubectl and oc..."

KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
ARCH=amd64

# Download and install kubectl binary.
curl -LO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl" && \
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Download and install oc binary.
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz && \
tar xvf oc.tar.gz && \
sudo mv oc /usr/local/bin/

# Install kubectx binary.
echo "Installing kubectx and kubens..."

KUBECTX_VERSION=$(curl -s https://api.github.com/repos/ahmetb/kubectx/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
curl -LO https://github.com/ahmetb/kubectx/archive/refs/tags/${KUBECTX_VERSION}.tar.gz && \
tar xvf ${KUBECTX_VERSION}.tar.gz && \
sudo mv kubectx-*/* /usr/local/bin/ && \
rm ${KUBECTX_VERSION}.tar.gz || { echo "Failed to install kubectx"; exit 1; }

# Enable autocompletion for kubectl, oc, and kubectx.
echo 'source <(kubectl completion zsh)' >> ~/.zshrc 
echo 'source <(oc completion zsh)' >> ~/.zshrc 
echo 'source <(kubectx completion zsh)' >> ~/.zshrc 

# Setting Aliases
echo 'alias k=kubectl' >> ~/.zshrc
echo 'alias kns=kubens' >> ~/.zshrc
echo 'alias kx=kubectx' >> ~/.zshrc

# Final message.
echo "Installation complete! Restart the terminal or run 'source ~/.zshrc' to apply the changes."
