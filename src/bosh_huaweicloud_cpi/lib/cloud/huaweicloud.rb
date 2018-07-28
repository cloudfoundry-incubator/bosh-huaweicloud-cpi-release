module Bosh
  module HuaweiCloud; end
end

require 'fog/openstack'
require 'httpclient'
require 'json'
require 'pp'
require 'set'
require 'tmpdir'
require 'securerandom'
require 'json'
require 'membrane'
require 'netaddr'

require 'common/common'
require 'common/exec'
require 'common/thread_pool'
require 'common/thread_formatter'

require 'bosh/cpi/registry_client'
require 'bosh/cpi/redactor'
require 'cloud'
require 'cloud/huaweicloud/helpers'
require 'cloud/huaweicloud/cloud'
require 'cloud/huaweicloud/cpi_lambda'
require 'cloud/huaweicloud/huaweicloud'
require 'cloud/huaweicloud/tag_manager'

require 'cloud/huaweicloud/network_configurator'
require 'cloud/huaweicloud/loadbalancer_configurator'
require 'cloud/huaweicloud/resource_pool'
require 'cloud/huaweicloud/security_groups'
require 'cloud/huaweicloud/floating_ip'
require 'cloud/huaweicloud/network'
require 'cloud/huaweicloud/private_network'
require 'cloud/huaweicloud/dynamic_network'
require 'cloud/huaweicloud/manual_network'
require 'cloud/huaweicloud/vip_network'
require 'cloud/huaweicloud/volume_configurator'
require 'cloud/huaweicloud/response_message'
require 'cloud/huaweicloud/request_message'
require 'cloud/huaweicloud/excon_logging_instrumentor'
require 'cloud/huaweicloud/availability_zone_provider'
require 'cloud/huaweicloud/stemcell'
require 'cloud/huaweicloud/stemcell_creator'
require 'cloud/huaweicloud/instance_type_mapper'
require 'cloud/huaweicloud/server_groups'
require 'cloud/huaweicloud/server'
require 'cloud/huaweicloud/vm_factory'
require 'cloud/huaweicloud/vm_creator'

module Bosh
  module Clouds
    Huawei = Bosh::HuaweiCloud::Cloud
    Huawei = Huawei # Alias needed for Bosh::Clouds::Provider.create method
  end
end
