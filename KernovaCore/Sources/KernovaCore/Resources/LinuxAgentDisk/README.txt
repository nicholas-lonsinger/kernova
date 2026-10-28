Kernova guest agent for Linux (64-bit Arm)
==========================================

The agent connects this virtual machine to Kernova, which shows its status.
It needs systemd.


Install
-------

Once the desktop has mounted this disk, open a terminal and run:

    sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/install.sh"

That installs the agent for you, and it connects at once. Kernova ejects this
disk when it does.

To install the system service too, which keeps the agent connected while
nobody is logged in, add --system. It asks for your password through sudo:

    sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/install.sh" --system

In a root shell, install.sh --system installs only the system service, without
sudo.


Without a desktop
-----------------

A guest with no desktop does not mount this disk on its own. Mount it, then
install the system service from it:

    sudo mkdir -p /mnt/kernova-agent
    sudo mount -o ro LABEL=KERNOVA_AGENT /mnt/kernova-agent
    sh /mnt/kernova-agent/install.sh --system

Without --system the agent runs only for that login.


Uninstall
---------

    sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/uninstall.sh"

With --system it removes the system service too. The system service's
account, kernova-agent, stays.


What it installs
----------------

For you:
  ~/.local/share/kernova-agent/                      the agent
  ~/.config/systemd/user/kernova-agent.service       runs it
  ~/.config/systemd/user/kernova-agent-rollback.*    checks its updates
  ~/.config/autostart/app.kernova.agent.desktop      starts it at a desktop
                                                     login

With --system:
  /var/lib/kernova-agent/                            the agent
  /etc/systemd/system/kernova-agent-system.service   runs it
  /etc/systemd/system/kernova-agent-rollback.*       checks its updates
  /etc/sysusers.d/kernova-agent.conf                 its account
  /etc/polkit-1/rules.d/50-kernova-agent.rules       lets it power off and
                                                     restart the guest

LICENSES.txt lists the licences of the software in kernova-agent.
