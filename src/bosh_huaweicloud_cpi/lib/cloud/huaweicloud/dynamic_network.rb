module Bosh::HuaweiCloud
  ##
  # Represents OpenStack dynamic network: where IaaS sets VM's IP
  class DynamicNetwork < PrivateNetwork
    ##
    # Creates a new dynamic network
    #
    # @param [String] name Network name
    # @param [Hash] spec Raw network spec
    def initialize(name, spec)
      super
    end

    def prepare(_huaweicloud, _security_group_ids)
      cloud_error("Network with id '#{subnet_id}' is a dynamic network. VRRP is not supported for dynamic networks") if @allowed_address_pairs
    end
  end
end
