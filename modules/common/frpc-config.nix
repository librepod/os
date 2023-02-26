{ config, pkgs, machineConfig, ... }:
let 
  # Generated once with `systemd-id128 -p new` command
  librepodAppKey = "b68d956f085444af8be05da0602bc9c3";
  generateFrpcConfig = pkgs.writeShellScriptBin "genFrpcConfig" ''
    #!${pkgs.runtimeShell} -eu

    export PATH=${pkgs.lib.makeBinPath [ config.nix.package pkgs.systemd pkgs.k3s pkgs.gawk pkgs.curl pkgs.kubernetes-helm ]}:$PATH

    echo "Generating frpc.ini file..."

    # Following systemd's machine-id recomendations we don't want to expose user's
    # Machine IDs, hence we hash it with a cryptographic keyed hash function, using a
    # fixed, application-specific key. That way the ID will be properly unique, and
    # derived in a constant way from the machine ID but there will be no way to retrieve
    # the original machine ID from the application-specific one.
    # See here for more details: https://man7.org/linux/man-pages/man5/machine-id.5.html
    hashedMachineId=$(systemd-id128 machine-id --app-specific=${librepodAppKey})
    remotePort=${machineConfig.relayRemotePort}
    hostIP=${machineConfig.hostIP}

    # @TODO Update this logic once we have an frp proxy registration backend:
    # See: https://github.com/orgs/librepod/projects/2/views/2?pane=issue&itemId=17580704
    # if [ -z "$remotePort" ]; then
    #   echo "Regestering frp client proxy at LibrePos Relay server..."
    #   frpcIni=$(curl --request POST --url 'https://relay.librepod.org/api/register-client-proxy&machineId=$hashedMachineId' --header 'accept: text/plain')
    #   echo $frpcIni > /tmp/frpc.ini
    # else
    cat << EOF > /tmp/frpc.ini
[common]
server_addr = ru.relay.librepod.org
server_port = 7000
authentication_method = token
token = ALOHA

[$hashedMachineId]
type = udp
local_ip = 127.0.0.1
local_port = 51820
remote_port = $remotePort
EOF
    # fi


    echo "The frpc.ini file has been generated!"
    echo "Upgrading wg-easy chart pointing to librepod relay server..."

    # We need to make sure that our wg-easy chart has been already installed upon
    # initial system boot. Hence we need to wait until wg-easy deployment is up.
    until [ -n "$(k3s kubectl wait deployment -n librepod-system wg-easy --for condition=Available=True)" ]; do sleep 5; done

    wgEasyCurrentVersion=$(helm list --kubeconfig /etc/rancher/k3s/k3s.yaml -A | grep wg-easy | awk '{print $9}')

    helm upgrade --kubeconfig /etc/rancher/k3s/k3s.yaml \
      --set hostIP=$hostIP \
      --set wgHost=relay.librepod.org \
      --set wgPort=$remotePort \
      -n librepod-system \
      wg-easy \
      https://github.com/librepod/charts/releases/download/$wgEasyCurrentVersion/$wgEasyCurrentVersion.tgz
  '';
in
{
  environment.systemPackages = [ generateFrpcConfig ];

  systemd.services.frpc = {
    description = "Frp Client Service";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    requires = [ "network.target" ];
    restartIfChanged = true;
    unitConfig.X-StopOnRemoval = true;
    serviceConfig = {
      Type = "simple";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStartPre = "${generateFrpcConfig}/bin/genFrpcConfig";
      ExecStart = "${pkgs.frp}/bin/frpc -c /tmp/frpc.ini";
      ExecReload = "${pkgs.frp}/bin/frpc reload -c /etc/frpc.ini";
    };
  };
}
