module ProjectRazor
  module ModelTemplate

    class Centos7 < Redhat
      include(ProjectRazor::Logging)

      def initialize(hash)
        super(hash)
        # Static config
        @hidden      = false
        @name        = "centos_7"
        @description = "CentOS 7 Model"
        @osversion   = "7"

        from_hash(hash) unless hash == nil
      end
    end
  end
end
