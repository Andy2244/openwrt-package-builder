#!/bin/sh
# Docker based OpenWRT package build environment

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#############################################
PLATFORM=$(uname -s)
SCRIPT_DIR=$(pwd)
DOCKER_VERSION=""
#MY_LANG="${LANG:-en_US.UTF-8}"
MY_TERM="${TERM:-xterm-256color}"
MY_HOSTNAME="docker_pb"
MY_TZ="UTC"
SUDO=sudo
SYSTEMD=0
# base Tag to use for docker image
IMAGE_TAG="andy2222/docker-openwrt-sdk-base"
IMAGE_TAG_HOST="pierrezemb/gostatic"
CPREFIX="openwrt_pb"
#############################################
if ! (sudo -v &>/dev/null); then
	SUDO=
fi
if (timedatectl &>/dev/null); then
	MY_TZ=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
elif [ -f /etc/timezone ]; then
	MY_TZ=$(cat /etc/timezone)
fi
if (systemctl --version &>/dev/null); then
	SYSTEMD=1
fi
if (docker version &>/dev/null); then
	DOCKER_VERSION=$(docker version -f '{{.Client.Version}}' 2>/dev/null)
fi
############### stop on error ###############
set -e
#############################################
function fail {
	echo -e "****** ${RED}ERROR: $*${NC}" >&2
	exit 1
}

function usage_and_exit {
	cat<<EOT
Dockerized automatic Openwrt Package-Builder.

Usage: $1 COMMAND [FILE]
    build        - build packages defined via [FILE]
    build_quick  - quickly build packages defined via [FILE], no (sdk, feeds, patches) updates are performed and build cache is reused.
    shell        - start shell in docker container (allows manual build/debug)
    host         - host the build packages locally via a tiny web server 
    clean        - clean/remove the associated container

  FILE:
    [FILE].txt   - the config file to-be used (must contain valid VERSION, TARGET, SUBTARGET)

Usage: $1 COMMAND
    cleanall        - remove ALL package builder docker containers
    update          - update docker images (aka pull)
    bundle_patches  - create per feed patches-[feed name]-[sdk version].tar.gz via '.patches' dir
                      - structure: .patches/[feed name]/[sdk version]/[patchfile].patch
                      - example:   .patches/packages/18.06.0/mypatch.patch

Examples:
  $1 build  example.txt
  $1 host   example.txt
  $1 cleanall
EOT
	exit 0
}
######## early exit #####
if [ $# -lt 1 ]; then
	usage_and_exit $0
fi

#########################
# all args = "$@", exit code = $?
# $1 = full container namme
# use /.cmd file to allow dynamic cmds on a already started container
function prepare_container {
	check_images
	
	local cid=$($SUDO docker ps -a -q -f name="$1")

	if [ -z "$cid" ]; then
		#-e GOSU_USER=`id -u`:`id -g`
		#-e LANG="$MY_LANG"

		$SUDO docker create -ti \
			--log-driver=none \
			--name "$1" \
			-h "${MY_HOSTNAME}_build" \
			-e TERM="$MY_TERM" \
			-e TZ="$my_tz" \
			--mount type=bind,source="$SCRIPT_DIR",target=/hostdir \
			$IMAGE_TAG /bin/bash -C /.cmd

		cid=$($SUDO docker ps -a -q -f name="$1")
	fi

	if [ -n "$cid" ]; then
		$SUDO docker stop "$1" 2>/dev/null
		$SUDO docker cp "$SCRIPT_DIR/build.in" "${1}:/workdir/build.sh"
		$SUDO docker cp "$FILE" "${1}:/workdir/"
		$SUDO docker cp "$SCRIPT_DIR/keys.tar.gz" "${1}:/workdir/"
		local patches="$(ls "$SCRIPT_DIR/patches-*-${VERSION}.tar.gz" 2>/dev/null)"
		local file
		for file in ${patches[@]}; do
			if [ -f "$file" ]; then
				$SUDO docker cp "$file" "${1}:/workdir/"
			fi
		done
	else
		fail "Something went wrong, for $1"
	fi
}

# run a shell in the container, useful for debugging.
function run_shell {
	prepare_container "$1"
	local filename=$(basename $FILE)
	echo "echo -e \"************* Host script dir ${YELLOW} '$SCRIPT_DIR' ${NC} has been mounted to ${GREEN} '/hostdir' ${NC} inside the container, for your convenience!  *************\"" > cmd.in	
	echo "echo -e \"************* available tools: mc, nano, edit \"" >> cmd.in
	echo "chmod 777 /workdir/ /workdir/build.sh && chmod 666 /workdir/$filename && dos2unix -q /workdir/build.sh /workdir/$filename && exec bash" >> cmd.in
	$SUDO docker cp cmd.in "${1}:/.cmd"
	$SUDO rm -f cmd.in
	$SUDO docker start -ai "$1"
	$SUDO docker stop "$1"
}

function run_build_packages {
	prepare_container "$1"
	local filename=$(basename $FILE)
	echo "chmod 777 /workdir/ /workdir/build.sh && chmod 666 /workdir/$filename && dos2unix -q /workdir/build.sh /workdir/$filename && exec /workdir/build.sh $filename" > cmd.in
	$SUDO docker cp cmd.in "${1}:/.cmd"
	$SUDO rm -f cmd.in
	$SUDO docker start -ai "$1"
	$SUDO docker stop "$1"
}

function run_build_packages_quick {
	prepare_container "$1"
	local filename=$(basename $FILE)
	echo "chmod 777 /workdir/ /workdir/build.sh && chmod 666 /workdir/$filename && dos2unix -q /workdir/build.sh /workdir/$filename && echo BUILD_QUICK=1 >> /workdir/$filename && exec /workdir/build.sh $filename" > cmd.in
	$SUDO docker cp cmd.in "${1}:/.cmd"
	$SUDO rm -f cmd.in
	$SUDO docker start -ai "$1"
	$SUDO docker stop "$1"
}

function run_cleanall {
	echo "Cleaning ALL"
	local cids=$($SUDO docker ps -a -q -f name="$CPREFIX" | tr '\n' ' ')
	if [ -n "$cids" ]; then
		$SUDO docker rm -f $cids
	fi
	# full cleanup
	$SUDO docker image prune -f
}

function run_clean {
	echo "Cleaning $1"
	$SUDO docker rm -f "$1"
}

function run_update_images {
	echo -e "${YELLOW}updating Docker images${NC}"
	$SUDO docker pull $IMAGE_TAG
	$SUDO docker pull $IMAGE_TAG_HOST
	$SUDO docker image prune -f
}

function check_images {
  cid1=$(docker image ls -a -q -f reference="$IMAGE_TAG_HOST")
  cid2=$(docker image ls -a -q -f reference="$IMAGE_TAG")
  if [ -z "$cid1" -o -z "$cid2" ]; then
    run_update_images
  fi
}

function run_host_packages {
	check_images
	
	local bin_dir="bin-$VERSION-$TARGET-$SUBTARGET"
	local host_dir="$SCRIPT_DIR/$bin_dir"/bin/
	# macos ? $HOSTNAME
	local hostname="$(hostname -f)"
	if [ ! -d "$host_dir" ];then
		fail "$host_dir does not exist!"
	fi
	local has_core=$([ -f "$host_dir/targets/$TARGET/$SUBTARGET/packages/Packages.manifest" ] && echo 1) 
	local custom_feeds=$(ls -d $host_dir/packages/*/* | grep -vE '/base$|/luci$|/routing$|/telephony$|/packages$')
	local official_feeds=$(ls -d $host_dir/packages/*/* | grep -E '/base$|/luci$|/routing$|/telephony$|/packages$')
	local arch=$(basename $(ls -d $host_dir/packages/*))
	
	if [ -z "$official_feeds" -a -z "$custom_feeds" -a "$has_core" -ne 1 ]; then
		fail "Nothing to host found in $host_dir"
	fi
	
	echo -e "Hosting ${YELLOW} $host_dir ${NC} via URL ${GREEN} http://${hostname}:8043/$VERSION/ ${NC}"
	echo -e "These lines can be used via your ${YELLOW} router luci UI ${NC} under ${YELLOW} 'System/Software/Configuration' ${NC} in the ${YELLOW} 'Custom feeds' ${NC} field."
	echo -e "${YELLOW}IMPORTANT${NC}: Make sure you ${YELLOW}disable 'Distribution feeds'${NC} that contain packages with the ${YELLOW}same name.${NC} (add '#' at the beginning)"
	echo -e "\t Otherwise your rebuild packages will NOT be listed and overwritten by the default 'Distribution feeds'!"
	echo -e "------------------------------------------------------------------------------------------------------------------------------------------------------"
	if [ -n "$official_feeds" ] || [ "$has_core" -eq 1 ]; then
		echo -e "${YELLOW}If you ${RED}did${YELLOW} customize or patch${NC} official packages, use these lines, otherwise not needed."
		echo -e "${YELLOW}NOTE:${NC} Those should also be added via the ${YELLOW} 'Custom feeds' ${NC} field."
		echo -e "${YELLOW}Custom official feeds entries${NC}"
		if [ "$has_core" -eq 1 ]; then
			echo -e "\t${GREEN}src/gz local_core http://${hostname}:8043/$VERSION/targets/$TARGET/$SUBTARGET/packages${NC}"
		fi
		local ofeed
		for ofeed in ${official_feeds[@]}; do
			if [ -f "$ofeed/Packages.manifest" ]; then
				local feed_name="$(basename $ofeed)"
				echo -e "\t${GREEN}src/gz local_${feed_name} http://${hostname}:8043/$VERSION/packages/$arch/$feed_name${NC}"
			fi
		done
		echo -e "------------------------------------------------------------------------------------------------------------------------------------------------------"
	fi
	if [ -n "$custom_feeds" ]; then
		echo -e "${YELLOW}Custom feeds entries${NC}"
		local cfeed
		for cfeed in ${custom_feeds[@]}; do
			if [ -f "$cfeed/Packages.manifest" ]; then
				local feed_name="$(basename $cfeed)"
				echo -e "\t${GREEN}src/gz local_${feed_name} http://${hostname}:8043/$VERSION/packages/$arch/$feed_name${NC}"
			fi
		done
		echo -e "------------------------------------------------------------------------------------------------------------------------------------------------------"
	fi
	echo -e "${YELLOW}NOTE:${NC} Make sure to disable 'Distribution feeds' that contain packages with the same names, or you wont see your updated versions!"
	echo -e "use ${RED} CTRL-C ${NC} to stop hosting!"

	$SUDO docker run --rm -ti \
	--name "$1" \
	-h "${MY_HOSTNAME}_host" \
	-p 8043:8043 \
	--mount type=bind,source="$host_dir",target="/srv/http/$VERSION",readonly \
	$IMAGE_TAG_HOST

	$SUDO docker rm -f "$1" 2>/dev/null
}

function copy_packages {
	local sdk_dir="sdk-$VERSION-$TARGET-$SUBTARGET"
	local bin_dir="bin-$VERSION-$TARGET-$SUBTARGET"
	local dst_dir="/workdir/$sdk_dir/bin/"
	$SUDO rm -f build_result.out
	set +e
	$SUDO docker cp "${1}:/workdir/.build_result" build_result.out 2>/dev/null
	set -e
	if [ -f build_result.out ] && [ $(cat build_result.out) -eq 0 ]; then
		$SUDO rm -fR "$SCRIPT_DIR/$bin_dir/"
		$SUDO mkdir -p -m 777 "$SCRIPT_DIR/$bin_dir/"
		$SUDO docker cp "${1}:$dst_dir" "$SCRIPT_DIR/$bin_dir/"
		#$SUDO chmod -fR `id -u`:`id -g` "$SCRIPT_DIR/$bin_dir/"
		echo -e "************* ${GREEN}Valid build result${NC} found, copying packages to ${GREEN} $SCRIPT_DIR/$bin_dir/ ${NC}"
		echo -e "************* Build results can now be locally hosted for installation via: ${GREEN} $0 host $FILE ${NC}"
	else
		echo -e "Problem detected you can debug by setting ${GREEN}'DEBUG=2'${NC} in ${YELLOW}$FILE${NC} or open a shell via: ${GREEN} $0 shell $FILE ${NC}"
		fail "No .build_result found in $1 or last build failed, skipping copy!"
	fi
	$SUDO rm -f build_result.out
}

# HELP: per feed patches can be added via a '.patches' dir, with subdirs of the feednames (base, luci, packages ...) and subdirs of the SDK version (snapshots, 18.06.0, 18.06.1)
# Examples: 
#	.patches/packages/18.06.0/mypatch.patch
#	.patches/base/snapshots/mypatch2.patch
# The generated files will be automatically used by 'builder.sh build' command and applied to the downloaded feeds
function create_patches {
	if [ -d "$SCRIPT_DIR/.patches" ]; then
		rm -f patches-*.tar.gz
	else
		fail "Error: no .patches dir found."
	fi
	
	local patch_feeds="$(ls -d $SCRIPT_DIR/.patches/* 2>/dev/null)"
	if [ -z "$patch_feeds" ]; then
		fail "Nothing todo empty .patches dir!"
	fi
	local feed_dir
	for feed_dir in ${patch_feeds[@]}; do
		local patch_versions="$(ls -d $feed_dir/*)"
		local version_dir
		for version_dir in ${patch_versions[@]}; do
			local feed_name="$(basename $feed_dir)"
			local version_name="$(basename $version_dir)"
			echo "Creating patches-$feed_name-$version_name from $version_dir"
			chmod 644 "$version_dir"/*.patch
			(cd "$version_dir" && tar -zcf "$SCRIPT_DIR/patches-$feed_name-$version_name".tar.gz *.patch)
		done
	done
}

# assume mixed or windows CRLF!
function import_config {
	if [ -f "$1" ]; then
		VERSION=$(sed -n -r -e '/^VERSION ?=/ s/.*\= *//p' "$1" | tr -d '"[:cntrl:]')
		TARGET=$(sed -n -r -e '/^TARGET ?=/ s/.*\= *//p' "$1" | tr -d '"[:cntrl:]')
		SUBTARGET=$(sed -n -r -e '/^SUBTARGET ?=/ s/.*\= *//p' "$1" | tr -d '"[:cntrl:]')
	else
		fail "file does not exist: $1"
	fi
	# check for required VARS
	[ -n "$VERSION" ] || fail "missing VERSION in $1"
	[ -n "$TARGET" ] || fail "missing TARGET in $1"
	[ -n "$SUBTARGET" ] || fail "missing SUBTARGET in $1"
	echo -e "${GREEN}Config imported${NC} with:"
	echo -e "SDK          ${YELLOW}$VERSION${NC}"
	echo -e "Target       ${GREEN}$TARGET${NC}"
	echo -e "Subtarget    ${GREEN}$SUBTARGET${NC}"
	echo "---------------------------"
}

function has_docker {
	if [ -z "$DOCKER_VERSION" ]; then
		echo -e "Install Docker first, check ${GREEN} https://docs.docker.com/install/ ${NC}"

		case $PLATFORM in
			Linux)
				echo -e "Alternatively you can quickly install via the official ${YELLOW}Docker Edge convenience script:${NC}"
				echo -e "> ${GREEN}curl -fsSL https://get.docker.com -o get-docker.sh ${NC}"
				echo -e "> ${GREEN}sudo sh get-docker.sh ${NC}"
				;;
			Darwin)
				echo -e "Direct download link: ${GREEN} https://download.docker.com/mac/stable/Docker.dmg ${NC}"
				echo -e "Make sure you meet the requirements, see: https://docs.docker.com/docker-for-mac/install/#what-to-know-before-you-install"
				echo -e "\t macOS El Capitan 10.11 and newer"
				echo -e "\t ${YELLOW}Virtualisation capable CPU${NC} and enabled in Bios (Intel VT or AMD-V)"
				echo -e "\t\t test via: ${GREEN} sysctl kern.hv_support ${NC}"
				;;
			*)
				echo -e "${YELLOW}untested OS detected!${NC}"
				;;
		esac

		fail "could not find Docker."
	fi	
}

function start_docker {
	DOCKER_STARTED=0
	if [ $SYSTEMD -eq 1 ]; then
		if [ $($SUDO systemctl show --property ActiveState docker 2>/dev/null) = 'ActiveState=inactive' ]; then
			echo "Starting Docker daemon."
			$SUDO systemctl start docker
			DOCKER_STARTED=1
		fi
	elif ! (docker ps -q); then
		fail "Docker daemon is not running. Please start Docker on your computer."
	fi
}
######################################### Main ############################################
has_docker
start_docker

CMD="$1"
FILE="$2"
if [ $# -eq 2 ]; then
	import_config $2
	CONTAINER_NAME="$CPREFIX-build-$VERSION-$TARGET-$SUBTARGET"
	CONTAINER_NAME_HOSTING="$CPREFIX-host-$VERSION-$TARGET-$SUBTARGET"
	case $1 in
		build)
			run_build_packages "$CONTAINER_NAME"
			copy_packages "$CONTAINER_NAME"
			;;
		build_quick)
			run_build_packages_quick "$CONTAINER_NAME"
			copy_packages "$CONTAINER_NAME"
			;;
		shell)
			run_shell "$CONTAINER_NAME"
			;;
		host)
			run_host_packages "$CONTAINER_NAME_HOSTING"
			;;
		clean)
			run_clean "$CONTAINER_NAME"
			;;
		*) usage_and_exit $0
	esac
elif [ $# -eq 1 ]; then
	case $1 in
		cleanall)
			run_cleanall ;;
		update)
			run_update_images ;;
		bundle_patches)
			create_patches ;;
		*) usage_and_exit $0
	esac
else
	fail "Invalid number of arguments given: $#"
fi

if [ $DOCKER_STARTED -eq 1 ]; then 
	$SUDO systemctl stop docker
	echo "Stopped docker daemon."
fi
