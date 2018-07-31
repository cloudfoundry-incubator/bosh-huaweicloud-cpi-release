
module Bosh::HuaweiCloud
  class PrivateNetwork < Network
    attr_reader :nic
    attr_accessor :allowed_address_pairs

    def initialize(name, spec)
      super
      @nic = {}
      # TODO: Huawei use subnet_id instead, we need to update the fog-huaweicloud as well to support this(subnet_id=>uuid).
      @nic['subnet_id'] = subnet_id if subnet_id
    end

    def subnet_id
      @spec.fetch('cloud_properties', {})
           .fetch('subnet_id', nil)
    end
  end
end
