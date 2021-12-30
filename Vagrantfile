# -*- mode: ruby -*-
# vim: set ft=ruby :

$host = "/host"

$configure_zfs = <<-SCRIPT
kldload zfs
sysrc -f /boot/loader.conf zfs_load="YES"
sysrc zfs_enable="YES"
truncate -s 1700M /home/vagrant/zpool.disk
zpool create -f zroot /home/vagrant/zpool.disk
zfs create -o compression=gzip-9 -o mountpoint=/zroot/jocker zroot/jocker
zfs create zroot/jocker_basejail
SCRIPT

### Fetched from: ftp://ftp.dk.freebsd.org/pub/FreeBSD/releases/amd64/12.2-RELEASE/base.txz
$create_jocker_jailbase = "tar -xf #{$host}/base.txz -C /zroot/jocker_basejail"

$make_utf8_default = "cp #{$host}/jocker/vagrant_data/login.conf /etc/ && cap_mkdb /etc/login.conf"


Vagrant.configure("2") do |config|
  ### Basic configuration across VM's
  config.vm.box = "freebsd/FreeBSD-12.2-RELEASE" # "freebsd/FreeBSD-12.2-STABLE"
  config.vm.box_check_update = false
  config.vm.network "private_network", ip: "192.168.83.10"

  config.vm.synced_folder "..", $host,
    type: "nfs",
    mount_options: ['nolockd,vers=3,udp,rsize=32768,wsize=32768']

  config.vm.provider "virtualbox" do |vb|
    #vb.gui = true
    vb.memory = "2048"
  end

  config.vm.provision "shell", inline: $configure_zfs
  config.vm.provision "shell", inline: $create_jocker_jailbase
  #config.vm.provision "shell", inline: $make_utf8_default


  ########################################
  ### VM used for development purposes ###
  ########################################
  config.vm.define "dev", primary: true do |dev|
    dev.vm.hostname = "jocker-dev"

    dev.vm.provision "shell", inline: <<-SHELL
      ## Setup my development environment
      ln -s #{$host}/jocker/example/jocker_config.yaml /usr/local/etc/jocker_config.yaml
      ln -s #{$host}/jocker /home/vagrant/jocker
      ln -s #{$host}/jcli /home/vagrant/jcli

      ## Install packages
      ## Use 'erlang-wx' instead of 'erlang', if the observer gui is needed.
      ## Also remember to tweak ssh to X-forwarding etc.
      pkg install -y zsh bash tmux git-lite vim erlang elixir elixir-hex jq
      pkg install -y py38-pipenv py38-pipx
      su - vagrant -c 'pipx install openapi-python-client --include-deps'
      su - vagrant -c 'cd jcli && pipenv install'

      pw usermod -s /usr/local/bin/zsh -n vagrant
      export HOME=/home/vagrant
      rm ~/.profile # we remove this to avoid error from yadm
      git clone -b with_my_bootstrap https://github.com/lgandersen/yadm.git ~/.yadm-project
      .yadm-project/bootstrap_dotfiles.sh
      chown -R vagrant /home/vagrant/.vim_runtime
    SHELL
  end

  ######################################################
  ### VM used for testing a build from a ports file ####
  ######################################################
  config.vm.define "test", autostart: false do |test|
    test.vm.hostname = "jocker-test"

    test.vm.provision "shell", inline: <<-SHELL
      pkg install -y git-lite erlang elixir elixir-hex
      cp -r #{$host}/jocker/ports /home/vagrant/
      cd /home/vagrant/jocker
      portsnap --interactive fetch extract
    SHELL
  end
end
