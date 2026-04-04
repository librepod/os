{ config, lib, pkgs, ... }:

let
  cfg = config.librepod.frpc;
in
{
  options.librepod.frpc = {
    enable = lib.mkEnableOption "FRP client";

    serverAddr = lib.mkOption {
      type = lib.types.str;
      description = "FRP relay server address";
    };

    serverPort = lib.mkOption {
      type = lib.types.int;
      default = 7000;
      description = "FRP relay server port";
    };

    auth = {
      method = lib.mkOption {
        type = lib.types.str;
        default = "token";
        description = "FRP authentication method";
      };
      token = lib.mkOption {
        type = lib.types.str;
        description = "FRP authentication token";
      };
    };

    webServer = {
      enable = lib.mkEnableOption "FRP client web server for admin API";
      addr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Web server bind address";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 7400;
        description = "Web server port";
      };
    };

    proxies = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Proxy name";
          };
          type = lib.mkOption {
            type = lib.types.enum [ "tcp" "udp" "http" "https" "stcp" ];
            description = "Proxy type";
          };
          localIp = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Local IP to forward to";
          };
          localPort = lib.mkOption {
            type = lib.types.int;
            description = "Local port to forward";
          };
          remotePort = lib.mkOption {
            type = lib.types.int;
            description = "Remote port on FRP server";
          };
        };
      });
      default = [];
      description = "FRP proxy definitions";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = map lib.lowPrio [ pkgs.frp ];

    services.frp = {
      enable = true;
      role = "client";
      settings = {
        serverAddr = cfg.serverAddr;
        serverPort = cfg.serverPort;
        loginFailExit = false;
        auth.method = cfg.auth.method;
        auth.token = cfg.auth.token;
      } // lib.optionalAttrs cfg.webServer.enable {
        webServer.addr = cfg.webServer.addr;
        webServer.port = cfg.webServer.port;
      } // lib.optionalAttrs (cfg.proxies != []) {
        proxies = map (p: {
          inherit (p) name type localIp localPort remotePort;
        }) cfg.proxies;
      };
    };
  };
}
