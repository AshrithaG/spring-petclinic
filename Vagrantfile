Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "petclinic-prod"
  config.vm.network "private_network", ip: "192.168.56.10"

  config.vm.provider "virtualbox" do |vb|
    vb.name = "petclinic-prod"
    vb.memory = 2048
    vb.cpus = 2
  end

  config.vm.provision "shell", inline: <<-SHELL
    apt-get update -qq
    apt-get install -y openjdk-17-jdk
    useradd -r -m -s /bin/bash petclinic || true
    mkdir -p /opt/petclinic
    chown petclinic:petclinic /opt/petclinic
    echo "Provisioning complete. Java version:"
    java -version
  SHELL
end
