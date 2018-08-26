require 'dry/monads/list'

module Dry
  module Monads
    # An implementation of do-notation.
    #
    # @see Do.for
    module Do
      # @private
      class Halt < StandardError
        # @private
        attr_reader :result

        def initialize(result)
          super()

          @result = result
        end

        # @return [Proc]
        def self.[](result)
          -> * { raise self, result, caller }
        end
      end

      # Generates a module that passes a block to methods
      # that either unwraps a single-valued monadic value or halts
      # the execution.
      #
      # @example A complete example
      #
      #   class CreateUser
      #     include Dry::Monads::Result::Mixin
      #     include Dry::Monads::Try::Mixin
      #     include Dry::Monads::Do.for(:call)
      #
      #     attr_reader :user_repo
      #
      #     def initialize(:user_repo)
      #       @user_repo = user_repo
      #     end
      #
      #     def call(params)
      #       json = yield parse_json(params)
      #       hash = yield validate(json)
      #
      #       user_repo.transaction do
      #         user = yield create_user(hash[:user])
      #         yield create_profile(user, hash[:profile])
      #       end
      #
      #       Success(user)
      #     end
      #
      #     private
      #
      #     def parse_json(params)
      #       Try(JSON::ParserError) {
      #         JSON.parse(params)
      #       }.to_result
      #     end
      #
      #     def validate(json)
      #       UserSchema.(json).to_monad
      #     end
      #
      #     def create_user(user_data)
      #       Try(Sequel::Error) {
      #         user_repo.create(user_data)
      #       }.to_result
      #     end
      #
      #     def create_profile(user, profile_data)
      #       Try(Sequel::Error) {
      #         user_repo.create_profile(user, profile_data)
      #       }.to_result
      #     end
      #   end
      #
      # @param [Array<Symbol>] methods
      # @return [Module]
      def self.for(*methods)
        mod = Module.new do
          methods.each { |m| Do.wrap_method(self, m) }
        end

        Module.new do
          singleton_class.send(:define_method, :included) do |base|
            base.prepend(mod)
          end
        end
      end

      # @api private
      def self.included(base)
        super

        # Actually mixes in Do::All
        require 'dry/monads/do/all'
        base.include All
      end

      protected

      using Module.new { # refinements for results coercion.
        refine Array do
          def or_one
            one? ? yield(first) : self
          end

          def coerce_or(results) [List.coerce(self).traverse] end
        end

        refine List do
          def coerce_or(results) [traverse] end
        end

        refine Object do
          def coerce_or(results) results end
        end
      } # using refinements for results coercion

      # @private
      def self.wrap_method(target, method)
        target.module_eval(<<-RUBY, __FILE__, __LINE__ + 1)
          def #{ method }(*)
            if block_given?
              super
            else
              super do |*ms|
                ms.or_one { |o| o.coerce_or(ms) }
                  .map(&:to_monad)
                  .map { |m| m.or(&Do::Halt[m]) }
                  .map(&:value!)
                  .or_one(&:itself)
              end
            end
          rescue Halt => e
            e.result
          end
        RUBY
      end
    end
  end
end
