# Grab latest from here https://hydra.nixos.org/job/nixos/trunk-combined/nixos.sd_image_new_kernel.aarch64-linux
# firmware = nixos-sd-image-21.11pre331775.c6b332cb1a4-aarch64-linux.img
# firmware_zst = $(firmware).zst
# sd_card = /dev/mmcblk0
# download-and-unpack:
#   # nix-shell -p wget zstd
#   wget https://hydra.nixos.org/build/158402880/download/1/$(firmware_zst)
#   unzstd -d $(firmware)

# firmware = ./output/nixos-sd-image-21.11pre295944.0747387223e-aarch64-linux.img
# sd_card = /dev/mmcblk0

copy:
  sudo cp -rf ./* /etc/nixos/

switch:
  sudo nixos-rebuild switch

copy-and-switch: copy switch

write-to-sd:
  sudo dd if=$(firmware) of=$(sd_card) bs=4096 conv=fsync status=progress

copy-to-pi:
  scp -r ./* root@cheeba-ryba:/etc/nixos/

copy-to-vb:
  scp -r $(ls | grep -v -e image-builders -e machine.txt) librepod-vb:/etc/nixos

copy-to-librepod-playground:
  scp -r $(ls | grep -v -e image-builders -e machine.txt) root@192.168.2.191:/etc/nixos

copy-to-yc-demo:
  scp -r $(ls | grep -v -e image-builders -e machine.txt) root@51.250.102.144:/etc/nixos

copy-manifests:
  scp -r ./sd-image/k3s/*.yaml cheeba-ryba:/var/lib/rancher/k3s/server/manifests/

build-qcow-image:
  nixos-generate --format qcow --configuration ./configuration.nix
  ARTIFACT=$(tail -1 ./image-builders/qcow/nixos-generate-output.txt)
  echo "Found img file: $(ARTIFACT)"
  sudo mv $(ARTIFACT) ./image-builders/qcow/output/

build-vmdk-image:
  # nixos-generate --format vmware --configuration ./image-builders/vmdk.nix \
  #   | tee ./nixos-generate-output.txt
  ARTIFACT=$$(tail -1 ./nixos-generate-output.txt); sudo mv $$ARTIFACT ./image-builders/output/

create-service-account:
  SA_ID=$$(yc iam service-account create --name sa-object-storage --format json | jq '.id')

morph-deploy machine:
  morph deploy ./deploy.nix switch --on {{machine}}

morph-build-dry-run machine:
  morph build ./deploy.nix --dry-run --on {{machine}}
  # earthly +morphBuildDryRun

copy-kube-config-from machineIp:
  scp root@{{machineIp}}:/etc/rancher/k3s/k3s.yaml ~/.kube/{{machineIp}}.config
  sed -i 's/127.0.0.1/{{machineIp}}/g' ~/.kube/{{machineIp}}.config
  cp ~/.kube/{{machineIp}}.config ~/.kube/config
  kubectx {{machineIp}}=default
