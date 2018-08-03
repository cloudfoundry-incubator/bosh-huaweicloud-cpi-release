module Bosh::HuaweiCloud
  ##
  # Represents OpenStack vip network: where users sets VM's IP (floating IP's
  # in OpenStack)
  class VipNetwork < Network
    ##
    # Creates a new vip network
    #
    # @param [String] name Network name
    # @param [Hash] spec Raw network spec
    def initialize(name, spec)
      super
    end

    ##
    # Configures OpenStack vip network
    #
    # @param [Bosh::HuaweiCloud::Huawei] huaweicloud
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server to
    #   configure
    def configure(huaweicloud, server, network_id)
      cloud_error("No IP provided for vip network `#{@name}'") if @ip.nil?

      huaweicloud.with_huaweicloud do
        FloatingIp.reassociate(huaweicloud, @ip, server, network_id)
      end
    end
  end
end
