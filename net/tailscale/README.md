# Tailscale
This readme should help you with tailscale client setup.

> [!NOTE]
> This package now launches `tailscaled` with a generated temporary config file via `--config`.
> You can change that file location with:
> `option tailscaled_config_file '/var/run/tailscale/tailscaled-config.hujson'`
> Put `tailscaled` schema options in `config daemon_settings 'daemon_settings'`
> (for example `option accept_routes '1'`, `list advertise_routes '192.168.50.0/24'`).

## First setup

First, enable and run daemon

```
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
```

Then you should use tailscale utility to get a login link for your device.

Run command and finish device registration with the given URL.
```
tailscale up
```

See the [OpenWrt wiki](https://openwrt.org/docs/guide-user/services/vpn/tailscale/start) for more detailed setup instructions
