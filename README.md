# Rebase Docker Images

This script aims at rebasing Docker images on top on another one. This is useful
if you have slim images that only have the (fat) binaries necessary for their
purpose. Rebasing the images on `busybox:latest` (the default) or
`alpine:latest` facilitates debugging and introspection through running commands
similar to `docker exec -it ash` on them. This script only works with properly
tagged image names, i.e. `alpine:latest` is valid, but specifying `alpine` will
fail.

## Example

Take the example of the excellent [portainer]. Inspecting the content of the
image with the following command:

```shell
docker run --rm --entrypoint=sh  portainer/portainer-ce:2.5.0 -c 'ls -lFh /'
```

would lead to the following error, as the `portainer/portainer-ce:2.5.0` image
only contains the files necessary to run [portainer].

    docker: Error response from daemon: OCI runtime create failed: container_linux.go:367: starting container process caused: exec: "sh": executable file not found in $PATH: unknown.

To be able to inspect the content of `portainer/portainer-ce:2.5.0`, you could
rebase the image on `busybox`. This will obviously add extra `busybox`-related
cruft, but would make the type of manual inspection described above possible. To
rebase it, you can run the following command from the main directory of this
distribution (`busybox:latest` is the default):

```shell
./rebase.sh portainer/portainer-ce:2.5.0
```

Once the image has been rebased on busybox, running the following command (note
the suffix `-busybox` that is automatically added to the name of the original
image):

```shell
docker run --rm --entrypoint=sh  portainer/portainer-ce:2.5.0-busybox -c 'ls -lFh /'
```

should this time show the content of the image, as rebasing the image on top of
`busybox:latest` has brought in the `sh` shell and the busybox implementation of
`ls`. You should see content similar to the following, mixing the content that
comes from the original `portainer/portainer-ce:2.5.0` but also the content of
`busybox:latest`.

```
total 179M   
drwxr-xr-x    2 root     root       12.0K Apr  7 19:47 bin/
drwxr-xr-x    2 root     root        4.0K May 27 13:02 data/
drwxr-xr-x    5 root     root         340 May 27 13:02 dev/
-rwxr-xr-x    1 root     root       58.3M Sep 16  2020 docker*
-rwxr-xr-x    1 root     root       17.1M Jan 13 22:33 docker-compose*
drwxr-xr-x    1 root     root        4.0K May 27 13:02 etc/
drwxr-xr-x    2 nobody   nobody      4.0K Apr  7 19:47 home/
-rwxr-xr-x    1 root     root       23.9M Oct 28  2020 kompose*
-rwxr-xr-x    1 root     root       42.0M Mar 25  2020 kubectl*
-rwxr-xr-x    1 root     root       37.5M May 23 21:02 portainer*
dr-xr-xr-x  149 root     root           0 May 27 13:02 proc/
drwxr-xr-x    2 root     root        4.0K May 23 21:04 public/
drwx------    2 root     root        4.0K Apr  7 19:47 root/
dr-xr-xr-x   11 root     root           0 May 27 13:02 sys/
drwxr-xr-x    1 root     root        4.0K Jan 22 00:38 tmp/
drwxr-xr-x    3 root     root        4.0K Apr  7 19:47 usr/
drwxr-xr-x    4 root     root        4.0K Apr  7 19:47 var/
```

Note that this is a constructed example. [portainer] also has images based on
[Alpine][alpine], these end with `-alpine` in their [tagname].

  [portainer]: https://portainer.io/
  [alpine]: https://hub.docker.com/_/alpine
  [tagname]: https://hub.docker.com/r/portainer/portainer-ce/tags?page=1&ordering=last_updated&name=-alpine

## Implementation

Docker images can be saved and loaded to and from tar files with the
[`save`][save] and [`load`][load] subcommands. In these tar files, there is:

+ a configuration file in JSON format with information about the image: exposed
  ports, entrypoint and command, sha256 sums for all layers, etc.
+ a manifest containing the name and tag of the image. The manifest points to
  the JSON configuration and all the layers.
+ All layers of the image, each represented itself as a tar file.

This script will [save] and untar both the base and the image to be rebased to a
temporary location. It will copy all the layers from the base image into the
image to be rebased and modify both its manifest and configuration to
incorporate all the layers from the base image. The script will keep the
remaining of the configuration as is, making sure that configuration for the
main image is kept intact. By default, the script will also change the name of
the image in a way that reflects the image that it has been rebased on. Once
done, the script will tar again and call the [load] command, which gives the
rebased image to the Docker daemon. Upon all operations completion, temporary
storage is cleaned up.

  [save]: https://docs.docker.com/engine/reference/commandline/image_save/
  [load]: https://docs.docker.com/engine/reference/commandline/image_load/