# WorkflowGen Upgrade Docker image
This repository contains the Dockerfiles used for the WorkflowGen Upgrade image. You can
find the image and a quick documentation on [Docker Hub](https://hub.docker.com/r/advantys/workflowgen-upgrade).
This repository is designed for documentation purposes. It provides information
on how the container is set up inside specific images and how it is configured at
runtime.

You can get started on the setup by visiting the Dockerfile for a specific platform
and get started on the configuration at runtime by visiting the
`docker-entrypoint.ps1` which is cross-platform.

# Content of this repository
This repository contains scripts for the pipeline build of this image as well as
all the needed resources to build the desired upgrade image.

**Pipeline scripts**

* azure-pipelines.yml

    Build definition file for the pipeline.

* scripts folder

    Contains multiple scripts for the pipeline build.

## Platform folders
Those folders contains all of the files necessary to build the Docker image
for a specific platform at the latest version. For example, the linux folder
has the following structure:

```
linux
    ubuntu-18.04
        Dockerfile.linux
```

The `linux` folder indicates the platform of the files underneath. The
`ubuntu-18.04` folders represent the base image currently supported
on the platform. The main image files are located in the folder that represents
the base image.

Common files between platforms are on the top level folder.

# Build a specific version
## Prerequisites

* You need Docker installed on your machine in order to build an image.

    **For Windows 10**

    Follow the instructions in the [Docker for Windows documentation page](https://docs.docker.com/docker-for-windows/).

    **For Windows Server**

    Follow the instructions in the [Docker Enterprise Edition documentation page](https://docs.docker.com/install/windows/docker-ee/).

    To verify that Docker is installed correctly, run the following command:
    ```powershell
    docker version
    ```

    **For Linux distributions**

    Check with your distribution for specific instructions.

    **For macOS**

    Follow the instructions in the [Docker for Mac documentation page](https://docs.docker.com/docker-for-mac/install/)

## Building
To build the current version of the image, execute the following command:

**Linux**
```bash
docker image build \
    -t advantys/workflowgen-upgrade:latest-ubuntu-18.04 \
    -f linux/ubuntu-18.04/Dockerfile.linux \
    .
```

**Windows**
```powershell
docker image build `
    -t advantys/workflowgen-upgrade:latest-win-ltsc2019 `
    -f windows/windowsservercore-ltsc2019/Dockerfile.windows
    .
```
