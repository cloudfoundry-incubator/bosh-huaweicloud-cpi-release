module Bosh::HuaweiCloud
  ##
  # Represents HuaweiCloud manual network: where user sets VM's IP
  class ManualNetwork < PrivateNetwork
    ##
    # Creates a new manual network
    #
    # @param [String] name Network name
    # @param [Hash] spec Raw network spec
    def initialize(name, spec)
      super
    end

    ##
    # Returns the private IP address
    #
    # @return [String] ip address
    def private_ip
      @ip
    end

    def prepare(huaweicloud, security_group_ids)
      if huaweicloud.use_nova_networking?
        @nic['v4_fixed_ip'] = @ip
      else
        @logger.debug("Creating port for IP #{@ip} in network #{subnet_id}")
        port = create_port_for_manual_network(huaweicloud, subnet_id, security_group_ids)
        @logger.debug("Port with ID #{port.id} and MAC address #{port.mac_address} created")
        @nic['port_id'] = port.id
        @spec['mac'] = port.mac_address
      end
    end

    def create_port_for_manual_network(huaweicloud, subnet_id, security_group_ids)
      port_properties = {
        network_id: subnet_id,
        fixed_ips: [{ ip_address: @ip }],
        security_groups: security_group_ids,
      }
      if @allowed_address_pairs
        cloud_error("Configured VRRP port with ip '#{@allowed_address_pairs}' does not exist.") unless vrrp_port?(huaweicloud)
        port_properties[:allowed_address_pairs] = [{ ip_address: @allowed_address_pairs }]
      end
      huaweicloud.with_huaweicloud { huaweicloud.network.ports.create(port_properties) }
    end

    def cleanup(huaweicloud)
      unless huaweicloud.use_nova_networking?
        port = huaweicloud.network.ports.get(@nic['port_id'])
        port&.destroy
      end
    end

    private

    def vrrp_port?(huaweicloud)
      vrrp_port = huaweicloud.with_huaweicloud { huaweicloud.network.ports.all(fixed_ips: "ip_address=#{@allowed_address_pairs}") }
      !(vrrp_port.nil? || vrrp_port.empty?)
    end
  end
end
