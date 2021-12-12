# Linux Runtime

Debian userland contained within a compressed read-only disk image for use with `compat.linux.emul_path`.

[helloSystem](https://hellosystem.github.io/) comes with a utility to download and install the runtime.

![image](https://user-images.githubusercontent.com/2480569/145692845-26f31b9c-2f8a-4be2-983c-a31111f7c5db.png)

## Background

FreeBSD comes with the Linuxulator, an implementation of Linux APIs on top of the FreeBSD kernel. This is not emulation and does not slow down execution. It is just an additional set of APIs available on FreeBSD. To run applications made for Linux, a Linux userland must be available. The FreeBSD Ports and Packages contain a CentOS el7 based userland. Desktop applications, however, are mostly optimized to run on Ubuntu. And since Ubuntu is based on Debian, that his what we are using for the Linux Runtime in helloSystem.

## License

The components contained in the compressed filesystem image are subject to their respective license terms; please see `/usr/share/doc/` inside the compressed filesystem image for more information.
