module Bosh::HuaweiCloud
  class SecurityGroups
    include Helpers

    def self.select_and_retrieve(huaweicloud, default_security_groups, network_spec_security_groups, resource_pool_spec_security_groups)
      picked_security_groups = pick_security_groups(
        default_security_groups,
        network_spec_security_groups,
        resource_pool_spec_security_groups,
      )

      huaweicloud_security_groups = huaweicloud.with_huaweicloud {
        retrieve_security_groups(huaweicloud)
      }

      map_to_security_groups_in_huaweicloud(picked_security_groups, huaweicloud_security_groups)
    end

    private

    def self.retrieve_security_groups(huaweicloud)
      if huaweicloud.use_nova_networking?
        huaweicloud.compute.security_groups
      else
        huaweicloud.network.security_groups
      end
    end

    def self.pick_security_groups(default_security_groups, network_spec_security_groups, resource_pool_spec_security_groups)
      return resource_pool_spec_security_groups unless resource_pool_spec_security_groups.empty?

      return network_spec_security_groups unless network_spec_security_groups.empty?

      default_security_groups
    end

    def self.map_to_security_groups_in_huaweicloud(picked_security_groups, huaweicloud_security_groups)
      picked_security_groups.map do |configured_sg|
        huaweicloud_security_group = find_huaweicloud_sg_by_name(huaweicloud_security_groups, configured_sg)
        huaweicloud_security_group ||= find_huaweicloud_sg_by_id(huaweicloud_security_groups, configured_sg)
        cloud_error("Security group `#{configured_sg}' not found") unless huaweicloud_security_group
        huaweicloud_security_group
      end
    end

    def self.find_huaweicloud_sg_by_name(huaweicloud_security_groups, security_group_name)
      huaweicloud_security_groups.find { |huaweicloud_sg| huaweicloud_sg.name == security_group_name }
    end

    def self.find_huaweicloud_sg_by_id(huaweicloud_security_groups, security_group_id)
      huaweicloud_security_groups.find { |huaweicloud_sg| huaweicloud_sg.id == security_group_id }
    end
  end
end
