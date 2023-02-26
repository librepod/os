{
  hostName = "cheeba-ryba-rpi";
  networkInterfaceName = "eth0";
  domain = "my.pi";
  metallb = {
    enable = true;
    ipRange = "192.168.2.240-192.168.2.243";
  };
  ingressNginx = {
    lbIP = "192.168.2.240";
  };
  unbound = {
    lbIP = "192.168.2.243";
    imageRepository = "mvance/unbound-rpi";
  };
  wgEasy = {
    lbIP = "192.168.2.242";
  };
  nfsProvisioner = {
    serverIP = "192.168.2.117";
  };
}
