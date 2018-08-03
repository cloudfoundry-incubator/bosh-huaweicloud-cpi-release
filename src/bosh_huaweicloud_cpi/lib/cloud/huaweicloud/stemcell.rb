module Bosh::HuaweiCloud
  module Stemcell
    include Helpers

    attr_reader :id, :image_id

    def initialize(logger, huaweicloud, id)
      @image_id = id
      @huaweicloud = huaweicloud
      @logger = logger
    end

    def self.create(logger, huaweicloud, id)
      regex = / light$/

      if id.match(regex)
        LightStemcell.new(logger, huaweicloud, id.gsub(regex, ''))
      else
        HeavyStemcell.new(logger, huaweicloud, id)
      end
    end

    def validate_existence
      image = @huaweicloud.with_huaweicloud { @huaweicloud.image.images.find_by_id(image_id) }
      cloud_error("Image `#{id}' not found") if image.nil?
      @logger.debug("Using image: `#{id}'")
    end
  end

  class HeavyStemcell
    include Stemcell

    def initialize(logger, huaweicloud, id)
      super
      @id = id
    end

    def delete
      image = @huaweicloud.with_huaweicloud { @huaweicloud.image.images.find_by_id(image_id) }
      if image
        @huaweicloud.with_huaweicloud { image.destroy }
        @logger.info("Stemcell `#{image_id}' is now deleted")
      else
        @logger.info("Stemcell `#{image_id}' not found. Skipping.")
      end
    end
  end

  class LightStemcell
    include Stemcell

    def initialize(logger, huaweicloud, id)
      super
      @id = "#{id} light"
    end

    def delete
      @logger.info("NoOP: Deleting light stemcell '#{id}'")
    end
  end
end
