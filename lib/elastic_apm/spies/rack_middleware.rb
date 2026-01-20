# Licensed to Elasticsearch B.V. under one or more contributor
# license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# frozen_string_literal: true

module ElasticAPM
  # @api private
  module Spies
    # @api private
    class RackMiddlewareSpy
      TYPE = 'app'
      SUBTYPE = 'rack'
      ACTION = 'middleware'

      # Module to be prepended to middleware classes to instrument their call method
      # Creates a span positioned at the START of the middleware, with duration = time until next middleware starts
      module Ext
        def call(env)
          return super(env) unless ElasticAPM.running?
          return super(env) unless ElasticAPM.current_transaction

          middleware_name = self.class.name || 'Anonymous'

          # Record WHEN this middleware started
          start_timestamp = ElasticAPM::Util.micros
          start_clock = ElasticAPM::Util.monotonic_micros

          # Record the FIRST middleware timing (for Rack Stack umbrella span)
          unless env['elastic_apm.first_middleware_clock']
            env['elastic_apm.first_middleware_clock'] = start_clock
            env['elastic_apm.first_middleware_timestamp'] = start_timestamp
          end

          # Store the current middleware timing in env for the NEXT middleware to use
          prev_middleware_clock = env['elastic_apm.prev_middleware_clock']
          env['elastic_apm.prev_middleware_clock'] = start_clock

          # Create span for PREVIOUS middleware if there was one
          # This way each middleware span covers the time from its start until this middleware started
          if prev_middleware_clock && env['elastic_apm.prev_middleware_name']
            prev_name = env['elastic_apm.prev_middleware_name']
            prev_timestamp = env['elastic_apm.prev_middleware_timestamp']
            duration = start_clock - prev_middleware_clock

            # Only create span if duration > 50 microseconds
            if duration > 50
              span = ElasticAPM.start_span(
                prev_name,
                RackMiddlewareSpy::TYPE,
                subtype: RackMiddlewareSpy::SUBTYPE,
                action: RackMiddlewareSpy::ACTION
              )
              if span
                span.timestamp = prev_timestamp
                span.clock_start = prev_middleware_clock
                span.instance_variable_set(:@duration, duration)
                ElasticAPM.end_span(span)
              end
            end
          end

          # Store current middleware info for the NEXT middleware to create our span
          env['elastic_apm.prev_middleware_name'] = middleware_name
          env['elastic_apm.prev_middleware_timestamp'] = start_timestamp

          # Call the next middleware
          # If we are the LAST middleware, we must close the Rack Stack BEFORE calling the app (controller)
          # so that the controller span is NOT a child of Rack Stack
          if self.class == RackMiddlewareSpy.last_middleware_class
             # Create span for THIS middleware immediately (small duration)
             duration = 100 # 100 micros estimate
             span = ElasticAPM.start_span(
               middleware_name,
               RackMiddlewareSpy::TYPE,
               subtype: RackMiddlewareSpy::SUBTYPE,
               action: RackMiddlewareSpy::ACTION
             )
             if span
               span.timestamp = start_timestamp
               span.clock_start = start_clock
               span.instance_variable_set(:@duration, duration)
               ElasticAPM.end_span(span)
             end
             
             # Update last_middleware_end
             env['elastic_apm.last_middleware_end'] = start_clock + duration
             
             # Close the Rack Stack span NOW
             close_rack_stack_span(env)
             
             # Clear prev_middleware_name so the "after" block doesn't run
             env['elastic_apm.prev_middleware_name'] = nil
          end

          result = super(env)

          # Record when the LAST middleware finished (for Rack Stack duration)
          # Only the first middleware to return sets this (which is the deepest/last in the chain)
          env['elastic_apm.last_middleware_end'] ||= ElasticAPM::Util.monotonic_micros

          # Create span for the LAST middleware (this one) if we're the last instrumented one
          # This happens when we return and no next middleware created our span
          # AND we haven't already handled it (checked via prev_middleware_name)
          if env['elastic_apm.prev_middleware_name'] == middleware_name
            # Use a small duration estimate for the last middleware
            duration = 100  # 100 microseconds estimate
            span = ElasticAPM.start_span(
              middleware_name,
              RackMiddlewareSpy::TYPE,
              subtype: RackMiddlewareSpy::SUBTYPE,
              action: RackMiddlewareSpy::ACTION
            )
            if span
              span.timestamp = start_timestamp
              span.clock_start = start_clock
              span.instance_variable_set(:@duration, duration)
              ElasticAPM.end_span(span)
            end
            # Update last_middleware_end to be just after this middleware's span
            env['elastic_apm.last_middleware_end'] = start_clock + duration
            # Clear so we don't create duplicate
            env['elastic_apm.prev_middleware_name'] = nil

            # Close the Rack Stack span now that all middlewares are done
            # This handles cases where we didn't identify the last middleware correctly
            close_rack_stack_span(env)
          end

          result
        end

        private

        def close_rack_stack_span(env)
          rack_stack_span = env['elastic_apm.rack_stack_span']
          return unless rack_stack_span

          rack_stack_timestamp = env['elastic_apm.rack_stack_timestamp']
          rack_stack_clock_start = env['elastic_apm.rack_stack_clock_start']
          last_middleware_end = env['elastic_apm.last_middleware_end']

          return unless last_middleware_end

          duration = last_middleware_end - rack_stack_clock_start

          rack_stack_span.timestamp = rack_stack_timestamp
          rack_stack_span.clock_start = rack_stack_clock_start
          rack_stack_span.instance_variable_set(:@duration, duration)
          ElasticAPM.end_span(rack_stack_span)

          # Clear so we don't close it again
          env['elastic_apm.rack_stack_span'] = nil
        end
      end

      class << self
        attr_accessor :last_middleware_class

        def instrument_middleware(klass)
          return if klass.nil?
          return if instrumented?(klass)
          return if should_skip?(klass)

          ElasticAPM.agent&.config&.logger&.debug("Instrumenting middleware: #{klass.name}")
          klass.prepend(Ext)
          instrumented_middlewares[klass] = true
        rescue => e
          ElasticAPM.agent&.config&.logger&.warn("Failed to instrument middleware #{klass.name}: #{e.message}")
        end

        def instrumented?(klass)
          instrumented_middlewares[klass] == true
        end

        def instrumented_middlewares
          @instrumented_middlewares ||= {}
        end

        def should_skip?(klass)
          # Skip ElasticAPM's own middleware
          return true if klass.name&.start_with?('ElasticAPM')

          # Skip anonymous classes
          return true if klass.name.nil?

          false
        end

        def reset!
          @instrumented_middlewares = {}
        end
      end

      def install
        # No-op: middleware instrumentation is applied via Railtie
      end
    end
  end
end
