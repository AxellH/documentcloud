module DC
  module Search

    class Field

      HAS_WHITESPACE = /\s/

      attr_reader :kind, :value

      def initialize(kind, value)
        @kind, @value = kind.strip, value.strip
      end

      def attribute?
        DC::DOCUMENT_ATTRIBUTES.include? @kind.downcase.to_sym
      end

      def entity?
        #DC::ENTITY_KINDS.include? @kind.downcase.to_sym
        false
      end

      def to_s
        val = @value.match(HAS_WHITESPACE) ? "\"#{@value}\"" : @value
        "#{@kind}:#{val}"
      end

      def to_json(opts={})
        {'kind' => kind, 'value' => value}.to_json
      end

    end

  end
end