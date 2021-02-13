# -*- mode: ruby -*-
# vim: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.
Vagrant.configure("2") do |config|
  # Every Vagrant development environment requires a box. You can search for
  # boxes at https://vagrantcloud.com/search.
  #config.vm.box = "freebsd/FreeBSD-12.2-STABLE"
  config.vm.box = "freebsd/FreeBSD-12.2-RELEASE"
  config.vm.box_check_update = false

  # Disable automatic box update checking. If you disable this, then
  # boxes will only be checked for updates when the user runs
  # `vagrant box outdated`. This is not recommended.
  # config.vm.box_check_update = false

  # Create a forwarded port mapping which allows access to a specific port
  # within the machine from a port on the host machine. In the example below,
  # accessing "localhost:8080" will access port 80 on the guest machine.
  # NOTE: This will enable public access to the opened port
  # config.vm.network "forwarded_port", guest: 80, host: 8080

  # Create a forwarded port mapping which allows access to a specific port
  # within the machine from a port on the host machine and only allow access
  # via 127.0.0.1 to disable public access
  # config.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1"

  # Create a private network, which allows host-only access to the machine
  # using a specific IP.
  config.vm.network "private_network", ip: "192.168.83.10"

  # Create a public network, which generally matched to bridged network.
  # Bridged networks make the machine appear as another physical device on
  # your network.
  # config.vm.network "public_network"

  # Share an additional folder to the guest VM. The first argument is
  # the path on the host to the actual folder. The second argument is
  # the path on the guest to mount the folder. And the optional third
  # argument is a set of non-required options.
  # config.vm.synced_folder "../data", "/vagrant_data"
  config.vm.synced_folder "..", "/vagrant",
    type: "nfs",
    mount_options: ['nolockd,vers=3,udp,rsize=32768,wsize=32768']

  config.vm.provider "virtualbox" do |vb|
    # Display the VirtualBox GUI when booting the machine
    #vb.gui = true

    # Customize the amount of memory on the VM:
    vb.memory = "2048"
  end
  #
  # View the documentation for the provider you are using for more
  # information on available options.

  # Enable provisioning with a shell script. Additional provisioners such as
  # Puppet, Chef, Ansible, Salt, and Docker are also available. Please see the
  # documentation for more information about their specific syntax and use.
  config.vm.provision "shell", inline: <<-SHELL
    # Install packages
    pkg install -y zsh bash tmux git-lite vim-console elixir elixir-hex jq

    ## Initialize firewall
    kldload pf
    sysrc -f /boot/loader.conf pf_load="YES"
    sysrc pf_enable="YES"
    sysrc pflog_enable="YES"
    sysrc gateway_enable="YES"

    ## Inititalize zfs
    kldload zfs
    sysrc -f /boot/loader.conf zfs_load="YES"
    sysrc zfs_enable="YES"
    truncate -s 2560M /home/vagrant/zpool.disk
    zpool create -f zroot /home/vagrant/zpool.disk
    zfs create -o compression=gzip-9 -o mountpoint=/zroot/jocker zroot/jocker
    zfs create zroot/jocker_basejail

    ## Initialize base-jail
    ## fetched from: ftp://ftp.dk.freebsd.org/pub/FreeBSD/releases/amd64/12.2-RELEASE/base.txz
    tar -xf /vagrant/base.txz -C /zroot/jocker_basejail
  SHELL

  # Virtual machine used for development purposes
  config.vm.define "dev", primary: true do |dev|
    dev.vm.hostname = "jocker-dev"

    dev.vm.provision "shell", inline: <<-SHELL
      ## Setup my development environment
      ln -s /vagrant/jocker/example/jocker_config.yaml /usr/local/etc/jocker_config.yaml
      ln -s /vagrant/jocker /home/vagrant/jocker
      pw usermod -s /usr/local/bin/zsh -n vagrant
      export HOME=/home/vagrant
      rm ~/.profile # we remove this to avoid error from yadm
      git clone -b with_my_bootstrap https://github.com/lgandersen/yadm.git ~/.yadm-project
      .yadm-project/bootstrap_dotfiles.sh
    SHELL
  end

  # Virtual machine used for testing
  config.vm.define "test", autostart: false do |test|
    test.vm.hostname = "jocker-test"

    test.vm.provision "shell", inline: <<-SHELL
      git clone https://github.com/lgandersen/jocker /home/vagrant/jocker
      ln -s /home/vagrant/jocker/example/jocker_config.yaml /usr/local/etc/jocker_config.yaml
      cd /home/vagrant/jocker
      mix deps.get
      mix local.rebar --force
      #mix compile
      #mix escript.build
    SHELL
  end
end
