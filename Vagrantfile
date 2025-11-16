# -*- mode: ruby -*-
# vi: set ft=ruby :

require "yaml"

vagrant_root = File.dirname(File.expand_path(__FILE__))
settings = YAML.load_file "#{vagrant_root}/settings.yaml"

IP_SECTIONS = settings["network"]["control_ip"].match(/^([0-9.]+\.)([^.]+)$/)
IP_NW       = IP_SECTIONS.captures[0]
IP_START    = Integer(IP_SECTIONS.captures[1])
NUM_WORKER_NODES = settings["nodes"]["workers"]["count"]
CLUSTER_NAME     = settings["cluster_name"].gsub(" ", "_")

Vagrant.configure("2") do |config|
  # Box info
  config.vm.box = settings["software"]["box"]
  config.vm.box_version = settings["software"]["box_version"] if settings["software"]["box_version"]
  config.vm.box_check_update = true
  config.vm.boot_timeout      = 120   # Increase SSH wait timeout

  # IMPORTANT: tell Vagrant the guest type so networking works
  config.vm.guest = :ubuntu
  # (If that ever misbehaves, try :ubuntu instead)

  # ===================
  # COMMON PROVISIONING
  # ===================
  config.vm.provision "shell",
    env: {
      "IP_NW"            => IP_NW,
      "IP_START"         => IP_START,
      "NUM_WORKER_NODES" => NUM_WORKER_NODES
    },
    inline: <<-SHELL
      apt-get update -y
      echo "$IP_NW$((IP_START)) controlplane" >> /etc/hosts
      for i in $(seq 1 ${NUM_WORKER_NODES}); do
        echo "$IP_NW$((IP_START+i)) node0${i}" >> /etc/hosts
      done
    SHELL

  # ===================
  # CONTROL PLANE
  # ===================
  config.vm.define "controlplane" do |controlplane|
    controlplane.vm.hostname = "controlplane"

    # Let vagrant-libvirt manage the libvirt network; just set IP
    controlplane.vm.network "private_network",
      ip: settings["network"]["control_ip"]

    controlplane.vm.provider :libvirt do |lv|
      lv.driver = "kvm"
      lv.cpus   = settings["nodes"]["control"]["cpu"]
      lv.memory = settings["nodes"]["control"]["memory"]
      lv.nested = true
    end

    controlplane.vm.provision "shell",
      env: {
        "DNS_SERVERS"              => settings["network"]["dns_servers"].join(" "),
        "ENVIRONMENT"              => settings["environment"],
        "KUBERNETES_VERSION"       => settings["software"]["kubernetes"],
        "KUBERNETES_VERSION_SHORT" => settings["software"]["kubernetes"][0..3],
        "OS"                       => settings["software"]["os"]
      },
      path: "scripts/common.sh"

    controlplane.vm.provision "shell",
      env: {
        "CALICO_VERSION" => settings["software"]["calico"],
        "CONTROL_IP"     => settings["network"]["control_ip"],
        "POD_CIDR"       => settings["network"]["pod_cidr"],
        "SERVICE_CIDR"   => settings["network"]["service_cidr"]
      },
      path: "scripts/master.sh"
  end

  # ===================
  # WORKERS
  # ===================
  (1..NUM_WORKER_NODES).each do |i|
    config.vm.define "node0#{i}" do |node|
      node.vm.hostname = "node0#{i}"

      node.vm.network "private_network",
        ip: IP_NW + "#{IP_START + i}"

      node.vm.provider :libvirt do |lv|
        lv.driver = "kvm"
        lv.cpus   = settings["nodes"]["workers"]["cpu"]
        lv.memory = settings["nodes"]["workers"]["memory"]
        lv.nested = true
      end

      node.vm.provision "shell",
        env: {
          "DNS_SERVERS"              => settings["network"]["dns_servers"].join(" "),
          "ENVIRONMENT"              => settings["environment"],
          "KUBERNETES_VERSION"       => settings["software"]["kubernetes"],
          "KUBERNETES_VERSION_SHORT" => settings["software"]["kubernetes"][0..3],
          "OS"                       => settings["software"]["os"]
        },
        path: "scripts/common.sh"

      node.vm.provision "shell", path: "scripts/node.sh"

      if i == NUM_WORKER_NODES && settings["software"]["dashboard"] && settings["software"]["dashboard"] != ""
        node.vm.provision "shell", path: "scripts/dashboard.sh"
      end
    end
  end
end
