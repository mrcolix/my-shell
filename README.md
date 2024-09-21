# Linux_setup
Configurazioni linux

## Install App

## Install zsh + Theme powerlevel10k

## Configure zsh + installazione Plugins

## Customize vim


I'd be glad to create a README.MD for the provided script:

## ZSH and Development Environment Setup Script

This script automates the installation of a development environment with:

* **zsh** as the default shell
* **Powerlevel10k** theme for a visually appealing prompt
* **Oh My Zsh** framework for customization and plugins
* **zsh-syntax-highlighting** plugin for syntax highlighting
* **zsh-autosuggestions** plugin for command suggestions
* **kube-ps1** plugin (optional) for Kubernetes integration (requires installation)
* **vim** text editor (optional)
* **vim desert colorscheme** (optional)

## Prerequisites

* **Supported Distributions:** Debian/Ubuntu, RedHat/CentOS/Fedora, Arch Linux
* **Root Privileges:** The script requires sudo access.

## Installation Steps

1. **Save the Script:** Save the script as `setup.sh` (or a preferred name) and make it executable:

   ```bash
   chmod +x setup.sh
   ```

2. **Run the Script:** Execute the script with caution:

   ```bash
   ./setup.sh
   ```

   The script will:

   * Update your system packages.
   * Install basic dependencies (git, curl, wget).
   * Install zsh.
   * Set zsh as the default shell.
   * Install Powerlevel10k theme.
   * Interactively handle the configuration of `~/.zshrc`:
     * If the file exists, it will prompt you to overwrite, backup, or cancel.
     * If you choose to overwrite or create a new file, it will:
       * Install Oh My Zsh.
       * Install zsh-syntax-highlighting and zsh-autosuggestions plugins.
       * Optionally install kube-ps1 (requires prior installation).
       * Configure `~/.zshrc` to enable the plugins.
   * Interactively handle the configuration of `~/.vimrc`:
     * If the file exists, it will prompt you to overwrite, backup, or cancel.
     * If you choose to overwrite or create a new file, it will:
       * Install vim.
       * Set desert colorscheme and other basic vim configurations.

3. **Restart Terminal or Source Configuration:**

   * To apply the changes immediately, restart your terminal or run:

     ```bash
     source ~/.zshrc
     ```

## Important Notes

* The script modifies your system configuration files. Proceed with caution.
* Only choose to overwrite existing files (`~/.zshrc` and `~/.vimrc`) if you understand the changes being made.
* Consider creating backups of your existing configuration files before running the script.
* This script is designed for convenience and might not be suitable for all environments. Be sure to review the script before running it.

## Additional Customization

* You can further customize your zsh and vim configurations by editing `~/.zshrc` and `~/.vimrc` directly.
* Many resources are available online for customizing zsh and vim.

## Troubleshooting

* If you encounter errors, review the script output and search online for specific issues.
* Consider creating an issue on a code-sharing platform (e.g., GitHub) if you need further assistance.

This README.MD provides a comprehensive overview of the script's functionality, installation steps, important notes, and troubleshooting tips. Feel free to customize it further based on your specific needs.