#!/bin/env bash

set -euxo pipefail

disc_image_url="https://cloud-images.ubuntu.com/minimal/releases/mantic/release/ubuntu-23.10-minimal-cloudimg-amd64.img"
cluster_name="integr8"

#################################
#################################

disc_image_name=$(basename "$disc_image_url")
disc_image_base_url=$(dirname "$disc_image_url")

master_vdi_size=10240
worker_vdi_size=10240
master_seed_iso_name="master_seed.iso"
worker_seed_iso_name="worker_seed.iso"


#################################
download_disc_image() {
    if [ ! -e "$disc_image_name" ]; then
      echo "Downloading cloud image..."
      wget -O "$disc_image_name" "$disc_image_url" \
          --quiet \
          --show-progress --progress=bar:force:noscroll 
    fi

    if [ ! -e SHA256SUMS ]; then
        wget "$disc_image_base_url"/SHA256SUMS \
            --quiet \
            --show-progress --progress=bar:force:noscroll 
    fi

    echo "Verifying cloud image..."
    sha256sum -c SHA256SUMS 2>&1 | grep OK || true
}

convert_img_to_vdi() {
    if [ ! -e "${disc_image_name%.*}.vdi" ]; then
        qemu-img convert -O vdi "$disc_image_name" "${disc_image_name%.*}.vdi"
    fi
}

create_master_vdi() {
    if [ ! -e "${disc_image_name%.*}-master.vdi" ]; then
        VBoxManage clonemedium disk \
           "${disc_image_name%.*}.vdi" "${disc_image_name%.*}-master.vdi"
    fi

    VBoxManage modifymedium \
        "${disc_image_name%.*}-master.vdi" --resize $master_vdi_size
}

create_master_seed_iso() {
    cloud-localds "$master_seed_iso_name" \
        --network-config init/master-network-config \
        init/master-user-data init/master-meta-data -v
}

create_shared_vdi() {
  if [ ! -e shared.vdi ]; then
    qemu-img create -f raw shared.raw 20G  -o preallocation=off
    sudo losetup /dev/loop0 shared.raw
    printf "g\nn\n\n\n\nw\n" | sudo fdisk "/dev/loop0" || true
    sudo partx -u /dev/loop0
    sudo mkfs.ext4 -F /dev/loop0p1
    VBoxManage convertfromraw shared.raw shared.vdi
    sudo losetup --detach /dev/loop0
  fi
}

create_master_instance() {
    instance_name="${cluster_name}-master"

    echo " check and create if the instance not exists"

    if ! VBoxManage showvminfo "$instance_name" >/dev/null 2>&1; then
      VBoxManage createvm --name "$instance_name" --register
    fi

    VBoxManage modifyvm "$instance_name" \
      --ostype Linux_64 \
      --groups "/k8s-cluster" \
      --memory 4096 \
      --cpus 2 \
      --acpi on --ioapic on \
      --pae off \
      --longmode on \
      --apic on

    echo "check if the first nic is configured"
    VBoxManage modifyvm "$instance_name" \
      --nic1 nat --nat-network1 "k8s-cluster" \
      --nictype1 82540EM \
      --cableconnected1 on \

    VBoxManage modifyvm "$instance_name" \
      --nic2 hostonly --hostonlyadapter2 "vboxnet0" \
      --nictype1 82540EM \
      --cableconnected2 on


    VBoxManage storagectl "$instance_name" \
      --name "PIIX4" \
      --bootable on \
      --add ide \
      --controller "PIIX4" \
      --hostiocache on 2> /dev/null || true

    VBoxManage storageattach "$instance_name" \
      --storagectl "PIIX4" \
      --port 0 \
      --device 0 \
      --type hdd \
      --medium "${disc_image_name%.*}-master.vdi"

    VBoxManage storageattach "$instance_name" \
      --storagectl "PIIX4" \
      --port 1 \
      --device 0 \
      --type dvddrive \
      --medium "$master_seed_iso_name"
      
    VBoxManage storageattach "$instance_name" \
      --storagectl "PIIX4" \
      --port 1 \
      --device 1 \
      --type hdd \
      --medium "shared.vdi"
  }

create_worker_vdi() {
    if [ ! -e "${disc_image_name%.*}-worker.vdi" ]; then
        VBoxManage clonemedium disk \
           "${disc_image_name%.*}.vdi" "${disc_image_name%.*}-worker.vdi"
    fi

    VBoxManage modifymedium \
        "${disc_image_name%.*}-worker.vdi" --resize $worker_vdi_size
}

create_worker_seed_iso() {
    cloud-localds "$worker_seed_iso_name" \
        --network-config init/worker-network-config \
        init/worker-user-data init/worker-meta-data -v
}

create_worker_instance() {
    instance_name="${cluster_name}-worker"

    if ! VBoxManage showvminfo "$instance_name" >/dev/null 2>&1; then
      VBoxManage createvm --name "$instance_name" --register
    fi

    VBoxManage modifyvm "$instance_name" \
      --ostype Linux_64 \
      --groups "/k8s-cluster" \
      --memory 4096 \
      --cpus 2 \
      --acpi on --ioapic on \
      --pae off \
      --longmode on \
      --apic on

    VBoxManage modifyvm "$instance_name" \
      --nic1 nat --nat-network1 "k8s-cluster" \
      --nictype1 82540EM \
      --cableconnected1 on \

    VBoxManage modifyvm "$instance_name" \
      --nic2 hostonly --hostonlyadapter2 "vboxnet0" \
      --nictype1 82540EM \
      --cableconnected2 on


    VBoxManage storagectl "$instance_name" \
      --name "PIIX4" \
      --bootable on \
      --add ide \
      --controller "PIIX4" \
      --hostiocache on 2> /dev/null || true

    VBoxManage storageattach "$instance_name" \
      --storagectl "PIIX4" \
      --port 0 \
      --device 0 \
      --type hdd \
      --medium "${disc_image_name%.*}-worker.vdi"

    VBoxManage storageattach "$instance_name" \
      --storagectl "PIIX4" \
      --port 1 \
      --device 0 \
      --type dvddrive \
      --medium "$worker_seed_iso_name"
      
    VBoxManage storageattach "$instance_name" \
      --storagectl "PIIX4" \
      --port 1 \
      --device 1 \
      --type hdd \
      --medium "shared.vdi"
  }

# download_disc_image;
# convert_img_to_vdi

# create_master_vdi
# create_master_seed_iso
# create_master_instance

# create_shared_vdi

create_worker_vdi
create_worker_seed_iso
create_worker_instance
