# Rebase Docker Images

This script aims at rebasing a Docker image on top on another one. This is
usefull if you have a slim image that only has the binaries necessary for its
purpose. Rebasing the image on `busybox:latest` (the default) or `alpine:latest`
facilitates debugging and introspection through `docker exec -it ash` or
similar. This script only works with properly tagged image names, i.e.
`alpine:latest` is valid, but specifying `alpine` will fail.

For example, to rebase the `portainer/portainer-ce:2.5.0` image on busybox, you
can run the following command from the main directory of this distribution:

```shell
./rebase.sh portainer/portainer-ce:2.5.0
```
