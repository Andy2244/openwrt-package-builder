## dockerized OpenWrt Package-Builder script

### Description
The package-builder script ```builder.sh/.ps1``` will setup, compile and can patch, host openwrt packages from official or custom openwrt feeds, via a config .txt file. It handles all task's automatically and only requires editing/creating the config files.

### Features
* fully isolated build environment, utilizing [Docker](https://docs.docker.com/install/) for Linux, Windows and Mac
* automatic setup of a openwrt package build environment, via official sdk
* automatic management/update of sdk versions to compile against ('18.06.0', '18.06.1', '18.06.2', 'snapshots')
* automatic patch support via locally provided patches or github PR numbers in config
* local feed support
* ability to locally host the build packages via a tiny webserver
* debug support, via config options or manual shell access into the docker containers

### Requirements
ALL Versions:
* 64bit OS
* [Docker](https://docs.docker.com/install/)
* check supported [Platforms](https://docs.docker.com/install/#supported-platforms)

Windows:
* Virtualisation capable CPU and enabled in Bios (Intel VT or AMD-V)
* Windows 10 Pro, Enterprise and Education, (Build > 1607)
* _requirements can be tested via_ ```.\builder.ps1```

Mac:
* Virtualisation capable CPU and enabled in Bios (Intel VT or AMD-V)
* macOS El Capitan 10.11 and newer

### Installation
* install Docker for your system [Win](https://download.docker.com/win/stable/Docker%20for%20Windows%20Installer.exe), [Mac](https://download.docker.com/mac/stable/Docker.dmg), [Linux](https://docs.docker.com/install/#supported-platforms)\
_For quick installation on Linux try the official Docker [convenience script](https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-using-the-convenience-script)._
* Get/unpack the script via [release page](https://github.com/Andy2244/openwrt-package-builder/releases) (zip/tar) or ```git clone https://github.com/Andy2244/openwrt-package-builder.git```

Windows: it is recommend to use Docker in 'LCOW' mode, to-do so:
- check _use Windows Containers instead of Linux Containers_ during installation or _Switch to Windows Containers_ via docker tray
- enable _Experimental features_ via Docker tray _Settings/Daemon_

Mac:
- macOS might ask multiple times per run for your _SUDO_ password, thats because the default _SUDO_ timeout is 5 minutes, which can be changed to 30 minutes via:\
```sudo sh -c 'echo "\nDefaults timestamp_timeout=30">>/etc/sudoers'```

### Useage
* check the examples and create a config file for your router/sdk
* make sure ```VERSION, TARGET, SUBTARGET``` matches your router's firmware
* _Check your routers openwrt firmware UI '/System/Software/Configuration/Distribution feeds' to confirm values_
* _start Docker_

#### Linux, Mac (shell):

_make script executeable_ \
```chmod +x builder.sh```

_build your config_ \
```./builder.sh build [config].txt```

_host the results localy, for easy luci-ui installation_ \
```./builder.sh host [config].txt```

#### Windows (Admin Powershell):

_build your config_ \
```.\builder.ps1 build [config].txt```

_host the results localy, for easy luci-ui installation_ \
```.\builder.ps1 host [config].txt```

#### Notes

* you can speed-up the build process by re-using a previously setup/updated environment via ```build_quick```. _This will not perform any updates_
* the ```cleanall``` command will remove all existing package-builder Docker containers and outdated images, freeing up space

### Advanced config Options

### Limitations
