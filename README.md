Bosh HuaweiCloud CPI release
==============================

- Website: https://bosh.io/docs/build-cpi/

bosh-huaweicloud-cpi-release is a bosh Provider for Huaweicloud.
It is based on [bosh-openstack-cpi-release](https://github.com/cloudfoundry-incubator/bosh-openstack-cpi-release)
which is a standard Bosh OpenStack CPI. BOSH-Huaweicloud-CPI has renamed OpenStack with Huaweicloud
and added some enhancements to interact with the many resources supported by Huaweicloud.


## Enhancements

- **Network**: fully supporting huaweicloud network resources, including vpc, subnet, nic and so on.

Maintainers
-----------

This provider plugin is maintained by:

* Edward Lee ([@freesky-edward](https://github.com/freesky-edward))
* zhongjun ([@zhongjun](https://github.com/zhongjun2))
* tommylikehu ([tommylikehu@gmail.com](https://github.com/TommyLike))


### How to make release

- Clone this repo
- Install bosh-cli
- Download `go1.8.1.linux-amd64.tar.gz` from https://storage.googleapis.com/golang/go1.8.1.linux-amd64.tar.gz
- Create bosh release

```
$ git clone https://github.com/zhongjun2/bosh-huaweicloud-cpi-release.git
$ cd bosh-huaweicloud-cpi-release
$ bosh create-release --force --tarball=../bosh-huaweicloud-cpi.tgz
```

## Usage

### Prepare your `Huawei Cloud` environment

- Create a vpc with switch and get `subnet_id`
- Create security group get `security_group_name`
- Create a key pair, get `key_pair_name` and download it private key, like bosh.pem

### Install bosh in Huawei Cloud

- Clone [bosh-deployment](https://github.com/zhongjun2/bosh-deployment) repo from github

```
$ git clone https://github.com/zhongjun2/bosh-deployment.git
$ cd bosh-deployment
```

use this command, modify the parameters

```
bosh create-env bosh-deployment/bosh.yml --state=state.json \
 --vars-store=creds.yml \
 -o bosh-deployment/huaweicloud/cpi.yml \
 -v director_name=my-bosh \
 -v internal_cidr=192.168.0.0/24 \
 -v internal_gw=192.168.0.1 \
 -v internal_ip=192.168.0.2 \
 -v subnet_id=... \
 -v default_security_groups=[bosh] \
 -v region=cn-north-1 \
 -v auth_url=https://iam.cn-north-1.myhwclouds.com/v3 \
 -v az=cn-north-1a \
 -v default_key_name=bosh \
 -v huaweicloud_password=... \
 -v huaweicloud_username=... \
 -v huaweicloud_domain=... \
 -v huaweicloud_project=cn-north-1 \
 -v private_key=bosh.pem
```
